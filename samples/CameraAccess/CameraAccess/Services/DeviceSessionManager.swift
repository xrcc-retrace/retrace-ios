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
  /// Drives the Settings "Connected" pill and the Expert "no active device" guard.
  @Published private(set) var hasAnyActiveDevice: Bool = false

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
  /// `.any` acquires.
  private let anyDeviceSelector: AutoDeviceSelector

  /// Display-capable filter selector — drives `hasDisplayCapableDevice`
  /// and is used for `.requiresDisplay` acquires.
  private let displayDeviceSelector: AutoDeviceSelector

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

  /// Background observation tasks.
  private var anyDeviceMonitorTask: Task<Void, Never>?
  private var displayDeviceMonitorTask: Task<Void, Never>?
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
    observeRegistration()
  }

  deinit {
    anyDeviceMonitorTask?.cancel()
    displayDeviceMonitorTask?.cancel()
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
      cameraPermission = status
      return status
    } catch {
      log("cameraPermissionStatus threw: \(error)")
      throw AcquireError.permissionCheckFailed(error.localizedDescription)
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
      cameraPermission = after
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

    let selector = (requirements == .requiresDisplay) ? displayDeviceSelector : anyDeviceSelector
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
      log("acquire(\(consumerLabel), req=\(requirements)) → createSession + start")
      let session = try wearables.createSession(deviceSelector: selector)
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
          if self.deviceSession === session {
            self.deviceSession = nil
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
        strong.hasAnyActiveDevice = deviceId != nil
      }
    }
    displayDeviceMonitorTask = Task { [weak self] in
      guard let strong = self else { return }
      for await deviceId in strong.displayDeviceSelector.activeDeviceStream() {
        guard let strong = self else { return }
        strong.hasDisplayCapableDevice = deviceId != nil
      }
    }
  }

  // MARK: - Private — registration observation

  private func observeRegistration() {
    registrationTask = Task { [weak self] in
      guard let wearables = self?.wearables else { return }
      for await state in wearables.registrationStateStream() {
        guard let self else { return }
        self.log("registrationState → \(state)")
        if state == .unavailable {
          // The device is no longer paired — invalidate any session
          // we're holding. Lease holders will discover this via their
          // own state observers and re-acquire on the next attempt.
          if let session = self.deviceSession {
            session.stop()
            self.deviceSession = nil
            self.leases.removeAll()
            self.stopSessionObservers()
          }
        }
      }
    }
  }

  // MARK: - Logging

  private func log(_ message: String) {
    print("[DeviceSessionManager] \(message)")
  }
}
