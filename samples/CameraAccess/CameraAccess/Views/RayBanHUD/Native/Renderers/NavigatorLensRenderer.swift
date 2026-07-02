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

  /// Recover the HUD after a system back-gesture dismiss: clear the dedupe cache
  /// (an unchanged snapshot would otherwise be suppressed) and re-send the current
  /// screen. Same body as `repaintAfterClip()`.
  func repaint() {
    lastSentSnapshot = nil
    scheduleSend()
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
    // `.receive(on:)` is load-bearing: `@Published` emits in `willSet`, so a
    // bare sink would run `scheduleSend()` BEFORE the property commits and
    // re-project the OLD value — which `scheduleSend`'s dedup then suppresses,
    // so the change wouldn't paint until the NEXT emission. Deferring to the
    // main queue lets the projection read the committed value.
    viewModel.$showReferenceImage
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.scheduleSend()
      }
      .store(in: &cancellables)

    // Saved/All tab selection — same reasoning (the CombineLatest3 above is
    // already at arity), its own repaint sink. `.receive(on:)` for the same
    // `willSet` reason as `$showReferenceImage` above: without it the first tap
    // projected the pre-commit `listTab`, got deduped, and only the SECOND tap
    // painted the new list. (The `CombineLatest3` sink avoids this because
    // `.throttle(scheduler:)` already reschedules off `willSet`.)
    viewModel.$listTab
      .receive(on: DispatchQueue.main)
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

    // "Watch step reference" is only offered when the CURRENT step resolves to
    // a playable video clip — manual/web steps resolve to .image/.none, and
    // failed/missing clips resolve to .none, so the pill is hidden for them.
    let detail = viewModel.detail
    let hasStepClip: Bool = {
      if case .video = resolveStepReferenceMedia() { return true }
      return false
    }()

    // Manual procedures show the current step's page image inline (video steps
    // resolve to .video → nil here, they use the "Watch step reference" pill).
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
      let diag = "step=\(step?.stepNumber ?? -1) sourceType=\(detail?.sourceType ?? "nil") scheme=\(scheme) hasStepClip=\(hasStepClip) img=\(referenceImageURL ?? "nil")"
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
      listTab: viewModel.listTab == .saved ? .saved : .all,
      savedCount: viewModel.savedProcedures.count,
      categories: NavigatorViewModel.learnerCategories,
      selectedCategory: viewModel.selectedCategory,
      isLoadingDetail: viewModel.isLoadingDetail,
      detailTitle: viewModel.detail?.title ?? "",
      detailMeta: Self.detailMeta(viewModel.detail),
      stepNumber: step?.stepNumber ?? 0,
      stepCount: steps.count,
      stepTitle: step?.title ?? "",
      // Truncated ~20% shorter than the original cap so the action pills
      // below the step card stay on-screen instead of getting pushed off the
      // 600px viewport (shared by both learner and expert detail screens).
      stepBody: LensComponents.truncate(step?.description ?? "", max: 160),
      stepIndex: sp,
      stepPageCount: steps.count,
      hasStepClip: hasStepClip,
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
      onSelectListTab:   { [weak viewModel] tab in
        Task { @MainActor in viewModel?.selectListTab(tab == .saved ? .saved : .all) }
      },
      onStartCoaching:   { [weak viewModel] in Task { @MainActor in viewModel?.startCoachingFromDetail() } },
      onWatchStepReference: { [weak self] in Task { @MainActor in self?.playStepReference() } },
      onToggleReferenceImage: { [weak viewModel] in Task { @MainActor in viewModel?.toggleReferenceImage() } },
      onStartTroubleshoot: { [weak viewModel] in Task { @MainActor in viewModel?.startTroubleshoot() } },
      onOpenGame:        { [weak viewModel] in Task { @MainActor in viewModel?.openGame() } },
      onTapCell:         { [weak viewModel] i in Task { @MainActor in viewModel?.tapGameCell(i) } },
      onGameRestart:     { [weak viewModel] in Task { @MainActor in viewModel?.restartGame() } }
    )
  }

  // MARK: - Watch step reference

  /// Resolve the CURRENT step's reference media from its authoritative
  /// `clip_url` + the procedure's `source_type`, appending `?profile=lens` to
  /// the `.video` case so the glasses stream the small bitrate-capped variant.
  /// Mirror of `CoachingLensRenderer.resolveReferenceMedia()` — per-step clips
  /// are bounded and small, so first frame is consistently fast on the lens
  /// regardless of how long the full recording is (which stays phone-only).
  private func resolveStepReferenceMedia() -> StepReferenceMedia {
    let steps = viewModel.detail?.steps ?? []
    guard !steps.isEmpty else { return .none }
    let sp = min(max(0, viewModel.stepPage), steps.count - 1)
    let media = steps[sp].referenceMedia(
      sourceType: viewModel.detail?.sourceType,
      baseURL: ServerEndpoint.shared.resolvedBaseURL
    )
    guard case .video(let url) = media,
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return media }
    components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "profile", value: "lens")]
    return components.url.map { .video($0) } ?? media
  }

  /// Play the CURRENT step's reference clip full-screen on the lens, reusing
  /// the reference-clip playback path (smooth `?profile=lens` variant + watchdog).
  /// Retargets automatically as the user pages steps — the clip URL is resolved
  /// from the VM at tap time. On finish / stop it repaints the step page.
  private func playStepReference() {
    guard case .video(let url) = resolveStepReferenceMedia() else {
      print("[Navigator] playStepReference skipped — current step has no video clip"); return
    }
    let steps = viewModel.detail?.steps ?? []
    let sp = steps.isEmpty ? 0 : min(max(0, viewModel.stepPage), steps.count - 1)
    let duration: TimeInterval? = steps.indices.contains(sp)
      ? { let d = steps[sp].timestampEnd - steps[sp].timestampStart; return d > 0 ? d : nil }()
      : nil

    print("[Navigator] playStepReference step=\(sp + 1) → \(url.absoluteString) (expectedDuration=\(duration.map { String($0) } ?? "nil")s)")
    Task { [weak self] in
      await self?.lensSession?.presentReferenceClip(
        uri: url.absoluteString,
        expectedDuration: duration,
        onStarted: { print("[Navigator] step-reference playback started") },
        onEnded: { [weak self] in print("[Navigator] step-reference ended/stopped — returning to steps"); self?.repaintAfterClip() },
        onError: { [weak self] reason in print("[Navigator] step-reference error: \(reason)"); self?.repaintAfterClip() }
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
