//
// AskAILensTrees.swift
//
// Pure tree-builder functions for the Ask-AI voice-search lens surface:
// Listening → Results (top matches) → Expanded (Start / Go back) → Not found.
//
// Conventions copied from NavigatorLensTrees / CoachingLensTrees:
//   - root FlexBox: column, padding 12, spacing 12, NO `.card` on the root.
//   - tappable rows = `LensComponents.actionPill` (never DSL `Button`).
//   - non-tappable header = `LensComponents.phaseChip`, `.alignSelf(.center)`.
//   - a "Go back" pill is the LAST child on every screen (per the plan).
//

import Foundation
import MWDATDisplay

// MARK: - Callbacks

struct AskAILensCallbacks {
  let onSelectCandidate: @Sendable (String) -> Void
  let onStart: @Sendable () -> Void
  let onBack: @Sendable () -> Void
}

// MARK: - Top-level dispatch

enum AskAILensTrees {

  static func tree(
    snapshot s: AskAILensSnapshot,
    callbacks cb: AskAILensCallbacks
  ) -> FlexBox {
    switch s.screen {
    case .listening: return listeningTree(callbacks: cb)
    case .results:   return resultsTree(snapshot: s, callbacks: cb)
    case .expanded:  return expandedTree(snapshot: s, callbacks: cb)
    case .notFound:  return notFoundTree(callbacks: cb)
    }
  }

  // MARK: - Listening

  private static func listeningTree(callbacks cb: AskAILensCallbacks) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 12,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      LensComponents.phaseChip("ASK AI").alignSelf(.center)
      LensComponents.cardPanel(spacing: 8, alignment: .center, crossAlignment: .center, padding: 14) {
        // Keep this heading SHORT. An `iconHeadingRow` icon scales to the text
        // line it sits beside; a long, wrapping heading (the previous "Tell me
        // what you want to work on") shrank the glyph to tiny. A one-line
        // heading keeps it hero-sized (same as `askAIHero`); the instruction
        // moves to the `.body` line below.
        LensComponents.iconHeadingRow(.speakerWithThreeArcs, "Listening")
        Text("Tell me what you want to work on", style: .body, color: .secondary)
      }
      LensComponents.smallIconButton(icon: .arrowLeft, onTap: cb.onBack)
    }
    .padding(12)
  }

  // MARK: - Results

  private static func resultsTree(
    snapshot s: AskAILensSnapshot,
    callbacks cb: AskAILensCallbacks
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 12,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      LensComponents.phaseChip("ASK AI").alignSelf(.center)
      for row in s.rows {
        resultRow(row, onTap: { cb.onSelectCandidate(row.id) })
      }
      LensComponents.smallIconButton(icon: .arrowLeft, onTap: cb.onBack)
    }
    .padding(12)
  }

  /// One result row: a single `.card` with the title in `.body`.
  private static func resultRow(
    _ row: AskAILensSnapshot.Row,
    onTap: @escaping @Sendable () -> Void
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 4,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      Text(row.title, style: .body, color: .primary)
    }
    .padding(12)
    .background(.card)
    .onTap(onTap)
  }

  // MARK: - Expanded (Start / Go back)

  private static func expandedTree(
    snapshot s: AskAILensSnapshot,
    callbacks cb: AskAILensCallbacks
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 12,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      LensComponents.phaseChip("ASK AI").alignSelf(.center)
      LensComponents.cardPanel(spacing: 8, padding: 14) {
        Text(s.expandedTitle, style: .heading, color: .primary)
        if !s.expandedReason.isEmpty {
          Text(s.expandedReason, style: .body, color: .secondary)
        }
      }
      LensComponents.actionPill(icon: .triangleRightCircle, label: "Start", onTap: cb.onStart)
      LensComponents.smallIconButton(icon: .arrowLeft, onTap: cb.onBack)
    }
    .padding(12)
  }

  // MARK: - Not found

  private static func notFoundTree(callbacks cb: AskAILensCallbacks) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 12,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      LensComponents.phaseChip("ASK AI").alignSelf(.center)
      LensComponents.cardPanel(spacing: 8, alignment: .center, crossAlignment: .center, padding: 14) {
        Text("No guide for that yet", style: .heading, color: .primary)
        Text("Try describing it a different way.", style: .body, color: .secondary)
      }
      LensComponents.smallIconButton(icon: .arrowLeft, onTap: cb.onBack)
    }
    .padding(12)
  }
}
