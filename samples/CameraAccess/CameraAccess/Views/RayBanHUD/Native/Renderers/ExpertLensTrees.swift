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

  /// Rebuilt 2026-06-22 for the real Meta Ray-Ban Display lens (hardware
  /// testing, NOT the phone simulator). The key platform constraint: on
  /// glasses the app only ever receives `FlexBox.onTap` / `Button.onClick`
  /// — the SDK consumes Neural Band swipes itself to move the focus
  /// highlight between tappable elements, and `HandGestureService` (the
  /// pinch-drag pipeline) only runs on `.iPhone` transport. So any control
  /// the user must reach has to be a tappable element.
  /// - Recording status chip at top — videoCamera icon + MM:SS timer only,
  ///   `.alignSelf(.center)` so it stays a compact capsule. No audio
  ///   indicator (gimmicky) and no hand-tracking / "Neural Band" status
  ///   text (meaningless on the band-driven Display path).
  /// - Tip row `[◀] card [▶]`: the arrows are tappable FlexBoxes that fire
  ///   `onRetreatTip` / `onAdvanceTip`. `crossAlignment: .stretch` makes
  ///   them match the card's full height; the card's `.flexGrow(1)` absorbs
  ///   the remaining width. This replaces the dead pinch-drag carousel —
  ///   swipe moves focus onto an arrow, pinch fires it, tip changes.
  /// - Stop pill as a tappable FlexBox row with explicit Icon + Text
  ///   children + `.card` background; kept LAST in tree order so it is
  ///   never the default focus (avoids an accidental-stop pinch). The
  ///   3-sec stop-confirm overlay that follows is the safety confirm.
  static func narrationTipTree(
    snapshot s: ExpertLensSnapshot,
    callbacks cb: ExpertLensCallbacks
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 12,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      // Recording status chip — compact capsule with rec icon + timer.
      // `.alignSelf(.center)` keeps it from stretching to full width under
      // the parent column's `crossAlignment: .stretch`. No audio indicator
      // and no hand-tracking text: on the Display path the Neural Band IS
      // the input, so a "Neural Band" status label is meaningless clutter.
      FlexBox(
        direction: MWDATDisplay.Direction.row,
        spacing: 10,
        alignment: .center,
        crossAlignment: .center
      ) {
        Icon(name: .videoCamera, style: .filled)
        Text(
          formatMMSS(s.recordingDurationWholeSeconds),
          style: .body,
          color: .primary
        )
      }
      .padding(10)
      .background(.card)
      .alignSelf(.center)

      // Tip row — [◀] card [▶]. On the real lens the app never receives a
      // raw swipe (the SDK consumes Neural Band swipes to move focus between
      // tappable elements), so tip cycling MUST go through tappable controls.
      // The arrows are tappable FlexBoxes; `crossAlignment: .stretch` makes
      // them match the card's full height with no hardcoded size, and the
      // card's `.flexGrow(1)` absorbs the remaining width (so it shrinks a
      // little to make room for the arrows). `onAdvanceTip` / `onRetreatTip`
      // are already wired in `ExpertLensRenderer.makeCallbacks()`.
      FlexBox(
        direction: MWDATDisplay.Direction.row,
        spacing: 8,
        alignment: .center,
        crossAlignment: .stretch
      ) {
        // ◀ previous tip — narrow, full card height, icon centered.
        FlexBox(
          direction: MWDATDisplay.Direction.column,
          spacing: 0,
          alignment: .center,
          crossAlignment: .center
        ) {
          Icon(name: .arrowLeft, style: .filled)
        }
        .padding(8)
        .background(.card)
        .onTap(cb.onRetreatTip)

        LensComponents.cardPanel(spacing: 8, padding: 14) {
          Text("HOW TO NARRATE", style: .meta, color: .secondary)
          Text(s.currentTipTitle, style: .heading, color: .primary)
          Text(s.currentTipBody, style: .body, color: .primary)
        }
        .flexGrow(1)

        // ▶ next tip.
        FlexBox(
          direction: MWDATDisplay.Direction.column,
          spacing: 0,
          alignment: .center,
          crossAlignment: .center
        ) {
          Icon(name: .arrowRight, style: .filled)
        }
        .padding(8)
        .background(.card)
        .onTap(cb.onAdvanceTip)
      }
      // `.flexGrow(1)` on the tip row (a child of the outer COLUMN) makes it
      // absorb all leftover vertical space between the chip and the Stop pill.
      // Result: the card is a constant, maximal height every render — it no
      // longer grows/shrinks as tip text length changes. The arrows stretch
      // to that height via the row's `crossAlignment: .stretch`, and the card
      // fills it via the row's `crossAlignment: .stretch` + its own flexGrow.
      .flexGrow(1)

      // Stop pill — tappable FlexBox row, NOT a Button widget. Explicit
      // Icon + Text children + `.card` background = guaranteed visible
      // affordance in resting state, no dependence on SDK button-style
      // rendering quirks (the `.outline` and even `.primary` styles
      // have shown label-on-focus behavior on hardware).
      FlexBox(
        direction: MWDATDisplay.Direction.row,
        spacing: 10,
        alignment: .center,
        crossAlignment: .center
      ) {
        Icon(name: .x, style: .filled)
        Text("Stop recording", style: .body, color: .primary)
      }
      .padding(12)
      .background(.card)
      .onTap(cb.onStopTapped)
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
        Text("\(remaining) sec", style: .heading, color: .primary)
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
