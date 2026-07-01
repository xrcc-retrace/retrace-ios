//
// CoachingLensTrees.swift
//
// Pure tree-builder functions for the coaching flow's lens surfaces.
//
// Each top-level function returns a `FlexBox` (or other `DisplayableView`)
// to send via `Display.send`. Functions take a `CoachingLensSnapshot` plus
// a `CoachingLensCallbacks` struct that closes over interactive intents
// (mute toggle, exit, expansion toggles, pagination, step navigation,
// reference-clip tap).
//
// Per the locked MWDATDisplay vocabulary, every visual change is a new
// tree — these functions are called once per state transition and the
// result is dispatched to the lens. Animations are SDK-decided.
//
// Surfaces handled here (per the original plan inventory):
//   1. Step page — .collapsed / .referenceInline / .insightsInline
//      (one tree; the image / insights panel REPLACES the step card inline —
//       there is no separate reference/insights page. A VIDEO reference is not
//       an inline panel: tapping the Reference pill plays it full-screen
//       directly, so .referenceInline for a video carries only an error card.)
//   2. Step page — .stepExpanded (paginated description)
//   3. Step completion celebration (1.5s window)
//   4. Completion page
//   5. Exit confirmation overlay
//
// Tree-order = focus-order: the FIRST tappable element in the tree
// receives default focus from the SDK's Captouch/Neural Band traversal.
// For overlays where the safe action should default-focus (cancel-style),
// the safe button is placed first.
//

import Foundation
import MWDATDisplay

// MARK: - Callbacks

/// Bundle of intents the lens surfaces can fire. Renderer wires these
/// to its local state mutations + VM actions; tree functions stay pure.
struct CoachingLensCallbacks {
  let onToggleReference: () -> Void
  let onToggleInsights: () -> Void
  let onExpandStep: () -> Void
  let onCollapse: () -> Void
  let onDescPagePrev: () -> Void
  let onDescPageNext: () -> Void
  let onMuteToggle: @Sendable () -> Void
  let onExit: @Sendable () -> Void
  let onRetryClip: () -> Void
  let onCompletionExit: @Sendable () -> Void
  let onExitConfirmCancel: () -> Void
  let onExitConfirmConfirm: () -> Void
}

// MARK: - Top-level dispatch

enum CoachingLensTrees {

  /// Top-level dispatch. Picks the right tree given the snapshot's
  /// pageKind + expansion + overlay flags.
  static func tree(
    snapshot s: CoachingLensSnapshot,
    callbacks cb: CoachingLensCallbacks
  ) -> FlexBox {
    if s.showDismissConfirmation {
      return exitConfirmationTree(snapshot: s, callbacks: cb)
    }
    if s.celebratingStepIndex != nil {
      return celebrationTree(snapshot: s)
    }
    switch s.pageKind {
    case .completion:
      return completionTree(snapshot: s, callbacks: cb)
    case .step:
      switch s.expansion {
      // `.collapsed`, `.referenceInline`, and `.insightsInline` are all the
      // SAME page — the reference clip / insights panel expands inline under
      // a truncated step card rather than swapping to a separate surface.
      // `collapsedStepTree` differentiates internally on `s.expansion`.
      case .collapsed, .referenceInline, .insightsInline:
        return collapsedStepTree(snapshot: s, callbacks: cb)
      case .stepExpanded:
        return stepExpandedTree(snapshot: s, callbacks: cb)
      }
    }
  }

  // MARK: - 1. Step page — collapsed / reference-inline / insights-inline

  /// The canonical learner surface. One tree drives three states, with a
  /// single content slot directly under the top band:
  ///
  ///   • `.collapsed`        — top band + step card + audio row
  ///   • `.referenceInline`  — IMAGE references only: the manual-page image
  ///                           panel REPLACES the step card (card removed;
  ///                           Reference pill → "Hide ref"). VIDEO references
  ///                           never enter this state on the happy path — the
  ///                           pill plays the clip full-screen directly; this
  ///                           state only carries a video load-error card.
  ///   • `.insightsInline`   — the insights panel REPLACES the step card
  ///                           (card removed entirely; Insights pill → "Hide insights")
  ///
  /// Reference and Insights pills sit on OPPOSITE ends of the top band
  /// (Reference left, Insights right) via a `flexGrow(1)` spacer — the
  /// DAT `Alignment` enum has no `spaceBetween`, but `FlexBox.flexGrow`
  /// exists, so an empty grow-spacer pushes the two pills apart. This
  /// mirrors the on-phone emulator (`CoachingStepPage.topAffordances`).
  static func collapsedStepTree(
    snapshot s: CoachingLensSnapshot,
    callbacks cb: CoachingLensCallbacks
  ) -> FlexBox {
    let referenceOpen = s.expansion == .referenceInline
    let insightsOpen = s.expansion == .insightsInline

    return FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 8,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      // Top band — Reference / Insights as opposite-end pills. Active pill
      // shows an icon/label swap ("Hide …" + .x), because the native DSL
      // `Background` enum is only `.none`/`.card` (no white-fill active state).
      //
      // Default focus: the DAT DSL exposes NO focus API (verified — no
      // defaultFocus/initialFocus/selected). The SDK gives default focus to
      // the FIRST tappable element in TREE order. So when Insights is open we
      // emit its pill FIRST and flip the row to `.rowReverse` — that keeps it
      // rendered on the right while making "Hide insights" the default-focused
      // control so the user can immediately toggle it back off. Reference
      // already gets default focus when collapsed/open (it's emitted first).
      if s.hasReference || !s.insights.isEmpty {
        FlexBox(
          direction: insightsOpen ? MWDATDisplay.Direction.rowReverse : MWDATDisplay.Direction.row,
          spacing: 8,
          alignment: .start,
          crossAlignment: .center
        ) {
          if insightsOpen {
            // Insights pill FIRST → default focus on "Hide insights".
            // rowReverse renders it on the right; Reference falls to the left.
            togglePill(icon: .x, label: "Hide insights", onTap: cb.onToggleInsights)
            growSpacer()
            if s.hasReference {
              togglePill(
                icon: s.referenceIsVideo ? .videoCamera : .eye,
                label: "Reference",
                onTap: cb.onToggleReference
              )
            }
          } else {
            // Normal order: Reference first (→ default focus), Insights right.
            if s.hasReference {
              togglePill(
                // Closed: video → camera glyph, image → eye glyph. Open: dismiss.
                icon: referenceOpen ? .x : (s.referenceIsVideo ? .videoCamera : .eye),
                label: referenceOpen ? "Hide ref" : "Reference",
                onTap: cb.onToggleReference
              )
            }
            growSpacer()
            if !s.insights.isEmpty {
              togglePill(icon: .exclamationTriangle, label: "Insights", onTap: cb.onToggleInsights)
            }
          }
        }
      }

      // Content slot (directly under the top band). Mutually exclusive:
      // the open panel REPLACES the step card in this same position — the
      // card is removed entirely, not truncated or pushed down.
      if referenceOpen {
        // Reference panel: only a VIDEO load error or a static IMAGE reaches
        // here. A video reference plays full-screen DIRECTLY from the pill tap
        // (see CoachingLensRenderer.playReferenceVideo) — there is no inline
        // poster step — so `.referenceInline` for a video only ever shows the
        // error card below.
        if let errorMsg = s.clipErrorMessage {
          // Visible failure instead of a silent no-op. "Try again" re-attempts
          // full-screen playback (LensSession logs the concrete reason).
          LensComponents.cardPanel(spacing: 8, padding: 14) {
            LensComponents.iconHeadingRow(.exclamationTriangle, errorMsg, style: .outline)
            togglePill(icon: .twoArrowsClockwise, label: "Try again", onTap: cb.onRetryClip)
          }
        } else {
          // Static reference image (manual page) — show, don't play.
          // The step card is gone while this panel is open, so the caption
          // carries the step title to re-anchor the user (was a redundant
          // "Reference image" label).
          LensComponents.cardPanel(spacing: 8, padding: 12) {
            if let imageURI = s.referencePosterURL {
              Image(uri: imageURI, sizePreset: .fill, cornerRadius: .medium)
            } else {
              Text(s.stepTitle, style: .heading, color: .primary)
            }
            Text(s.stepTitle, style: .body, color: .primary)
          }
        }
      } else if insightsOpen {
        // Insights panel replaces the step card.
        LensComponents.cardPanel(spacing: 8, padding: 14) {
          Text("INSIGHTS", style: .meta, color: .secondary)
          if s.insights.isEmpty {
            LensComponents.iconHeadingRow(.exclamationTriangle, "No insights", style: .outline)
            Text("Just follow the step instructions.", style: .body, color: .secondary)
          } else {
            for item in s.insights {
              FlexBox(
                direction: MWDATDisplay.Direction.row,
                spacing: 6,
                alignment: .start,
                crossAlignment: .start
              ) {
                Text("•", style: .body, color: .primary)
                Text("\(item.category): \(item.text)", style: .body, color: .primary)
              }
            }
          }
        }
      } else {
        // Collapsed: the full step card (tap → .stepExpanded).
        LensComponents.cardPanel(spacing: 8, padding: 14) {
          Text("STEP \(s.stepIndex + 1) OF \(s.totalSteps)", style: .meta, color: .secondary)
          Text(s.stepTitle, style: .heading, color: .primary)
          Text(LensComponents.truncate(s.stepDescription, max: 180), style: .body, color: .primary)
        }
        .onTap(cb.onExpandStep)
      }

      LensComponents.audioActionRow(
        isMuted: s.isMuted,
        onMute: cb.onMuteToggle,
        onExit: cb.onExit
      )
    }
    .padding(12)
  }

  // MARK: - 2. Step expanded (paginated)

  static func stepExpandedTree(
    snapshot s: CoachingLensSnapshot,
    callbacks cb: CoachingLensCallbacks
  ) -> FlexBox {
    let pages = LensComponents.paginate(s.stepDescription, chunkSize: 180)
    let page = pages.indices.contains(s.descPage) ? pages[s.descPage] : (pages.first ?? "")

    return FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 8,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      LensComponents.cardPanel(spacing: 8, padding: 14) {
        Text("STEP \(s.stepIndex + 1) OF \(s.totalSteps)", style: .meta, color: .secondary)
        Text(s.stepTitle, style: .heading, color: .primary)
        Text(page, style: .body, color: .primary)
      }
      .onTap(cb.onCollapse)

      // Pagination row (only when more than one page)
      if s.descPagesTotal > 1 {
        FlexBox(
          direction: MWDATDisplay.Direction.row,
          spacing: 12,
          alignment: .center,
          crossAlignment: .center
        ) {
          FlexBox(
            direction: MWDATDisplay.Direction.row,
            spacing: 0,
            alignment: .center,
            crossAlignment: .center
          ) {
            Icon(name: .arrowLeft, style: .outline)
          }
          .padding(6)
          .onTap(cb.onDescPagePrev)

          Text("\(s.descPage + 1) / \(s.descPagesTotal)", style: .meta, color: .secondary)

          FlexBox(
            direction: MWDATDisplay.Direction.row,
            spacing: 0,
            alignment: .center,
            crossAlignment: .center
          ) {
            Icon(name: .arrowRight, style: .outline)
          }
          .padding(6)
          .onTap(cb.onDescPageNext)
        }
      }

      LensComponents.audioActionRow(
        isMuted: s.isMuted,
        onMute: cb.onMuteToggle,
        onExit: cb.onExit
      )
    }
    .padding(12)
  }

  // MARK: - 5. Step completion celebration (1.5s window)

  static func celebrationTree(snapshot s: CoachingLensSnapshot) -> FlexBox {
    // Use the celebrating index — it's the step that just completed and
    // stays stable through the 1.8s celebration window (the VM doesn't
    // clear `celebratingStepIndex` until the slide finishes). `stepIndex`
    // would flip mid-window when `displayedStepIndex` advances and would
    // show the WRONG step number on the "completed" card.
    let completedStep = (s.celebratingStepIndex ?? s.stepIndex) + 1
    return FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 12,
      alignment: .center,
      crossAlignment: .center
    ) {
      LensComponents.cardPanel(
        spacing: 12,
        alignment: .center,
        crossAlignment: .center,
        padding: 24
      ) {
        LensComponents.iconHeadingRow(.checkmark, "Step completed", style: .filled)
        Text("Step \(completedStep) of \(s.totalSteps)", style: .meta, color: .secondary)
      }
    }
    .padding(12)
  }

  // MARK: - 6. Completion page

  static func completionTree(
    snapshot s: CoachingLensSnapshot,
    callbacks cb: CoachingLensCallbacks
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 16,
      alignment: .center,
      crossAlignment: .stretch
    ) {
      LensComponents.cardPanel(
        spacing: 8,
        alignment: .center,
        crossAlignment: .center,
        padding: 20
      ) {
        LensComponents.iconHeadingRow(.checkmark, s.procedureTitle ?? "Procedure complete", style: .filled)
        if let duration = s.formattedSessionDuration {
          Text("\(s.totalSteps) steps · \(duration)", style: .body, color: .secondary)
        } else {
          Text("\(s.totalSteps) steps", style: .body, color: .secondary)
        }
      }

      Button(
        label: "Return to workflows",
        style: .primary,
        iconName: .arrowRight,
        onClick: cb.onCompletionExit
      )
    }
    .padding(16)
  }

  // MARK: - 7. Exit confirmation overlay

  static func exitConfirmationTree(
    snapshot s: CoachingLensSnapshot,
    callbacks cb: CoachingLensCallbacks
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 12,
      alignment: .center,
      crossAlignment: .stretch
    ) {
      LensComponents.cardPanel(
        spacing: 12,
        alignment: .center,
        crossAlignment: .stretch,
        padding: 18
      ) {
        // Centered heading (DSL Text has no alignment; a centered row does it).
        FlexBox(
          direction: MWDATDisplay.Direction.row,
          spacing: 0,
          alignment: .center,
          crossAlignment: .center
        ) {
          Text("Are you sure you want to exit?", style: .heading, color: .primary)
        }

        // Custom FlexBox pills (not DSL `Button`) so the label is CENTERED and
        // there's no built-in collapse/expand button animation.
        // Default focus: Cancel (first tappable child — safe option).
        centerButton(icon: .arrowLeft, label: "Cancel", onTap: cb.onExitConfirmCancel)
        centerButton(icon: .x, label: "Confirm exit", onTap: cb.onExitConfirmConfirm)
      }
    }
    .padding(12)
  }

  // MARK: - Helpers

  /// Empty grow-spacer that pushes flanking row children to opposite ends
  /// (the `Alignment` enum has no `spaceBetween`; `flexGrow` is the lever).
  private static func growSpacer() -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.row,
      spacing: 0,
      alignment: .center,
      crossAlignment: .center
    ) {}
    .flexGrow(1)
  }

  /// Full-width `.card` button with its icon+label CENTERED (vs the DSL
  /// `Button`, which left-aligns and carries a built-in press animation).
  /// Used for the exit-confirmation overlay actions.
  private static func centerButton(
    icon: IconName,
    label: String,
    onTap: @escaping () -> Void
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.row,
      spacing: 6,
      alignment: .center,
      crossAlignment: .center
    ) {
      Icon(name: icon, style: .outline)
      Text(label, style: .body, color: .primary)
    }
    .padding(8)
    .background(.card)
    .onTap(onTap)
  }

  /// Small icon+label pill in a `.card` background, tappable. Used for
  /// the Reference / Insights toggles and the "Hide …" dismissers.
  private static func togglePill(
    icon: IconName,
    label: String,
    onTap: @escaping () -> Void
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.row,
      spacing: 6,
      alignment: .start,
      crossAlignment: .center
    ) {
      Icon(name: icon, style: .outline)
      Text(label, style: .meta, color: .primary)
    }
    .padding(6)
    .background(.card)
    .onTap(onTap)
  }
}
