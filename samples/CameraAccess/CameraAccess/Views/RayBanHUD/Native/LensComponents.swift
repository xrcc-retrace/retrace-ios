//
// LensComponents.swift
//
// Reusable `FlexBox` factory functions for the native lens renderers.
//
// Goals:
//   - One canonical implementation of every recurring lens surface
//     (cards, the audio/exit footer, the "use your phone" handoff, the
//     phase chips for Troubleshoot). Renderers compose these.
//   - Hide the FlexBox-modifier boilerplate (`.padding`, `.background`)
//     so per-page tree code stays focused on layout intent.
//   - Bake the spacing fix from the Step 3 smoke test: in column FlexBoxes
//     that contain an `Icon` + `Text(.heading)`, spacing of 8 caused the
//     icon to overlap the heading on the lens. Minimum spacing here is 12.
//
// Tree-order rule: every focusable element added to a FlexBox becomes
// part of the Captouch / Neural Band traversal in document order. Place
// the safer default-focus element first when building overlays.
//

import Foundation  // CGFloat (Foundation re-exports CoreGraphics on Apple platforms)
import MWDATDisplay

// `MWDATDisplay.Direction` is fully qualified throughout this file
// because our project defines `enum Direction` at module scope in
// `Views/RayBanHUD/HUDInputEngine.swift` (used by the SwiftUI focus
// engine), which shadows the SDK's. Other MWDATDisplay types
// (Alignment, Background, TextStyle, etc.) don't collide with anything
// in the project so they stay unqualified.

enum LensComponents {

  // MARK: - Surfaces

  /// Standard content card. `.card` background, `.medium` corner radius,
  /// padded inset. Used for step cards, narration cards, completion cards.
  ///
  /// `spacing` defaults to 12 — matches the smoke-test finding that 8
  /// caused icon/heading overlap on the lens.
  static func cardPanel(
    direction: MWDATDisplay.Direction = .column,
    spacing: CGFloat = 12,
    alignment: Alignment = .start,
    crossAlignment: Alignment = .stretch,
    padding: CGFloat = 16,
    @ComponentBuilder content: () -> [any ViewComponent]
  ) -> FlexBox {
    FlexBox(
      direction: direction,
      spacing: spacing,
      alignment: alignment,
      crossAlignment: crossAlignment,
      content: content
    )
    .padding(padding)
    .background(.card)
  }

  /// Small uppercase chip in a `.card` background. Used for phase
  /// indicators ("IDENTIFY", "DIAGNOSE", "FIND FIX") and product chips
  /// (uppercased product name on the diagnose page).
  static func phaseChip(_ label: String, color: TextColor = .secondary) -> FlexBox {
    FlexBox(direction: .row, spacing: 0, alignment: .start, crossAlignment: .center) {
      Text(label.uppercased(), style: .meta, color: color)
    }
    .padding(6)
    .background(.card)
  }

  /// Bottom-anchored row, split to opposite corners: Mute/Unmute as its own
  /// labelled pill on the LEFT, Exit as its own labelled pill on the RIGHT —
  /// mirroring the top band's Reference/Insights split. Each pill carries its
  /// own `.card` background (two separate buttons, not one shared bar); an
  /// empty `flexGrow(1)` spacer pushes them apart (the `Alignment` enum has
  /// no `spaceBetween`).
  ///
  /// Tree order: mute first, exit second. D-pad traversal follows.
  static func audioActionRow(
    isMuted: Bool,
    onMute: @escaping @Sendable () -> Void,
    onExit: @escaping @Sendable () -> Void
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.row,
      spacing: 8,
      alignment: .start,
      crossAlignment: .center
    ) {
      // Mute / Unmute — bottom-left. Icon reflects state, label the action.
      FlexBox(direction: MWDATDisplay.Direction.row, spacing: 6, alignment: .start, crossAlignment: .center) {
        Icon(name: isMuted ? .speakerOff : .speakerWithThreeArcs, style: .outline)
        Text(isMuted ? "Unmute" : "Mute", style: .meta, color: .primary)
      }
      .padding(6)
      .background(.card)
      .onTap(onMute)

      // Grow-spacer pushes Exit to the right edge.
      FlexBox(direction: MWDATDisplay.Direction.row, spacing: 0, alignment: .center, crossAlignment: .center) {}
      .flexGrow(1)

      // Exit — bottom-right.
      FlexBox(direction: MWDATDisplay.Direction.row, spacing: 6, alignment: .start, crossAlignment: .center) {
        Icon(name: .x, style: .outline)
        Text("Exit", style: .meta, color: .primary)
      }
      .padding(6)
      .background(.card)
      .onTap(onExit)
    }
  }

  /// "Press on your phone to continue" card. Routed via
  /// `LensFlow.handoffToPhone(reason:)`. Static, no interactive elements —
  /// the user is expected to act on the phone screen.
  ///
  /// `heading` defaults to the canonical imperative ("Press on your phone
  /// to continue") so existing call sites need only pass `reason:`. Other
  /// phone-only surfaces can pass an action-specific heading like
  /// "Open Server Settings" or "Pick a mode on your phone".
  ///
  /// The icon row was dropped 2026-06-14: `.metaAi` rendered as a faint
  /// white-in-rectangle blob against the `.card` background, and there's
  /// no mapped phone/tap glyph in `LensIconMap` that would clearly convey
  /// "act on the phone." Leading with the imperative text alone is cleaner.
  static func handoffCard(
    heading: String = "Press on your phone to continue",
    reason: String
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 12,
      alignment: .center,
      crossAlignment: .center
    ) {
      Text(heading, style: .heading, color: .primary)
      Text(reason, style: .body, color: .secondary)
    }
    .padding(24)
    .background(.card)
  }

  // MARK: - Helpers

  /// Truncate a description to `maxLength` characters with a trailing ellipsis.
  /// Used for the collapsed step card preview.
  static func truncate(_ text: String, max length: Int) -> String {
    guard text.count > length else { return text }
    return String(text.prefix(length - 1)) + "…"
  }

  /// Paginate a long string into ~`chunkSize`-character pages, breaking on
  /// word boundaries when possible. Used by the coaching `.stepExpanded`
  /// surface (Step 6) for the visible ◀ ▶ pagination.
  ///
  /// Returns `(pages, totalPages)`. `pages` is a flat array; renderers
  /// pull `pages[descPage]`.
  static func paginate(_ text: String, chunkSize: Int) -> [String] {
    guard !text.isEmpty else { return [""] }
    guard text.count > chunkSize else { return [text] }

    var result: [String] = []
    var remaining = text[...]

    while !remaining.isEmpty {
      if remaining.count <= chunkSize {
        result.append(String(remaining))
        break
      }

      // Find a word boundary near the chunk size — search backwards from
      // the cap so we don't split mid-word. Bail to a hard cut if no
      // space found within the chunk.
      let cap = remaining.index(remaining.startIndex, offsetBy: chunkSize)
      let searchRange = remaining.startIndex..<cap
      let breakIdx = remaining.range(of: " ", options: .backwards, range: searchRange)?.lowerBound ?? cap

      let page = remaining[remaining.startIndex..<breakIdx]
      result.append(String(page).trimmingCharacters(in: .whitespaces))

      // Skip the boundary space if we broke on one.
      let nextStart = breakIdx == cap ? cap : remaining.index(after: breakIdx)
      remaining = remaining[nextStart...]
    }

    return result
  }
}
