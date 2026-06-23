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

  /// Small uppercase chip in a `.card` background. Used for product /
  /// category chips (uppercased product name on the diagnose page, "DEVICE"
  /// on the confirm overlay). Label is CENTERED so that when the chip is
  /// stretched full-width under a `.stretch` parent the text sits in the
  /// middle of the pill (not left-aligned). When the chip is sized to its
  /// content (e.g. via `.alignSelf(.center)`), centering is a no-op.
  static func phaseChip(_ label: String, color: TextColor = .secondary) -> FlexBox {
    FlexBox(direction: .row, spacing: 0, alignment: .center, crossAlignment: .center) {
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

  /// A single icon wrapped in a start-aligned row so it renders at its
  /// natural, small inline size at the TOP-LEFT of a card — and does not
  /// stretch. A lone `Icon` placed directly as a column child renders
  /// oversized on the lens (it fills the card and the text overlaps it);
  /// nesting it in a row is the fix. Mirrors the phone stage-header card's
  /// small leading icon.
  static func iconRow(_ name: IconName, style: IconStyle = .outline) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.row,
      spacing: 0,
      alignment: .start,
      crossAlignment: .center
    ) {
      Icon(name: name, style: style)
    }
  }

  /// Full-width static action pill with a CENTERED icon+label in a `.card`
  /// background. This is the lens-native replacement for the DSL `Button`
  /// (which left-aligns its label and carries a built-in collapse/expand
  /// press animation the user dislikes). `icon` is optional — pass `nil` for
  /// a text-only pill when no mapped glyph fits (e.g. "Upload a manual").
  ///
  /// Used by the troubleshoot resolved / no-solution / confirm / exit
  /// surfaces; mirrors coaching's centered pills.
  static func actionPill(
    icon: IconName? = nil,
    label: String,
    onTap: @escaping () -> Void
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.row,
      spacing: 6,
      alignment: .center,
      crossAlignment: .center
    ) {
      if let icon {
        Icon(name: icon, style: .outline)
      }
      Text(label, style: .body, color: .primary)
    }
    .padding(8)
    .background(.card)
    .onTap(onTap)
  }

  /// Slim 3-segment diagnostic phase indicator, the lens companion to the
  /// phone's `DiagnosticPhaseLensBar`. `activeIndex`: 0 = Identify,
  /// 1 = Diagnose, 2 = Find a fix.
  ///
  /// Bright-vs-faint, not filled-vs-invisible: the lens `Background` enum is
  /// only `.none`/`.card` with no opacity, so a future segment can't be a
  /// "dim fill". The one lever with two visible levels is `TextColor`
  /// (`.primary`/`.secondary`), so future segments render a `.secondary`
  /// dash — a faint but visible track — while past+current segments are a
  /// solid `.card` bar. (Closest we can get to the phone bar's 0.95/0.18.)
  static func phaseSegments(activeIndex: Int) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.row,
      spacing: 6,
      alignment: .start,
      crossAlignment: .center
    ) {
      for i in 0..<3 {
        if i <= activeIndex {
          // Done / current — solid filled bar (a space gives it height).
          FlexBox(direction: MWDATDisplay.Direction.row, spacing: 0, alignment: .center, crossAlignment: .center) {
            Text(" ", style: .meta, color: .primary)
          }
          .flexGrow(1)
          .padding(2)
          .background(.card)
        } else {
          // Upcoming — faint dash, no fill, still holding its flexGrow width.
          FlexBox(direction: MWDATDisplay.Direction.row, spacing: 0, alignment: .center, crossAlignment: .center) {
            Text("—", style: .meta, color: .secondary)
          }
          .flexGrow(1)
          .padding(2)
        }
      }
    }
  }

  /// Paper-airplane "sending to the web and back" animation track. A glasses
  /// icon anchors the left (you), a globe anchors the right (the web), and a
  /// paper airplane shuttles between them. Horizontal motion is achieved with
  /// two empty `flexGrow` spacers whose ratio is interpolated by `frame` (the
  /// `Alignment` enum has no positioning, but `FlexBox.flexGrow(Float)` does).
  ///
  /// `frame` is the renderer's monotonic frame counter; the airplane ping-pongs
  /// with a fixed period, so "send" and "return" read as one continuous loop.
  /// Driven by `TroubleshootLensRenderer`'s ~8fps frame loop during the
  /// online-search window.
  static func airplaneTrack(frame: Int) -> FlexBox {
    let period = 24
    let half = period / 2
    let phase = ((frame % period) + period) % period
    // Triangle wave 0 → 1 → 0 across the period (out to the web, then back).
    let pos: Double = phase <= half
      ? Double(phase) / Double(half)
      : Double(period - phase) / Double(half)
    // Bias away from 0 so neither spacer fully collapses (keeps the anchors
    // pinned to the edges and the plane off the icons).
    let pLeft = Float(max(0.04, pos))
    let pRight = Float(max(0.04, 1.0 - pos))

    return FlexBox(
      direction: MWDATDisplay.Direction.row,
      spacing: 6,
      alignment: .start,
      crossAlignment: .center
    ) {
      Icon(name: .smartGlasses, style: .outline)
      FlexBox(direction: MWDATDisplay.Direction.row, spacing: 0, alignment: .center, crossAlignment: .center) {}
        .flexGrow(pLeft)
      Icon(name: .paperAirplane, style: .filled)
      FlexBox(direction: MWDATDisplay.Direction.row, spacing: 0, alignment: .center, crossAlignment: .center) {}
        .flexGrow(pRight)
      Icon(name: .globeWesternHemisphere, style: .outline)
    }
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
