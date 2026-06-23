//
// DeviceSessionManager.swift
//
// Single source of truth for DAT `DeviceSession` lifecycle. Multi-consumer
// refcounted manager that serves all four consumers in the app:
//   - "expert"      : StreamSessionViewModel (recording)
//   - "gemini-live" : GeminiLiveSessionBase (Coaching + Troubleshoot)
//   - "lens"        : LensDisplayCoordinator (display capability)
//   - "wearables-vm": WearablesViewModel (hasActiveDevice observation)
//
// Modeled on `samples/CameraAccess/CameraAccess/ViewModels/DeviceSessionManager.swift`
// in `facebook/meta-wearables-dat-ios` (the 0.7 reference), extended for our needs:
//   - Multiple consumers acquire/release independently
//   - Two AutoDeviceSelectors exposed (filterless + supportsDisplay) so the
//     Settings "Connected" pill and the lens path don't need their own
//   - Single shared DeviceSession across capabilities (Stream + Display)
//     per the SDK's capability-composition model — both addStream and
//     addDisplay attach to the same DeviceSession; a second createSession
//     against the same physical device throws sessionAlreadyExists.
//   - withThrowingTaskGroup races stateStream() vs errorStream() so a
//     `datAppOnTheGlassesUpdateRequired` fires immediately instead of
//     timing out after 5 s (the bug in our old awaitDeviceSessionStarted).
//   - Internal `lifecycleTask` serializes acquire/release across rapid
//     view dismiss/remount — subsumes StreamSessionViewModel's static
//     `teardownInFlight` gate.
//
// Phase 1: manager is dead code. Consumers don't call it yet. Wired into
// CameraAccessApp.swift via @StateObject + .environmentObject so it's
// available everywhere, but no behavior changes until Phase 2+.
//

import Combine
import Foundation
import MWDATCore
import SwiftUI

@MainActor
final class DeviceSessionManager: ObservableObject {

  // MARK: - Public observable state

  /// True when ANY device is reachable right now (filterless AutoDeviceSelector).
  /// This is the SDK's *session-eligibility* signal — "is there a device I can
  /// start a `DeviceSession` on this instant" — NOT raw Bluetooth connection
  /// state. Used by the Expert "no active device" launch guard and the launch
  /// gate. Do **not** use it for a "Connected" pill: a paired, link-up,
  /// compatible device can still report `false` here if the auto-selector
  /// hasn't latched it as session-eligible yet. Use `hasConnectedDevice` for
  /// connection-status UI.
  @Published private(set) var hasAnyActiveDevice: Bool = false

  /// True when ANY paired device reports `LinkState.connected` — i.e. the DAT
  /// transport link to the glasses is actually up. This is the honest answer
  /// to "are the glasses connected right now", independent of whether the
  /// auto-selector has picked one for a session. Drives the Settings
  /// "Connected" pill. Fed by per-device `addLinkStateListener` (event-driven,
  /// no polling).
  @Published private(set) var hasConnectedDevice: Bool = false

  /// True when a display-capable device (Meta Ray-Ban Display) is reachable.
  /// Drives the lens path's selector requirement.
  @Published private(set) var hasDisplayCapableDevice: Bool = false

  /// `DeviceSessionError`s observed on the active session's error stream are
  /// fanned out here so non-display consumers (which don't subscribe to
  /// errorStream themselves) can still react.
  let sessionErrors = PassthroughSubject<DeviceSessionError, Never>()

  /// Last observed DAT `Permission.camera` status, refreshed every time
  /// `cameraPermissionStatus()` or `ensureCameraPermissionGranted()` runs.
  /// Published so onboarding / Profile UI can react without polling.
  /// `nil` until the first query.
  ///
  /// Note: there is no DAT-side microphone permission in 0.7.0 — the
  /// `MWDATCore.Permission` enum has only `.camera`. iOS-native
  /// `AVAudioApplication.requestRecordPermission()` is the canonical
  /// path for mic access; it's prompted at session start by
  /// `AudioSessionManager.requestMicrophonePermission()`.
  @Published private(set) var cameraPermission: PermissionStatus?

  // MARK: - Public types

  enum DeviceRequirements: Equatable {
    /// Any device is acceptable.
    case any
    /// Caller needs `Device.supportsDisplay() == true` (lens path).
    case requiresDisplay
  }

  enum AcquireError: Error, CustomStringConvertible {
    case noEligibleDevice
    case requirementsConflictWithActiveSession(DeviceRequirements)
    case sessionStartFailed(DeviceSessionError)
    case startTimedOut
    case cancelled
    /// DAT `Permission.camera` was not `.granted` at the time of acquire.
    /// The acquire path does not prompt — the prompt happens in onboarding or
    /// via an explicit `ensureCameraPermissionGranted()` call from the consumer.
    /// Without this permission, `wearables.devices` stays empty and
    /// `createSession` would throw `.noEligibleDevice` further down anyway
    /// (per the SDK contract — a device does not appear in `devicesStream`
    /// until the user has granted at least one DAT permission via Meta AI).
    case cameraPermissionDenied
    /// `checkPermissionStatus` / `requestPermission` itself threw — distinct
    /// from a user denial. Usually means the SDK couldn't reach Meta AI.
    case permissionCheckFailed(String)

    var description: String {
      switch self {
      case .noEligibleDevice:
        return "noEligibleDevice"
      case .requirementsConflictWithActiveSession(let req):
        return "requirementsConflictWithActiveSession(\(req))"
      case .sessionStartFailed(let inner):
        return "sessionStartFailed(\(inner))"
      case .startTimedOut:
        return "startTimedOut"
      case .cancelled:
        return "cancelled"
      case .cameraPermissionDenied:
        return "cameraPermissionDenied"
      case .permissionCheckFailed(let inner):
        return "permissionCheckFailed(\(inner))"
      }
    }
  }

  // MARK: - Private state

  private let wearables: WearablesInterface

  /// Filterless selector — drives `hasAnyActiveDevice` and is used for
  /// `.any` acquires. `var`, not `let`: an `AutoDeviceSelector` created before
  /// any device is available (app launched pre-permission) can stay latched at
  /// "no device" and never recover when permission is later granted mid-session
  /// — so `restartDeviceMonitoring()` recreates it on the permission→granted
  /// transition, replicating what a cold app launch does.
  private var anyDeviceSelector: AutoDeviceSelector

  /// Display-capable filter selector — drives `hasDisplayCapableDevice`
  /// and is used for `.requiresDisplay` acquires. `var` for the same
  /// post-permission-recovery reason as `anyDeviceSelector`.
  private var displayDeviceSelector: AutoDeviceSelector

  /// The one active DeviceSession (if any). At most one session per
  /// physical device at a time; consumers share it.
  private var deviceSession: DeviceSession?

  /// Bookkeeping: which consumer labels currently hold a lease on the
  /// active session. Keyed by string consumer label so a re-acquire
  /// after a SwiftUI dismiss/remount is recognized as the same consumer
  /// (preserves the teardownInFlight serialization semantic).
  private var leases: [String: Date] = [:]

  /// Serializes acquire/release operations so a release-in-flight cannot
  /// race with a fresh acquire. Replaces StreamSessionViewModel's static
  /// `Self.teardownInFlight` gate.
  private var lifecycleTask: Task<Void, Never>?

  /// Set true whenever a session was torn down this cycle (via
  /// `teardownActiveSession`). `acquire()` consumes it to insert a brief settle
  /// before a fresh `createSession`: the SDK reports `DeviceSession.stopped`
  /// *before* its WARP transport threads actually exit, so recreating too fast
  /// stands up a second WARP stack alongside the one still draining — the
  /// `DCTEvent` use-after-free crash (deref of a freed `datax_list` in
  /// `tryOpenChannel`). Heuristic mitigation for an SDK-internal lifecycle gap.
  private var recentlyToreDown: Bool = false

  /// Per-device `LinkState` cache + listener tokens, keyed by `DeviceIdentifier`.
  /// Refreshed whenever `devicesStream()` emits and whenever a device's
  /// `addLinkStateListener` fires. Derives `hasConnectedDevice`.
  private var deviceLinkState: [DeviceIdentifier: LinkState] = [:]
  private var linkStateTokens: [DeviceIdentifier: AnyListenerToken] = [:]

  /// Raw, un-derived signals straight from the two `AutoDeviceSelector`s. The
  /// published `hasAnyActiveDevice` / `hasDisplayCapableDevice` are *derived*
  /// from these OR-ed with "a connected, compatible device exists" — because
  /// the filterless `AutoDeviceSelector` can refuse to latch when more than one
  /// device is paired and one reports `Compatibility.undefined` (observed with
  /// a Ray-Ban Display + Oakley Vanguard paired simultaneously). See
  /// `recomputeConnectivity()` and `connectedCompatibleDeviceId(_:)`.
  private var selectorHasAnyActive: Bool = false
  private var selectorHasDisplayActive: Bool = false

  /// Background observation tasks.
  private var anyDeviceMonitorTask: Task<Void, Never>?
  private var displayDeviceMonitorTask: Task<Void, Never>?
  private var deviceLinkMonitorTask: Task<Void, Never>?
  private var sessionStateTask: Task<Void, Never>?
  private var sessionErrorTask: Task<Void, Never>?
  private var registrationTask: Task<Void, Never>?

  // MARK: - Init

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.anyDeviceSelector = AutoDeviceSelector(wearables: wearables)
    self.displayDeviceSelector = AutoDeviceSelector(
      wearables: wearables,
      filter: { $0.supportsDisplay() }
    )
    startDeviceMonitoring()
    startLinkStateMonitoring()
    observeRegistration()
  }

  deinit {
    anyDeviceMonitorTask?.cancel()
    displayDeviceMonitorTask?.cancel()
    deviceLinkMonitorTask?.cancel()
    sessionStateTask?.cancel()
    sessionErrorTask?.cancel()
    registrationTask?.cancel()
    lifecycleTask?.cancel()
  }

  // MARK: - Public API — permissions

  /// Non-prompting query of the current DAT `Permission.camera` status.
  /// Refreshes the published `cameraPermission` property as a side effect
  /// so the latest value is observable by any UI bound to it.
  ///
  /// Background — per the DAT 0.7 contract
  /// (https://wearables.developer.meta.com/docs/build-integration-ios/):
  /// "A device will not appear in the devicesStream until the user has
  /// granted at least one permission (for example, camera)." That makes
  /// this status the upstream gate for everything else: registration can
  /// be `.registered` and the glasses can be Bluetooth-connected, but
  /// `createSession` will still throw `noEligibleDevice` until camera
  /// permission flips to `.granted`.
  @discardableResult
  func cameraPermissionStatus() async throws -> PermissionStatus {
    do {
      let status = try await wearables.checkPermissionStatus(.camera)
      updateCameraPermission(status)
      return status
    } catch {
      log("cameraPermissionStatus threw: \(error)")
      throw AcquireError.permissionCheckFailed(error.localizedDescription)
    }
  }

  /// Single writer for `cameraPermission`. Detects the no→yes transition and,
  /// on grant, restarts device monitoring with fresh selectors. This is the
  /// fix for "grant permission mid-session → stays Not Connected until restart":
  /// the DAT contract only surfaces devices *after* a permission is granted, so
  /// the selectors/streams created at launch (pre-permission) never see the
  /// device. Recreating them on the grant edge mirrors a cold launch.
  private func updateCameraPermission(_ status: PermissionStatus) {
    let was = cameraPermission
    cameraPermission = status
    if status == .granted, was != .granted {
      log("cameraPermission \(was.map { String(describing: $0) } ?? "nil") → granted; restarting device monitoring")
      restartDeviceMonitoring()
    }
  }

  /// Check-then-prompt for DAT `Permission.camera`. If the permission is
  /// already `.granted`, returns immediately without surfacing the Meta AI
  /// deep-link. Otherwise calls `wearables.requestPermission(.camera)`,
  /// which routes the user through Meta AI to accept or deny and returns
  /// when control comes back to our app.
  ///
  /// Intended call sites: (1) onboarding's permissions screen — eager
  /// first prompt during first-launch flow; (2) a future "Grant glasses
  /// camera access" button on the Profile / Server Settings screens for
  /// users who skipped onboarding or revoked later. **NOT called from
  /// `acquire(...)`** — by design, mid-session-start is the wrong time
  /// to bounce the user out to Meta AI. Acquire surfaces
  /// `.cameraPermissionDenied` and lets the caller decide whether to
  /// re-prompt or just show a CTA.
  @discardableResult
  func ensureCameraPermissionGranted() async throws -> PermissionStatus {
    let current = try await cameraPermissionStatus()
    if current == .granted { return .granted }
    log("ensureCameraPermissionGranted: not granted (\(current)) — prompting via Meta AI")
    do {
      let after = try await wearables.requestPermission(.camera)
      updateCameraPermission(after)
      log("ensureCameraPermissionGranted: post-prompt status = \(after)")
      log("ensureCameraPermissionGranted: post-prompt devices=\(wearables.devices.count) hasAnyActive=\(hasAnyActiveDevice) hasDisplay=\(hasDisplayCapableDevice)")
      return after
    } catch {
      log("ensureCameraPermissionGranted: requestPermission threw: \(error)")
      throw AcquireError.permissionCheckFailed(error.localizedDescription)
    }
  }

  /// `true` iff DAT camera permission is `.granted`. Aliases
  /// `cameraPermissionStatus() == .granted` for compatibility with
  /// older call sites that expected a combined camera+microphone gate
  /// (the DAT mic permission turned out not to exist in the 0.7.0
  /// `Permission` enum — iOS-native record permission is the only
  /// mic gate, and `AudioSessionManager.requestMicrophonePermission()`
  /// handles that at session start).
  func allGlassesPermissionsGranted() async throws -> Bool {
    return try await cameraPermissionStatus() == .granted
  }

  /// Combined check-then-prompt for the DAT permissions needed by a
  /// glasses session. As of 0.7.0 that's just camera (no DAT-side mic
  /// permission). The iOS-native record permission is prompted at
  /// session start by `AudioSessionManager` and isn't part of this
  /// pre-flight gate.
  @discardableResult
  func ensureAllGlassesPermissionsGranted() async throws -> Bool {
    return try await ensureCameraPermissionGranted() == .granted
  }

  /// Result of a non-prompting camera-permission probe that distinguishes
  /// "no device connected yet" from a genuine denial. The plain
  /// `cameraPermissionStatus()` throws `PermissionError.noDevice` whenever no
  /// device has an established DAT connection at the moment of the call — which
  /// is *not* a permission problem and must not surface an "Allow camera" CTA.
  enum CameraPermissionProbe: Equatable, Sendable {
    /// Camera permission is granted.
    case granted
    /// Camera permission is explicitly denied — surface the request CTA.
    case denied
    /// No device has an active DAT connection yet (`.noDevice` family). Caller
    /// should wait and re-probe once a device connects — NOT prompt.
    case noConnectedDevice
    /// Meta AI missing / SDK internal error / request already in flight —
    /// needs user action other than waiting.
    case unavailable(String)
  }

  /// Non-prompting probe that maps the SDK's typed `PermissionError` into the
  /// tri-state above so callers can tell "glasses aren't connected yet" apart
  /// from "user denied camera access". Refreshes `cameraPermission` on success.
  func probeCameraPermission() async -> CameraPermissionProbe {
    // `checkPermissionStatus` is typed-throws `PermissionError`, so the single
    // `catch` binds `error` as `PermissionError` — no `as?` cast needed.
    do {
      let status = try await wearables.checkPermissionStatus(.camera)
      updateCameraPermission(status)
      return status == .granted ? .granted : .denied
    } catch {
      switch error {
      case .noDevice, .noDeviceWithConnection, .connectionError, .requestTimeout:
        return .noConnectedDevice
      case .metaAINotInstalled, .requestInProgress, .internalError:
        return .unavailable(error.description)
      @unknown default:
        return .unavailable(error.description)
      }
    }
  }

  // MARK: - Public API — sessions

  /// Acquire a started DeviceSession for the named consumer.
  ///
  /// Multiple consumers may acquire the same underlying session — they
  /// share it, and the session is not stopped until every consumer has
  /// released. If a release is mid-flight, the acquire awaits it first.
  ///
  /// If the requirements conflict with the currently-active session
  /// (e.g. caller requires display but the active session is on a
  /// non-display device), throws `.requirementsConflictWithActiveSession`.
  ///
  /// Errors during start (`datAppOnTheGlassesUpdateRequired`, etc.) fire
  /// from the SDK's `errorStream()` and are raced against `stateStream()`'s
  /// transition to `.started`, so failures surface immediately rather
  /// than waiting for a timeout.
  /// Names of the currently-paired Meta devices, from `Device.nameOrId()`.
  /// `wearables.devices` only ever contains Meta glasses (not AirPods or other
  /// BT peripherals), so these are exactly the names `AudioSessionManager`
  /// matches against `AVAudioSessionPortDescription.portName` to pin the
  /// glasses' BT HFP input. Returns an empty array when no glasses are paired —
  /// the audio layer then falls back to its name heuristics / iOS default.
  static func pairedDeviceNames(from wearables: WearablesInterface) -> [String] {
    wearables.devices.compactMap { wearables.deviceForIdentifier($0)?.nameOrId() }
  }

  func acquire(
    consumerLabel: String,
    requirements: DeviceRequirements = .any
  ) async throws -> DeviceSession {
    // Wait for any release in flight before mutating state.
    await lifecycleTask?.value

    // Permission gate. DAT 0.7 contract: a device does not appear in
    // `devicesStream` until `Permission.camera` is granted via Meta AI —
    // so without this, `createSession` further down would just throw
    // `.noEligibleDevice` after the awaitMatchingDevice timeout. Surface
    // the real reason instead. Non-prompting: the prompt belongs in
    // onboarding (via `ensureCameraPermissionGranted()`), not mid-acquire.
    let permission = try await cameraPermissionStatus()
    guard permission == .granted else {
      log("acquire(\(consumerLabel)) → blocked, cameraPermission=\(permission)")
      throw AcquireError.cameraPermissionDenied
    }

    // Already-active session: reuse if requirements are satisfied. Per Meta's
    // session-lifecycle skill (`mwdat-ios:session-lifecycle`): "Don't restart
    // during `paused` — wait for `started` or `stopped`." The same caution
    // applies to `.starting` (transient — racing in with a fresh createSession
    // would either be redundant or throw `sessionAlreadyExists`) and
    // `.stopping` (must reach `.stopped` before we can create a replacement).
    if let session = deviceSession {
      switch session.state {
      case .started:
        guard requirementsSatisfied(by: session, requirements: requirements) else {
          throw AcquireError.requirementsConflictWithActiveSession(requirements)
        }
        leases[consumerLabel] = Date()
        log("acquire(\(consumerLabel), req=\(requirements)) → reuse existing session, leases=\(leases.count)")
        return session

      case .paused, .starting:
        log("acquire(\(consumerLabel)) → existing session in .\(session.state); waiting for terminal/started state")
        let resumed = await awaitSessionResumedOrTerminated(session: session, timeout: 10.0)
        if resumed,
          let current = deviceSession,
          current === session,
          current.state == .started {
          guard requirementsSatisfied(by: current, requirements: requirements) else {
            throw AcquireError.requirementsConflictWithActiveSession(requirements)
          }
          leases[consumerLabel] = Date()
          log("acquire(\(consumerLabel)) → resumed to .started, leases=\(leases.count)")
          return current
        }
        // Stopped (or timed out) while we waited — clear and fall through to
        // a fresh createSession.
        if deviceSession === session {
          log("acquire(\(consumerLabel)) → previous session terminated while waiting; will create fresh")
          deviceSession = nil
          stopSessionObservers()
        }

      case .stopping:
        log("acquire(\(consumerLabel)) → existing session in .stopping; waiting for .stopped before recreating")
        await waitForSessionStopped(session)
        if deviceSession === session {
          deviceSession = nil
          stopSessionObservers()
        }

      case .stopped:
        deviceSession = nil
        stopSessionObservers()

      @unknown default:
        log("acquire(\(consumerLabel)) → existing session in unknown state \(session.state); dropping")
        deviceSession = nil
        stopSessionObservers()
      }
    }

    // Create a fresh session. Before calling `wearables.createSession`,
    // make sure a matching device is actually present — registration
    // flaps (e.g. user middle-pinches to exit a session on the glasses,
    // glasses drop the registration, glasses re-register a beat later)
    // can leave a window where `wearables.registrationState` is back to
    // `.registered` but the `AutoDeviceSelector` hasn't yet emitted a
    // matched device. `createSession` would throw `.noEligibleDevice`
    // synchronously in that window. Poll briefly for the matching
    // `has*ActiveDevice` to flip true.
    await awaitMatchingDevice(requirements: requirements, timeout: 3.0)

    // Prefer an explicit selector for a known connected+compatible device.
    // The filterless `AutoDeviceSelector` can stall at `nil` when a second
    // paired device reports `Compatibility.undefined` (e.g. an Oakley Vanguard
    // alongside the Ray-Ban Display), throwing `noEligibleDevice` even though a
    // perfectly usable Display is connected. Targeting the device by id with a
    // `SpecificDeviceSelector` sidesteps the auto-pick ambiguity. Fall back to
    // the auto-selector when no connected+compatible device is resolvable.
    let requiresDisplay = (requirements == .requiresDisplay)
    let selector: any DeviceSelector
    if let targetId = connectedCompatibleDeviceId(requiresDisplay: requiresDisplay) {
      selector = SpecificDeviceSelector(device: targetId)
      log("acquire(\(consumerLabel)) → SpecificDeviceSelector(\(wearables.deviceForIdentifier(targetId)?.nameOrId() ?? targetId))")
    } else {
      selector = requiresDisplay ? displayDeviceSelector : anyDeviceSelector
      log("acquire(\(consumerLabel)) → falling back to AutoDeviceSelector (no connected+compatible device resolved)")
    }
    do {
      let paired = wearables.devices
      let pairedDescriptions = paired.map { id -> String in
        if let d = wearables.deviceForIdentifier(id) {
          return "{name=\(d.nameOrId()) type=\(d.deviceType().rawValue) supportsDisplay=\(d.supportsDisplay()) compatibility=\(d.compatibility())}"
        } else {
          return "{id=\(id) unresolved}"
        }
      }.joined(separator: ", ")
      log("acquire(\(consumerLabel)) pre-createSession: req=\(requirements) devices=\(paired.count) [\(pairedDescriptions)]")

      // SDK reports `DeviceSession.stopped` before its WARP transport threads
      // exit. If a session was just torn down this cycle, settle briefly so a
      // fresh createSession doesn't stand up a second WARP stack alongside the
      // one still draining (the `DCTEvent` use-after-free). Heuristic — there's
      // no SDK signal for "WARP fully drained" beyond `.stopped`.
      if recentlyToreDown {
        recentlyToreDown = false
        log("acquire(\(consumerLabel)) → settle 300ms after recent teardown (WARP drain)")
        try? await Task.sleep(nanoseconds: 300_000_000)
      }

      log("acquire(\(consumerLabel), req=\(requirements)) → createSession + start")
      let session = try await createSessionWithDrainRetry(selector: selector, consumerLabel: consumerLabel)
      deviceSession = session
      startSessionObservers(for: session)

      let stateStream = session.stateStream()
      let errorStream = session.errorStream()
      try session.start()

      // Fast path: state may have transitioned to .started before our
      // for-await loop even begins. stateStream() does not buffer past
      // events, so we must check synchronously first.
      if session.state == .started {
        leases[consumerLabel] = Date()
        log("acquire(\(consumerLabel)) → already .started, leases=\(leases.count)")
        return session
      }

      // Race state→.started against errorStream — whichever fires first wins.
      try await waitForSessionStart(stateStream: stateStream, errorStream: errorStream)
      leases[consumerLabel] = Date()
      log("acquire(\(consumerLabel)) → .started after wait, leases=\(leases.count)")
      return session
    } catch let error as DeviceSessionError {
      deviceSession = nil
      stopSessionObservers()
      throw AcquireError.sessionStartFailed(error)
    } catch let error as AcquireError {
      throw error
    } catch {
      deviceSession = nil
      stopSessionObservers()
      throw AcquireError.sessionStartFailed(.unexpectedError(description: error.localizedDescription))
    }
  }

  /// Release the named consumer's hold on the session. When the last
  /// consumer releases, the session is stopped.
  ///
  /// Releases run on `lifecycleTask` so a subsequent `acquire` from the
  /// same consumer (e.g. SwiftUI dismiss/remount) waits for the stop to
  /// finish before recreating.
  func release(consumerLabel: String) async {
    leases.removeValue(forKey: consumerLabel)
    log("release(\(consumerLabel)) → leases=\(leases.count)")

    guard leases.isEmpty, let session = deviceSession else { return }

    // Chain onto any prior lifecycle task (setup OR another release in
    // flight) so concurrent releases serialize instead of trampling.
    // Previously this method assigned `lifecycleTask = task` then nil'd
    // it at the end — two concurrent releases could overlap: B's assign
    // overwrites A's, A's nil-out at the end wipes B's handle, and the
    // next acquire reads `lifecycleTask == nil` and doesn't await B's
    // stop. The chained pattern mirrors `stopCameraStream` in
    // `GeminiLiveSessionBase` — same fix shape, same reason.
    //
    // No trailing `lifecycleTask = nil` — leaving the last completed task
    // assigned is harmless (Task is small, `await .value` fast-returns).
    let prior = lifecycleTask
    let task = Task { [weak self] in
      await prior?.value
      session.stop()
      // Best-effort wait for the SDK to confirm .stopped so a follow-up
      // acquire doesn't hit a half-torn-down session.
      await self?.waitForSessionStopped(session)
      await MainActor.run { [weak self] in
        guard let self else { return }
        if self.deviceSession === session {
          self.deviceSession = nil
        }
        self.stopSessionObservers()
      }
    }
    lifecycleTask = task
    await task.value
  }

  /// Serialized teardown of the active session, used by the registration-
  /// `.unavailable` and stateStream-`.stopped` observers (which fire
  /// asynchronously, outside any `acquire`/`release` call). Mirrors `release()`:
  /// chains onto `lifecycleTask` → `stop()` → `await waitForSessionStopped` →
  /// nil. Because `acquire()` awaits `lifecycleTask` at its top, a concurrent
  /// re-acquire cannot stand up a replacement session until this one reaches
  /// terminal `.stopped` — closing the window that produced two live WARP
  /// stacks. Fire-and-forget (the observers can't await): the serialization
  /// guarantee comes from `acquire()` awaiting `lifecycleTask`, not from here.
  private func teardownActiveSession(reason: String) {
    guard let session = deviceSession else { return }
    log("teardownActiveSession(\(reason))")
    recentlyToreDown = true
    let prior = lifecycleTask
    let task = Task { [weak self] in
      await prior?.value
      session.stop()
      await self?.waitForSessionStopped(session)
      await MainActor.run { [weak self] in
        guard let self else { return }
        if self.deviceSession === session {
          self.deviceSession = nil
        }
        self.stopSessionObservers()
      }
    }
    lifecycleTask = task
  }

  /// `wearables.createSession`, tolerant of a prior session whose WARP transport
  /// is still draining. The SDK can clear its session bookkeeping (so a fresh
  /// createSession is allowed) before the old transport threads exit; if it's
  /// still mid-teardown it instead throws `.sessionAlreadyExists`. In that case
  /// back off once and retry rather than failing the acquire. Heuristic for the
  /// same stopped-vs-WARP-drain gap as the settle in `acquire()`.
  private func createSessionWithDrainRetry(
    selector: any DeviceSelector,
    consumerLabel: String
  ) async throws -> DeviceSession {
    do {
      return try wearables.createSession(deviceSelector: selector)
    } catch DeviceSessionError.sessionAlreadyExists {
      log("acquire(\(consumerLabel)) → createSession threw .sessionAlreadyExists; backing off 300ms and retrying once")
      try? await Task.sleep(nanoseconds: 300_000_000)
      return try wearables.createSession(deviceSelector: selector)
    }
  }

  // MARK: - Private — requirements

  private func requirementsSatisfied(
    by session: DeviceSession,
    requirements: DeviceRequirements
  ) -> Bool {
    switch requirements {
    case .any:
      return true
    case .requiresDisplay:
      guard let device = wearables.deviceForIdentifier(session.deviceId) else { return false }
      return device.supportsDisplay()
    }
  }

  /// Wait briefly for a matching active device to become available.
  /// Returns immediately if one is already present. If the timeout
  /// elapses, returns anyway and lets `wearables.createSession` throw
  /// `.noEligibleDevice` as it would have synchronously — keeps the
  /// error surface unchanged for callers.
  ///
  /// Polling at 150ms covers the typical post-registration-flap window
  /// (~500ms–2s in observation) without burning CPU.
  private func awaitMatchingDevice(
    requirements: DeviceRequirements,
    timeout: TimeInterval
  ) async {
    func available() -> Bool {
      switch requirements {
      case .any: return hasAnyActiveDevice
      case .requiresDisplay: return hasDisplayCapableDevice
      }
    }
    let started = Date()
    if available() {
      log("awaitMatchingDevice(req=\(requirements)) → already available")
      return
    }
    log("awaitMatchingDevice(req=\(requirements)) → waiting up to \(timeout)s (devices=\(wearables.devices.count) hasAnyActive=\(hasAnyActiveDevice) hasDisplay=\(hasDisplayCapableDevice))")
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      try? await Task.sleep(nanoseconds: 150_000_000)
      if available() {
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        log("awaitMatchingDevice(req=\(requirements)) → matched after \(elapsed)ms")
        return
      }
    }
    let elapsed = Int(Date().timeIntervalSince(started) * 1000)
    log("awaitMatchingDevice(req=\(requirements)) → TIMEOUT after \(elapsed)ms (devices=\(wearables.devices.count) hasAnyActive=\(hasAnyActiveDevice) hasDisplay=\(hasDisplayCapableDevice)); createSession will throw noEligibleDevice")
  }

  // MARK: - Private — start race

  /// Race state→.started against errorStream. Whichever resolves first wins.
  /// Mirrors `samples/CameraAccess/.../DeviceSessionManager.swift waitForSessionStart`.
  private func waitForSessionStart(
    stateStream: AsyncStream<DeviceSessionState>,
    errorStream: AsyncStream<DeviceSessionError>
  ) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for await state in stateStream {
          if state == .started { return }
          if state == .stopped {
            throw DeviceSessionError.unexpectedError(description: "Session stopped before started")
          }
        }
        throw DeviceSessionError.unexpectedError(description: "State stream ended before .started")
      }

      group.addTask {
        for await error in errorStream {
          throw error
        }
        // Error stream ended cleanly — let the state group settle.
      }

      // The first task to finish (success or throw) wins.
      try await group.next()
      group.cancelAll()
    }
  }

  /// Best-effort wait for `.stopped`. We don't throw here — release should
  /// always succeed from the caller's POV even if the SDK is slow to confirm.
  private func waitForSessionStopped(_ session: DeviceSession) async {
    if session.state == .stopped { return }
    let stream = session.stateStream()
    let deadline = Date().addingTimeInterval(3.0)
    for await state in stream {
      if state == .stopped { return }
      if Date() > deadline {
        log("waitForSessionStopped: timeout, session state=\(state)")
        return
      }
    }
  }

  /// Wait for a `.paused` or `.starting` session to either resume to
  /// `.started` or transition to the terminal `.stopped`. Returns `true`
  /// if it resumed to `.started`, `false` if it stopped or the timeout
  /// elapsed. Pure observation — never throws; the caller decides whether
  /// timeout means "fall through to fresh createSession" or "surface error".
  ///
  /// Modeled after `waitForSessionStopped`'s best-effort stance. Used by
  /// `acquire()` to honor Meta's "don't restart during `.paused`" guidance
  /// from the `mwdat-ios:session-lifecycle` skill.
  private func awaitSessionResumedOrTerminated(
    session: DeviceSession,
    timeout: TimeInterval
  ) async -> Bool {
    if session.state == .started { return true }
    if session.state == .stopped { return false }

    let stream = session.stateStream()
    let deadline = Date().addingTimeInterval(timeout)
    for await state in stream {
      if state == .started { return true }
      if state == .stopped { return false }
      if Date() > deadline {
        log("awaitSessionResumedOrTerminated: timeout, session state=\(state)")
        return false
      }
    }
    return false
  }

  // MARK: - Private — session-state observers

  private func startSessionObservers(for session: DeviceSession) {
    stopSessionObservers()
    sessionStateTask = Task { [weak self] in
      for await state in session.stateStream() {
        guard let self else { return }
        self.log("DeviceSession.state → \(state)")
        if state == .stopped {
          // Route through the serialized teardown (not a bare nil) so an
          // in-flight re-acquire serializes behind the cleanup and the
          // post-teardown settle, rather than racing a fresh createSession
          // against the still-draining WARP stack. waitForSessionStopped
          // early-returns since we're already `.stopped`.
          if self.deviceSession === session {
            self.teardownActiveSession(reason: "stateStream .stopped")
          }
          return
        }
      }
    }
    sessionErrorTask = Task { [weak self] in
      for await error in session.errorStream() {
        guard let self else { return }
        self.log("DeviceSession.error → \(error)")
        self.sessionErrors.send(error)
      }
    }
  }

  private func stopSessionObservers() {
    sessionStateTask?.cancel()
    sessionStateTask = nil
    sessionErrorTask?.cancel()
    sessionErrorTask = nil
  }

  // MARK: - Private — device monitoring

  private func startDeviceMonitoring() {
    anyDeviceMonitorTask = Task { [weak self] in
      // The outer guard hoists the weak `self` to a strong local so the
      // for-await body can call `activeDeviceStream()` on a non-optional.
      // Inside the body we keep checking the original weak `self` so
      // cancellation drops the loop cleanly without retaining the manager.
      guard let strong = self else { return }
      for await deviceId in strong.anyDeviceSelector.activeDeviceStream() {
        guard let strong = self else { return }
        strong.selectorHasAnyActive = deviceId != nil
        strong.recomputeConnectivity()
      }
    }
    displayDeviceMonitorTask = Task { [weak self] in
      guard let strong = self else { return }
      for await deviceId in strong.displayDeviceSelector.activeDeviceStream() {
        guard let strong = self else { return }
        strong.selectorHasDisplayActive = deviceId != nil
        strong.recomputeConnectivity()
      }
    }
  }

  /// Recreate the device selectors and re-subscribe every device-monitoring
  /// stream. Called on the camera-permission→granted edge.
  ///
  /// Why recreate rather than just re-derive: a long-lived `AutoDeviceSelector`
  /// instantiated before any device was available (the app launched with no
  /// permission, so `devicesStream` was empty) does not recover when the device
  /// later appears post-grant — `activeDeviceStream()` stays at `nil`. A cold
  /// launch works only because the selectors are built *after* permission
  /// already exists. This reproduces that: fresh selectors + a fresh
  /// `devicesStream` subscription that re-seeds link listeners and recomputes.
  private func restartDeviceMonitoring() {
    log("restartDeviceMonitoring: recreating selectors + re-subscribing streams")
    anyDeviceMonitorTask?.cancel()
    displayDeviceMonitorTask?.cancel()
    deviceLinkMonitorTask?.cancel()
    for token in linkStateTokens.values { Task { await token.cancel() } }
    linkStateTokens.removeAll()
    selectorHasAnyActive = false
    selectorHasDisplayActive = false

    anyDeviceSelector = AutoDeviceSelector(wearables: wearables)
    displayDeviceSelector = AutoDeviceSelector(
      wearables: wearables,
      filter: { $0.supportsDisplay() }
    )

    startDeviceMonitoring()
    startLinkStateMonitoring()
    // Seed synchronously from the current device set so eligibility updates
    // immediately on grant rather than waiting for the next stream tick
    // (idempotent with the async seed inside startLinkStateMonitoring).
    refreshLinkListeners(for: wearables.devices)
  }

  // MARK: - Private — link-state (connection) monitoring

  /// Tracks the DAT transport link of each paired device via
  /// `Device.addLinkStateListener`, deriving `hasConnectedDevice`. This is the
  /// honest "are the glasses connected" signal — distinct from
  /// `hasAnyActiveDevice` (auto-selector session-eligibility), which can lag or
  /// stay `false` even while a compatible device is linked.
  ///
  /// `devicesStream()` tells us the set of paired devices; we (re)attach a
  /// link-state listener per device on each emission and seed the cache from
  /// the device's current `linkState`. Event-driven — no polling.
  private func startLinkStateMonitoring() {
    deviceLinkMonitorTask = Task { [weak self] in
      guard let strong = self else { return }
      // Seed from the devices already known at construction time.
      strong.refreshLinkListeners(for: strong.wearables.devices)
      for await devices in strong.wearables.devicesStream() {
        guard let strong = self else { return }
        strong.refreshLinkListeners(for: devices)
      }
    }
  }

  /// Drop listeners/cache for departed devices, attach a fresh listener +
  /// seed the current `linkState` for present devices, then recompute.
  private func refreshLinkListeners(for devices: [DeviceIdentifier]) {
    let present = Set(devices)

    // Forget devices that are no longer paired so a removed device can't keep
    // `hasConnectedDevice` stuck on.
    for (id, token) in linkStateTokens where !present.contains(id) {
      Task { await token.cancel() }
      linkStateTokens.removeValue(forKey: id)
    }
    deviceLinkState = deviceLinkState.filter { present.contains($0.key) }

    for deviceId in devices {
      guard let device = wearables.deviceForIdentifier(deviceId) else { continue }
      // Always reseed the current link state (covers devices we already had a
      // listener on but whose state changed before the listener attached).
      deviceLinkState[deviceId] = device.linkState

      guard linkStateTokens[deviceId] == nil else { continue }
      let token = device.addLinkStateListener { [weak self] state in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.deviceLinkState[deviceId] = state
          self.recomputeConnectivity()
        }
      }
      linkStateTokens[deviceId] = token
    }

    recomputeConnectivity()
  }

  /// Identifier of a paired device that is link-connected AND compatible,
  /// optionally requiring display support. This is the device we can actually
  /// start a session on right now — used both to derive the published
  /// eligibility flags and to build a `SpecificDeviceSelector` for
  /// `createSession`, sidestepping the filterless `AutoDeviceSelector`'s
  /// refusal to auto-pick among multiple devices when one is
  /// `Compatibility.undefined`. Returns the first match in `wearables.devices`
  /// order.
  func connectedCompatibleDeviceId(requiresDisplay: Bool) -> DeviceIdentifier? {
    for id in wearables.devices {
      guard let device = wearables.deviceForIdentifier(id) else { continue }
      guard device.linkState == .connected else { continue }
      guard device.compatibility() == .compatible else { continue }
      if requiresDisplay && !device.supportsDisplay() { continue }
      return id
    }
    return nil
  }

  /// Recompute the published connectivity flags. Idempotent.
  ///
  /// - `hasConnectedDevice` — any device link-connected (raw transport truth).
  /// - `hasAnyActiveDevice` / `hasDisplayCapableDevice` — the auto-selector
  ///   signal OR a connected+compatible device exists. The OR is the fix for
  ///   the auto-selector stalling at `nil` while a compatible Display is
  ///   plainly connected; `acquire` then targets that device explicitly.
  private func recomputeConnectivity() {
    let connected = deviceLinkState.values.contains(.connected)
    if connected != hasConnectedDevice { hasConnectedDevice = connected }

    let anyEligible = selectorHasAnyActive || connectedCompatibleDeviceId(requiresDisplay: false) != nil
    if anyEligible != hasAnyActiveDevice { hasAnyActiveDevice = anyEligible }

    let displayEligible = selectorHasDisplayActive || connectedCompatibleDeviceId(requiresDisplay: true) != nil
    if displayEligible != hasDisplayCapableDevice { hasDisplayCapableDevice = displayEligible }

    let snapshot = deviceLinkState
      .map { "\(wearables.deviceForIdentifier($0.key)?.nameOrId() ?? $0.key)=\($0.value)" }
      .joined(separator: ", ")
    log("connectivity: connected=\(hasConnectedDevice) anyActive=\(hasAnyActiveDevice) (selector=\(selectorHasAnyActive)) displayCapable=\(hasDisplayCapableDevice) (selector=\(selectorHasDisplayActive)) links=[\(snapshot)]")
  }

  // MARK: - Private — registration observation

  private func observeRegistration() {
    registrationTask = Task { [weak self] in
      guard let wearables = self?.wearables else { return }
      for await state in wearables.registrationStateStream() {
        guard let self else { return }
        self.log("registrationState → \(state)")
        if state == .unavailable {
          // The device is no longer paired — invalidate any session we're
          // holding. Lease holders discover this via their own state observers
          // and re-acquire on the next attempt. Previously this stopped the
          // session and nil'd the reference synchronously, bypassing
          // `lifecycleTask` and never awaiting `.stopped` — letting a re-acquire
          // create a replacement while the old WARP transport was still draining
          // (two live stacks → the `DCTEvent` use-after-free). Route through the
          // serialized teardown so the next `acquire()` waits for terminal
          // `.stopped` + settle before recreating.
          self.leases.removeAll()
          self.teardownActiveSession(reason: "registration .unavailable")
        }
      }
    }
  }

  // MARK: - Logging

  private func log(_ message: String) {
    print("[DeviceSessionManager] \(message)")
  }
}
