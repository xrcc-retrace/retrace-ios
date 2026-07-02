//
// TroubleshootLensTrees.swift
//
// Pure tree-builder functions for the troubleshoot flow's lens surfaces.
//
// Mirror of `CoachingLensTrees` for the troubleshoot mode. Per the plan
// surface inventory (Step 8):
//   8.  TroubleshootIdentifyPage          (phase=.discovering)
//   9.  TroubleshootDiagnosePage          (phase=.diagnosing, no narration)
//   10. TroubleshootSearchingPage         (narration != nil — 5 sub-states)
//   11. TroubleshootResolvedPage          (resolution=.matched/.generated)
//   12. TroubleshootNoSolutionPage        (resolution=.noMatch)
//   13. TroubleshootConfirmOverlay        (pendingConfirmation = true)
//   14. End-diagnostic exit overlay        (showDismissConfirmation = true)
//
// The exit-confirmation overlay (surface 14) is rendered ON the lens
// (`exitConfirmationTree`), mirroring the coaching flow: the Exit pill sets
// a renderer-local flag, and "Confirm exit" runs the VM's `onExitConfirmed`
// bridge (endSession + dismiss). The phone's own exit overlay stays wired
// for the iPhone back-gesture path.
//

import Foundation
import MWDATDisplay

// MARK: - Callbacks

/// Bundle of intents the troubleshoot surfaces can fire. Renderer wires
/// these to VM actions; tree functions stay pure.
struct TroubleshootLensCallbacks {
  // Top-bar / audio row
  let onMuteToggle: @Sendable () -> Void
  let onExit: @Sendable () -> Void

  // Confirm overlay
  let onConfirmIdentification: @Sendable () -> Void
  let onRequestReIdentify: @Sendable () -> Void

  // Resolved / no-solution
  let onStartProcedure: @Sendable () -> Void
  let onRediagnose: @Sendable () -> Void
  let onUploadManual: @Sendable () -> Void

  // On-lens exit confirmation (mirrors coaching)
  let onExitConfirmCancel: @Sendable () -> Void
  let onExitConfirmConfirm: @Sendable () -> Void
}

// MARK: - Top-level dispatch

enum TroubleshootLensTrees {

  /// Top-level dispatch. Picks the right tree given the snapshot's
  /// overlay flags (manual upload, confirm) and current phase.
  static func tree(
    snapshot s: TroubleshootLensSnapshot,
    callbacks cb: TroubleshootLensCallbacks
  ) -> FlexBox {
    // Highest-priority overlay: on-lens exit confirmation ("End diagnostic?").
    // Drives over every phase tree until cancelled/confirmed.
    if s.showDismissConfirmation {
      return exitConfirmationTree(callbacks: cb)
    }

    // Next: phone is showing the PDF picker → handoff card on lens. Same
    // "Use your phone" pattern as Step 10's phone-only flows.
    if s.showManualUploadSheet {
      return LensComponents.handoffCard(reason: "Upload a PDF manual on iPhone")
    }

    // Next priority: identification confirmation overlay. Drives over
    // the phase tree until accepted/rejected.
    if s.pendingConfirmation {
      return confirmOverlayTree(snapshot: s, callbacks: cb)
    }

    // A landed resolution IS the handoff surface — show it the moment the
    // search result exists, regardless of phase. `phase == .resolved` only
    // arrives via the `handoff_to_learner` tool call, which Gemini may issue
    // late or never; the resolution is our own verified state. (Matches the
    // phone emulator's routing in TroubleshootSessionView.) The VM's hold
    // tasks guarantee narration is nil once a resolution is applied, so the
    // `.foundFix` success flash still gets its floor before this fires.
    if let resolution = s.resolution {
      if case .noMatch = resolution {
        return noSolutionTree(callbacks: cb, isMuted: s.isMuted)
      }
      return resolvedTree(snapshot: s, callbacks: cb)
    }

    // Searching narration overrides the diagnose page. Active during
    // `.diagnosing` (initial library search) and `.resolving` (web
    // search + synthesizing).
    if let narration = s.narration {
      return searchingTree(narration: narration, callbacks: cb, isMuted: s.isMuted, animFrame: s.searchAnimFrame)
    }

    switch s.phase {
    case .discovering:
      return identifyTree(callbacks: cb, isMuted: s.isMuted)
    case .diagnosing:
      return diagnoseTree(snapshot: s, callbacks: cb)
    case .resolving, .resolved:
      // Resolution not landed yet (it routes above when it has) — we're
      // between library miss and web search with no narration set. Show a
      // generic "Looking for a fix…" placeholder so the lens doesn't blank.
      return searchingTree(narration: .searchingLibrary, callbacks: cb, isMuted: s.isMuted, animFrame: s.searchAnimFrame)
    }
  }

  // MARK: - 8. Identify page

  static func identifyTree(
    callbacks cb: TroubleshootLensCallbacks,
    isMuted: Bool
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 8,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      LensComponents.phaseHeader(icon: .circleHandle, title: "Identify")
      LensComponents.cardPanel(spacing: 8, padding: 14) {
        Text("Show me what's broken", style: .heading, color: .primary)
        Text("Or describe it out loud — say or show the device.", style: .body, color: .secondary)
      }
      LensComponents.audioActionRow(
        isMuted: isMuted,
        onMute: cb.onMuteToggle,
        onExit: cb.onExit
      )
    }
    .padding(12)
  }

  // MARK: - 9. Diagnose page

  static func diagnoseTree(
    snapshot s: TroubleshootLensSnapshot,
    callbacks cb: TroubleshootLensCallbacks
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 8,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      LensComponents.phaseHeader(icon: .bug, title: "Diagnose")
      // Product chip — the identified device carried into diagnose, mirroring
      // the phone HUD's yellow chip (lens can't fill yellow, so it's a `.card`
      // chip). `.alignSelf(.center)` makes it a compact centered pill (it would
      // otherwise stretch full-width under the column's `.stretch`). Renders
      // only when identification has landed.
      if let product = s.identifiedProductName {
        LensComponents.phaseChip(product).alignSelf(.center)
      }
      LensComponents.cardPanel(spacing: 8, padding: 14) {
        Text("Describe what's wrong", style: .heading, color: .primary)
        Text("Tell me what you're seeing — strange noises, error lights, parts that don't fit.", style: .body, color: .secondary)
      }
      LensComponents.audioActionRow(
        isMuted: s.isMuted,
        onMute: cb.onMuteToggle,
        onExit: cb.onExit
      )
    }
    .padding(12)
  }

  // MARK: - 10. Searching page (5 narration states)

  static func searchingTree(
    narration: TroubleshootLensSnapshot.LensSearchNarration,
    callbacks cb: TroubleshootLensCallbacks,
    isMuted: Bool,
    animFrame: Int
  ) -> FlexBox {
    // The phase header carries the (small) icon now; the status card is just
    // the live title + detail per narration sub-state.
    let (title, detail): (String, String?) = {
      switch narration {
      case .searchingLibrary:
        return ("Searching your library", "Checking your saved procedures.")
      case .libraryMissed:
        return ("No procedure found in your library.", "Looking online next.")
      case .searchingWeb:
        return ("Searching online", "Reddit, iFixit, repair forums.")
      case .synthesizing(let n):
        return ("Synthesizing the procedure", "Found \(n) source\(n == 1 ? "" : "s") on Reddit, iFixit, repair forums.")
      case .foundFix(let n):
        return ("Solution found", "From \(n) online source\(n == 1 ? "" : "s").")
      }
    }()

    // The online-search window (web + synthesizing) shows the animated
    // paper-airplane "sending to the web and back" track instead of a static
    // icon. The other (brief) states keep the static stage icon.
    let animated: Bool = {
      switch narration {
      case .searchingWeb, .synthesizing: return true
      default:                           return false
      }
    }()

    return FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 8,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      LensComponents.phaseHeader(icon: .lightBulb, title: "Find a fix", subtitle: "Library and web")
      LensComponents.cardPanel(spacing: 8, padding: 14) {
        // Animated paper-airplane track during the online search; the brief
        // states are text-only (the header carries the small phase icon, so
        // there's no second oversized status icon in the card).
        if animated {
          LensComponents.airplaneTrack(frame: animFrame)
        }
        Text(title, style: .heading, color: .primary)
        if let detail {
          Text(detail, style: .body, color: .secondary)
        }
      }
      LensComponents.audioActionRow(
        isMuted: isMuted,
        onMute: cb.onMuteToggle,
        onExit: cb.onExit
      )
    }
    .padding(12)
  }

  // MARK: - 11. Resolved page

  static func resolvedTree(
    snapshot s: TroubleshootLensSnapshot,
    callbacks cb: TroubleshootLensCallbacks
  ) -> FlexBox {
    let (procedureTitle, sourceText): (String, String) = {
      switch s.resolution {
      case .matchedProcedure(let title, _):
        return (title, "Found in your library.")
      case .generatedSOP(let title, _):
        return (title, "Synthesized from web sources.")
      case .noMatch, .none:
        // Shouldn't happen — dispatch routes `.noMatch` to `noSolutionTree`
        // and `nil` resolution shouldn't reach the `.resolved` phase.
        return ("Fix ready", "")
      }
    }()

    // Start button: 3 sub-states per the plan.
    let (startLabel, startIcon): (String, IconName) = {
      if s.handoffInFlight {
        return ("Starting…", .metaAi)
      } else if s.handoffError != nil {
        return ("Try again", .exclamationTriangle)
      } else {
        return ("Start", .arrowRight)
      }
    }()

    return FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 12,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      LensComponents.phaseHeader(icon: .lightBulb, title: "Find a fix", subtitle: "Library and web")
      LensComponents.cardPanel(spacing: 8, padding: 14) {
        Text(procedureTitle, style: .heading, color: .primary)
        if !sourceText.isEmpty {
          Text(sourceText, style: .meta, color: .secondary)
        }
      }
      // Default focus: Start (first tappable in tree order). Static centered
      // pills — not the DSL `Button` (animated, left-aligned).
      LensComponents.actionPill(icon: startIcon, label: startLabel, onTap: cb.onStartProcedure)
      LensComponents.actionPill(icon: .twoArrowsClockwise, label: "Rediagnose", onTap: cb.onRediagnose)
      LensComponents.audioActionRow(
        isMuted: s.isMuted,
        onMute: cb.onMuteToggle,
        onExit: cb.onExit
      )
    }
    .padding(12)
  }

  // MARK: - 12. No-solution page

  static func noSolutionTree(
    callbacks cb: TroubleshootLensCallbacks,
    isMuted: Bool
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 12,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      LensComponents.phaseHeader(icon: .lightBulb, title: "Find a fix", subtitle: "Library and web")
      LensComponents.cardPanel(spacing: 8, padding: 14) {
        Text("Nothing found", style: .heading, color: .primary)
        Text(
          "Couldn't match a saved procedure or synthesize one from the web. Try uploading a manual.",
          style: .body,
          color: .secondary
        )
      }
      // Upload-manual: default focus (first tappable). Flips the manual-upload
      // sheet on the phone, which triggers the handoff card on the next
      // snapshot. Text-only — no mapped upload glyph in the lens icon set.
      LensComponents.actionPill(label: "Upload a manual", onTap: cb.onUploadManual)
      LensComponents.actionPill(icon: .twoArrowsClockwise, label: "Rediagnose", onTap: cb.onRediagnose)
      LensComponents.audioActionRow(
        isMuted: isMuted,
        onMute: cb.onMuteToggle,
        onExit: cb.onExit
      )
    }
    .padding(12)
  }

  // MARK: - 13. Identification confirmation overlay

  static func confirmOverlayTree(
    snapshot s: TroubleshootLensSnapshot,
    callbacks cb: TroubleshootLensCallbacks
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 12,
      alignment: .center,
      crossAlignment: .stretch
    ) {
      // Top: a centered "DEVICE" pill (the category when known, else "Device"),
      // mirroring the phone confirm overlay's category chip. `.alignSelf(.center)`
      // keeps it a compact capsule under the column's `.stretch`.
      LensComponents.phaseChip(s.identifiedCategory ?? "Device")
        .alignSelf(.center)
      // Middle: the identified device name + confidence, centered.
      LensComponents.cardPanel(
        spacing: 8,
        alignment: .center,
        crossAlignment: .center,
        padding: 18
      ) {
        Text(s.identifiedProductName ?? "Identified product", style: .heading, color: .primary)
        if let confidence = s.identifiedConfidence {
          Text("\(confidence) confidence", style: .meta, color: .secondary)
        }
      }
      // EMPIRICAL TEST (confirm overlay only): label-only DSL `Button`s.
      // The DSL Button renders the SDK focus cursor/highlight (which the
      // static `actionPill` does NOT), so the default-focused control is
      // visible without a swipe. We drop `iconName` deliberately: the
      // collapse-to-icon-on-blur behavior (label hidden until hover) is
      // icon-driven, so a label-only Button should keep its text visible at
      // all times. Default focus = "That's it" (first tappable in tree order).
      // If this reads well on-glass, roll the same pattern out to the
      // resolved / no-solution / exit buttons.
      Button(label: "That's it", style: .primary, iconName: .checkmark, onClick: cb.onConfirmIdentification)
      Button(label: "Try again", style: .secondary, iconName: .twoArrowsClockwise, onClick: cb.onRequestReIdentify)
    }
    .padding(12)
  }

  // MARK: - 14. On-lens exit confirmation overlay

  /// "End diagnostic?" confirmation rendered ON the glasses (mirrors the
  /// coaching exit overlay). Cancel is first → default focus on the safe
  /// option. Static centered pills, no DSL `Button` animation.
  static func exitConfirmationTree(
    callbacks cb: TroubleshootLensCallbacks
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
          Text("End diagnostic?", style: .heading, color: .primary)
        }
        LensComponents.actionPill(icon: .arrowLeft, label: "Cancel", onTap: cb.onExitConfirmCancel)
        LensComponents.actionPill(icon: .x, label: "Confirm exit", onTap: cb.onExitConfirmConfirm)
      }
    }
    .padding(12)
  }
}
