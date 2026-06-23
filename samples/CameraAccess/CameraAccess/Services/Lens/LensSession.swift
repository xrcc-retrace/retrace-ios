//
// LensSession.swift
//
// Top-level dispatcher for on-glasses lens output. Owns the
// `LensDisplayCoordinator` (SDK lifecycle) and the currently-active
// per-flow `LensRenderer`. Mode views call `activate(_:vm:)` on
// `.onAppear` and `deactivate()` on `.onDisappear` so the right
// renderer is wired to the right view model at the right time.
//
// Output is gated by the `@AppStorage("lensOutputEnabled")` toggle in
// Server Settings → Debug. When the toggle is OFF, every `send(_:)`
// silently no-ops. This keeps Step 3+ work safe to iterate on without
// disturbing the existing emulator UX.
//
// In Step 3 the dispatcher is minimal: it owns the coordinator and
// gates sends on the toggle. `activate(_:vm:)` is a no-op until renderers
// land in Steps 6, 8, 9.
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

  /// Whether the last `send(_:)` saw the toggle ON. Used to log once
  /// per state transition (toggle flip) instead of per-send.
  private var lastLoggedToggleState: Bool? = nil

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
  /// The only gate that belongs in this wrapper is the user-controlled
  /// `lensOutputEnabled` toggle from Server Settings → Debug.
  /// Acquire-time failures (non-display device active, no display-capable
  /// device reachable, DAT helper missing) surface via the coordinator's
  /// own log lines — once per attach attempt, not per send.
  func send(_ view: some DisplayableView) async {
    let toggleOn = UserDefaults.standard.bool(forKey: "lensOutputEnabled")
    if lastLoggedToggleState != toggleOn {
      if toggleOn {
        print("[LensSession] send forwarding → coordinator (lensOutputEnabled=true)")
      } else {
        print("[LensSession] send suppressed — lensOutputEnabled=false in Server Settings → Debug")
      }
      lastLoggedToggleState = toggleOn
    }
    guard toggleOn else { return }
    await coordinator.send(view)
  }

  /// Mount a renderer for the given flow. The supplied `vm` is the
  /// flow's view model; renderers downcast it on instantiation.
  ///
  /// As of Step 6, the coaching renderer is wired. Troubleshoot (Step 8)
  /// and expert (Step 9) renderers will land via additional switch arms.
  /// `handoffToPhone` ships in Step 10.
  func activate(_ flow: LensFlow, vm: AnyObject?) {
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
    lastLoggedToggleState = nil
    currentFlow = .idle
    Task { [weak self] in
      await self?.send(FlexBox(direction: MWDATDisplay.Direction.column) {})
    }
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
  func presentReferenceClip(
    uri: String,
    onStarted: @escaping () -> Void = {},
    onEnded: @escaping () -> Void,
    onError: @escaping (String) -> Void = { _ in }
  ) async {
    guard UserDefaults.standard.bool(forKey: "lensOutputEnabled") else { return }
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
    // (`.ended` / `.stopped`) will arrive to un-pause; the silent
    // `lensOutputEnabled`-off early-return above never reaches this point,
    // so the caller can't latch the gate closed forever.
    onStarted()

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
    guard let display = coordinator.display else { return }
    await display.sendVideoStop()
  }
}
