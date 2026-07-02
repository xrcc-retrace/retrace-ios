//
// WiFiLinkMonitor.swift
//
// Phone-side observability for DAT 0.8's WiFi video transport. The SDK
// exposes NO API for which link (WiFi vs BT Classic) video is riding — the
// "link lease" is negotiated internally and failures are silent. Every line
// this file prints carries a greppable "[WIFI]" tag so one console search
// covers the whole diagnosis trail. What we CAN observe from the app:
//
//   1. NWPathMonitor — is the phone's WiFi path up at all.
//   2. getifaddrs — the `awdl0` (Apple Wireless Direct Link / peer-to-peer
//      WiFi) interface state. NOTE: the DAT high link is a SoftAP/TCP join,
//      not AWDL, so awdl0 is ambient context, not a join signal.
//   3. OSLogStore — the SDK runs in-process, so its NSLog (MWDATCore) and
//      os_log (MWDATCamera) entries are readable from our own process. At
//      the interesting moments (frame-gap-soft, frame-starvation) we dump
//      the last 60s of join-trace entries (WifiSelector, SoftAP, airshield,
//      ACDC, markWifiStartError, ...) straight into the console.
//   4. NEHotspotConfigurationManager.getConfiguredSSIDs — an SSID configured
//      by this app means the SDK attempted a hotspot join from our process.
//
// Started/stopped by the glasses camera consumers around stream lifetime;
// snapshots every 5s while active plus on-demand at interesting moments
// (first frame, frame-gap-soft, frame-starvation, recovery).
//

import Foundation
import Network
import NetworkExtension
import OSLog
import MWDATCore

final class WiFiLinkMonitor: @unchecked Sendable {
  static let shared = WiFiLinkMonitor()

  private let queue = DispatchQueue(label: "com.retrace.wifi-link-monitor")
  private var pathMonitor: NWPathMonitor?
  private var snapshotTimer: DispatchSourceTimer?
  private var lastSnapshot = ""

  private init() {}

  /// Begin logging. Idempotent; safe to call from any thread.
  func start(context: String) {
    queue.async { [self] in
      guard pathMonitor == nil else { return }
      print("[WIFI] link monitor started (\(context)) — snapshot: \(Self.interfaceSnapshot())")
      logConfiguredHotspotSSIDs(context: "monitor-start")

      let monitor = NWPathMonitor()
      monitor.pathUpdateHandler = { path in
        let ifaces = path.availableInterfaces.map { "\($0.name)(\($0.type))" }.joined(separator: ", ")
        print("[WIFI] path update: status=\(path.status) usesWiFi=\(path.usesInterfaceType(.wifi)) ifaces=[\(ifaces)]")
      }
      monitor.start(queue: queue)
      pathMonitor = monitor

      // Poll interface flags — awdl0 up/running transitions are the P2P
      // signal NWPathMonitor doesn't surface. Log only on change.
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now() + 5.0, repeating: 5.0)
      timer.setEventHandler { [self] in
        let snap = Self.interfaceSnapshot()
        if snap != lastSnapshot {
          lastSnapshot = snap
          print("[WIFI] link snapshot changed: \(snap)")
        }
      }
      timer.resume()
      snapshotTimer = timer
    }
  }

  func stop(context: String) {
    queue.async { [self] in
      guard pathMonitor != nil else { return }
      pathMonitor?.cancel()
      pathMonitor = nil
      snapshotTimer?.cancel()
      snapshotTimer = nil
      lastSnapshot = ""
      print("[WIFI] link monitor stopped (\(context)) — final snapshot: \(Self.interfaceSnapshot())")
    }
  }

  /// One-shot correlated log for interesting moments (first frame,
  /// starvation). Safe from any thread. The frame-gap and starvation
  /// moments additionally dump the SDK's own join-trace log entries.
  func logSnapshot(context: String) {
    queue.async { [self] in
      print("[WIFI] snapshot @\(context): \(Self.interfaceSnapshot())")
      if context.contains("frame-gap-soft") || context.contains("frame-starvation") {
        logConfiguredHotspotSSIDs(context: context)
        dumpRecentSDKLogs(context: context)
      }
    }
  }

  // MARK: - SDK join-trace dump (OSLogStore)

  /// Join-trace markers verified present in the DAT 0.8.0 binaries. Matched
  /// case-insensitively against the SDK's in-process unified-log entries.
  /// Deliberately SPECIFIC: a bare "wifi" term matches "uses wifi" in every
  /// com.apple.network path line (926 false positives in the first field
  /// capture) and drowns the real signal.
  private static let sdkLogTerms: [String] = [
    "softap", "airshield", "acdc", "warp", "xms", "hera", "datax",
    "wifiselector", "markwifistarterror", "linklease", "link lease",
    "wifi_direct", "wifi transport", "wifi connection", "wifistart",
    "transportswitched", "linktype changed", "enablingwifi",
  ]

  /// Apple's own networking subsystems — pure noise for this diagnosis
  /// (our server/Bonjour/analytics traffic), never the DAT SDK's voice.
  private static let excludedSubsystems: [String] = [
    "com.apple.network", "com.apple.CFNetwork", "com.apple.NetworkExtension",
  ]

  /// Print the last 60s of SDK unified-log entries that look like WiFi
  /// join/link-lease activity. `OSLogStore(scope: .currentProcessIdentifier)`
  /// needs no entitlement and sees the SDK's NSLog + os_log output because
  /// the SDK runs in-process. Our own `print()` lines go to stdout, not the
  /// unified log, so they can't echo back into this dump.
  ///
  /// Always ends with a sender census (entry counts per emitting binary) so
  /// a zero-match dump still answers "does the SDK log anything at all?" —
  /// the ACDC event logger may default to a noop, in which case the join is
  /// invisible from in-process and the diagnosis must move to Console.app.
  private func dumpRecentSDKLogs(context: String) {
    // Flush the SDK's buffered logger first so the freshest entries land.
    Logging.flush()
    do {
      let store = try OSLogStore(scope: .currentProcessIdentifier)
      let position = store.position(date: Date().addingTimeInterval(-60))
      let entries = try store.getEntries(at: position)
      var matched = 0
      let cap = 200
      var senderCounts: [String: Int] = [:]
      for entry in entries {
        guard let log = entry as? OSLogEntryLog else { continue }
        senderCounts[log.sender, default: 0] += 1
        let message = log.composedMessage
        let lower = message.lowercased()
        // Take everything the MWDAT frameworks say, plus any entry matching
        // a specific join-trace term — but never Apple's nw-layer chatter.
        let fromSDK = log.sender.hasPrefix("MWDAT")
        let isExcluded = Self.excludedSubsystems.contains { log.subsystem.hasPrefix($0) }
        let termHit = !isExcluded && Self.sdkLogTerms.contains { lower.contains($0) }
        guard fromSDK || termHit else { continue }
        matched += 1
        if matched <= cap {
          let source = log.subsystem.isEmpty ? log.sender : "\(log.sender)/\(log.subsystem)"
          print("[WIFI][sdk@\(context)] \(log.date) [\(source)] \(message)")
        }
      }
      let capped = matched > cap ? " (printed first \(cap))" : ""
      print("[WIFI] sdk log dump @\(context): \(matched) join-trace entries in last 60s\(capped)")
      let census = senderCounts.sorted { $0.value > $1.value }.prefix(12)
        .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
      print("[WIFI] sender census @\(context) (last 60s): \(census)")
    } catch {
      print("[WIFI] sdk log dump @\(context) failed: \(error)")
    }
  }

  /// An SSID configured by this app via NEHotspotConfiguration = the SDK
  /// attempted a SoftAP join from our process. Empty = no join attempted
  /// (or the SDK joins by other means).
  private func logConfiguredHotspotSSIDs(context: String) {
    NEHotspotConfigurationManager.shared.getConfiguredSSIDs { ssids in
      let list = ssids.isEmpty ? "none" : ssids.joined(separator: ", ")
      print("[WIFI] NEHotspot configured SSIDs @\(context): \(list)")
    }
  }

  /// Compact state of the interfaces that matter: `en0` (infrastructure
  /// WiFi) and any `awdl*` (peer-to-peer WiFi — ambient context only).
  private static func interfaceSnapshot() -> String {
    var addrs: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addrs) == 0, let first = addrs else { return "unavailable" }
    defer { freeifaddrs(addrs) }

    var states: [String: String] = [:]
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let name = String(cString: ptr.pointee.ifa_name)
      guard name == "en0" || name.hasPrefix("awdl") else { continue }
      let flags = Int32(bitPattern: UInt32(ptr.pointee.ifa_flags))
      let up = (flags & IFF_UP) != 0
      let running = (flags & IFF_RUNNING) != 0
      // An interface appears once per address family; up+running wins.
      let state = up ? (running ? "up+running" : "up") : "down"
      if states[name] == nil || state == "up+running" {
        states[name] = state
      }
    }
    if states["awdl0"] == nil { states["awdl0"] = "absent" }
    if states["en0"] == nil { states["en0"] = "absent" }
    return states.sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: " ")
  }
}
