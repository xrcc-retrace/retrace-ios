//
// LensFlow.swift
//
// Identifies which user flow currently owns the on-glasses lens.
// `LensSession.activate(_:vm:)` consumes this to pick the right renderer.
//
// Flows that have no useful lens state (mode selection, server settings,
// onboarding, pre-recording warmup, manual upload sheet) map to
// `.handoffToPhone(reason:)` — the lens shows a static "use your phone"
// card while the actual interaction happens on the iPhone screen.
//

import Foundation

enum LensFlow: Equatable {
  case idle
  case coaching
  case troubleshoot
  case expert
  case handoffToPhone(reason: String)
}
