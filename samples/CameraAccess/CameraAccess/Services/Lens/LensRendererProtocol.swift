//
// LensRendererProtocol.swift
//
// Contract for a per-flow lens renderer. Each flow (coaching, troubleshoot,
// expert) implements this to project its view-model state into a FlexBox
// tree the SDK can render on the glasses.
//
// Renderers are owned by `LensSession`, instantiated on `activate(_:vm:)`,
// torn down on `deactivate()`. They subscribe to their flow's @Published
// properties via Combine, debounce repaint cadence, and emit trees through
// the session's `send(_:)` (which respects the lens toggle + coordinator
// state).
//
// In Step 3 this protocol exists as a forward declaration only — no
// renderers conform yet. They land in Steps 6, 8, 9.
//

import Foundation
import MWDATDisplay

@MainActor
protocol LensRenderer: AnyObject {
  /// Stop subscriptions, release the snapshot publisher, and any
  /// per-renderer state. Idempotent — called from `LensSession.deactivate()`
  /// and again from `activate()` of a new renderer.
  func cancel()

  /// Force a re-send of the CURRENT lens tree, even if the projected snapshot is
  /// unchanged. Used to recover the on-glasses HUD after the system "back" gesture
  /// (middle-finger pinch) dismissed it — the session keeps running, only the lens
  /// content was cleared. Renderers with a dedupe cache must clear it first.
  func repaint()
}
