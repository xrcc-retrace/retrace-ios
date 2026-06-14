//
// CoachingLensRenderer.swift
//
// Subscribes to `CoachingSessionViewModel`'s published state and emits
// `FlexBox` trees through `LensSession.send(_:)`. Owns the lens-side
// local UI state (`expansion`, `descPage`) — these are independent of
// the SwiftUI emulator's own state (the lens and the emulator are two
// surfaces of the same VM, each with its own focus/expansion).
//
// Celebration sequencing is fully driven by VM state — the VM owns the
// 1.5s + 0.3s timeline by toggling `celebratingStepIndex` and
// `displayedStepIndex`. The renderer just dispatches the right tree per
// snapshot; no `Task.sleep` here.
//
// Conforms to `LensRenderer` (defined in `Services/Lens/LensRendererProtocol.swift`)
// so `LensSession` can hold and cancel it generically.
//

import Combine
import Foundation
import MWDATDisplay

@MainActor
final class CoachingLensRenderer: LensRenderer {

  // MARK: - Inputs

  private let viewModel: CoachingSessionViewModel
  private weak var lensSession: LensSession?

  // MARK: - Local UI state (lens-side only — does NOT mirror the phone emulator's @State)

  private var expansion: CoachingLensSnapshot.LensCoachingExpansion = .collapsed
  private var descPage: Int = 0

  // MARK: - Subscriptions

  private var cancellables: Set<AnyCancellable> = []

  // MARK: - Init

  init(viewModel: CoachingSessionViewModel, lensSession: LensSession) {
    self.viewModel = viewModel
    self.lensSession = lensSession
    subscribe()
  }

  // MARK: - LensRenderer

  func cancel() {
    cancellables.removeAll()
  }

  // MARK: - Subscription wiring

  /// Combine pipeline that re-renders on any relevant @Published change.
  /// Throttle to 120ms collapses rapid bursts (a single step-advance
  /// transition fires `currentStepIndex`, `displayedStepIndex`,
  /// `celebratingStepIndex`, and `slideDirection` within one frame).
  private func subscribe() {
    // Publishers.CombineLatest takes at most 4 sources — chain via
    // CombineLatest{4,3,2} as needed.
    let stepState = Publishers.CombineLatest4(
      viewModel.$currentStepIndex,
      viewModel.$displayedStepIndex,
      viewModel.$isCompleted,
      viewModel.$celebratingStepIndex
    )
    let mutedAndConnection = Publishers.CombineLatest(
      viewModel.$isMuted,
      viewModel.$geminiConnectionState
    )

    Publishers.CombineLatest(stepState, mutedAndConnection)
      .throttle(for: .milliseconds(120), scheduler: DispatchQueue.main, latest: true)
      .sink { [weak self] _ in
        self?.scheduleSend()
      }
      .store(in: &cancellables)
  }

  // MARK: - Snapshot projection

  private func projectSnapshot() -> CoachingLensSnapshot {
    let step = viewModel.displayedStep
    let description = step?.description ?? ""
    let pages = LensComponents.paginate(description, chunkSize: 180)
    let insights = buildInsights(from: step)

    // Bound descPage to the actual page count (in case the description
    // shrunk after a step transition).
    let safePage = pages.indices.contains(descPage) ? descPage : 0

    let posterURL: String? = {
      guard let step, step.clipUrl != nil else { return nil }
      return LensImageURL.clipPosterURL(
        procedureId: viewModel.lensProcedureId,
        stepIndex: step.stepNumber
      )
    }()

    return CoachingLensSnapshot(
      pageKind: viewModel.isCompleted ? .completion : .step,
      isMuted: viewModel.isMuted,
      connection: connectionStatus(),
      showDismissConfirmation: false,  // wired up in a future iteration
      stepIndex: viewModel.displayedStepIndex,
      totalSteps: viewModel.lensTotalSteps,
      stepTitle: step?.title ?? "",
      stepDescription: description,
      expansion: expansion,
      hasClip: step?.clipUrl != nil,
      clipPosterURL: posterURL,
      insights: insights,
      descPage: safePage,
      descPagesTotal: pages.count,
      celebratingStepIndex: viewModel.celebratingStepIndex,
      procedureTitle: viewModel.lensProcedureTitle,
      formattedSessionDuration: viewModel.formattedSessionDuration
    )
  }

  private func buildInsights(from step: ProcedureStepResponse?) -> [CoachingLensSnapshot.InsightItem] {
    guard let step else { return [] }
    var items: [CoachingLensSnapshot.InsightItem] = []
    items.append(contentsOf: step.tips.map { .init(category: "Tip", text: $0) })
    items.append(contentsOf: step.warnings.map { .init(category: "Warning", text: $0) })
    items.append(contentsOf: step.errorCriteria.map { .init(category: "Red flag", text: $0) })
    return items
  }

  private func connectionStatus() -> LensConnectionStatus {
    switch viewModel.geminiConnectionState {
    case .connected:    return .connected
    case .connecting:   return .connecting
    case .disconnected: return .idle
    case .error(let reason): return .failed(reason: reason)
    }
  }

  // MARK: - Send pipeline

  /// Build the current snapshot, dispatch through the right tree function,
  /// and send to LensSession. Called from the throttled subscriber AND
  /// from local-state mutations (toggle taps, page changes).
  private func scheduleSend() {
    let snapshot = projectSnapshot()
    let callbacks = makeCallbacks()
    let tree = CoachingLensTrees.tree(snapshot: snapshot, callbacks: callbacks)
    Task { [weak self] in
      await self?.lensSession?.send(tree)
    }
  }

  // MARK: - Callbacks (lens-side intents)

  private func makeCallbacks() -> CoachingLensCallbacks {
    CoachingLensCallbacks(
      onToggleReference: { [weak self] in
        guard let self else { return }
        self.expansion = (self.expansion == .referenceExpanded) ? .collapsed : .referenceExpanded
        self.descPage = 0
        self.scheduleSend()
      },
      onToggleInsights: { [weak self] in
        guard let self else { return }
        self.expansion = (self.expansion == .insightsExpanded) ? .collapsed : .insightsExpanded
        self.descPage = 0
        self.scheduleSend()
      },
      onExpandStep: { [weak self] in
        guard let self else { return }
        self.expansion = .stepExpanded
        self.descPage = 0
        self.scheduleSend()
      },
      onCollapse: { [weak self] in
        guard let self else { return }
        self.expansion = .collapsed
        self.descPage = 0
        self.scheduleSend()
      },
      onDescPagePrev: { [weak self] in
        guard let self else { return }
        self.descPage = max(0, self.descPage - 1)
        self.scheduleSend()
      },
      onDescPageNext: { [weak self] in
        guard let self else { return }
        let description = self.viewModel.displayedStep?.description ?? ""
        let pages = LensComponents.paginate(description, chunkSize: 180)
        self.descPage = min(max(0, pages.count - 1), self.descPage + 1)
        self.scheduleSend()
      },
      onMuteToggle: { [weak viewModel] in
        Task { @MainActor in
          viewModel?.toggleMute()
        }
      },
      onExit: { [weak viewModel] in
        Task { @MainActor in
          // Fire the same callback that the lens middle-pinch fires,
          // surfacing the exit-confirmation overlay on the phone side.
          viewModel?.onBackGesture?()
        }
      },
      onReferenceClipTap: { [weak self] in
        // Step 7 wires `LensSession.presentReferenceClip` — for now this
        // is a no-op until the video handoff plumbing lands.
        _ = self
      },
      onCompletionExit: { [weak viewModel] in
        Task { @MainActor in
          viewModel?.onBackGesture?()
        }
      },
      onExitConfirmCancel: {
        // No-op until exit overlay wiring lands (snapshot.showDismissConfirmation
        // stays false in this iteration, so this never fires).
      },
      onExitConfirmConfirm: {
        // Same — placeholder.
      }
    )
  }
}
