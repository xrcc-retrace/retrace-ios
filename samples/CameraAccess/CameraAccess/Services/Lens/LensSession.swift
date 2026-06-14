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

  init(coordinator: LensDisplayCoordinator) {
    self.coordinator = coordinator
  }

  // MARK: - Public API

  /// Send a DisplayableView (FlexBox or VideoPlayer) to the glasses.
  /// Silently no-ops when the lens output toggle is off or no display
  /// is paired. Renderers and ad-hoc smoke tests call through here so
  /// the toggle gate stays in one place.
  func send(_ view: some DisplayableView) async {
    guard UserDefaults.standard.bool(forKey: "lensOutputEnabled") else { return }
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

    case .troubleshoot, .expert, .handoffToPhone, .idle:
      // Step 8/9/10 land these. For now activation is a no-op and the
      // lens retains whatever tree was last sent.
      break
    }
  }

  /// Tear down the active renderer. Leaves the last-sent tree on the
  /// lens — the next `activate()` will repaint. The display capability
  /// itself stays attached (it's app-scoped via `LensDisplayCoordinator`).
  func deactivate() {
    currentRenderer?.cancel()
    currentRenderer = nil
    currentFlow = .idle
  }
}
