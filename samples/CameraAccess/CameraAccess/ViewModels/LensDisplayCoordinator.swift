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
  /// Shared `DeviceSessionManager` — the single owner of every DAT
  /// `DeviceSession`. All session lifecycle routes through this manager so
  /// camera + display can coexist on one `DeviceSession` per the SDK's
  /// capability-composition model.
  private let sessionManager: DeviceSessionManager
  private var deviceSelector: AutoDeviceSelector
  private var deviceSession: DeviceSession?
  private var stateListenerToken: AnyListenerToken?
  private var coreStateTask: Task<Void, Never>?
  private var sessionErrorTask: Task<Void, Never>?
  private var registrationTask: Task<Void, Never>?
  private var displayStateTask: Task<Void, Never>?
  private var displayStateContinuation: AsyncStream<DisplayState>.Continuation?
  private var pendingAction: (() async -> Void)?

  /// When true, `attachToDisplay()` refuses to acquire the shared DeviceSession.
  /// Set by `suspendAttaching()` at the start of a TERMINAL teardown ("Take back
  /// on phone"), so a late lazy `send(_:)` from a renderer that hasn't unmounted
  /// yet can't re-acquire the very Bluetooth session the exit is releasing
  /// (that race produced `createSession → sessionAlreadyExists`). Cleared by
  /// `resumeAttaching()`, called whenever a lens flow legitimately activates.
  private var suspendAttach = false

  /// The in-flight `attachViaManager`/`acquire("lens")` operation, if any. Held so
  /// `detachFromDisplay()` can DRAIN it before releasing — otherwise an attach that
  /// already passed the synchronous `!suspendAttach` guard and is suspended inside
  /// `acquire` would re-add the "lens" lease AFTER the detach released it, reviving
  /// the DeviceSession. Also lets concurrent lazy sends coalesce onto one attach.
  private var attachTask: Task<Void, Never>?
  /// Monotonic id for the current attach, so the post-await cleanup only clears
  /// `attachTask` when it's still the one this call installed (`Task` has no
  /// identity to compare with `===`).
  private var attachGeneration = 0

  /// Single-flight send serialization. `capability.send(_:)` MUST NOT be called
  /// concurrently: `send(_:)` is re-entered on the main actor while a prior send
  /// is suspended inside `capability.send`, so awaiting inline would put two
  /// sends in flight. Overlapping sends make the MWDATDisplay link throw
  /// "Superseded by new display request" and — worse — WEDGE the link, so it
  /// stops rendering new trees AND stops routing taps back (a frozen,
  /// unresponsive lens). Renderers fire `Task { await send(...) }` freely; we
  /// coalesce here. `queuedSend` holds the LATEST tree (latest-wins; stale
  /// frames drop), `sendDrainTask` is the lone serial drainer.
  private var queuedSend: ((Display) async -> Void)?
  private var sendDrainTask: Task<Void, Never>?

  /// Cancellable for the manager's sessionErrors fan-out, when the
  /// manager path is active. Replaces the inline `sessionErrorTask`
  /// in that mode.
  private var managerSessionErrorsCancellable: AnyCancellable?

  /// Cancellable for the manager's `sessionInvalidated` fan-out — a forced
  /// out-of-band session drop (a sibling consumer detected the shared transport
  /// is dead via frame starvation, which never reaches `errorStream`). When it
  /// fires our `DeviceSession` is a corpse, so we detach rather than keep
  /// rendering onto it.
  private var managerSessionInvalidatedCancellable: AnyCancellable?

  /// Set true once an `attachToDisplay()` attempt fails with a reason
  /// that won't resolve without external state change (active glasses
  /// don't support display, or no display-capable device is reachable
  /// at all). Subsequent `attachToDisplay()` calls short-circuit so a
  /// renderer pumping ~8 lazy `coordinator.send` calls per second on a
  /// non-display device doesn't loop attach attempts at the same rate.
  ///
  /// Reset in `resetDisplaySession()` — which fires whenever
  /// `wearables.registrationStateStream()` emits `.available` /
  /// `.unavailable`, i.e. exactly the moments when "try again" might
  /// produce a different outcome (a Display device just paired, or the
  /// active non-display device disconnected).
  ///
  /// NOT set for `datAppOnTheGlassesUpdateRequired` (own recovery UI) or
  /// generic catch-all errors (those flip `didFailToStartSession`) — the
  /// same "permanent for the current registration" rationale doesn't apply
  /// uniformly to those.
  private var attachUnavailableForCurrentRegistration: Bool = false

  init(wearables: WearablesInterface, sessionManager: DeviceSessionManager) {
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
    managerSessionInvalidatedCancellable?.cancel()
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
    // Registration state just flipped — the world might look different
    // now (Display just paired, or the active non-display device just
    // disconnected). Clear the "attach unavailable" short-circuit so
    // the next `coordinator.send(_:)` triggers a fresh attach attempt.
    attachUnavailableForCurrentRegistration = false
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
      // Serialize: stash the latest tree (latest-wins) and ensure ONE drainer
      // runs. Do NOT `await doSend` inline — `send` re-enters on the main actor
      // while a prior `doSend` is suspended in `capability.send`, so an inline
      // await would overlap two sends and wedge the link (see `queuedSend`).
      let sendableView = view
      queuedSend = { [weak self] cap in await self?.doSend(sendableView, on: cap) }
      if sendDrainTask == nil {
        sendDrainTask = Task { [weak self] in await self?.drainSends() }
      }
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

  /// Serial send drainer. Sends one tree at a time so `capability.send` is never
  /// called concurrently. Re-reads `display`/`isConnected` each iteration so a
  /// teardown mid-drain stops us before sending to a stopping/stopped capability
  /// (preserves the WARP-drain ordering — we never call `send` once the link is
  /// going away). Exits when the queue is empty or the link is gone, then nils
  /// itself so the next `send(_:)` restarts it.
  private func drainSends() async {
    while let next = queuedSend, let cap = display, isConnected {
      queuedSend = nil
      await next(cap)
    }
    sendDrainTask = nil
  }

  func clearSessionStartFailure() {
    didFailToStartSession = false
  }

  /// Suppress lazy re-attach during a terminal teardown (return-to-phone). See
  /// `suspendAttach`. Stays in effect until a flow legitimately `activate`s.
  func suspendAttaching() { suspendAttach = true }

  /// Re-enable attaching — called from `LensSession.activate(_:vm:)` so any real
  /// activation clears a prior teardown's suppression.
  func resumeAttaching() { suspendAttach = false }

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
    // Coalesce concurrent lazy sends onto ONE in-flight attach so two sends can't
    // both run setupDisplay or both add the "lens" lease.
    if let inflight = attachTask { await inflight.value; return }
    // A terminal teardown is in progress — refuse to re-acquire the shared
    // DeviceSession. A trailing lazy `send(_:)` must not revive the Bluetooth
    // session the exit just released. Cleared by `resumeAttaching()` on the next
    // legitimate `LensSession.activate(...)`.
    guard !suspendAttach else {
      print("[LensDisplayCoordinator] attach suppressed — terminal teardown in progress")
      return
    }
    // Short-circuit if a prior attempt against the current registration
    // state already determined no display device is reachable / claimable.
    // Without this, a renderer pumping ~8 lazy `coordinator.send` calls
    // per second on a non-display device would loop attach attempts at
    // the same rate, hammering DSM and flooding logs. Reset happens in
    // `resetDisplaySession()` when registration availability changes.
    guard !attachUnavailableForCurrentRegistration else { return }

    didFailToStartSession = false

    // Run the acquire+setupDisplay as a tracked task so `detachFromDisplay()` can
    // await it before releasing the lease (closes the acquire-vs-detach window).
    // `Task` is a value type (no identity), so track a generation counter to only
    // clear `attachTask` if it's still THIS attach (a detach or newer attach may
    // have replaced it while we awaited).
    attachGeneration &+= 1
    let gen = attachGeneration
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.attachViaManager(self.sessionManager)
    }
    attachTask = task
    await task.value
    if attachGeneration == gen { attachTask = nil }
  }

  /// Get a ready DeviceSession from the shared manager (which has already
  /// raced stateStream/errorStream and resolved to `.started` or thrown),
  /// then add the Display capability on it. The manager fans
  /// `DeviceSessionError`s out via `sessionErrors` so we don't need our
  /// own per-consumer errorStream observer.
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
    managerSessionInvalidatedCancellable = manager.sessionInvalidated.sink { [weak self] reason in
      Task { @MainActor [weak self] in
        guard let self else { return }
        await self.handleSessionInvalidated(reason)
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
      //
      // Set `attachUnavailableForCurrentRegistration = true` so the
      // ~120ms-cadence lazy `coordinator.send` calls don't loop attach
      // attempts at the same rate. The flag clears in
      // `resetDisplaySession()` when registration state changes.
      print("[LensDisplayCoordinator] lens output unavailable — active glasses do not support display capability (non-display DAT model); phone UI takes over")
      requiresDATAppUpdate = false
      didFailToStartSession = false
      attachUnavailableForCurrentRegistration = true
    } catch DeviceSessionManager.AcquireError.noEligibleDevice {
      // No display-capable device is currently reachable. Same outcome
      // as the requirements-conflict case: the phone UI takes over, lens
      // stays inert. Distinct log so the user can tell "no Display
      // glasses paired" from "another consumer pinned a non-display
      // device first."
      print("[LensDisplayCoordinator] lens output unavailable — no display-capable glasses reachable (no Ray-Ban Meta Display paired or active)")
      requiresDATAppUpdate = false
      didFailToStartSession = false
      attachUnavailableForCurrentRegistration = true
    } catch {
      print("[LensDisplayCoordinator] manager.acquire threw → \(error)")
      requiresDATAppUpdate = false
      didFailToStartSession = true
      errorMessage = "Failed to acquire session [\(error)]: \(error.localizedDescription)"
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
            self.queuedSend = nil
            self.stateListenerToken = nil
            self.displayStateContinuation?.finish()
            self.displayStateContinuation = nil
            self.display = nil
            self.coreStateTask?.cancel()
            self.coreStateTask = nil
            // Release our lease and let the manager decide whether to actually
            // stop the shared DeviceSession — it stays alive if another consumer
            // (e.g. "gemini-live") still holds it. Calling `deviceSession?.stop()`
            // here bypassed the manager's refcount, killing a session other
            // consumers depend on AND desyncing the manager (it still thought the
            // session was live), which could trigger a recreate-before-drain →
            // the doubled WARP stack / `DCTEvent` use-after-free. `release` is
            // idempotent, so this stays safe if `detachFromDisplay` already ran.
            self.deviceSession = nil
            await self.sessionManager.release(consumerLabel: "lens")
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
    // Drain any attach already past the `!suspendAttach` guard and suspended inside
    // `acquire`/`setupDisplay`, so its trailing lease-add can't outlive the release
    // below. Awaiting (not cancelling) is safe: `acquire` completes predictably now
    // that it's serialized in the manager.
    if let inflight = attachTask {
      await inflight.value
      attachTask = nil
    }
    stateListenerToken = nil
    displayStateContinuation?.finish()
    displayStateContinuation = nil
    displayStateTask?.cancel()
    displayStateTask = nil
    await display?.stop()
    display = nil

    // The manager's session-error fan-out subscription for this attach.
    managerSessionErrorsCancellable?.cancel()
    managerSessionErrorsCancellable = nil
    managerSessionInvalidatedCancellable?.cancel()
    managerSessionInvalidatedCancellable = nil

    // Release the DeviceSession. The manager owns it, so drop our local
    // ref BEFORE telling the manager — if the manager decides to stop the
    // session (last consumer releasing), the stop happens against the
    // underlying SDK object, not us.
    deviceSession = nil
    await sessionManager.release(consumerLabel: "lens")

    isConnected = false
    pendingAction = nil
    // Drop any tree still queued for the (now gone) link. The drainer, if
    // running, exits on its next `display`/`isConnected` re-check. We do NOT
    // cancel `sendDrainTask` here — it may be suspended inside `capability.send`
    // and cancelling would race teardown; letting it drain naturally is safe.
    queuedSend = nil
  }

  private func handleSessionError(_ error: DeviceSessionError) {
    print("[LensDisplayCoordinator] DeviceSession error stream → \(error)")
    requiresDATAppUpdate = error == .datAppOnTheGlassesUpdateRequired
    didFailToStartSession = true
    errorMessage = "DeviceSessionError.\(error): \(error.localizedDescription)"
  }

  /// The shared session was force-invalidated out of band (a sibling consumer
  /// detected the transport is dead). Our `DeviceSession` is now a corpse —
  /// detach the display capability instead of pumping `send`s into a dead link.
  /// A subsequent renderer `send` will lazily re-attach via a fresh session.
  private func handleSessionInvalidated(_ reason: String) async {
    print("[LensDisplayCoordinator] session invalidated → \(reason); detaching display")
    await detachFromDisplay()
  }
}
