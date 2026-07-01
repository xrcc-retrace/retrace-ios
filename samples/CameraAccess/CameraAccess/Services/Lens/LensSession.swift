//
// LensSession.swift
//
// Top-level dispatcher for on-glasses lens output. Owns the
// `LensDisplayCoordinator` (SDK lifecycle) and the currently-active
// per-flow `LensRenderer`. Mode views call `activate(_:vm:)` on
// `.onAppear` and `deactivate()` on `.onDisappear` so the right
// renderer is wired to the right view model at the right time.
//
// Every `send(_:)` forwards to the coordinator, which owns the on-glasses
// Display lifecycle (lazy-attach, lazy-detach). When no Display-capable
// device is reachable the coordinator's acquire fails non-fatally and logs
// once per attach attempt — sends from an iPhone-only run cost nothing.
//

import Combine
import Foundation
import MWDATDisplay
import SwiftUI

@MainActor
final class LensSession: ObservableObject {
  /// The on-glasses display capability. Exposed so callers wiring
  /// video → UI handoff (Step 7) can attach `onPlaybackEvent` directly.
  let coordinator: LensDisplayCoordinator

  /// The flow currently driving lens output. `nil` when no view is mounted.
  @Published private(set) var currentFlow: LensFlow = .idle

  /// The active renderer. Single-slot; replaced on `activate(_:vm:)`.
  private var currentRenderer: LensRenderer?

  /// Safety-net timer for reference-clip playback. Armed when a clip starts,
  /// cancelled on the terminal `.ended`/`.stopped` event, on error, on a
  /// back-gesture stop, or when a new clip replaces it. If the SDK never
  /// delivers a terminal event (BT drop mid-clip, display detach), this fires
  /// `onEnded` so the caller's restore path (un-mute Gemini, un-gate camera)
  /// still runs instead of latching the camera/mic off until session teardown.
  private var clipWatchdog: Task<Void, Never>?

  init(coordinator: LensDisplayCoordinator) {
    self.coordinator = coordinator
  }

  // MARK: - Public API

  /// Send a DisplayableView (FlexBox or VideoPlayer) to the glasses.
  ///
  /// Calls through to `LensDisplayCoordinator.send(_:)` which owns the
  /// **lazy-attach** lifecycle: when `display == nil`, that first send
  /// is what triggers `attachToDisplay()` and queues the view to fire
  /// once the Display capability reaches `.started`. We must NOT short-
  /// circuit here on `display == nil`, or the lens never attaches.
  ///
  /// Acquire-time failures (non-display device active, no display-capable
  /// device reachable, DAT helper missing) surface via the coordinator's
  /// own log lines — once per attach attempt, not per send.
  func send(_ view: some DisplayableView) async {
    await coordinator.send(view)
  }

  /// Mount a renderer for the given flow. The supplied `vm` is the
  /// flow's view model; renderers downcast it on instantiation.
  ///
  /// As of Step 6, the coaching renderer is wired. Troubleshoot (Step 8)
  /// and expert (Step 9) renderers will land via additional switch arms.
  /// `handoffToPhone` ships in Step 10.
  func activate(_ flow: LensFlow, vm: AnyObject?) {
    // A legitimate activation re-enables attaching after any prior terminal
    // teardown (return-to-phone) suppressed it.
    coordinator.resumeAttaching()
    currentRenderer?.cancel()
    currentRenderer = nil
    currentFlow = flow

    switch flow {
    case .coaching:
      guard let coachingVM = vm as? CoachingSessionViewModel else {
        print("[LensSession] activate(.coaching) skipped — vm is not CoachingSessionViewModel")
        return
      }
      currentRenderer = CoachingLensRenderer(viewModel: coachingVM, lensSession: self)
      print("[LensSession] activate(.coaching) ✓")

    case .troubleshoot:
      guard let diagnosticVM = vm as? DiagnosticSessionViewModel else {
        print("[LensSession] activate(.troubleshoot) skipped — vm is not DiagnosticSessionViewModel")
        return
      }
      currentRenderer = TroubleshootLensRenderer(viewModel: diagnosticVM, lensSession: self)
      print("[LensSession] activate(.troubleshoot) ✓")

    case .expert:
      guard let context = vm as? ExpertLensContext else {
        print("[LensSession] activate(.expert) skipped — vm is not ExpertLensContext")
        return
      }
      currentRenderer = ExpertLensRenderer(context: context, lensSession: self)
      print("[LensSession] activate(.expert) ✓")

    case .navigator:
      guard let navVM = vm as? NavigatorViewModel else {
        print("[LensSession] activate(.navigator) skipped — vm is not NavigatorViewModel")
        return
      }
      currentRenderer = NavigatorLensRenderer(viewModel: navVM, lensSession: self)
      print("[LensSession] activate(.navigator) ✓")

    case .askAI:
      guard let askVM = vm as? AskAISessionViewModel else {
        print("[LensSession] activate(.askAI) skipped — vm is not AskAISessionViewModel")
        return
      }
      currentRenderer = AskAILensRenderer(viewModel: askVM, lensSession: self)
      print("[LensSession] activate(.askAI) ✓")

    case .handoffToPhone, .idle:
      // Step 10 lands `.handoffToPhone`. For now activation is a no-op
      // and the lens retains whatever tree was last sent.
      break
    }
  }

  /// Tear down the active renderer and CLEAR the lens. The display capability
  /// itself stays attached (it's app-scoped via `LensDisplayCoordinator`), but
  /// we send an empty root so stale content (e.g. the coaching steps / exit
  /// overlay) doesn't linger on the glasses after the session ends — the next
  /// `activate()` repaints. Without this clear, exiting a session left the
  /// last tree frozen on the display.
  func deactivate() {
    currentRenderer?.cancel()
    currentRenderer = nil
    currentFlow = .idle
    // Clear the glasses ONLY if we're still attached. NEVER re-acquire the
    // Display (and the shared Bluetooth DeviceSession) just to paint an empty
    // frame: during an exit that would re-acquire the very session the exit is
    // releasing, racing the manager's WARP drain (→ `sessionAlreadyExists`).
    guard coordinator.display != nil else { return }
    Task { [weak self] in
      await self?.send(FlexBox(direction: MWDATDisplay.Direction.column) {})
    }
  }

  /// Terminal teardown for "return to phone". Unlike `deactivate()` — which only
  /// clears the renderer and repaints, keeping the app-scoped Display attached —
  /// this HARD-detaches: it suppresses further lazy re-attach and releases the
  /// `"lens"` DeviceSession lease deterministically and awaited, so the Bluetooth
  /// session is actually let go and can't be revived by a trailing `send(_:)`.
  /// Called from `GlassesNavigationCoordinator.exitGlassesMode()`.
  func teardown() async {
    currentRenderer?.cancel()
    currentRenderer = nil
    currentFlow = .idle
    coordinator.suspendAttaching()
    await coordinator.detachFromDisplay()
  }

  // MARK: - Reference clip handoff (Step 7)

  /// Present a reference clip in full-screen takeover mode. Per
  /// `mwdat-ios:display-access`: *"Each `send(_:)` replaces the previous
  /// content on the glasses... Use a root `FlexBox` for UI, or a root
  /// `VideoPlayer` for video."* Sending a `VideoPlayer` here displaces
  /// the active FlexBox tree entirely; on `.ended` / `.stopped`,
  /// `onEnded` fires so the caller (the active renderer) can re-send
  /// its current snapshot tree to return the UI.
  ///
  /// Critical contract from the plugin docs: install `onPlaybackEvent`
  /// BEFORE sending the video so the terminal event isn't dropped on
  /// the floor while the closure is being attached.
  /// `onError` fires with a human-readable reason when the clip can't be
  /// shown — display not attached, a malformed/non-HTTP(S) URL, or an SDK
  /// playback/load failure (e.g. the server 404'd the .mp4). The renderer
  /// uses it to surface a visible "couldn't load clip" card on the lens
  /// instead of failing silently.
  /// `expectedDuration` (the step's clip length, when known) sizes the
  /// playback watchdog: it fires at `expectedDuration + 5s`, or a hard 60s
  /// cap when the duration is unknown/non-positive.
  func presentReferenceClip(
    uri: String,
    expectedDuration: TimeInterval? = nil,
    onStarted: @escaping () -> Void = {},
    onEnded: @escaping () -> Void,
    onError: @escaping (String) -> Void = { _ in }
  ) async {
    // A new clip supersedes any prior one — cancel a stale watchdog so it
    // can't fire against this presentation.
    clipWatchdog?.cancel()
    clipWatchdog = nil

    guard let display = coordinator.display else {
      print("[LensSession] presentReferenceClip skipped — display not attached")
      onError("Display not attached")
      return
    }

    // Pre-validate: the DAT VideoPlayer throws DisplayError.invalidVideoURL
    // on blank/non-HTTP(S) URLs. Catch it here so we surface a clear reason
    // rather than letting it get swallowed inside coordinator.send.
    guard let parsed = URL(string: uri),
          let scheme = parsed.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else {
      print("[LensSession] presentReferenceClip skipped — invalid video URL: \(uri)")
      onError("Invalid clip URL")
      return
    }

    // Latency instrumentation (always on, independent of any experiment toggle):
    // the `.started` event is the real "video began playing" signal, so the gap
    // from our `coordinator.send` below is the on-glasses load latency we're
    // tuning. `clipSendAt` is captured by reference and set just before the send.
    var clipSendAt: Date?
    display.onPlaybackEvent = { [weak self] event in
      switch event.type {
      case .started:
        if let sentAt = clipSendAt {
          let ms = Int(Date().timeIntervalSince(sentAt) * 1000)
          print("[LensClip] first frame after \(ms)ms")
        }
      case .ended, .stopped:
        Task { @MainActor [weak self] in
          self?.clipWatchdog?.cancel()
          self?.clipWatchdog = nil
          self?.coordinator.display?.onPlaybackEvent = nil
          onEnded()
        }
      default:
        break
      }
    }

    // All guards have passed and we're committed to displaying the clip —
    // signal "started" now so the caller can pause the Gemini loop. Firing
    // here (not before the guards) guarantees a matching terminal event
    // (`.ended` / `.stopped`) will arrive to un-pause; the display-not-attached
    // early-return above never reaches this point, so the caller can't latch
    // the gate closed forever.
    onStarted()

    // Arm the safety-net watchdog now that the clip is committed. If no
    // terminal `.ended`/`.stopped` ever arrives (BT drop mid-clip, display
    // detach), this fires `onEnded` on the main actor so the caller still
    // restores the camera + Gemini audio and repaints the step card.
    let timeout = (expectedDuration.map { $0 > 0 ? $0 + 5 : 60 }) ?? 60
    clipWatchdog = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self, !Task.isCancelled else { return }
        print("[LensSession] clip watchdog fired after \(Int(timeout))s — forcing restore")
        self.clipWatchdog = nil
        self.coordinator.display?.onPlaybackEvent = nil
        onEnded()
      }
    }

    // `MWDATDisplay.VideoPlayer` is qualified explicitly because this
    // file imports SwiftUI (for `@MainActor` plumbing) and SwiftUI's
    // `VideoPlayer` from AVKit can collide with the DSL one. Same rule
    // applies in any renderer file that mixes SwiftUI + MWDATDisplay
    // (per the plan's Constraint #8).
    clipSendAt = Date()  // start the send → .started latency clock
    await coordinator.send(
      MWDATDisplay.VideoPlayer(
        provider: .uri(uri),
        codec: .mp4,
        onError: { error in
          print("[LensSession] VideoPlayer error: \(error)")
          // Hand the failure back to the renderer on the main actor so it
          // can paint an error card. Clear the now-stale playback handler.
          Task { @MainActor [weak self] in
            self?.clipWatchdog?.cancel()
            self?.clipWatchdog = nil
            self?.coordinator.display?.onPlaybackEvent = nil
            onError(String(describing: error))
          }
        }
      )
    )
  }

  /// User-initiated early exit during clip playback (e.g. Neural Band
  /// back gesture). Sends a stop to the SDK, which triggers a `.stopped`
  /// playback event — the handler installed by `presentReferenceClip`
  /// then re-sends the active snapshot tree.
  ///
  /// Not wired yet from a back-gesture handler — Step 11 will add the
  /// "interrupt playback on back gesture" path. This exists so that
  /// path has a single call site to target.
  func dismissReferenceClip() async {
    // The `sendVideoStop()` below produces a `.stopped` event that cancels the
    // watchdog too, but cancel eagerly in case the stop event is itself dropped.
    clipWatchdog?.cancel()
    clipWatchdog = nil
    guard let display = coordinator.display else { return }
    await display.sendVideoStop()
  }
}
