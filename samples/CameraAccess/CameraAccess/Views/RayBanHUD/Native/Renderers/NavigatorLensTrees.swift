//
// NavigatorLensTrees.swift
//
// Pure tree-builder functions for the glasses-first NAVIGATION shell:
// Home (banner + 3 mode pills) → Expert hub → Browse list → Procedure
// detail (one step per page) → "coming soon" handoff.
//
// Conventions copied verbatim from CoachingLensTrees / TroubleshootLensTrees
// (see the plan's "Design conventions to honor"):
//   - root FlexBox: column, padding 12, spacing 12, NO `.card` on the root.
//   - tappable rows = `LensComponents.actionPill` (never DSL `Button`).
//   - non-tappable header = `LensComponents.phaseChip`, `.alignSelf(.center)`
//     to stay a compact centered chip under a `.stretch` column.
//   - default focus = first tappable child in tree order.
//   - no card-in-card: a list row is a single `.card`, status as inline meta.
//

import Foundation
import MWDATDisplay

// MARK: - Callbacks

/// Intents the navigator surfaces can fire. The renderer wires these to
/// `NavigatorViewModel` methods; tree functions stay pure.
struct NavigatorLensCallbacks {
  let onExpert: @Sendable () -> Void
  let onLearner: @Sendable () -> Void
  let onTroubleshoot: @Sendable () -> Void
  let onRecord: @Sendable () -> Void
  let onBrowse: @Sendable () -> Void
  let onSelectProcedure: @Sendable (String) -> Void
  let onPrevPage: @Sendable () -> Void
  let onNextPage: @Sendable () -> Void
  let onPrevStep: @Sendable () -> Void
  let onNextStep: @Sendable () -> Void
  let onBack: @Sendable () -> Void
  /// Recording-outcome intents.
  let onReviewOnPhone: @Sendable () -> Void
  let onRetryRecording: @Sendable () -> Void
  /// Upload-or-discard gate intents (`.expertReview`).
  let onUploadRecording: @Sendable () -> Void
  let onDiscardRecording: @Sendable () -> Void
  /// Learner-mode intents.
  let onAskAI: @Sendable () -> Void
  let onOpenFilter: @Sendable () -> Void
  let onSelectCategory: @Sendable (String) -> Void
  let onStartCoaching: @Sendable () -> Void
  /// Play the full source recording full-screen on the lens (video procedures only).
  let onWatchRecording: @Sendable () -> Void
  /// Toggle the inline per-step reference image (manual procedures only).
  let onToggleReferenceImage: @Sendable () -> Void
  /// Troubleshoot-mode intent.
  let onStartTroubleshoot: @Sendable () -> Void
  /// Hidden "Retrace" mini-game intents.
  let onOpenGame: @Sendable () -> Void
  let onTapCell: @Sendable (Int) -> Void
  let onGameRestart: @Sendable () -> Void
}

// MARK: - Top-level dispatch

enum NavigatorLensTrees {

  static func tree(
    snapshot s: NavigatorLensSnapshot,
    callbacks cb: NavigatorLensCallbacks
  ) -> FlexBox {
    switch s.screen {
    case .home:
      return homeTree(snapshot: s, callbacks: cb)
    case .expertHub:
      return expertHubTree(callbacks: cb)
    case .browseList:
      return browseListTree(snapshot: s, callbacks: cb)
    case .procedureDetail:
      return detailTree(snapshot: s, callbacks: cb)
    case let .expertReview(durationLabel):
      return reviewTree(durationLabel: durationLabel, callbacks: cb)
    case .expertProcessing:
      return processingTree(callbacks: cb)
    case let .expertDone(title, stepCount):
      return doneTree(title: title, stepCount: stepCount, callbacks: cb)
    case let .expertFailed(reason):
      return failedTree(reason: reason, callbacks: cb)
    case .learnerHub:
      return learnerHubTree(snapshot: s, callbacks: cb)
    case .learnerFilter:
      return learnerFilterTree(snapshot: s, callbacks: cb)
    case .learnerProcedureDetail:
      return learnerDetailTree(snapshot: s, callbacks: cb)
    case .troubleshootIntro:
      return troubleshootIntroTree(callbacks: cb)
    case let .comingSoon(heading, reason):
      return comingSoonTree(heading: heading, reason: reason, callbacks: cb)
    case .retraceGame:
      return retraceGameTree(snapshot: s, callbacks: cb)
    }
  }

  // MARK: - Home

  private static func homeTree(
    snapshot s: NavigatorLensSnapshot,
    callbacks cb: NavigatorLensCallbacks
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 12,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      // Brand banner — image when available, else a centered wordmark.
      // `.flexGrow(1)` gives it an equal share of the screen.
      FlexBox(
        direction: MWDATDisplay.Direction.row,
        spacing: 0,
        alignment: .center,
        crossAlignment: .center
      ) {
        if let url = s.bannerURL {
          Image(uri: url, sizePreset: .fill, cornerRadius: .medium)
        } else {
          Text("RETRACE", style: .heading, color: .primary)
        }
      }
      .flexGrow(1)

      // Three tall tappable mode rows. `.flexGrow(1)` splits the leftover
      // vertical space evenly so they fill the screen; generous padding gives
      // thick, easy-to-hit targets. Static `.card` rows (not DSL Button) per
      // `feedback_lens_button_no_animation` — and a Button can't fill height.
      tallModeRow(icon: .videoCamera, label: "Expert", onTap: cb.onExpert)
      tallModeRow(icon: .eye, label: "Learner", onTap: cb.onLearner)
      tallModeRow(icon: .exclamationTriangle, label: "Troubleshoot", onTap: cb.onTroubleshoot)

      // Hidden easter-egg: a small, compact sparkle that opens the "Retrace"
      // mini-game. `.alignSelf(.center)` keeps it sized to its icon (not a
      // full-width fourth "mode") so it reads as a discoverable extra. Static
      // (no animation) per the frame-rate constraint.
      gameLauncher(onTap: cb.onOpenGame)
    }
    .padding(12)
  }

  /// Icon-only launcher for the hidden game. Last in tree order so Neural-Band
  /// focus reaches the three modes first. Deliberately a bigger card than
  /// `LensComponents.smallIconButton` (padding 24 vs 8, matching the mode rows'
  /// thickness) so it stands out at the bottom of Home as an easy-to-hit target.
  /// The glyph itself stays the default size — a lone `MWDATDisplay.Icon` has no
  /// size parameter and no sibling `.heading` Text to scale against (see
  /// `LensComponents.phaseHeader`), so we enlarge the surface, not the icon.
  /// Kept `.alignSelf(.center)` (not full-width) so it stays visually distinct
  /// from the three mode rows rather than reading as a fourth mode.
  private static func gameLauncher(onTap: @escaping @Sendable () -> Void) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.row,
      spacing: 0,
      alignment: .center,
      crossAlignment: .center
    ) {
      Icon(name: .starCircleTriangleAi, style: .outline)
    }
    .padding(24)
    .background(.card)
    .alignSelf(.center)
    .onTap(onTap)
  }

  /// A full-width, screen-filling tappable mode row: centered icon + heading in
  /// a `.card`, grown to share the column's free vertical space.
  private static func tallModeRow(
    icon: IconName,
    label: String,
    onTap: @escaping @Sendable () -> Void
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.row,
      spacing: 12,
      alignment: .center,
      crossAlignment: .center
    ) {
      Icon(name: icon, style: .outline)
      Text(label, style: .heading, color: .primary)
    }
    .padding(24)
    .background(.card)
    .flexGrow(1)
    .onTap(onTap)
  }

  // MARK: - Expert hub

  private static func expertHubTree(callbacks cb: NavigatorLensCallbacks) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 12,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      LensComponents.phaseChip("EXPERT MODE").alignSelf(.center)

      // Record is the HERO — the primary thing an expert comes here to do
      // (Browse procedures is the secondary path). Tall, big `.heading` text,
      // grown to dominate the view. First tappable → owns default focus.
      recordHero(onTap: cb.onRecord)

      LensComponents.actionPill(icon: .eye, label: "Browse procedures", onTap: cb.onBrowse)
      LensComponents.smallIconButton(icon: .arrowLeft, onTap: cb.onBack)
    }
    .padding(12)
  }

  /// The prominent Record hero on the Expert hub — the Expert-side analog of
  /// `askAIHero`. Same recipe: a tall centered `.card` with a filled camera glyph
  /// to the LEFT of big `.heading` "Record" text in a `.row`, `.flexGrow(1)` so it
  /// expands to fill the hub's free vertical space and dominates the view.
  private static func recordHero(onTap: @escaping @Sendable () -> Void) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.row,
      spacing: 10,
      alignment: .center,
      crossAlignment: .center
    ) {
      Icon(name: .videoCamera, style: .filled)
      Text("Record", style: .heading, color: .primary)
    }
    .padding(28)
    .background(.card)
    .flexGrow(1)
    .onTap(onTap)
  }

  // MARK: - Browse list

  private static func browseListTree(
    snapshot s: NavigatorLensSnapshot,
    callbacks cb: NavigatorLensCallbacks
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 12,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      LensComponents.phaseChip("EXPERT MODE").alignSelf(.center)

      if s.isLoadingList {
        LensComponents.cardPanel(padding: 14) {
          Text("Loading procedures…", style: .body, color: .secondary)
        }
      } else if let error = s.listError {
        LensComponents.cardPanel(padding: 14) {
          Text(error, style: .body, color: .primary)
        }
      } else if s.listRows.isEmpty {
        LensComponents.cardPanel(padding: 14) {
          Text("No procedures yet", style: .body, color: .secondary)
        }
      } else {
        // Procedure list + a full-height escape rail on the right (mirrors the
        // Learner hub). Swiping RIGHT from any row reaches the rail so the user
        // can exit without traversing the whole list to the bottom Back button.
        FlexBox(
          direction: MWDATDisplay.Direction.row,
          spacing: 8,
          alignment: .start,
          crossAlignment: .stretch
        ) {
          FlexBox(
            direction: MWDATDisplay.Direction.column,
            spacing: 12,
            alignment: .start,
            crossAlignment: .stretch
          ) {
            for row in s.listRows {
              procedureRow(row, onTap: { cb.onSelectProcedure(row.id) })
            }
          }
          .flexGrow(1)

          rightEscapeRail(onTap: cb.onBack)
        }
      }

      LensComponents.smallIconButton(icon: .arrowLeft, onTap: cb.onBack)
    }
    .padding(12)
  }

  /// One browse-list row: a single `.card` (no nesting) with the title in
  /// `.body` and an optional status as inline `.meta` — NOT a nested chip.
  private static func procedureRow(
    _ row: NavigatorLensSnapshot.Row,
    onTap: @escaping @Sendable () -> Void
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 4,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      Text(row.title, style: .body, color: .primary)
      if let status = row.statusLabel {
        Text(status.uppercased(), style: .meta, color: .secondary)
      }
    }
    .padding(12)
    .background(.card)
    .onTap(onTap)
  }

  // MARK: - Procedure detail (one step per page)

  private static func detailTree(
    snapshot s: NavigatorLensSnapshot,
    callbacks cb: NavigatorLensCallbacks
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 12,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      LensComponents.phaseChip("EXPERT MODE").alignSelf(.center)

      if s.isLoadingDetail {
        LensComponents.cardPanel(padding: 14) {
          Text("Loading…", style: .body, color: .secondary)
        }
      } else {
        LensComponents.cardPanel(spacing: 8, padding: 14) {
          Text(s.detailTitle, style: .meta, color: .secondary)
          Text("STEP \(s.stepNumber) OF \(s.stepCount)", style: .meta, color: .secondary)
          if let img = s.referenceImageURL, s.isReferenceImageOpen {
            Image(uri: img, sizePreset: .fill, cornerRadius: .medium)
          }
          Text(s.stepTitle, style: .heading, color: .primary)
          Text(s.stepBody, style: .body, color: .primary)
        }
        if s.stepPageCount > 1 {
          pagerRow(
            label: "\(s.stepNumber) / \(s.stepCount)",
            onPrev: cb.onPrevStep,
            onNext: cb.onNextStep
          )
        }
        if s.hasRecording {
          LensComponents.actionPill(icon: .videoCamera, label: "Watch full recording", onTap: cb.onWatchRecording)
        }
        if s.referenceImageURL != nil {
          LensComponents.actionPill(
            icon: s.isReferenceImageOpen ? .x : .eye,
            label: s.isReferenceImageOpen ? "Hide image" : "View reference image",
            onTap: cb.onToggleReferenceImage
          )
        }
      }

      LensComponents.smallIconButton(icon: .arrowLeft, onTap: cb.onBack)
    }
    .padding(12)
  }

  // MARK: - Learner hub (Ask AI + filter pill + procedure list)

  private static func learnerHubTree(
    snapshot s: NavigatorLensSnapshot,
    callbacks cb: NavigatorLensCallbacks
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 12,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      LensComponents.phaseChip("LEARNER MODE").alignSelf(.center)

      // Ask AI is the HERO — the primary way learners find a procedure (the
      // list below is secondary). Tall, big `.heading` text, grown to dominate
      // the view. First tappable → owns default focus.
      askAIHero(onTap: cb.onAskAI)

      // One readable filter pill → dedicated FILTERS screen (the 8-chip strip
      // overflowed the 600px viewport unreadably).
      LensComponents.actionPill(
        icon: .slidersHorizontal,
        label: s.selectedCategory == "All" ? "Filter" : "Filter: \(s.selectedCategory)",
        onTap: cb.onOpenFilter
      )

      if s.isLoadingList {
        LensComponents.cardPanel(padding: 14) {
          Text("Loading procedures…", style: .body, color: .secondary)
        }
      } else if let error = s.listError {
        LensComponents.cardPanel(padding: 14) {
          Text(error, style: .body, color: .primary)
        }
      } else if s.listRows.isEmpty {
        LensComponents.cardPanel(padding: 14) {
          Text(
            s.selectedCategory == "All" ? "No procedures yet" : "Nothing in this category",
            style: .body,
            color: .secondary
          )
        }
      } else {
        // Procedure list + a full-height escape rail on the right. Swiping RIGHT
        // from any row reaches the rail; the Back pill below it makes a swipe
        // DOWN from the rail land on Back — a quick escape without traversing
        // the whole list.
        FlexBox(
          direction: MWDATDisplay.Direction.row,
          spacing: 8,
          alignment: .start,
          crossAlignment: .stretch
        ) {
          FlexBox(
            direction: MWDATDisplay.Direction.column,
            spacing: 12,
            alignment: .start,
            crossAlignment: .stretch
          ) {
            for row in s.listRows {
              procedureRow(row, onTap: { cb.onSelectProcedure(row.id) })
            }
          }
          .flexGrow(1)

          rightEscapeRail(onTap: cb.onBack)
        }
      }

      LensComponents.smallIconButton(icon: .arrowLeft, onTap: cb.onBack)
    }
    .padding(12)
  }

  /// The prominent Ask-AI hero on the Learner hub. A tall centered `.card` with a
  /// filled AI glyph to the LEFT of big `.heading` "Ask AI" text — a `.row` so the
  /// icon+label read as one centered group (main-axis `alignment: .center` centers
  /// the pair horizontally; `crossAlignment: .center` aligns the icon vertically
  /// with the text). `.flexGrow(1)` lets it expand to fill the hub's free vertical
  /// space so it dominates the view (the procedure list is the secondary path).
  /// `.heading` is the largest text style the DSL offers.
  private static func askAIHero(onTap: @escaping @Sendable () -> Void) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.row,
      spacing: 10,
      alignment: .center,
      crossAlignment: .center
    ) {
      Icon(name: .starCircleTriangleAi, style: .filled)
      Text("Ask AI", style: .heading, color: .primary)
    }
    .padding(28)
    .background(.card)
    .flexGrow(1)
    .onTap(onTap)
  }

  /// A single full-height `.card` pill down the right of the procedure list —
  /// ONE focus target (just an `.arrowLeft` glyph, no text), vertically stretched
  /// via `.alignSelf(.stretch)` so it sits beside EVERY row. Swipe RIGHT from any
  /// row to land on it, then select to exit (it fires `onBack`).
  private static func rightEscapeRail(
    onTap: @escaping @Sendable () -> Void
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 0,
      alignment: .center,
      crossAlignment: .center
    ) {
      Icon(name: .arrowLeft, style: .filled)
    }
    .padding(EdgeInsets(top: 14, bottom: 14, leading: 12, trailing: 12))
    .background(.card)
    .alignSelf(.stretch)
    .onTap(onTap)
  }

  // MARK: - Learner filter screen (3-column tile grid)

  /// Number of columns in the filter tile grid.
  private static let filterGridColumns = 3

  private static func learnerFilterTree(
    snapshot s: NavigatorLensSnapshot,
    callbacks cb: NavigatorLensCallbacks
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 12,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      LensComponents.phaseChip("FILTERS").alignSelf(.center)

      // Grid of square category tiles; the active one shows a checkmark.
      // Re-tapping the active category clears the filter (handled in the VM).
      filterGrid(
        categories: s.categories,
        selected: s.selectedCategory,
        onSelect: cb.onSelectCategory
      )

      LensComponents.smallIconButton(icon: .arrowLeft, onTap: cb.onBack)
    }
    .padding(12)
  }

  /// A column of equal-width tile rows (`filterGridColumns` per row). Rows are
  /// chunked in plain Swift and the last row is padded with invisible spacers so
  /// every tile stays the same width. No grid primitive exists in the DSL — this
  /// is FlexBox rows of `.flexGrow(1)` cells.
  private static func filterGrid(
    categories: [String],
    selected: String,
    onSelect: @escaping @Sendable (String) -> Void
  ) -> FlexBox {
    let cols = filterGridColumns
    var rows: [[String?]] = []
    var i = 0
    while i < categories.count {
      var row: [String?] = Array(categories[i..<min(i + cols, categories.count)])
      while row.count < cols { row.append(nil) }   // pad to keep columns aligned
      rows.append(row)
      i += cols
    }
    return FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 8,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      for row in rows {
        FlexBox(
          direction: MWDATDisplay.Direction.row,
          spacing: 8,
          alignment: .start,
          crossAlignment: .stretch
        ) {
          for cell in row {
            filterCell(label: cell, selected: selected, onSelect: onSelect)
          }
        }
      }
    }
  }

  /// One grid cell. `nil` label → an invisible `.flexGrow(1)` spacer that holds a
  /// column slot in the last row. Otherwise a square-ish `.card` tile with
  /// centered text (+ a checkmark when selected). `.meta` text keeps the longer
  /// labels ("Calibration", "Maintenance") readable in a narrow third-width cell.
  private static func filterCell(
    label: String?,
    selected: String,
    onSelect: @escaping @Sendable (String) -> Void
  ) -> FlexBox {
    guard let label else {
      return FlexBox(
        direction: MWDATDisplay.Direction.column,
        spacing: 0,
        alignment: .center,
        crossAlignment: .center
      ) {}
      .flexGrow(1)
    }
    let isSelected = (label == selected)
    return FlexBox(
      direction: MWDATDisplay.Direction.row,
      spacing: 6,
      alignment: .center,
      crossAlignment: .center
    ) {
      // Checkmark sits in the row NEXT TO the `.meta` label so it scales small
      // (a lone/column-stacked icon would balloon — see `iconHeadingRow` rule).
      if isSelected {
        Icon(name: .checkmark, style: .filled)
      }
      Text(label, style: .meta, color: isSelected ? .primary : .secondary)
    }
    .padding(EdgeInsets(top: 18, bottom: 18, leading: 8, trailing: 8))
    .background(.card)
    .flexGrow(1)
    .onTap { onSelect(label) }
  }

  // MARK: - Learner procedure detail (one step per page + Start coaching)

  private static func learnerDetailTree(
    snapshot s: NavigatorLensSnapshot,
    callbacks cb: NavigatorLensCallbacks
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 12,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      LensComponents.phaseChip("LEARNER MODE").alignSelf(.center)

      if s.isLoadingDetail {
        LensComponents.cardPanel(padding: 14) {
          Text("Loading…", style: .body, color: .secondary)
        }
      } else {
        LensComponents.cardPanel(spacing: 8, padding: 14) {
          Text(s.detailTitle, style: .meta, color: .secondary)
          Text("STEP \(s.stepNumber) OF \(s.stepCount)", style: .meta, color: .secondary)
          if let img = s.referenceImageURL, s.isReferenceImageOpen {
            Image(uri: img, sizePreset: .fill, cornerRadius: .medium)
          }
          Text(s.stepTitle, style: .heading, color: .primary)
          Text(s.stepBody, style: .body, color: .primary)
        }
        if s.stepPageCount > 1 {
          pagerRow(
            label: "\(s.stepNumber) / \(s.stepCount)",
            onPrev: cb.onPrevStep,
            onNext: cb.onNextStep
          )
        }
        if s.hasRecording {
          LensComponents.actionPill(icon: .videoCamera, label: "Watch full recording", onTap: cb.onWatchRecording)
        }
        if s.referenceImageURL != nil {
          LensComponents.actionPill(
            icon: s.isReferenceImageOpen ? .x : .eye,
            label: s.isReferenceImageOpen ? "Hide image" : "View reference image",
            onTap: cb.onToggleReferenceImage
          )
        }
        LensComponents.actionPill(icon: .triangleRightCircle, label: "Start coaching", onTap: cb.onStartCoaching)
      }

      LensComponents.smallIconButton(icon: .arrowLeft, onTap: cb.onBack)
    }
    .padding(12)
  }

  // MARK: - Troubleshoot intro (Identify → Diagnose → Find a fix)

  private static func troubleshootIntroTree(callbacks cb: NavigatorLensCallbacks) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 12,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      LensComponents.phaseChip("TROUBLESHOOT").alignSelf(.center)

      FlexBox(
        direction: MWDATDisplay.Direction.row,
        spacing: 0,
        alignment: .center,
        crossAlignment: .center
      ) {
        Text("Fix a problem", style: .heading, color: .primary)
      }

      // What troubleshoot does — three steps, each in its own `.card` box, laid
      // out horizontally so the icon + title + caption read as a compact unit.
      FlexBox(
        direction: MWDATDisplay.Direction.row,
        spacing: 8,
        alignment: .start,
        crossAlignment: .stretch
      ) {
        troubleshootStepBox(title: "Identify", caption: "Spot the device")
        troubleshootStepBox(title: "Diagnose", caption: "Ask and rule out")
        troubleshootStepBox(title: "Find a fix", caption: "Library or web manuals")
      }

      LensComponents.actionPill(icon: .triangleRightCircle, label: "Start Troubleshoot", onTap: cb.onStartTroubleshoot)
      LensComponents.smallIconButton(icon: .arrowLeft, onTap: cb.onBack)
    }
    .padding(12)
  }

  /// One intro step: a `.card` box with a `.body` title over a `.meta` caption.
  /// `.flexGrow(1)` makes the three boxes share the row width equally; the parent
  /// row's `.stretch` cross-alignment gives them a common height. No inline icon:
  /// each box is only a third of the viewport wide, and an icon + title in a row
  /// overflowed that width (wrapping "Diagnose" to two lines). Dropping the icon
  /// gives the title the full box width so every step title fits on one line.
  private static func troubleshootStepBox(
    title: String,
    caption: String
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 6,
      alignment: .center,
      crossAlignment: .center
    ) {
      Text(title, style: .body, color: .primary)
      Text(caption, style: .meta, color: .secondary)
    }
    .padding(12)
    .background(.card)
    .flexGrow(1)
  }

  // MARK: - Recording outcome

  /// The upload-or-discard gate shown right after the stop countdown, before any
  /// upload fires. Mirrors the phone's `ExpertRecordingReviewView` idle phase:
  /// Upload (primary, forward-path `.arrowRight`, FIRST tappable → default focus)
  /// then Discard (single tap — deletes the temp clip). No Back button: Discard
  /// is the only exit, matching the phone where it's the sole pre-upload escape.
  private static func reviewTree(
    durationLabel: String,
    callbacks cb: NavigatorLensCallbacks
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 12,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      LensComponents.phaseChip("EXPERT MODE").alignSelf(.center)
      LensComponents.cardPanel(spacing: 8, alignment: .center, crossAlignment: .center, padding: 14) {
        LensComponents.iconHeadingRow(.videoCamera, "Recording complete", style: .filled)
        Text("\(durationLabel) captured", style: .body, color: .secondary)
      }
      LensComponents.actionPill(icon: .arrowRight, label: "Upload", onTap: cb.onUploadRecording)
      LensComponents.actionPill(icon: .x, label: "Discard", onTap: cb.onDiscardRecording)
    }
    .padding(12)
  }

  private static func processingTree(callbacks cb: NavigatorLensCallbacks) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 12,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      LensComponents.phaseChip("EXPERT MODE").alignSelf(.center)
      LensComponents.cardPanel(spacing: 8, alignment: .center, crossAlignment: .center, padding: 14) {
        Text("Processing your procedure…", style: .heading, color: .primary)
        Text("This takes a minute. Leaving won't cancel it.", style: .body, color: .secondary)
      }
      // Not a bare "back" arrow: on this screen `onBack` only dismisses the
      // lens — the upload + server processing keep running (see
      // GlassesNavigationCoordinator.confirmUploadPendingRecording). Label it
      // explicitly so the user doesn't read the arrow as "cancel". Mirrors the
      // phone's "Keep working in the background" affordance in
      // ExpertRecordingReviewView.
      LensComponents.actionPill(icon: .arrowLeft, label: "Keep in background", onTap: cb.onBack)
    }
    .padding(12)
  }

  private static func doneTree(
    title: String,
    stepCount: Int,
    callbacks cb: NavigatorLensCallbacks
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 12,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      LensComponents.phaseChip("EXPERT MODE").alignSelf(.center)
      LensComponents.cardPanel(spacing: 8, alignment: .center, crossAlignment: .center, padding: 14) {
        // Short, FIXED heading keeps the checkmark hero-sized — `title` is a
        // procedure name that can be long and would shrink the paired glyph to
        // tiny. Title + step count drop to `.body` lines below.
        LensComponents.iconHeadingRow(.checkmark, "Recording saved", style: .filled)
        Text(title, style: .body, color: .primary)
        Text("\(stepCount) step\(stepCount == 1 ? "" : "s") captured", style: .body, color: .secondary)
      }
      LensComponents.actionPill(icon: .arrowRight, label: "Review on phone", onTap: cb.onReviewOnPhone)
      LensComponents.smallIconButton(icon: .arrowLeft, onTap: cb.onBack)
    }
    .padding(12)
  }

  private static func failedTree(
    reason: String,
    callbacks cb: NavigatorLensCallbacks
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 12,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      LensComponents.phaseChip("EXPERT MODE").alignSelf(.center)
      LensComponents.cardPanel(spacing: 8, alignment: .center, crossAlignment: .center, padding: 14) {
        // Short heading so the warning glyph stays hero-sized; the detail is the
        // `reason` body line below.
        LensComponents.iconHeadingRow(.exclamationTriangle, "Couldn't save", style: .filled)
        Text(reason, style: .body, color: .secondary)
      }
      LensComponents.actionPill(icon: .twoArrowsClockwise, label: "Record again", onTap: cb.onRetryRecording)
      LensComponents.smallIconButton(icon: .arrowLeft, onTap: cb.onBack)
    }
    .padding(12)
  }

  // MARK: - Coming soon / handoff

  private static func comingSoonTree(
    heading: String,
    reason: String,
    callbacks cb: NavigatorLensCallbacks
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 12,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      LensComponents.handoffCard(heading: heading, reason: reason)
      LensComponents.smallIconButton(icon: .arrowLeft, onTap: cb.onBack)
    }
    .padding(12)
  }

  // MARK: - Shared pager

  /// `[◀]  label  [▶]` row. Arrows are tappable FlexBoxes (not DSL `Button`),
  /// matching the ExpertLensTrees carousel. Placed AFTER content in tree order
  /// so focus flows content → pager → Back.
  private static func pagerRow(
    label: String,
    onPrev: @escaping @Sendable () -> Void,
    onNext: @escaping @Sendable () -> Void
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.row,
      spacing: 8,
      alignment: .center,
      crossAlignment: .center
    ) {
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
      .onTap(onPrev)

      FlexBox(
        direction: MWDATDisplay.Direction.row,
        spacing: 0,
        alignment: .center,
        crossAlignment: .center
      ) {
        Text(label, style: .meta, color: .secondary)
      }
      .flexGrow(1)

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
      .onTap(onNext)
    }
  }

  // MARK: - Retrace mini-game

  /// The hidden "Retrace" Simon-says game: a RETRACE chip, a status line, the
  /// 3×3 tappable grid, and a footer (Play again on game-over + Back).
  private static func retraceGameTree(
    snapshot s: NavigatorLensSnapshot,
    callbacks cb: NavigatorLensCallbacks
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 12,
      alignment: .start,
      crossAlignment: .stretch
    ) {
      LensComponents.phaseChip("RETRACE").alignSelf(.center)

      FlexBox(
        direction: MWDATDisplay.Direction.row,
        spacing: 0,
        alignment: .center,
        crossAlignment: .center
      ) {
        Text(gameStatusText(s), style: .meta, color: .secondary)
      }

      // `.flexGrow(1)` makes the grid eat the leftover height, pinning the
      // footer to the bottom with the column's 12pt gap above it.
      gameGrid(cells: s.gameCells, onTap: cb.onTapCell)

      if s.gamePhase == .gameOver {
        LensComponents.actionPill(icon: .twoArrowsClockwise, label: "Play again", onTap: cb.onGameRestart)
      }
      // Small, centered, bottom-anchored Back — deliberately compact so it
      // doesn't compete with the grid for space.
      LensComponents.smallIconButton(icon: .arrowLeft, onTap: cb.onBack)
    }
    .padding(12)
  }

  /// One status line under the chip — phase-specific, always trailing BEST.
  private static func gameStatusText(_ s: NavigatorLensSnapshot) -> String {
    switch s.gamePhase {
    case .watch:    return "Watch the path · round \(s.gameRound) · best \(s.gameBest)"
    case .input:    return "Your turn · round \(s.gameRound) · best \(s.gameBest)"
    case .gameOver: return "Game over · score \(s.gameScore) · best \(s.gameBest)"
    }
  }

  /// 3×3 grid: a column of three rows, each a row of three `.flexGrow(1)` cells.
  /// `.flexGrow(1)` on the grid + rows makes it fill the leftover height/width.
  private static func gameGrid(
    cells: [NavigatorLensSnapshot.CellState],
    onTap: @escaping @Sendable (Int) -> Void
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.column,
      spacing: 8,
      alignment: .center,
      crossAlignment: .stretch
    ) {
      gameRow(cells: cells, base: 0, onTap: onTap)
      gameRow(cells: cells, base: 3, onTap: onTap)
      gameRow(cells: cells, base: 6, onTap: onTap)
    }
    .flexGrow(1)
  }

  private static func gameRow(
    cells: [NavigatorLensSnapshot.CellState],
    base: Int,
    onTap: @escaping @Sendable (Int) -> Void
  ) -> FlexBox {
    FlexBox(
      direction: MWDATDisplay.Direction.row,
      spacing: 8,
      alignment: .center,
      crossAlignment: .stretch
    ) {
      gameCell(cells: cells, index: base, onTap: onTap)
      gameCell(cells: cells, index: base + 1, onTap: onTap)
      gameCell(cells: cells, index: base + 2, onTap: onTap)
    }
    .flexGrow(1)
  }

  /// One grid cell — a CONSTANT-SIZE `.card` tile. Every cell is the same padded
  /// card (so the 3×3 never reflows as the highlight moves, and the grid is
  /// always visible for the player to aim at during the input phase). The
  /// highlight is the INNER GLYPH: each state renders a `.heading`-size `Text`
  /// mark, and since they all share the heading line-height the tile size is
  /// identical in every state — only the glyph ink changes (a faint dot when
  /// idle, a bold filled circle when lit). `Icon` is avoided here because the
  /// DSL gives it no size control, so it can't read as a strong highlight.
  private static func gameCell(
    cells: [NavigatorLensSnapshot.CellState],
    index: Int,
    onTap: @escaping @Sendable (Int) -> Void
  ) -> FlexBox {
    let state = cells.indices.contains(index) ? cells[index] : .idle
    return FlexBox(
      direction: MWDATDisplay.Direction.row,
      spacing: 0,
      alignment: .center,
      crossAlignment: .center
    ) {
      cellGlyph(state)
    }
    .padding(10)
    .background(.card)
    .flexGrow(1)
    .onTap { onTap(index) }
  }

  /// The cell's mark. All three are `.heading`-size `Text` so every tile keeps
  /// the same height regardless of state; the contrast is glyph shape + colour:
  ///   idle  → a small dim middle-dot (a visible-but-recessive tap target)
  ///   lit   → a bold bright filled circle (the flash you have to retrace)
  ///   wrong → a bright X on the tile that ended the run
  private static func cellGlyph(
    _ state: NavigatorLensSnapshot.CellState
  ) -> Text {
    switch state {
    case .idle:  return Text("·", style: .heading, color: .secondary)
    case .lit:   return Text("●", style: .heading, color: .primary)
    case .wrong: return Text("X", style: .heading, color: .primary)
    }
  }
}
