//
// NavigatorLensSnapshot.swift
//
// Value-type snapshot for the glasses-first NAVIGATION shell (home →
// mode hubs → procedure list → procedure detail). Projected from
// `NavigatorViewModel` by `NavigatorLensRenderer`, dedup'd via
// `Equatable`, then rendered to a `FlexBox` tree by `NavigatorLensTrees`.
//
// Same discipline as the other `*LensSnapshot` types: primitives + local
// enums only — no `MWDATDisplay` or VM types leak in, and server URLs are
// carried as `String` (not parsed `URL`).
//

import Foundation

struct NavigatorLensSnapshot: Equatable {

  /// Which navigator surface is currently on the lens.
  enum Screen: Equatable {
    case home
    case expertHub
    case browseList
    case procedureDetail
    /// Glasses-first recording outcome screens. `.expertReview` is the
    /// upload-or-discard gate (duration pre-formatted to a "M:SS" string).
    case expertReview(durationLabel: String)
    case expertProcessing
    case expertDone(title: String, stepCount: Int)
    case expertFailed(reason: String)
    /// Learner mode (browse → coach). Detail reuses the `detail*`/`step*` fields.
    case learnerHub
    /// Dedicated category filter screen (reuses `categories` + `selectedCategory`).
    case learnerFilter
    case learnerProcedureDetail
    /// Troubleshoot mode intro/description (Identify → Diagnose → Find a fix).
    case troubleshootIntro
    /// Lens-side "act on your phone" handoff (modes not yet on the lens,
    /// editing, etc.). Carries the card copy.
    case comingSoon(heading: String, reason: String)
    /// Hidden "Retrace" Simon-says game (Home sparkle button).
    case retraceGame
  }

  // MARK: - Retrace mini-game

  /// Coarse phase the game tree branches on (full state lives in the engine).
  enum GamePhase: Equatable {
    case watch      // replaying the sequence
    case input      // player's turn
    case gameOver   // wrong tap
  }

  /// Per-cell render state for the 3×3 grid. The DSL has no accent colour and
  /// no per-element sizing, so every cell is a constant-size `.card` tile and
  /// the state is carried by a `.heading`-size glyph inside it (see
  /// `NavigatorLensTrees`). There is deliberately no `.correct` state: during
  /// the input phase a correct tap does NOT repaint (so the lens focus ring
  /// stays where the player pressed) — the per-tap confirmation is audio.
  enum CellState: Equatable {
    case idle       // navigable target; recedes to a faint dot
    case lit        // flashing during .watch; a bold filled mark
    case wrong      // the cell that ended the run
  }

  let screen: Screen

  // MARK: Home
  /// HTTPS banner URL; nil → render the `Text` wordmark fallback.
  let bannerURL: String?

  // MARK: Browse list
  let isLoadingList: Bool
  let listError: String?
  let listRows: [Row]          // current page slice only
  let listPage: Int            // 0-based
  let listPageCount: Int

  /// Which slice of the Learner list is showing. Local mirror of
  /// `NavigatorViewModel.ListTab` — no VM types leak into the snapshot.
  enum ListTab: Equatable { case saved, all }

  // MARK: Learner hub — Saved/All tab + category filter chips
  let listTab: ListTab
  let savedCount: Int
  let categories: [String]
  let selectedCategory: String

  // MARK: Procedure detail (one STEP per page)
  let isLoadingDetail: Bool
  let detailTitle: String
  let detailMeta: String       // e.g. "6 steps · From a recording"
  let stepNumber: Int          // 1-based, from the server
  let stepCount: Int
  let stepTitle: String
  let stepBody: String         // truncated for the lens
  let stepIndex: Int           // 0-based page index into steps
  let stepPageCount: Int       // == stepCount; pager visible when > 1
  /// True only when the CURRENT step resolves to a playable video clip —
  /// gates the "Watch step reference" pill. False for manual/web steps
  /// (they resolve to .image/.none) and for steps with failed/missing clips.
  /// Recomputed as the user pages steps.
  let hasStepClip: Bool
  /// Current step's reference image URL (manual procedures only, https only);
  /// nil for video/web or over a plain-http server. Swaps as the user pages steps.
  /// Non-nil → the "View reference image" toggle pill is shown.
  let referenceImageURL: String?
  /// Whether the inline reference image is currently expanded (toggle open).
  let isReferenceImageOpen: Bool

  struct Row: Equatable {
    let id: String
    let title: String
    let statusLabel: String?   // "Processing" / "Failed" / "Partial"; nil when ready
  }

  // MARK: Retrace mini-game
  let gamePhase: GamePhase
  let gameCells: [CellState]   // exactly 9, row-major (0..2 top, 3..5 mid, 6..8 bottom)
  let gameRound: Int           // 1-based round being attempted
  let gameScore: Int           // highest round completed this run
  let gameBest: Int            // persisted high score
}
