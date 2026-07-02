//
// LocalNetworkPermission.swift
//
// iOS has NO query or request API for the Local Network permission — the
// system prompt fires lazily on the app's first local-network activity and
// the decision persists per-install (delete + reinstall to reset). This is
// the DTS-sanctioned workaround: publish a Bonjour service and browse for
// it. Finding our own service proves the grant; a browser parked in
// `.waiting` with the DNS policy error proves denial; anything else within
// the timeout stays `.unknown` (e.g. the prompt is on screen, unanswered).
//
// Why this matters for Retrace: DAT 0.8's WiFi video transport AND the
// `_retrace._tcp` server discovery both die *silently* when this permission
// is denied — the SDK just stays on Bluetooth and Bonjour finds nothing.
// This probe makes the state visible ([LocalNet] logs) and actionable
// (Settings deep-link alert wired in CameraAccessApp).
//
// The probe uses a dedicated `_retrace-lnp._tcp` type (declared in
// Info.plist NSBonjourServices) so the fake service can never confuse the
// DAT SDK's `_bonjour._tcp` browse or our own `_retrace._tcp` discovery.
//

import Foundation
import Network

@MainActor
final class LocalNetworkPermission: ObservableObject {
  static let shared = LocalNetworkPermission()

  enum Status: Equatable {
    case unknown   // not probed yet, probe timed out, or prompt unanswered
    case granted
    case denied    // definitive: mDNS policy-denied error observed
  }

  @Published private(set) var status: Status = .unknown
  /// Flips true (once per run) when a probe returns a definitive denial.
  /// `CameraAccessApp` presents the Settings deep-link alert off this.
  @Published var showDeniedAlert = false

  private var probeTask: Task<Status, Never>?
  private var alertShownThisRun = false

  /// Persisted grant marker. The probe itself is NOT free: it publishes +
  /// browses Bonjour with peer-to-peer enabled for up to 10s, which powers
  /// up AWDL — the same radio subsystem the DAT SDK's WiFi Direct video
  /// link uses. Probing on every launch risks contending with a session's
  /// link join, so once a grant is observed we persist it and never probe
  /// again (a later revocation surfaces as WiFi video silently degrading;
  /// the user can re-check via Settings).
  private static let grantedDefaultsKey = "retrace.localNetworkPermissionGranted"

  private init() {
    if UserDefaults.standard.bool(forKey: Self.grantedDefaultsKey) {
      status = .granted
    }
  }

  private nonisolated static let probeType = "_retrace-lnp._tcp"
  /// kDNSServiceErr_PolicyDenied / kDNSServiceErr_NoAuth — what mDNSResponder
  /// returns when the Local Network permission is off for this app.
  private nonisolated static let deniedDNSCodes: Set<Int32> = [-65570, -65555]

  /// Log the last-known state WITHOUT probing. Use this at glasses-session
  /// start: an active probe publishes + browses Bonjour with peer-to-peer
  /// enabled, which would run concurrently with the DAT SDK's own WiFi
  /// link-lease negotiation — contention we don't want at exactly that
  /// moment. Active probing happens at app launch (`check`).
  func logStatus(context: String) {
    switch status {
    case .granted:
      print("[LocalNet] Local Network permission: GRANTED (cached) (\(context))")
    case .denied:
      print("[LocalNet] ⚠️ Local Network permission: DENIED (cached) (\(context)) — WiFi glasses video and server discovery are blocked; enable it in Settings → Privacy & Security → Local Network → Retrace")
    case .unknown:
      print("[LocalNet] Local Network permission: undetermined (\(context)) — launch probe hasn't resolved; not re-probing during session start")
    }
  }

  /// Trigger the system prompt if undetermined and resolve the current state.
  /// Safe to call repeatedly; concurrent callers share one in-flight probe.
  /// A `.granted` result is cached for the run; `.denied`/`.unknown` re-probe
  /// so a Settings flip mid-run is picked up on the next app foreground.
  @discardableResult
  func check(context: String) async -> Status {
    if status == .granted { return .granted }
    if let inFlight = probeTask {
      return await inFlight.value
    }
    print("[LocalNet] probe start (\(context))")
    let task = Task { await Self.probe() }
    probeTask = task
    let result = await task.value
    probeTask = nil
    status = result
    switch result {
    case .granted:
      UserDefaults.standard.set(true, forKey: Self.grantedDefaultsKey)
      print("[LocalNet] Local Network permission: GRANTED (\(context)) — persisted; no further launch probes")
    case .denied:
      print("[LocalNet] ⚠️ Local Network permission: DENIED (\(context)) — WiFi glasses video and server discovery are blocked; enable it in Settings → Privacy & Security → Local Network → Retrace")
      if !alertShownThisRun {
        alertShownThisRun = true
        showDeniedAlert = true
      }
    case .unknown:
      print("[LocalNet] Local Network permission: undetermined after probe (\(context)) — prompt may be awaiting an answer")
    }
    return result
  }

  private nonisolated static func probe() async -> Status {
    await withCheckedContinuation { continuation in
      let queue = DispatchQueue(label: "com.retrace.localnet-probe")
      let serviceName = "retrace-lnp-\(UUID().uuidString.prefix(8))"

      guard let listener = try? NWListener(using: .tcp) else {
        // Can't even build the probe — don't report a scary false denial.
        continuation.resume(returning: .unknown)
        return
      }
      listener.service = NWListener.Service(name: serviceName, type: probeType)

      let params = NWParameters.tcp
      params.includePeerToPeer = true
      let browser = NWBrowser(for: .bonjour(type: probeType, domain: nil), using: params)

      var finished = false
      // Everything below runs on `queue`, so `finished` needs no lock.
      let finish: (Status) -> Void = { result in
        guard !finished else { return }
        finished = true
        // Nil the handlers BEFORE cancel: they strongly capture this closure,
        // which strongly captures browser/listener — without this, each
        // object owns a closure that owns the object (retain cycle) and both
        // leak on every non-granted probe.
        browser.browseResultsChangedHandler = nil
        browser.stateUpdateHandler = nil
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        browser.cancel()
        listener.cancel()
        continuation.resume(returning: result)
      }

      browser.browseResultsChangedHandler = { results, _ in
        for result in results {
          if case .service(let name, _, _, _) = result.endpoint, name == serviceName {
            finish(.granted)
            return
          }
        }
      }
      browser.stateUpdateHandler = { state in
        if case .waiting(let error) = state,
          case .dns(let code) = error, deniedDNSCodes.contains(code) {
          finish(.denied)
        }
      }
      listener.stateUpdateHandler = { state in
        if case .waiting(let error) = state,
          case .dns(let code) = error, deniedDNSCodes.contains(code) {
          finish(.denied)
        }
      }
      // Empty handler keeps inbound probe connections from erroring the listener.
      listener.newConnectionHandler = { connection in connection.cancel() }

      listener.start(queue: queue)
      browser.start(queue: queue)

      // Generous ceiling: while the system prompt is on screen no results
      // arrive, and we must NOT misreport that as a denial.
      queue.asyncAfter(deadline: .now() + 10.0) {
        finish(.unknown)
      }
    }
  }
}
