//
// LensIconMap.swift
//
// Maps the SF Symbol identifiers used across our SwiftUI emulator to
// `MWDATDisplay.IconName` cases from DAT 0.7's fixed 127-icon set.
//
// All lens-renderer code MUST go through `LensIconMap.icon(for:)` rather
// than referencing `IconName` cases directly — that way SF Symbol names
// stay the single source of truth and the map captures every mismatch
// in one place. Several SF Symbols have no native equivalent on the
// glasses; those are documented inline as "gap — ...".
//
// The 127-icon set is enumerated at:
//   https://wearables.developer.meta.com/docs/reference/ios_swift/dat/0.7/mwdatdisplay_iconname
//

import MWDATDisplay

enum LensIconMap {
  /// SF Symbol → IconName lookup. Whenever you add a new icon usage in a
  /// renderer, register it here (or accept the `.iCircle` fallback).
  static let symbolToIcon: [String: IconName] = [
    // Direct matches
    "checkmark":                     .checkmark,
    "xmark":                         .x,
    "xmark.circle":                  .x,
    "xmark.circle.fill":             .x,
    "arrow.left":                    .arrowLeft,
    "arrow.right":                   .arrowRight,
    "arrow.clockwise":               .twoArrowsClockwise,
    "arrow.uturn.backward":         .arrowULeft,
    "play.fill":                     .triangleRight,
    "exclamationmark.triangle.fill": .exclamationTriangle,
    "exclamationmark.triangle":      .exclamationTriangle,
    "eye.fill":                      .eye,
    "eye":                           .eye,
    "gear":                          .gear,
    "gearshape":                     .gear,
    "video.fill":                    .videoCamera,
    "video":                         .videoCamera,
    "video.slash":                   .videoCameraOff,
    "info.circle":                   .iCircle,
    "info.circle.fill":              .iCircle,

    // AI / Gemini cues — sparkles isn't perfect but reads as "AI is doing
    // something" and matches Meta AI's own iconography.
    "sparkles":                      .metaAi,
    "sparkles.rectangle.stack.fill": .metaAi,

    // Mic — gap. MWDATDisplay has no microphone glyph. We use the speaker
    // icon as the closest "audio is on/off" stand-in for the mute toggle.
    "mic.fill":                      .speakerWithThreeArcs,
    "mic":                           .speakerWithThreeArcs,
    "mic.slash.fill":                .speakerOff,
    "mic.slash":                     .speakerOff,

    // Neural Band — only meaningful when we want to signal "use your hand".
    "hand.raised.fill":              .wristband,
    "hand.raised":                   .wristband,

    // Gaps: SF Symbols with no semantic equivalent in the 127-icon set.
    //   - "pause.fill"           → no pause glyph; use a text label
    //   - "square.and.arrow.up"  → no share-sheet glyph; use a text label
    // Renderers that need these should pass an explicit fallback or omit
    // the icon entirely and rely on text alone.
  ]

  /// Look up the IconName for an SF Symbol identifier, returning `fallback`
  /// (default `.iCircle`) when the symbol has no entry in the map.
  static func icon(for symbol: String, fallback: IconName = .iCircle) -> IconName {
    symbolToIcon[symbol] ?? fallback
  }
}
