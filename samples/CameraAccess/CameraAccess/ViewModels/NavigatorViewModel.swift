//
// NavigatorViewModel.swift
//
// Owns ALL state for the glasses-first navigation shell: which screen the
// lens is on, the cached procedure list + list/step paging, and the loaded
// procedure detail. Mutated by tap callbacks from `NavigatorLensRenderer`;
// the renderer subscribes to these `@Published` props and repaints.
//
// Unlike the coaching renderer (which owns ephemeral chrome like `expansion`
// locally), the navigator's screen + page indices live HERE because they are
// genuine navigation state driven by Neural-Band taps — see the plan's
// "Design conventions to honor" note.
//
// Runtime launches (Record / Start coaching) are delegated OUT via the
// `onRecordRequested` hook so the `GlassesNavigationCoordinator` owns the
// session swap; until it's wired (E3), Record falls back to a handoff card.
//

import Combine
import Foundation

@MainActor
final class NavigatorViewModel: ObservableObject {

  enum Screen: Equatable {
    case home
    case expertHub
    case browseList
    case procedureDetail(id: String)
    // Glasses-first recording outcome screens (driven by the coordinator).
    // `.expertReview` is the upload-or-discard gate shown after the stop
    // countdown, before any upload fires (mirrors the phone's
    // `ExpertRecordingReviewView`). Duration is for the "M:SS captured" label.
    case expertReview(duration: TimeInterval)
    case expertProcessing
    case expertDone(title: String, stepCount: Int, procedureId: String)
    case expertFailed(reason: String)
    // Learner mode (glasses-first browse → coach).
    case learnerHub
    case learnerFilter
    case learnerProcedureDetail(id: String)
    // Troubleshoot mode: the intro/description screen (Identify → Diagnose →
    // Find a fix). "Start now" delegates the live diagnostic session out via
    // `onTroubleshootRequested`; exiting the session returns here.
    case troubleshootIntro
    case comingSoon(heading: String, reason: String)
    // Hidden easter-egg: "Retrace" Simon-says memory game, reachable from the
    // Home sparkle button. State lives in `game` (RetraceGameEngine).
    case retraceGame
  }

  /// Rows per paged list page on the lens (≈5 fits the 600×600 viewport).
  static let rowsPerPage = 5

  /// Canonical category chips — kept in sync with `DiscoverViewModel.categories`
  /// (and the backend `ProcedureCategory` literal). "All" is a UI-only no-op.
  static let learnerCategories = [
    "All",
    "Assembly",
    "Electrical",
    "Calibration",
    "Maintenance",
    "Repair",
    "Inspection",
    "Other",
  ]

  // MARK: - Published nav state

  @Published private(set) var screen: Screen = .home
  @Published private(set) var listPage: Int = 0
  @Published private(set) var stepPage: Int = 0

  @Published private(set) var procedures: [ProcedureListItem] = []
  @Published private(set) var isLoadingList = false
  @Published private(set) var listError: String?

  @Published private(set) var detail: ProcedureResponse?
  @Published private(set) var isLoadingDetail = false

  /// Whether the inline per-step reference image is expanded on the detail view
  /// (manual procedures). Toggled by the "View reference image" pill; stays open
  /// across step paging (the image just swaps) and resets when a detail is opened.
  @Published private(set) var showReferenceImage = false

  /// Selected Learner category chip ("All" = no filter).
  @Published private(set) var selectedCategory: String = "All"

  /// Hidden "Retrace" mini-game state machine (Home sparkle button).
  let game = RetraceGameEngine()

  // MARK: - Delegated runtime launches (wired by the coordinator)

  /// Set by `GlassesNavigationCoordinator` (E3) to launch the phone-hosted
  /// recording runtime. Nil until then → Record shows a handoff placeholder.
  var onRecordRequested: (() -> Void)?

  /// Set by the coordinator to launch the phone-hosted Ask AI voice session.
  var onAskAIRequested: (() -> Void)?

  /// Set by the coordinator. Fired from the `.expertReview` gate: confirm
  /// uploads the pending recording, discard deletes it and returns to the hub.
  var onUploadRecording: (() -> Void)?
  var onDiscardRecording: (() -> Void)?

  /// Set by the coordinator to launch the phone-hosted coaching session for a
  /// chosen procedure. Nil → "Start coaching" shows a handoff placeholder.
  var onCoachRequested: ((ProcedureResponse) -> Void)?

  /// Set by the coordinator to launch the phone-hosted diagnostic session.
  /// Nil → "Start now" shows a handoff placeholder.
  var onTroubleshootRequested: (() -> Void)?

  // MARK: - Dependencies

  private let api: ProcedureAPIService
  private var loadTask: Task<Void, Never>?

  init(api: ProcedureAPIService) {
    self.api = api
  }

  // MARK: - Lifecycle

  /// Reset to Home — called by the coordinator on `enterGlassesMode()`.
  func reset() {
    loadTask?.cancel()
    screen = .home
    listPage = 0
    stepPage = 0
    detail = nil
    listError = nil
    isLoadingList = false
    isLoadingDetail = false
    selectedCategory = "All"
    game.stop()
  }

  // MARK: - Home → modes

  func openExpertHub() { screen = .expertHub }

  func openLearner() {
    selectedCategory = "All"
    screen = .learnerHub
    loadProcedures()
  }

  func openTroubleshoot() { screen = .troubleshootIntro }

  // MARK: - Hidden mini-game

  /// Open the "Retrace" game and deal round 1.
  func openGame() {
    screen = .retraceGame
    game.start()
  }

  /// Forward a grid-cell tap to the engine.
  func tapGameCell(_ index: Int) { game.tapCell(index) }

  /// "Play again" from the game-over screen.
  func restartGame() { game.start() }

  // MARK: - Expert hub

  func record() {
    if let onRecordRequested {
      onRecordRequested()
    } else {
      screen = .comingSoon(
        heading: "Recording — coming soon",
        reason: "Lens-launched recording isn't wired yet. Use your phone."
      )
    }
  }

  // MARK: - Recording outcome (driven by GlassesNavigationCoordinator)

  func goExpertHub() { screen = .expertHub }

  /// Show the upload-or-discard gate after a glasses-first recording stops.
  func showRecordingReview(duration: TimeInterval) {
    screen = .expertReview(duration: duration)
  }

  /// Gate intents → delegated to the coordinator (owns the file + upload).
  func confirmUpload() { onUploadRecording?() }
  func discardRecording() { onDiscardRecording?() }

  func showProcessing() { screen = .expertProcessing }

  func showDone(title: String, stepCount: Int, procedureId: String) {
    screen = .expertDone(title: title, stepCount: stepCount, procedureId: procedureId)
  }

  func showRecordingFailed(reason: String) {
    screen = .expertFailed(reason: reason)
  }

  /// "Review on phone" from the done screen → lens handoff card; the phone is
  /// where editing happens.
  func reviewOnPhone() {
    screen = .comingSoon(
      heading: "Review on your phone",
      reason: "Open this procedure on your phone to review and edit the steps."
    )
  }

  func openBrowse() {
    listPage = 0
    screen = .browseList
    loadProcedures()
  }

  func loadProcedures() {
    loadTask?.cancel()
    isLoadingList = true
    listError = nil
    loadTask = Task { [weak self] in
      guard let self else { return }
      do {
        let items = try await self.api.fetchProcedures()
        if Task.isCancelled { return }
        self.procedures = items
        self.isLoadingList = false
      } catch {
        if Task.isCancelled { return }
        self.listError = "Couldn't load procedures"
        self.isLoadingList = false
      }
    }
  }

  // MARK: - List paging

  var listPageCount: Int {
    guard !procedures.isEmpty else { return 1 }
    return Int(ceil(Double(procedures.count) / Double(Self.rowsPerPage)))
  }

  func nextPage() { listPage = min(listPageCount - 1, listPage + 1) }
  func prevPage() { listPage = max(0, listPage - 1) }

  // MARK: - Detail

  /// Row tap from a procedure list. Routes to the Learner detail when on the
  /// Learner hub (Start-coaching CTA, back → hub) and the Expert detail
  /// otherwise (read-only, back → browse list).
  func selectProcedure(id: String) {
    if case .learnerHub = screen {
      openLearnerProcedure(id: id)
    } else {
      openProcedure(id: id)
    }
  }

  func openProcedure(id: String) {
    stepPage = 0
    detail = nil
    showReferenceImage = false
    screen = .procedureDetail(id: id)
    loadDetail(id: id)
  }

  /// Toggle the inline reference image on the procedure-detail view.
  func toggleReferenceImage() { showReferenceImage.toggle() }

  func loadDetail(id: String) {
    loadTask?.cancel()
    isLoadingDetail = true
    loadTask = Task { [weak self] in
      guard let self else { return }
      do {
        let proc = try await self.api.fetchProcedure(id: id)
        if Task.isCancelled { return }
        self.detail = proc
        self.isLoadingDetail = false
      } catch {
        if Task.isCancelled { return }
        self.isLoadingDetail = false
      }
    }
  }

  func nextStep() {
    let count = detail?.steps.count ?? 1
    stepPage = min(max(0, count - 1), stepPage + 1)
  }

  func prevStep() { stepPage = max(0, stepPage - 1) }

  // MARK: - Learner mode

  /// Client-side category filter, mirroring `DiscoverViewModel.filteredProcedures`.
  /// "All" is a no-op; nil/empty category falls into "Other" so legacy rows
  /// surface in the catch-all chip instead of vanishing.
  var filteredProcedures: [ProcedureListItem] {
    guard selectedCategory != "All" else { return procedures }
    return procedures.filter {
      let c = ($0.category?.isEmpty == false ? $0.category : nil) ?? "Other"
      return c == selectedCategory
    }
  }

  /// Open the dedicated filter screen.
  func openLearnerFilter() { screen = .learnerFilter }

  /// Pick a category on the filter screen. Re-tapping the active category
  /// clears the filter (→ "All"); "All" itself always just sets All. Stays on
  /// the filter screen so the user can see the checkmark move / clear; they
  /// tap Back to return to the hub with the filter applied.
  func selectCategory(_ category: String) {
    selectedCategory = (category == selectedCategory && category != "All") ? "All" : category
  }

  func openLearnerProcedure(id: String) {
    stepPage = 0
    detail = nil
    showReferenceImage = false
    screen = .learnerProcedureDetail(id: id)
    loadDetail(id: id)
  }

  /// "Start coaching" from the Learner detail → delegate to the coordinator.
  /// Nil hook (or no loaded detail) → handoff placeholder.
  func startCoachingFromDetail() {
    if let detail, let onCoachRequested {
      onCoachRequested(detail)
    } else {
      screen = .comingSoon(
        heading: "Coaching — coming soon",
        reason: "Lens-launched coaching isn't wired yet. Use your phone."
      )
    }
  }

  func askAI() {
    if let onAskAIRequested {
      onAskAIRequested()
    } else {
      screen = .comingSoon(
        heading: "Ask AI — coming soon",
        reason: "Voice search isn't wired yet. Use your phone."
      )
    }
  }

  /// Return to the Learner hub (used by the coordinator after a coaching or
  /// Ask AI runtime ends). Keeps the cached list + selected category intact.
  func goLearnerHub() { screen = .learnerHub }

  // MARK: - Troubleshoot mode

  /// "Start now" from the troubleshoot intro → delegate to the coordinator.
  /// Nil hook → handoff placeholder.
  func startTroubleshoot() {
    if let onTroubleshootRequested {
      onTroubleshootRequested()
    } else {
      screen = .comingSoon(
        heading: "Troubleshoot — coming soon",
        reason: "Lens-launched diagnostics aren't wired yet. Use your phone."
      )
    }
  }

  /// Return to the troubleshoot intro (used by the coordinator after the
  /// diagnostic session — or a coaching session handed off from it — ends).
  func goTroubleshootIntro() { screen = .troubleshootIntro }

  // MARK: - Back

  func back() {
    switch screen {
    case .home:
      break
    case .expertHub, .comingSoon, .troubleshootIntro:
      screen = .home
    case .browseList:
      screen = .expertHub
    case .procedureDetail:
      stepPage = 0
      detail = nil
      screen = .browseList
    case .expertReview:
      // Backing out of the gate = discard (cleans up the temp file via the hook).
      discardRecording()
    case .expertProcessing, .expertDone, .expertFailed:
      screen = .expertHub
    case .learnerHub:
      screen = .home
    case .learnerFilter:
      screen = .learnerHub
    case .learnerProcedureDetail:
      stepPage = 0
      detail = nil
      screen = .learnerHub
    case .retraceGame:
      game.stop()
      screen = .home
    }
  }
}
