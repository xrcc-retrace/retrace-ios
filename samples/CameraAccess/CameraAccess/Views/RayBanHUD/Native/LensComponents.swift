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
    // The DSL has no width lever (no `frame`/`width`), so a compact pill is
    // made WIDER by adding horizontal inset: more leading/trailing than
    // top/bottom via `EdgeInsets`. Bumped overall vs the old uniform 10.
    .padding(EdgeInsets(top: 12, bottom: 12, leading: 22, trailing: 22))
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
      .padding(10)
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
      .padding(10)
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

  /// Hero icon-beside-heading row for status / completion / info cards: a glyph
  /// in a `.row` immediately LEFT of a `.heading` title. Because the icon scales
  /// to the text it sits next to in a row, pairing it with `.heading` gives a
  /// deliberate large "hero" glyph (matching `askAIHero`/`recordHero`) — and,
  /// critically, it does NOT balloon the way a lone or column-stacked icon does.
  ///
  /// THE SIZING RULE (load-bearing — see also `phaseHeader`): `MWDATDisplay.Icon`
  /// has no size parameter; it scales to the `Text` it sits next to in the SAME
  /// `.row`. A lone icon, or an icon stacked above/below text in a `.column`,
  /// has nothing to scale against and balloons (fills the card, overlaps the
  /// title). Use this helper (hero, `.heading`), `phaseHeader` (small, `.body`),
  /// or `actionPill` (small, `.body`) — never a bare `Icon` as a card child.
  static func iconHeadingRow(
    _ icon: IconName,
    _ title: String,
    style: IconStyle = .filled,
    color: TextColor = .primary
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.row,
      spacing: 10,
      alignment: .center,
      crossAlignment: .center
    ) {
      Icon(name: icon, style: style)
      Text(title, style: .heading, color: color)
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
    .padding(12)
    .background(.card)
    .onTap(onTap)
  }

  /// A compact, content-sized, icon-only tappable pill in a `.card`.
  /// `.alignSelf(.center)` keeps it from stretching full-width so it stays
  /// visually subordinate to the screen's content — used for "go back"/escape
  /// controls (and the hidden-game launcher) that shouldn't pull focus from the
  /// content. Defaults to a left arrow. The icon renders at its default
  /// (moderate) size because it has no sibling `Text` to scale against — fine
  /// for a standalone small button (the lone-icon "ballooning" only bites when
  /// an icon sits beside a `.heading`; see `phaseHeader`).
  static func smallIconButton(
    icon: IconName = .arrowLeft,
    onTap: @escaping () -> Void
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.row,
      spacing: 0,
      alignment: .center,
      crossAlignment: .center
    ) {
      Icon(name: icon, style: .outline)
    }
    .padding(8)
    .background(.card)
    .alignSelf(.center)
    .onTap(onTap)
  }

  /// Centered current-phase header for the troubleshoot lens — a small icon
  /// preceding the phase name, with an optional secondary subtitle.
  ///
  /// Critical sizing rule (learned the hard way on real glasses):
  /// `MWDATDisplay.Icon` has NO size parameter — it scales to the SIZE OF THE
  /// TEXT IT SITS NEXT TO. Next to `.heading`, or with no sibling text at all
  /// (a lone or column-stacked icon), the icon balloons and overlaps the title.
  /// Next to
  /// `.body`/`.meta` it renders small — which is why the mute/exit (`.meta`)
  /// and action (`.body`) pill icons have always looked fine. So the title
  /// here is `.body`, NOT `.heading`, to keep the leading icon small.
  static func phaseHeader(icon: IconName, title: String, subtitle: String? = nil) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 4,
      alignment: .center,
      crossAlignment: .center
    ) {
      // Title row: small icon immediately left of the title. `.body` (not
      // `.heading`) keeps the icon small — see the sizing rule above.
      FlexBox(
        direction: MWDATDisplay.Direction.row,
        spacing: 6,
        alignment: .center,
        crossAlignment: .center
      ) {
        Icon(name: icon, style: .outline)
        Text(title, style: .body, color: .primary)
      }
      if let subtitle {
        Text(subtitle, style: .meta, color: .secondary)
      }
    }
    .padding(10)
    .background(.card)
    .alignSelf(.center)
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
