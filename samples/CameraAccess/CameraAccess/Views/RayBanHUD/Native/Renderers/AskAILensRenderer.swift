//
// AskAILensRenderer.swift
//
// Subscribes to `AskAISessionViewModel`'s published search state and emits the
// Ask-AI lens trees through `LensSession.send(_:)`. Same skeleton as the
// navigator/coaching renderers: CombineLatest → throttle(120ms) → project →
// `AskAILensTrees.tree(...)` → send.
//

import Combine
import Foundation
import MWDATDisplay

@MainActor
final class AskAILensRenderer: LensRenderer {

  private let viewModel: AskAISessionViewModel
  private weak var lensSession: LensSession?
  private var cancellables: Set<AnyCancellable> = []

  init(viewModel: AskAISessionViewModel, lensSession: LensSession) {
    self.viewModel = viewModel
    self.lensSession = lensSession
    subscribe()
    // Paint immediately on activation so the lens shows the listening card the
    // moment Ask AI opens (before the first state change).
    scheduleSend()
  }

  func cancel() {
    cancellables.removeAll()
  }

  /// Recover the HUD after a system back-gesture dismiss. No dedupe cache here —
  /// `scheduleSend()` always sends — so just re-project and re-send.
  func repaint() {
    scheduleSend()
  }

  private func subscribe() {
    Publishers.CombineLatest3(
      viewModel.$searchState,
      viewModel.$candidates,
      viewModel.$expandedCandidate
    )
    .throttle(for: .milliseconds(120), scheduler: DispatchQueue.main, latest: true)
    .sink { [weak self] _ in
      self?.scheduleSend()
    }
    .store(in: &cancellables)
  }

  private func projectSnapshot() -> AskAILensSnapshot {
    let screen: AskAILensSnapshot.Screen
    switch viewModel.searchState {
    case .listening: screen = .listening
    case .results:   screen = .results
    case .expanded:  screen = .expanded
    case .notFound:  screen = .notFound
    }
    let rows = viewModel.candidates.map {
      AskAILensSnapshot.Row(id: $0.procedureId, title: $0.title)
    }
    return AskAILensSnapshot(
      screen: screen,
      rows: rows,
      expandedTitle: viewModel.expandedCandidate?.title ?? "",
      expandedReason: LensComponents.truncate(viewModel.expandedCandidate?.matchReason ?? "", max: 200)
    )
  }

  private func scheduleSend() {
    let snapshot = projectSnapshot()
    let callbacks = makeCallbacks()
    let tree = AskAILensTrees.tree(snapshot: snapshot, callbacks: callbacks)
    Task { [weak self] in
      await self?.lensSession?.send(tree)
    }
  }

  private func makeCallbacks() -> AskAILensCallbacks {
    AskAILensCallbacks(
      onSelectCandidate: { [weak viewModel] id in Task { @MainActor in viewModel?.expand(procedureId: id) } },
      onStart:           { [weak viewModel] in Task { @MainActor in viewModel?.startSelected() } },
      onBack:            { [weak viewModel] in Task { @MainActor in viewModel?.back() } }
    )
  }
}
