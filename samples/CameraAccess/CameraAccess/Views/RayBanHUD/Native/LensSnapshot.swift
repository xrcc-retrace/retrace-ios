//
// LensSnapshot.swift
//
// Value-type "snapshots" projected from each flow's view model. The
// per-flow renderers (Step 6/8/9) subscribe to the source VMs via
// Combine, project incoming changes into one of these structs, and
// dedup with `.removeDuplicates()` before debouncing and emitting a
// `FlexBox` tree.
//
// Why snapshots:
//   - They isolate the renderer from VM-specific API churn — the
//     renderer only re-renders when something it actually paints changes.
//   - `Equatable` enables Combine's `.removeDuplicates()`, which
//     dramatically reduces BT traffic to the glasses.
//   - All types here are primitives or local enums — no `MWDATDisplay`
//     or VM types leak into the snapshot layer.
//
// The renderer (Step 6) is responsible for keeping any local enums
// here (`LensCoachingExpansion`, etc.) in sync with the VM's own
// enums (e.g. `CoachingStepPage.ExpansionState`, which is private to
// that view file and can't be imported).
//

import Foundation

// MARK: - Shared

/// Whether the lens path is in a renderable state at all. Drives the
/// difference between an active flow's tree and the "use your phone"
/// handoff card.
enum LensConnectionStatus: Equatable {
  case idle           // no flow active
  case connecting     // session warming up
  case connected      // ready to render
  case reconnecting   // mid-session interruption
  case failed(reason: String)
}

// MARK: - Coaching

struct CoachingLensSnapshot: Equatable {
  // Page-mode discriminator
  let pageKind: PageKind
  enum PageKind: Equatable { case step, completion }

  // Universal
  let isMuted: Bool
  let connection: LensConnectionStatus
  let showDismissConfirmation: Bool

  // Step page
  let stepIndex: Int                          // 0-based
  let totalSteps: Int
  let stepTitle: String
  let stepDescription: String                 // full text; renderer paginates
  let expansion: LensCoachingExpansion
  let hasClip: Bool
  let clipPosterURL: String?                  // HTTPS, from LensImageURL
  let insights: [InsightItem]
  let descPage: Int                           // active page in paginated description
  let descPagesTotal: Int                     // computed by renderer from stepDescription
  let celebratingStepIndex: Int?              // when non-nil, render celebration tree

  // Completion page
  let procedureTitle: String?
  let formattedSessionDuration: String?

  /// Local mirror of `CoachingStepPage.ExpansionState`. The renderer
  /// owns the canonical mapping when projecting the snapshot.
  enum LensCoachingExpansion: Equatable {
    case collapsed
    case referenceExpanded
    case insightsExpanded
    case stepExpanded
  }

  struct InsightItem: Equatable {
    let category: String      // "Tips", "Warnings", "Red flags"
    let text: String
  }
}

// MARK: - Troubleshoot

struct TroubleshootLensSnapshot: Equatable {
  let phase: LensDiagnosticPhase
  let isMuted: Bool
  let connection: LensConnectionStatus

  // Identification / confirmation
  let identifiedProductName: String?
  let identifiedCategory: String?
  let identifiedConfidence: String?           // e.g. "high" / "medium"
  let pendingConfirmation: Bool               // controls whether confirm overlay renders

  // Searching narration (5 states from the original plan)
  let narration: LensSearchNarration?

  // Resolution
  let resolution: LensResolution?
  let handoffInFlight: Bool
  let handoffError: String?

  // Manual upload — routes to handoff card
  let showManualUploadSheet: Bool

  // Exit overlay
  let showDismissConfirmation: Bool

  /// Mirrors `DiagnosticPhase` in `Models/DiagnosticModels.swift`.
  enum LensDiagnosticPhase: Equatable {
    case discovering
    case diagnosing
    case resolving
    case resolved
  }

  /// Five-stage narration during search. Each stage paints a different
  /// tree per the plan's surface 10 table.
  enum LensSearchNarration: Equatable {
    case searchingLibrary
    case libraryMissed                         // 3s floor enforced by VM
    case searchingWeb
    case synthesizing(sourceCount: Int)
    case foundFix(sourceCount: Int)            // 2.5s floor enforced by VM
  }

  /// Resolution outcomes that drive page selection.
  enum LensResolution: Equatable {
    case matchedProcedure(title: String, procedureId: String)
    case generatedSOP(title: String, procedureId: String)
    case noMatch
  }
}

// MARK: - Expert

struct ExpertLensSnapshot: Equatable {
  // Gate: pre-recording chrome routes to handoff card; in-recording
  // routes to the narration tip page.
  let isHUDActive: Bool

  let isRecording: Bool
  let recordingDurationWholeSeconds: Int      // debounced from float duration

  // Narration tip carousel
  let tipIndex: Int                           // 0-based
  let totalTips: Int                          // typically 7
  let currentTipTitle: String
  let currentTipBody: String

  // Hand tracking ambient indicator
  let handTrackingStatusLabel: String         // "Hands on" / "Hands off" / "Tracking..."

  // Stop-confirm overlay
  let stopFlowActive: Bool
  let stopCountdownRemaining: Int?            // 3, 2, 1, then nil
}
