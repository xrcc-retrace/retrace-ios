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

  /// Reason the last `send(_:)` was suppressed (or `.delivered` if it
  /// actually went through). Used to log only on transitions so a
  /// renderer pumping 8 BT-sends/sec doesn't flood the console with the
  /// same suppression message. Cleared on `deactivate()`.
  private enum SendState { case undecided, delivered, toggleOff, displayNil }
  private var lastSendState: SendState = .undecided

  init(coordinator: LensDisplayCoordinator) {
    self.coordinator = coordinator
  }

  // MARK: - Public API

  /// Send a DisplayableView (FlexBox or VideoPlayer) to the glasses.
  /// Silently no-ops when the lens output toggle is off or no display
  /// is paired. Renderers and ad-hoc smoke tests call through here so
  /// the toggle gate stays in one place.
  ///
  /// Suppression reasons are logged once per state transition (not per
  /// send) — so "lens output disabled" or "display unavailable on this
  /// device" surfaces clearly in the console without spamming.
  func send(_ view: some DisplayableView) async {
    guard UserDefaults.standard.bool(forKey: "lensOutputEnabled") else {
      if lastSendState != .toggleOff {
        print("[LensSession] send suppressed — lensOutputEnabled=false in Server Settings → Debug")
        lastSendState = .toggleOff
      }
      return
    }
    guard coordinator.display != nil else {
      if lastSendState != .displayNil {
        print("[LensSession] send suppressed — no display capability (non-display glasses or display not yet attached)")
        lastSendState = .displayNil
      }
      return
    }
    if lastSendState != .delivered {
      print("[LensSession] send delivering → glasses display")
      lastSendState = .delivered
    }
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

  /// Tear down the active renderer. Leaves the last-sent tree on the
  /// lens — the next `activate()` will repaint. The display capability
  /// itself stays attached (it's app-scoped via `LensDisplayCoordinator`).
  func deactivate() {
    currentRenderer?.cancel()
    currentRenderer = nil
    lastSendState = .undecided
    currentFlow = .idle
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
  func presentReferenceClip(
    uri: String,
    onEnded: @escaping () -> Void
  ) async {
    guard UserDefaults.standard.bool(forKey: "lensOutputEnabled") else { return }
    guard let display = coordinator.display else {
      print("[LensSession] presentReferenceClip skipped — display not attached")
      return
    }

    display.onPlaybackEvent = { [weak self] event in
      if event.type == .ended || event.type == .stopped {
        Task { @MainActor [weak self] in
          self?.coordinator.display?.onPlaybackEvent = nil
          onEnded()
        }
      }
    }

    // `MWDATDisplay.VideoPlayer` is qualified explicitly because this
    // file imports SwiftUI (for `@MainActor` plumbing) and SwiftUI's
    // `VideoPlayer` from AVKit can collide with the DSL one. Same rule
    // applies in any renderer file that mixes SwiftUI + MWDATDisplay
    // (per the plan's Constraint #8).
    await coordinator.send(
      MWDATDisplay.VideoPlayer(
        provider: .uri(uri),
        codec: .mp4,
        onError: { error in
          print("[LensSession] VideoPlayer error: \(error)")
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
