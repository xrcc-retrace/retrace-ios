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
//   11. TroubleshootResolvedPage          (phase=.resolved, resolution=.matched/.generated)
//   12. TroubleshootNoSolutionPage        (phase=.resolved, resolution=.noMatch)
//   13. TroubleshootConfirmOverlay        (pendingConfirmation = true)
//   14. End-diagnostic exit overlay        — owned by the SwiftUI view; lens follows
//
// The exit-confirmation overlay (surface 14) lives on the phone side
// (`TroubleshootSessionView.showDismissConfirmation`), not on the VM, so
// the lens doesn't render it — the user sees the confirmation on the
// phone while the lens stays on the active phase tree.
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
}

// MARK: - Top-level dispatch

enum TroubleshootLensTrees {

  /// Top-level dispatch. Picks the right tree given the snapshot's
  /// overlay flags (manual upload, confirm) and current phase.
  static func tree(
    snapshot s: TroubleshootLensSnapshot,
    callbacks cb: TroubleshootLensCallbacks
  ) -> FlexBox {
    // Highest-priority overlay: phone is showing the PDF picker → handoff
    // card on lens. Same "Use your phone" pattern as Step 10's phone-only
    // flows.
    if s.showManualUploadSheet {
      return LensComponents.handoffCard(reason: "Upload a PDF manual on iPhone")
    }

    // Next priority: identification confirmation overlay. Drives over
    // the phase tree until accepted/rejected.
    if s.pendingConfirmation {
      return confirmOverlayTree(snapshot: s, callbacks: cb)
    }

    // Searching narration overrides the diagnose page. Active during
    // `.diagnosing` (initial library search) and `.resolving` (web
    // search + synthesizing).
    if let narration = s.narration {
      return searchingTree(narration: narration, callbacks: cb, isMuted: s.isMuted)
    }

    switch s.phase {
    case .discovering:
      return identifyTree(callbacks: cb, isMuted: s.isMuted)
    case .diagnosing:
      return diagnoseTree(snapshot: s, callbacks: cb)
    case .resolving:
      // Phase is between library miss and web search — no narration set
      // yet. Show a generic "Looking for a fix…" placeholder so the
      // lens doesn't blank.
      return searchingTree(narration: .searchingLibrary, callbacks: cb, isMuted: s.isMuted)
    case .resolved:
      if case .noMatch = s.resolution {
        return noSolutionTree(callbacks: cb, isMuted: s.isMuted)
      } else {
        return resolvedTree(snapshot: s, callbacks: cb)
      }
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
      LensComponents.phaseChip("IDENTIFY")
      LensComponents.cardPanel(spacing: 8, padding: 14) {
        Text("Show me what's broken", style: .heading, color: .primary)
        Text("Hold the product up to the camera.", style: .body, color: .secondary)
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
      // Product chip on top — uppercased name in a `.card` background.
      // Renders only when identification has landed.
      if let product = s.identifiedProductName {
        LensComponents.phaseChip(product)
      }
      LensComponents.phaseChip("DIAGNOSE")
      LensComponents.cardPanel(spacing: 8, padding: 14) {
        Text("Describe what's wrong", style: .heading, color: .primary)
        Text("Tell me the symptoms so I can find a fix.", style: .body, color: .secondary)
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
    isMuted: Bool
  ) -> FlexBox {
    let (iconName, title, detail): (IconName, String, String?) = {
      switch narration {
      case .searchingLibrary:
        return (.eye, "Searching your library…", nil)
      case .libraryMissed:
        return (.exclamationTriangle, "No procedure found", "Trying the web next.")
      case .searchingWeb:
        return (.metaAi, "Searching online…", nil)
      case .synthesizing(let n):
        return (.metaAi, "Synthesizing answer…", "From \(n) sources")
      case .foundFix(let n):
        return (.checkmark, "Found a fix", "Based on \(n) sources")
      }
    }()

    return FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 8,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      LensComponents.phaseChip("FIND FIX")
      LensComponents.cardPanel(
        spacing: 12,
        alignment: .center,
        crossAlignment: .center,
        padding: 18
      ) {
        Icon(name: iconName, style: .outline)
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
        return (title, "From your library.")
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
      LensComponents.phaseChip("FIND FIX")
      LensComponents.cardPanel(spacing: 8, padding: 14) {
        Text(procedureTitle, style: .heading, color: .primary)
        if !sourceText.isEmpty {
          Text(sourceText, style: .meta, color: .secondary)
        }
      }
      // Default focus: Start (placed first among Buttons per the plan).
      Button(
        label: startLabel,
        style: .primary,
        iconName: startIcon,
        onClick: cb.onStartProcedure
      )
      Button(
        label: "Rediagnose",
        style: .secondary,
        iconName: .twoArrowsClockwise,
        onClick: cb.onRediagnose
      )
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
      LensComponents.phaseChip("FIND FIX")
      LensComponents.cardPanel(
        spacing: 12,
        alignment: .center,
        crossAlignment: .center,
        padding: 18
      ) {
        Icon(name: .exclamationTriangle, style: .outline)
        Text("Nothing found", style: .heading, color: .primary)
        Text(
          "I couldn't find a matching procedure. Upload a manual to keep going.",
          style: .body,
          color: .secondary
        )
      }
      // Upload-manual: primary; flips the manual-upload sheet on the
      // phone, which triggers the handoff card on the next snapshot.
      Button(
        label: "Upload a manual",
        style: .primary,
        iconName: .metaAi,
        onClick: cb.onUploadManual
      )
      Button(
        label: "Rediagnose",
        style: .secondary,
        iconName: .twoArrowsClockwise,
        onClick: cb.onRediagnose
      )
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
      LensComponents.cardPanel(
        spacing: 8,
        alignment: .center,
        crossAlignment: .center,
        padding: 18
      ) {
        if let category = s.identifiedCategory {
          LensComponents.phaseChip(category)
        }
        Text(s.identifiedProductName ?? "Identified product", style: .heading, color: .primary)
        if let confidence = s.identifiedConfidence {
          Text("\(confidence) confidence", style: .meta, color: .secondary)
        }
      }
      // Default focus: "That's it" (first Button child of the FlexBox).
      // SDK tree-order traversal lands here on initial render.
      Button(
        label: "That's it",
        style: .primary,
        iconName: .checkmark,
        onClick: cb.onConfirmIdentification
      )
      Button(
        label: "Try again",
        style: .secondary,
        iconName: .twoArrowsClockwise,
        onClick: cb.onRequestReIdentify
      )
    }
    .padding(12)
  }
}
