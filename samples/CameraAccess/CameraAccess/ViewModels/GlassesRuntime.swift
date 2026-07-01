//
// GlassesRuntime.swift
//
// Uniform teardown contract for the heavy runtime VMs hosted INVISIBLY behind
// the glasses-first standby (coaching / troubleshoot / Ask AI / expert
// recording). `GlassesNavigationCoordinator` holds the active one as a weak
// `GlassesRuntime?` and AWAITS `shutdown()` on every exit, so the camera +
// Gemini + DeviceSession lease are provably released BEFORE the lens tears down
// or the phone cover dismisses — no more "camera still on after Take back on
// phone".
//
// Conformances reuse each VM's existing teardown body, then await it to
// completion (see each VM's `shutdown()`).
//

import Foundation

@MainActor
protocol GlassesRuntime: AnyObject {
  /// Fully tear the runtime down and RETURN ONLY when complete: stop Gemini,
  /// stop the camera Stream, release the DeviceSession lease. Must be idempotent
  /// (the host `.onDisappear` may also fire a teardown as a backstop).
  func shutdown() async
}

// The Gemini Live base provides a default `shutdown()` in its class body
// (dynamically dispatched, so the coaching / troubleshoot / Ask AI subclass
// overrides are honored through this protocol witness).
extension GeminiLiveSessionBase: GlassesRuntime {}
