//
// ExpertLensTrees.swift
//
// Pure tree-builder functions for the expert recording lens surfaces.
//
// Per the plan surface inventory (Step 9):
//   15. ExpertNarrationTipPage           (recording, isHUDActive)
//   16. Expert stop-confirm overlay      (3s auto-countdown)
//
// Pre-recording chrome (warmup, mode select) routes to the handoff card
// per Step 10 — those phases aren't handled here. The renderer guards
// `isHUDActive` and sends `LensComponents.handoffCard(...)` while the
// recorder is warming up.
//

import Foundation
import MWDATDisplay

// MARK: - Callbacks

/// Bundle of intents the expert surfaces can fire. Renderer wires these
/// to VM actions; tree functions stay pure.
struct ExpertLensCallbacks {
  let onMuteToggle: @Sendable () -> Void   // No audio gate on Expert; placeholder for shared row.
  let onExit: @Sendable () -> Void
  let onAdvanceTip: @Sendable () -> Void
  let onRetreatTip: @Sendable () -> Void
  let onStopTapped: @Sendable () -> Void
  let onStopCancel: @Sendable () -> Void
}

// MARK: - Top-level dispatch

enum ExpertLensTrees {

  static func tree(
    snapshot s: ExpertLensSnapshot,
    callbacks cb: ExpertLensCallbacks
  ) -> FlexBox {
    // Pre-recording / warmup → handoff card on the lens. The Start CTA
    // lives on the phone chrome; the lens just tells the user where to
    // look. Step 10 generalizes this routing.
    if !s.isHUDActive {
      return LensComponents.handoffCard(reason: "Get ready on your phone")
    }

    if s.stopFlowActive {
      return stopConfirmTree(snapshot: s, callbacks: cb)
    }

    return narrationTipTree(snapshot: s, callbacks: cb)
  }

  // MARK: - 15. Narration tip page

  static func narrationTipTree(
    snapshot s: ExpertLensSnapshot,
    callbacks cb: ExpertLensCallbacks
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 8,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      // Status row: REC icon + MM:SS + hand-tracking status. No audio
      // meter and no pulsing dot per the plan (lens is repaint-only;
      // continuous animation isn't a primitive).
      FlexBox(
        direction: MWDATDisplay.Direction.row,
        spacing: 8,
        alignment: .start,
        crossAlignment: .center
      ) {
        Icon(name: .videoCamera, style: .filled)
        Text(formatMMSS(s.recordingDurationWholeSeconds), style: .body, color: .primary)
        Text(s.handTrackingStatusLabel, style: .meta, color: .secondary)
      }
      .padding(8)
      .background(.card)

      // Tip card — counter + title + body.
      LensComponents.cardPanel(spacing: 8, padding: 14) {
        Text("TIP \(s.tipIndex + 1) OF \(s.totalTips)", style: .meta, color: .secondary)
        Text(s.currentTipTitle, style: .heading, color: .primary)
        Text(s.currentTipBody, style: .body, color: .primary)
      }

      // Carousel nav — ◀ / ▶ tappable icons.
      FlexBox(
        direction: MWDATDisplay.Direction.row,
        spacing: 24,
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
        .onTap(cb.onRetreatTip)

        FlexBox(
          direction: MWDATDisplay.Direction.row,
          spacing: 0,
          alignment: .center,
          crossAlignment: .center
        ) {
          Icon(name: .arrowRight, style: .outline)
        }
        .padding(6)
        .onTap(cb.onAdvanceTip)
      }

      // Stop-recording — outline button per the plan; the lens-driven
      // 3-second confirmation flow runs through the renderer's local
      // state machine (`stopFlowActive` + countdown Task).
      Button(
        label: "Stop recording",
        style: .outline,
        iconName: .x,
        onClick: cb.onStopTapped
      )
    }
    .padding(12)
  }

  // MARK: - 16. Stop-confirm overlay (3s auto-countdown)

  static func stopConfirmTree(
    snapshot s: ExpertLensSnapshot,
    callbacks cb: ExpertLensCallbacks
  ) -> FlexBox {
    let remaining = s.stopCountdownRemaining ?? 3
    return FlexBox(
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
        Text("Stop recording?", style: .heading, color: .primary)
        Text("\(remaining)…", style: .heading, color: .primary)
        // Default focus: Cancel (first tappable child, safe option).
        Button(
          label: "Cancel",
          style: .secondary,
          iconName: .arrowLeft,
          onClick: cb.onStopCancel
        )
      }
    }
    .padding(12)
  }

  // MARK: - Helpers

  private static func formatMMSS(_ seconds: Int) -> String {
    let m = seconds / 60
    let s = seconds % 60
    return String(format: "%02d:%02d", m, s)
  }
}
