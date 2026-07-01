//
// NavigatorLensRenderer.swift
//
// Subscribes to `NavigatorViewModel`'s published nav state and emits the
// navigation-shell `FlexBox` trees through `LensSession.send(_:)`.
//
// Same skeleton as the coaching/troubleshoot renderers: CombineLatest of the
// VM's `@Published` props → `.throttle(120ms, latest:true)` → `scheduleSend()`
// → `projectSnapshot()` → `NavigatorLensTrees.tree(...)` → `lensSession.send`.
//
// Unlike the coaching renderer, all nav state lives in the VM (the navigator
// IS navigation state), so the tap callbacks just call VM methods — no
// renderer-local UI state to keep in sync.
//

import Combine
import Foundation
import MWDATDisplay

@MainActor
final class NavigatorLensRenderer: LensRenderer {

  private let viewModel: NavigatorViewModel
  private weak var lensSession: LensSession?
  private var cancellables: Set<AnyCancellable> = []

  /// Last snapshot actually sent. Identical snapshots are skipped so we don't
  /// waste BT bandwidth AND — critically for the mini-game — don't reset the
  /// lens focus ring (a re-send always re-anchors focus to the first tappable
  /// element). Mirrors `ExpertLensRenderer`'s dedupe.
  private var lastSentSnapshot: NavigatorLensSnapshot?

  /// Dedupes the per-step reference-image debug line so it prints once per change.
  private var lastImageDiag: String?

  init(viewModel: NavigatorViewModel, lensSession: LensSession) {
    self.viewModel = viewModel
    self.lensSession = lensSession
    subscribe()
    // Paint the current screen immediately on activation (don't wait for the
    // first state change) so the lens shows Home as soon as the navigator opens.
    scheduleSend()
  }

  func cancel() {
    cancellables.removeAll()
  }

  // MARK: - Subscription

  private func subscribe() {
    let nav = Publishers.CombineLatest4(
      viewModel.$screen,
      viewModel.$listPage,
      viewModel.$stepPage,
      viewModel.$procedures
    )
    let loading = Publishers.CombineLatest4(
      viewModel.$isLoadingList,
      viewModel.$listError,
      viewModel.$detail,
      viewModel.$isLoadingDetail
    )

    Publishers.CombineLatest3(nav, loading, viewModel.$selectedCategory)
      .throttle(for: .milliseconds(120), scheduler: DispatchQueue.main, latest: true)
      .sink { [weak self] _ in
        self?.scheduleSend()
      }
      .store(in: &cancellables)

    // The mini-game drives its own repaints (watch-phase flashing + tap
    // feedback). The CombineLatest above is arity-full, so a dedicated sink is
    // the clean add. Same 120ms throttle keeps BT traffic bounded.
    viewModel.game.$state
      .throttle(for: .milliseconds(120), scheduler: DispatchQueue.main, latest: true)
      .sink { [weak self] _ in
        self?.scheduleSend()
      }
      .store(in: &cancellables)

    // The inline reference-image toggle is separate VM state (not in the
    // arity-full CombineLatest above), so it gets its own repaint sink.
    viewModel.$showReferenceImage
      .sink { [weak self] _ in
        self?.scheduleSend()
      }
      .store(in: &cancellables)
  }

  // MARK: - Snapshot projection

  private func projectSnapshot() -> NavigatorLensSnapshot {
    // Map VM screen → snapshot screen.
    let snapScreen: NavigatorLensSnapshot.Screen
    switch viewModel.screen {
    case .home:                       snapScreen = .home
    case .expertHub:                  snapScreen = .expertHub
    case .browseList:                 snapScreen = .browseList
    case .procedureDetail:            snapScreen = .procedureDetail
    case let .expertReview(d):        snapScreen = .expertReview(durationLabel: Self.durationLabel(d))
    case .expertProcessing:           snapScreen = .expertProcessing
    case let .expertDone(t, n, _):    snapScreen = .expertDone(title: t, stepCount: n)
    case let .expertFailed(r):        snapScreen = .expertFailed(reason: r)
    case .learnerHub:                 snapScreen = .learnerHub
    case .learnerFilter:              snapScreen = .learnerFilter
    case .learnerProcedureDetail:     snapScreen = .learnerProcedureDetail
    case .troubleshootIntro:          snapScreen = .troubleshootIntro
    case let .comingSoon(h, r):       snapScreen = .comingSoon(heading: h, reason: r)
    case .retraceGame:                snapScreen = .retraceGame
    }

    // Project the mini-game engine state → 9 row-major cell states.
    // NOTE: no "correct trail" is projected. Mid-sequence correct taps change
    // only internal engine progress, leaving the projected snapshot identical —
    // which `scheduleSend()`'s equality check then suppresses, so the lens isn't
    // resent and the focus ring stays where the player pressed. Per-tap feedback
    // is the cell's audio tone; the grid only repaints on wrong / round-complete.
    let g = viewModel.game.state
    var gameCells = Array(repeating: NavigatorLensSnapshot.CellState.idle, count: 9)
    if let lit = g.litCell, gameCells.indices.contains(lit) { gameCells[lit] = .lit }
    if let wrong = g.wrongCell, gameCells.indices.contains(wrong) { gameCells[wrong] = .wrong }
    let gamePhase: NavigatorLensSnapshot.GamePhase
    switch g.phase {
    case .watch:    gamePhase = .watch
    case .input:    gamePhase = .input
    case .gameOver: gamePhase = .gameOver
    }

    // Full procedure list — no pagination. One tall column; on the Display
    // the user Neural-Band-traverses the rows and (if the SDK follows focus)
    // the viewport scrolls to keep the focused row visible. Pagination is
    // kept in NavigatorViewModel for a quick revert if the Display hard-clips
    // instead of scrolling. See the `pageCount`/`page` fallback below.
    // The Learner hub applies the selected category filter; Expert browse shows
    // the whole library.
    let listSource: [ProcedureListItem]
    switch viewModel.screen {
    case .learnerHub: listSource = viewModel.filteredProcedures
    default:          listSource = viewModel.procedures
    }
    let rows = listSource.map {
      NavigatorLensSnapshot.Row(
        id: $0.id,
        title: $0.title,
        statusLabel: Self.statusLabel($0.status)
      )
    }
    let pageCount = 1
    let page = 0

    // Detail step page.
    let steps = viewModel.detail?.steps ?? []
    let sp = steps.isEmpty ? 0 : min(max(0, viewModel.stepPage), steps.count - 1)
    let step = steps.indices.contains(sp) ? steps[sp] : nil

    // "Watch full recording" is only offered for video-sourced procedures that
    // carry a real source file — manual/web procedures have per-step images, not
    // a full recording, so the pill is hidden for them.
    let detail = viewModel.detail
    let hasRecording = (detail?.sourceType ?? "video").lowercased() == "video"
        && !(detail?.sourceVideo?.isEmpty ?? true)

    // Manual procedures show the current step's page image inline (video steps
    // resolve to .video → nil here, they use the "Watch full recording" pill).
    // Gated on https because the lens Image(uri:) loader is https-only — over a
    // plain-http server we omit it so the card shows text instead of a blank box.
    let referenceImageURL: String? = {
      let base = ServerEndpoint.shared.resolvedBaseURL
      guard base.hasPrefix("https://"),
            let step,
            case .image(let url) = step.referenceMedia(sourceType: detail?.sourceType, baseURL: base)
      else { return nil }
      return url.absoluteString
    }()

    // Debug: one line per (step, resolution) change on the detail screens so a
    // missing reference image is diagnosable (http server → suppressed; no
    // clip_url → nil; video → uses the recording pill instead).
    switch viewModel.screen {
    case .procedureDetail, .learnerProcedureDetail:
      let scheme = ServerEndpoint.shared.resolvedBaseURL.hasPrefix("https://") ? "https" : "http"
      let diag = "step=\(step?.stepNumber ?? -1) sourceType=\(detail?.sourceType ?? "nil") scheme=\(scheme) hasRecording=\(hasRecording) img=\(referenceImageURL ?? "nil")"
      if diag != lastImageDiag {
        lastImageDiag = diag
        print("[Navigator] detail \(diag)")
      }
    default:
      break
    }

    return NavigatorLensSnapshot(
      screen: snapScreen,
      bannerURL: LensImageURL.bannerURL(),
      isLoadingList: viewModel.isLoadingList,
      listError: viewModel.listError,
      listRows: rows,
      listPage: page,
      listPageCount: pageCount,
      categories: NavigatorViewModel.learnerCategories,
      selectedCategory: viewModel.selectedCategory,
      isLoadingDetail: viewModel.isLoadingDetail,
      detailTitle: viewModel.detail?.title ?? "",
      detailMeta: Self.detailMeta(viewModel.detail),
      stepNumber: step?.stepNumber ?? 0,
      stepCount: steps.count,
      stepTitle: step?.title ?? "",
      stepBody: LensComponents.truncate(step?.description ?? "", max: 200),
      stepIndex: sp,
      stepPageCount: steps.count,
      hasRecording: hasRecording,
      referenceImageURL: referenceImageURL,
      isReferenceImageOpen: viewModel.showReferenceImage,
      gamePhase: gamePhase,
      gameCells: gameCells,
      gameRound: g.round,
      gameScore: g.score,
      gameBest: g.best
    )
  }

  // MARK: - Send

  private func scheduleSend() {
    let snapshot = projectSnapshot()
    // Don't paint the Learner hub until its procedures have loaded. Tapping
    // "Learner" flips the screen synchronously (loading state) and then mutates
    // state again when the fetch resolves — two separate runloop ticks, so the
    // throttle can't merge them and the lens would flicker from an empty
    // "Loading procedures…" hub to the populated list. Suppressing the loading
    // send keeps the previous screen (Home) up until the list is ready, so the
    // learner hub is sent exactly once — already populated.
    if case .learnerHub = snapshot.screen, snapshot.isLoadingList { return }
    // Skip redundant sends: an identical tree wastes BT bandwidth and resets
    // the focus ring to the first tappable element. This is what keeps the
    // game cursor put across correct taps (which don't change the snapshot).
    if let last = lastSentSnapshot, last == snapshot { return }
    lastSentSnapshot = snapshot
    let callbacks = makeCallbacks()
    let tree = NavigatorLensTrees.tree(snapshot: snapshot, callbacks: callbacks)
    Task { [weak self] in
      await self?.lensSession?.send(tree)
    }
  }

  // MARK: - Callbacks → VM intents

  private func makeCallbacks() -> NavigatorLensCallbacks {
    NavigatorLensCallbacks(
      onExpert:          { [weak viewModel] in Task { @MainActor in viewModel?.openExpertHub() } },
      onLearner:         { [weak viewModel] in Task { @MainActor in viewModel?.openLearner() } },
      onTroubleshoot:    { [weak viewModel] in Task { @MainActor in viewModel?.openTroubleshoot() } },
      onRecord:          { [weak viewModel] in Task { @MainActor in viewModel?.record() } },
      onBrowse:          { [weak viewModel] in Task { @MainActor in viewModel?.openBrowse() } },
      onSelectProcedure: { [weak viewModel] id in Task { @MainActor in viewModel?.selectProcedure(id: id) } },
      onPrevPage:        { [weak viewModel] in Task { @MainActor in viewModel?.prevPage() } },
      onNextPage:        { [weak viewModel] in Task { @MainActor in viewModel?.nextPage() } },
      onPrevStep:        { [weak viewModel] in Task { @MainActor in viewModel?.prevStep() } },
      onNextStep:        { [weak viewModel] in Task { @MainActor in viewModel?.nextStep() } },
      onBack:            { [weak viewModel] in Task { @MainActor in viewModel?.back() } },
      onReviewOnPhone:   { [weak viewModel] in Task { @MainActor in viewModel?.reviewOnPhone() } },
      onRetryRecording:  { [weak viewModel] in Task { @MainActor in viewModel?.record() } },
      onUploadRecording: { [weak viewModel] in Task { @MainActor in viewModel?.confirmUpload() } },
      onDiscardRecording: { [weak viewModel] in Task { @MainActor in viewModel?.discardRecording() } },
      onAskAI:           { [weak viewModel] in Task { @MainActor in viewModel?.askAI() } },
      onOpenFilter:      { [weak viewModel] in Task { @MainActor in viewModel?.openLearnerFilter() } },
      onSelectCategory:  { [weak viewModel] c in Task { @MainActor in viewModel?.selectCategory(c) } },
      onStartCoaching:   { [weak viewModel] in Task { @MainActor in viewModel?.startCoachingFromDetail() } },
      onWatchRecording:  { [weak self] in Task { @MainActor in self?.watchRecording() } },
      onToggleReferenceImage: { [weak viewModel] in Task { @MainActor in viewModel?.toggleReferenceImage() } },
      onStartTroubleshoot: { [weak viewModel] in Task { @MainActor in viewModel?.startTroubleshoot() } },
      onOpenGame:        { [weak viewModel] in Task { @MainActor in viewModel?.openGame() } },
      onTapCell:         { [weak viewModel] i in Task { @MainActor in viewModel?.tapGameCell(i) } },
      onGameRestart:     { [weak viewModel] in Task { @MainActor in viewModel?.restartGame() } }
    )
  }

  // MARK: - Watch full recording

  /// Play the procedure's FULL source recording full-screen on the lens, reusing
  /// the reference-clip playback path (smooth `?profile=lens` variant + watchdog).
  /// On finish / stop it repaints the procedure-detail (steps) view.
  private func watchRecording() {
    guard let detail = viewModel.detail else {
      print("[Navigator] watchRecording skipped — no detail loaded"); return
    }
    guard let filename = detail.sourceVideo, !filename.isEmpty else {
      print("[Navigator] watchRecording skipped — no source_video on \(detail.id)"); return
    }
    guard (detail.sourceType ?? "video").lowercased() == "video" else {
      print("[Navigator] watchRecording skipped — sourceType=\(detail.sourceType ?? "nil"), not a recording"); return
    }
    guard var uri = LensImageURL.uploadURL(filename: filename) else {
      print("[Navigator] watchRecording skipped — could not build upload URL (empty server base?)"); return
    }
    // Request the bitrate-capped variant so the full recording streams smoothly
    // over the Bluetooth Display link (matches how step clips resolve).
    uri += (uri.contains("?") ? "&" : "?") + "profile=lens"

    let duration = detail.totalDuration
    print("[Navigator] watchRecording → \(uri) (expectedDuration=\(duration)s)")
    Task { [weak self] in
      await self?.lensSession?.presentReferenceClip(
        uri: uri,
        expectedDuration: duration > 0 ? duration : nil,
        onStarted: { print("[Navigator] full-recording playback started") },
        onEnded: { [weak self] in print("[Navigator] full-recording ended/stopped — returning to steps"); self?.repaintAfterClip() },
        onError: { [weak self] reason in print("[Navigator] full-recording error: \(reason)"); self?.repaintAfterClip() }
      )
    }
  }

  /// The full-screen video takeover replaced the FlexBox tree, but the projected
  /// snapshot is otherwise unchanged — so clear the dedupe cache to force a
  /// re-send of the current detail (steps) view. This is the "return to the
  /// previous procedure steps view" after playback ends or is stopped.
  private func repaintAfterClip() {
    lastSentSnapshot = nil
    scheduleSend()
  }

  // MARK: - Helpers

  /// Format a recording duration as "M:SS" for the review-gate caption.
  private static func durationLabel(_ t: TimeInterval) -> String {
    let total = max(0, Int(t.rounded()))
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  private static func statusLabel(_ status: String?) -> String? {
    switch status {
    case "processing":        return "Processing"
    case "failed":            return "Failed"
    case "completed_partial": return "Partial"
    default:                  return nil   // completed / nil → ready, no chip
    }
  }

  private static func detailMeta(_ proc: ProcedureResponse?) -> String {
    guard let proc else { return "" }
    let n = proc.steps.count
    let stepsLabel = "\(n) step\(n == 1 ? "" : "s")"
    let source: String
    switch proc.sourceType {
    case "video":  source = "From a recording"
    case "manual": source = "From a manual"
    case "web":    source = "From the web"
    default:       source = ""
    }
    return source.isEmpty ? stepsLabel : "\(stepsLabel) · \(source)"
  }
}
