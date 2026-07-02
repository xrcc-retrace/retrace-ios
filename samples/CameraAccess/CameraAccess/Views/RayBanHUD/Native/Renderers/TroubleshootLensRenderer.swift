//
// TroubleshootLensRenderer.swift
//
// Mirrors `CoachingLensRenderer` for troubleshoot mode. Subscribes to
// `DiagnosticSessionViewModel`'s published state, projects into a
// `TroubleshootLensSnapshot`, dispatches to `TroubleshootLensTrees`, and
// emits through `LensSession.send(_:)`.
//
// Per the plan's subscription pattern: ~120ms throttle collapses the 2-4
// `@Published` mutations that fire during one phase transition into one
// BT send. The phase tree is fully VM-driven; the only lens-local state is
// `showExitConfirmation` (the on-lens end-diagnostic overlay flag, mirroring
// coaching).
//

import Combine
import Foundation
import MWDATDisplay

@MainActor
final class TroubleshootLensRenderer: LensRenderer {

  // MARK: - Inputs

  private let viewModel: DiagnosticSessionViewModel
  private weak var lensSession: LensSession?

  // MARK: - Local UI state (lens-side only)

  /// Lens-side exit-confirmation flag. When true, `tree()` renders the
  /// on-lens "End diagnostic?" overlay over the active phase tree. Toggled by
  /// the Exit pill and the overlay's Cancel/Confirm — the confirmation lives
  /// ON the glasses (mirrors coaching), not the phone.
  private var showExitConfirmation = false

  // MARK: - Search animation (paper airplane)

  /// Frame-loop task driving the paper-airplane animation while we're in the
  /// online-search window. Nil when not animating. Mirrors the proven loop in
  /// `ExpertLensRenderer.beginStopCountdown` (no SDK animation primitive — we
  /// repaint a new tree per frame).
  private var searchAnimTask: Task<Void, Never>?
  /// Monotonic frame counter fed into the snapshot; the tree derives the
  /// airplane's horizontal position from it. Reset to 0 when the loop stops.
  private var searchAnimFrame = 0
  /// Frame cadence — ~8 fps. Smooth enough for a gentle slide, cheap on the
  /// BT Display link.
  /// ≥ the MWDATDisplay minimum send spacing (~0.3s) so the airplane loop
  /// can't saturate the link and time out the frame that matters (the
  /// searching → resolved transition).
  private let searchAnimTickNanos: UInt64 = 400_000_000

  // MARK: - Subscriptions

  private var cancellables: Set<AnyCancellable> = []

  // MARK: - Init

  init(viewModel: DiagnosticSessionViewModel, lensSession: LensSession) {
    self.viewModel = viewModel
    self.lensSession = lensSession
    subscribe()
  }

  // MARK: - LensRenderer

  func cancel() {
    cancellables.removeAll()
    searchAnimTask?.cancel()
    searchAnimTask = nil
    searchAnimFrame = 0
  }

  /// Recover the HUD after a system back-gesture dismiss. No dedupe cache here —
  /// `scheduleSend()` always sends — so just re-project and re-send.
  func repaint() {
    scheduleSend()
  }

  // MARK: - Subscription wiring

  /// Two CombineLatest groups (each capped at 4) merged into one
  /// throttled stream. The split is purely a `CombineLatest4`
  /// arity-limit workaround; logically all 7 signals drive each repaint.
  private func subscribe() {
    let phaseAndProduct = Publishers.CombineLatest4(
      viewModel.$phase,
      viewModel.$identifiedProduct,
      viewModel.$pendingConfirmation,
      viewModel.$searchNarration
    )
    let resolutionAndHandoff = Publishers.CombineLatest4(
      viewModel.$resolution,
      viewModel.$handoffInFlight,
      viewModel.$handoffError,
      viewModel.$showManualUploadSheet
    )
    let muteAndConnection = Publishers.CombineLatest(
      viewModel.$isMuted,
      viewModel.$geminiConnectionState
    )

    Publishers.CombineLatest3(phaseAndProduct, resolutionAndHandoff, muteAndConnection)
      .throttle(for: .milliseconds(120), scheduler: DispatchQueue.main, latest: true)
      .sink { [weak self] _ in
        // Start/stop the airplane loop on state edges first, then repaint.
        // The loop itself calls `scheduleSend()` directly (not via this sink),
        // so it can't re-trigger `syncSearchAnimation` and recurse.
        self?.syncSearchAnimation()
        self?.scheduleSend()
      }
      .store(in: &cancellables)
  }

  /// Run the paper-airplane frame loop iff we're in the online-search window
  /// (`searchingWeb` / `synthesizing`). Idempotent: a running loop is left
  /// alone, and leaving the window cancels it and resets the frame. Driven
  /// off the state sink, so every narration/phase edge re-evaluates it.
  private func syncSearchAnimation() {
    let animating: Bool
    switch viewModel.searchNarration {
    case .searchingWeb, .synthesizing: animating = true
    default:                           animating = false
    }

    if animating {
      guard searchAnimTask == nil else { return }
      searchAnimTask = Task { [weak self] in
        guard let self else { return }
        do {
          while !Task.isCancelled {
            try await Task.sleep(nanoseconds: self.searchAnimTickNanos)
            self.searchAnimFrame &+= 1
            self.scheduleSend()
          }
        } catch {
          // Cancelled (left the window or renderer torn down).
        }
      }
    } else if searchAnimTask != nil {
      searchAnimTask?.cancel()
      searchAnimTask = nil
      searchAnimFrame = 0
    }
  }

  // MARK: - Snapshot projection

  private func projectSnapshot() -> TroubleshootLensSnapshot {
    TroubleshootLensSnapshot(
      phase: mapPhase(viewModel.phase),
      isMuted: viewModel.isMuted,
      connection: connectionStatus(),
      identifiedProductName: viewModel.identifiedProduct?.productName,
      identifiedCategory: viewModel.identifiedProduct?.category,
      identifiedConfidence: viewModel.identifiedProduct?.confidence,
      pendingConfirmation: viewModel.pendingConfirmation,
      narration: mapNarration(viewModel.searchNarration),
      resolution: mapResolution(viewModel.resolution),
      handoffInFlight: viewModel.handoffInFlight,
      handoffError: viewModel.handoffError,
      showManualUploadSheet: viewModel.showManualUploadSheet,
      showDismissConfirmation: showExitConfirmation,
      searchAnimFrame: searchAnimFrame
    )
  }

  private func mapPhase(_ phase: DiagnosticPhase) -> TroubleshootLensSnapshot.LensDiagnosticPhase {
    switch phase {
    case .discovering: return .discovering
    case .diagnosing:  return .diagnosing
    case .resolving:   return .resolving
    case .resolved:    return .resolved
    }
  }

  private func mapNarration(
    _ n: DiagnosticSessionViewModel.SearchNarration?
  ) -> TroubleshootLensSnapshot.LensSearchNarration? {
    guard let n else { return nil }
    switch n {
    case .searchingLibrary:               return .searchingLibrary
    case .libraryMissed:                  return .libraryMissed
    case .searchingWeb:                   return .searchingWeb
    case .synthesizing(let count):        return .synthesizing(sourceCount: count)
    case .foundFix(let count):            return .foundFix(sourceCount: count)
    }
  }

  private func mapResolution(
    _ r: DiagnosticResolution?
  ) -> TroubleshootLensSnapshot.LensResolution? {
    guard let r else { return nil }
    switch r {
    case .matchedProcedure(let candidate):
      return .matchedProcedure(title: candidate.title, procedureId: candidate.id)
    case .generatedSOP(let procedureId, let title):
      return .generatedSOP(title: title, procedureId: procedureId)
    case .noMatch:
      return .noMatch
    }
  }

  private func connectionStatus() -> LensConnectionStatus {
    switch viewModel.geminiConnectionState {
    case .connected:          return .connected
    case .connecting:         return .connecting
    case .disconnected:       return .idle
    case .error(let reason):  return .failed(reason: reason)
    }
  }

  // MARK: - Send pipeline

  private func scheduleSend() {
    let snapshot = projectSnapshot()
    let callbacks = makeCallbacks()
    let tree = TroubleshootLensTrees.tree(snapshot: snapshot, callbacks: callbacks)
    Task { [weak self] in
      await self?.lensSession?.send(tree)
    }
  }

  // MARK: - Callbacks (lens-side intents)

  private func makeCallbacks() -> TroubleshootLensCallbacks {
    TroubleshootLensCallbacks(
      onMuteToggle: { [weak viewModel] in
        Task { @MainActor in
          viewModel?.toggleMute()
        }
      },
      onExit: { [weak self] in
        Task { @MainActor in
          // Show the end-diagnostic confirmation ON the lens (was: route to
          // the phone overlay via viewModel.onBackGesture). Mirrors coaching.
          guard let self else { return }
          self.showExitConfirmation = true
          self.scheduleSend()
        }
      },
      onConfirmIdentification: { [weak viewModel] in
        Task { @MainActor in
          viewModel?.confirmIdentification()
        }
      },
      onRequestReIdentify: { [weak viewModel] in
        Task { @MainActor in
          viewModel?.requestReIdentify()
        }
      },
      onStartProcedure: { [weak viewModel] in
        Task { @MainActor in
          // Parity with the SwiftUI Resolved page's Start button. The
          // VM exposes `onLensStartHandoff` so the view layer can pass
          // its `startHandoff(procedureId:)` closure (it owns the
          // `onExit(payload)` navigation, which the renderer can't
          // reach). We pick the procedure id off the current resolution.
          guard let vm = viewModel else { return }
          let procedureId: String? = {
            switch vm.resolution {
            case .matchedProcedure(let c): return c.id
            case .generatedSOP(let id, _): return id
            case .noMatch, .none: return nil
            }
          }()
          guard let pid = procedureId else { return }
          vm.onLensStartHandoff?(pid)
        }
      },
      onRediagnose: { [weak viewModel] in
        Task { @MainActor in
          viewModel?.rediagnose()
        }
      },
      onUploadManual: { [weak viewModel] in
        Task { @MainActor in
          // Mirrors the SwiftUI no-solution page's button: flips the
          // sheet flag and the next snapshot routes to the handoff
          // card via the dispatch in `TroubleshootLensTrees.tree`.
          viewModel?.showManualUploadSheet = true
        }
      },
      onExitConfirmCancel: { [weak self] in
        Task { @MainActor in
          guard let self else { return }
          self.showExitConfirmation = false
          self.scheduleSend()
        }
      },
      onExitConfirmConfirm: { [weak self] in
        Task { @MainActor in
          guard let self else { return }
          self.showExitConfirmation = false
          // Run the host-installed terminal exit (endSession + dismiss/onExit).
          self.viewModel.onExitConfirmed?()
        }
      }
    )
  }
}
