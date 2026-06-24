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
//   1. Step page — .collapsed
//   2. Step page — .referenceExpanded
//   3. Step page — .insightsExpanded
//   4. Step page — .stepExpanded (paginated description)
//   5. Step completion celebration (1.5s window)
//   6. Completion page
//   7. Exit confirmation overlay
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
  let onReferenceClipTap: () -> Void
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
      case .collapsed:          return collapsedStepTree(snapshot: s, callbacks: cb)
      case .referenceExpanded:  return referenceExpandedTree(snapshot: s, callbacks: cb)
      case .insightsExpanded:   return insightsExpandedTree(snapshot: s, callbacks: cb)
      case .stepExpanded:       return stepExpandedTree(snapshot: s, callbacks: cb)
      }
    }
  }

  // MARK: - 1. Collapsed step page

  static func collapsedStepTree(
    snapshot s: CoachingLensSnapshot,
    callbacks cb: CoachingLensCallbacks
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 8,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      // Top toggle pills row (only if their content exists)
      if s.hasClip || !s.insights.isEmpty {
        FlexBox(
          direction: MWDATDisplay.Direction.row,
          spacing: 8,
          alignment: .start,
          crossAlignment: .center
        ) {
          if s.hasClip {
            togglePill(
              icon: .videoCamera,
              label: "Reference",
              onTap: cb.onToggleReference
            )
          }
          if !s.insights.isEmpty {
            togglePill(
              icon: .exclamationTriangle,
              label: "Insights",
              onTap: cb.onToggleInsights
            )
          }
        }
      }

      // Step card — onTap expands to .stepExpanded
      LensComponents.cardPanel(spacing: 8, padding: 14) {
        Text("STEP \(s.stepIndex + 1) OF \(s.totalSteps)", style: .meta, color: .secondary)
        Text(s.stepTitle, style: .heading, color: .primary)
        Text(LensComponents.truncate(s.stepDescription, max: 180), style: .body, color: .primary)
      }
      .onTap(cb.onExpandStep)

      LensComponents.audioActionRow(
        isMuted: s.isMuted,
        onMute: cb.onMuteToggle,
        onExit: cb.onExit
      )
    }
    .padding(12)
  }

  // MARK: - 2. Reference expanded

  static func referenceExpandedTree(
    snapshot s: CoachingLensSnapshot,
    callbacks cb: CoachingLensCallbacks
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 8,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      // "Hide ref" dismiss pill
      togglePill(icon: .x, label: "Hide ref", onTap: cb.onCollapse)

      // Clip thumbnail panel — tap to play full-screen (Step 7 wires the video handoff)
      LensComponents.cardPanel(spacing: 8, padding: 12) {
        if let posterURI = s.clipPosterURL {
          Image(uri: posterURI, sizePreset: .fill, cornerRadius: .medium)
        } else {
          // Fallback when poster route hasn't been deployed yet — just text.
          Text("Reference clip", style: .heading, color: .primary)
        }
        Text("Tap to play full-screen", style: .meta, color: .secondary)
      }
      .onTap(cb.onReferenceClipTap)

      // Compact step header
      LensComponents.cardPanel(spacing: 4, padding: 12) {
        Text("STEP \(s.stepIndex + 1) OF \(s.totalSteps)", style: .meta, color: .secondary)
        Text(s.stepTitle, style: .body, color: .primary)
      }

      LensComponents.audioActionRow(
        isMuted: s.isMuted,
        onMute: cb.onMuteToggle,
        onExit: cb.onExit
      )
    }
    .padding(12)
  }

  // MARK: - 3. Insights expanded

  static func insightsExpandedTree(
    snapshot s: CoachingLensSnapshot,
    callbacks cb: CoachingLensCallbacks
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 8,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      togglePill(icon: .x, label: "Hide insights", onTap: cb.onCollapse)

      LensComponents.cardPanel(spacing: 8, padding: 14) {
        Text("INSIGHTS", style: .meta, color: .secondary)
        if s.insights.isEmpty {
          Icon(name: .exclamationTriangle, style: .outline)
          Text("No insights", style: .heading, color: .primary)
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

      LensComponents.cardPanel(spacing: 4, padding: 12) {
        Text("STEP \(s.stepIndex + 1) OF \(s.totalSteps)", style: .meta, color: .secondary)
        Text(s.stepTitle, style: .body, color: .primary)
      }

      LensComponents.audioActionRow(
        isMuted: s.isMuted,
        onMute: cb.onMuteToggle,
        onExit: cb.onExit
      )
    }
    .padding(12)
  }

  // MARK: - 4. Step expanded (paginated)

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
        Icon(name: .checkmark, style: .filled)
        Text("Step completed", style: .heading, color: .primary)
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
        Icon(name: .checkmark, style: .filled)
        Text(s.procedureTitle ?? "Procedure complete", style: .heading, color: .primary)
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
        Text("Are you sure you want to exit?", style: .heading, color: .primary)

        // Default focus: Cancel (first tappable child — safe option).
        Button(
          label: "Cancel",
          style: .secondary,
          iconName: .arrowLeft,
          onClick: { @Sendable in cb.onExitConfirmCancel() }
        )

        Button(
          label: "Confirm exit",
          style: .outline,
          iconName: .x,
          onClick: { @Sendable in cb.onExitConfirmConfirm() }
        )
      }
    }
    .padding(12)
  }

  // MARK: - Helpers

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
