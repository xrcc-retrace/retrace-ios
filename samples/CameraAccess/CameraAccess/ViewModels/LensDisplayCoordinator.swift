//
// LensDisplayCoordinator.swift
//
// Owns the lifecycle of the on-glasses display capability:
// attach to a display-capable device, send DisplayableView trees, detach.
//
// Modeled on `samples/DisplayAccess/DisplayAccess/ViewModels/DisplayViewModel.swift`
// from `facebook/meta-wearables-dat-ios`. That sample is the canonical reference
// for MWDATDisplay usage — when in doubt, read it.
//
// Key differences from the sample:
//   - We use the older ObservableObject / @Published pattern (the project is
//     Swift 5.0, no @Observable macro). Behavior is identical.
//   - The selector filter scopes to display-capable devices so older Ray-Ban
//     Meta without a display are silently ignored.
//   - Sends are queued via `pendingAction` so a tap that fires before the
//     display has finished starting auto-fires once DisplayState.started arrives.
//
// This coordinator is a leaf — it does NOT own renderers, snapshots, or any
// per-flow logic. `LensSession` (above it) decides what to send; this just
// owns the SDK-side plumbing.
//

import Combine
import MWDATCore
import MWDATDisplay
import SwiftUI

@MainActor
final class LensDisplayCoordinator: ObservableObject {
  /// Display capability is started and ready to receive `send(_:)`.
  @Published private(set) var isConnected: Bool = false

  /// A `send(_:)` is currently awaiting completion.
  @Published private(set) var isSending: Bool = false

  /// Most recent error surfaced from a DisplayError, DeviceSessionError, or
  /// underlying send/start failure. `nil` once cleared.
  @Published var errorMessage: String?

  /// The DAT helper app on the glasses needs to be updated before a display
  /// session will start. Surfaced as a separate flag so Settings UI can show
  /// the "Update app on glasses" CTA distinctly from generic failures.
  @Published private(set) var requiresDATAppUpdate: Bool = false

  /// Last `attachToDisplay()` attempt failed (any reason). Used by Settings
  /// to auto-present after a failed launch, mirroring the sample's UX.
  @Published private(set) var didFailToStartSession: Bool = false

  /// The live Display capability. `nil` while detached or while starting.
  /// Exposed (read-only) so callers like `LensSession` can wire `onPlaybackEvent`
  /// for video → UI handoff after `send(VideoPlayer(...))`.
  private(set) var display: Display?

  private let wearables: WearablesInterface
  /// Phase 2: optional shared `DeviceSessionManager`. When the
  /// `deviceSessionManagerEnabled` toggle is ON, all session lifecycle
  /// routes through this manager so camera + display can coexist on
  /// one `DeviceSession` per the SDK's capability-composition model.
  /// When OFF (default during migration) the coordinator falls back to
  /// its own `wearables.createSession` path — preserved so we have a
  /// sub-second on-device rollback.
  private let sessionManager: DeviceSessionManager?
  private var deviceSelector: AutoDeviceSelector
  private var deviceSession: DeviceSession?
  private var stateListenerToken: AnyListenerToken?
  private var coreStateTask: Task<Void, Never>?
  private var sessionErrorTask: Task<Void, Never>?
  private var registrationTask: Task<Void, Never>?
  private var displayStateTask: Task<Void, Never>?
  private var displayStateContinuation: AsyncStream<DisplayState>.Continuation?
  private var pendingAction: (() async -> Void)?

  /// Cancellable for the manager's sessionErrors fan-out, when the
  /// manager path is active. Replaces the inline `sessionErrorTask`
  /// in that mode.
  private var managerSessionErrorsCancellable: AnyCancellable?

  /// Reads the live debug toggle. Re-read on each `attachToDisplay()`
  /// so a flip in Settings takes effect on the next attach (no app
  /// relaunch required).
  private var deviceSessionManagerEnabled: Bool {
    UserDefaults.standard.bool(forKey: "deviceSessionManagerEnabled") && sessionManager != nil
  }

  init(wearables: WearablesInterface, sessionManager: DeviceSessionManager? = nil) {
    self.wearables = wearables
    self.sessionManager = sessionManager
    self.deviceSelector = AutoDeviceSelector(
      wearables: wearables,
      filter: { $0.supportsDisplay() }
    )
    observeRegistration()
  }

  deinit {
    stateListenerToken = nil
    coreStateTask?.cancel()
    sessionErrorTask?.cancel()
    registrationTask?.cancel()
    displayStateTask?.cancel()
    managerSessionErrorsCancellable?.cancel()
  }

  // MARK: - Registration Observation

  /// Reset the display session whenever registration availability flips. A
  /// previously-paired device that is unregistered or a fresh pairing both
  /// need a fresh selector + session.
  private func observeRegistration() {
    registrationTask = Task { [weak self] in
      guard let wearables = self?.wearables else { return }
      for await state in wearables.registrationStateStream() {
        guard let self, !Task.isCancelled else { return }
        if state == .available || state == .unavailable {
          await self.resetDisplaySession()
        }
      }
    }
  }

  private func resetDisplaySession() async {
    await detachFromDisplay()
    deviceSelector = AutoDeviceSelector(
      wearables: wearables,
      filter: { $0.supportsDisplay() }
    )
  }

  // MARK: - Public API

  /// Send a DisplayableView (FlexBox or VideoPlayer) to the glasses.
  /// Auto-attaches on first call. If the display isn't yet at .started,
  /// the view is queued and fires once the display becomes ready.
  func send(_ view: some DisplayableView) async {
    if let display, isConnected {
      await doSend(view, on: display)
      return
    }

    // Queue and trigger attach. The pending action fires from the display
    // state-stream handler once .started arrives (see setupDisplay).
    let sendableView = view
    pendingAction = { [weak self] in
      guard let self, let cap = self.display else { return }
      await self.doSend(sendableView, on: cap)
    }

    if display == nil {
      await attachToDisplay()
    }
  }

  func clearSessionStartFailure() {
    didFailToStartSession = false
  }

  // MARK: - Session Management

  private func doSend(_ view: some DisplayableView, on capability: Display) async {
    isSending = true
    defer { isSending = false }

    do {
      try await capability.send(view)
      print("[LensDisplayCoordinator] display.send ✓")
    } catch {
      print("[LensDisplayCoordinator] display.send threw → \(error)")
      let message = (error as? DisplayError)?.description ?? error.localizedDescription
      errorMessage = "\(String(describing: type(of: error))).\(error): \(message)"
    }
  }

  func attachToDisplay() async {
    guard display == nil else { return }

    didFailToStartSession = false

    if deviceSessionManagerEnabled, let manager = sessionManager {
      await attachViaManager(manager)
    } else {
      await attachInline()
    }
  }

  /// Phase 2 path. Get a ready DeviceSession from the shared manager
  /// (which has already raced stateStream/errorStream and resolved
  /// to `.started` or thrown), then add the Display capability on it.
  /// The manager fans `DeviceSessionError`s out via `sessionErrors`
  /// so we don't need our own per-consumer errorStream observer.
  private func attachViaManager(_ manager: DeviceSessionManager) async {
    // Subscribe to the manager's session-error fan-out so we still react
    // to `datAppOnTheGlassesUpdateRequired` etc. The cancellable is held
    // for the lifetime of this attach; `detachFromDisplay` clears it.
    managerSessionErrorsCancellable = manager.sessionErrors.sink { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.handleSessionError(error)
      }
    }

    do {
      print("[LensDisplayCoordinator] attachViaManager → manager.acquire('lens', .requiresDisplay)")
      let session = try await manager.acquire(consumerLabel: "lens", requirements: .requiresDisplay)
      deviceSession = session

      let deviceId = session.deviceId
      if let device = wearables.deviceForIdentifier(deviceId) {
        print("[LensDisplayCoordinator] selected device: name=\(device.nameOrId()) type=\(device.deviceType().rawValue) supportsDisplay=\(device.supportsDisplay()) compatibility=\(device.compatibility())")
      } else {
        print("[LensDisplayCoordinator] selected device: <not resolvable> id=\(deviceId)")
      }

      // Session is already `.started` — proceed directly to display setup.
      await setupDisplay(on: session)
    } catch DeviceSessionManager.AcquireError.sessionStartFailed(.datAppOnTheGlassesUpdateRequired) {
      print("[LensDisplayCoordinator] manager.acquire threw → datAppOnTheGlassesUpdateRequired")
      requiresDATAppUpdate = true
      didFailToStartSession = true
      errorMessage = DeviceSessionError.datAppOnTheGlassesUpdateRequired.localizedDescription
    } catch DeviceSessionManager.AcquireError.requirementsConflictWithActiveSession(_) {
      // The active DeviceSession is on a device that doesn't support
      // display (Vanguard, regular RBM, etc.). Coaching / Troubleshoot
      // already acquired with `.any`, so the lens path can't piggy-back
      // on the same session. This is an EXPECTED outcome on non-display
      // glasses — the phone-side SwiftUI emulator is the UI. Not an
      // error to surface in the UI; just log the diagnosis and leave
      // `display = nil` so `LensSession.send(_:)` no-ops cleanly.
      print("[LensDisplayCoordinator] lens output unavailable — active glasses do not support display capability (non-display DAT model); phone UI takes over")
      requiresDATAppUpdate = false
      didFailToStartSession = false
    } catch DeviceSessionManager.AcquireError.noEligibleDevice {
      // No display-capable device is currently reachable. Same outcome
      // as the requirements-conflict case: the phone UI takes over, lens
      // stays inert. Distinct log so the user can tell "no Display
      // glasses paired" from "another consumer pinned a non-display
      // device first."
      print("[LensDisplayCoordinator] lens output unavailable — no display-capable glasses reachable (no Ray-Ban Meta Display paired or active)")
      requiresDATAppUpdate = false
      didFailToStartSession = false
    } catch {
      print("[LensDisplayCoordinator] manager.acquire threw → \(error)")
      requiresDATAppUpdate = false
      didFailToStartSession = true
      errorMessage = "Failed to acquire session [\(error)]: \(error.localizedDescription)"
    }
  }

  /// Pre-manager inline path. Preserved unchanged so flipping the
  /// `deviceSessionManagerEnabled` toggle OFF reverts behavior to
  /// exactly what it was before the manager landed.
  private func attachInline() async {
    do {
      let devSession = try wearables.createSession(deviceSelector: deviceSelector)
      deviceSession = devSession

      let deviceId = devSession.deviceId
      if let device = wearables.deviceForIdentifier(deviceId) {
        print("[LensDisplayCoordinator] selected device: name=\(device.nameOrId()) type=\(device.deviceType().rawValue) supportsDisplay=\(device.supportsDisplay()) compatibility=\(device.compatibility())")
      } else {
        print("[LensDisplayCoordinator] selected device: <not resolvable> id=\(deviceId)")
      }

      let stateStream = devSession.stateStream()
      let errorStream = devSession.errorStream()
      coreStateTask = Task { [weak self] in
        for await sessionState in stateStream {
          guard let self, !Task.isCancelled else { return }
          print("[LensDisplayCoordinator] DeviceSession.state → \(sessionState)")
          switch sessionState {
          case .started:
            self.requiresDATAppUpdate = false
            self.didFailToStartSession = false
            await self.setupDisplay(on: devSession)
          case .stopping, .stopped:
            self.isConnected = false
            self.display = nil
          case .starting, .idle, .paused:
            break
          @unknown default:
            break
          }
        }
      }
      sessionErrorTask = Task { [weak self] in
        for await error in errorStream {
          guard let self, !Task.isCancelled else { return }
          self.handleSessionError(error)
        }
      }

      try devSession.start()
    } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
      print("[LensDisplayCoordinator] createSession/start threw → datAppOnTheGlassesUpdateRequired")
      requiresDATAppUpdate = true
      didFailToStartSession = true
      errorMessage = DeviceSessionError.datAppOnTheGlassesUpdateRequired.localizedDescription
    } catch {
      print("[LensDisplayCoordinator] createSession/start threw → \(error)")
      requiresDATAppUpdate = false
      didFailToStartSession = true
      errorMessage = "Failed to create session [\(error)]: \(error.localizedDescription)"
    }
  }

  private func setupDisplay(on devSession: DeviceSession) async {
    guard display == nil else { return }

    do {
      print("[LensDisplayCoordinator] addDisplay() …")
      let capability = try devSession.addDisplay()
      print("[LensDisplayCoordinator] addDisplay() ✓ initialState=\(capability.state)")

      let (stateStream, continuation) = AsyncStream.makeStream(of: DisplayState.self)
      displayStateContinuation = continuation
      stateListenerToken = capability.statePublisher.listen { state in
        continuation.yield(state)
      }

      displayStateTask = Task { [weak self] in
        for await state in stateStream {
          guard let self, !Task.isCancelled else { return }
          print("[LensDisplayCoordinator] Display.state → \(state)")
          switch state {
          case .starting:
            break
          case .started:
            self.isConnected = true
            // Fire any pending send queued before the display was ready.
            if let action = self.pendingAction {
              self.pendingAction = nil
              await action()
            }
          case .stopping:
            self.isConnected = false
          case .stopped:
            self.isConnected = false
            self.stateListenerToken = nil
            self.displayStateContinuation?.finish()
            self.displayStateContinuation = nil
            self.display = nil
            self.coreStateTask?.cancel()
            self.coreStateTask = nil
            self.deviceSession?.stop()
            self.deviceSession = nil
          @unknown default:
            break
          }
        }
      }

      print("[LensDisplayCoordinator] capability.start() …")
      await capability.start()
      print("[LensDisplayCoordinator] capability.start() returned, state=\(capability.state)")
      display = capability
    } catch {
      print("[LensDisplayCoordinator] setupDisplay/addDisplay threw → \(error)")
      errorMessage = "Failed to start display [\(error)]: \(error.localizedDescription)"
    }
  }

  func detachFromDisplay() async {
    stateListenerToken = nil
    displayStateContinuation?.finish()
    displayStateContinuation = nil
    displayStateTask?.cancel()
    displayStateTask = nil
    await display?.stop()
    display = nil

    // Inline-path observers (only populated when toggle was OFF). Cancel
    // unconditionally — they're nil when the manager path was active.
    coreStateTask?.cancel()
    coreStateTask = nil
    sessionErrorTask?.cancel()
    sessionErrorTask = nil

    // Manager-path subscription, equivalent purpose to sessionErrorTask
    // above but driven by the manager's PassthroughSubject. Same nil-safe
    // semantics — only populated when toggle is ON.
    managerSessionErrorsCancellable?.cancel()
    managerSessionErrorsCancellable = nil

    // Release the DeviceSession. The manager owns it under the new path;
    // we own it under the inline path. Branch on whichever produced it.
    if deviceSessionManagerEnabled, let manager = sessionManager {
      // Drop our local ref BEFORE telling the manager — if the manager
      // decides to stop the session (last consumer releasing), the stop
      // happens against the underlying SDK object, not us.
      deviceSession = nil
      await manager.release(consumerLabel: "lens")
    } else {
      deviceSession?.stop()
      deviceSession = nil
    }

    isConnected = false
    pendingAction = nil
  }

  private func handleSessionError(_ error: DeviceSessionError) {
    print("[LensDisplayCoordinator] DeviceSession error stream → \(error)")
    requiresDATAppUpdate = error == .datAppOnTheGlassesUpdateRequired
    didFailToStartSession = true
    errorMessage = "DeviceSessionError.\(error): \(error.localizedDescription)"
  }
}
