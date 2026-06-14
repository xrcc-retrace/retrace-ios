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
// BT send. The renderer owns no local UI state (unlike Coaching's
// `expansion` / `descPage`) — the troubleshoot phase tree is fully
// driven by VM state.
//

import Combine
import Foundation
import MWDATDisplay

@MainActor
final class TroubleshootLensRenderer: LensRenderer {

  // MARK: - Inputs

  private let viewModel: DiagnosticSessionViewModel
  private weak var lensSession: LensSession?

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
        self?.scheduleSend()
      }
      .store(in: &cancellables)
  }

  // MARK: - Snapshot projection

  private func projectSnapshot() -> TroubleshootLensSnapshot {
    TroubleshootLensSnapshot(
      phase: mapPhase(viewModel.phase),
      isMuted: viewModel.isMuted,
      connection: connectionStatus(),
      identifiedProductName: viewModel.identifiedProduct?.productName,
      identifiedCategory: viewModel.identifiedProduct?.category,
      identifiedConfidence: nil,  // VM doesn't currently expose confidence; future addition
      pendingConfirmation: viewModel.pendingConfirmation,
      narration: mapNarration(viewModel.searchNarration),
      resolution: mapResolution(viewModel.resolution),
      handoffInFlight: viewModel.handoffInFlight,
      handoffError: viewModel.handoffError,
      showManualUploadSheet: viewModel.showManualUploadSheet,
      showDismissConfirmation: false  // view-owned, lens doesn't mirror per Step 8 scope
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
      onExit: { [weak viewModel] in
        Task { @MainActor in
          // Same back-gesture hook the SwiftUI view installed in
          // `.onAppear` — surfaces the end-diagnostic confirmation
          // overlay on the phone. The lens stays on the active phase
          // tree (Step 8 scope; see file header for rationale).
          viewModel?.onBackGesture?()
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
      }
    )
  }
}
