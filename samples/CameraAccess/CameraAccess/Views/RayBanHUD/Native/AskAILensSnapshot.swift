//
// AskAILensSnapshot.swift
//
// Value-type snapshot for the Ask-AI voice-search lens surface. Projected from
// `AskAISessionViewModel` by `AskAILensRenderer`, dedup'd via `Equatable`, then
// rendered to a `FlexBox` tree by `AskAILensTrees`.
//
// Same discipline as the other `*LensSnapshot` types: primitives + local enums
// only — no `MWDATDisplay` or VM types leak in.
//

import Foundation

struct AskAILensSnapshot: Equatable {

  enum Screen: Equatable {
    case listening   // greeting + waiting / search in flight (no "searching" UI)
    case results     // top matches
    case expanded    // one match expanded (Start / Go back)
    case notFound    // search returned nothing
  }

  let screen: Screen
  let rows: [Row]            // top matches (results screen)
  let expandedTitle: String  // expanded screen
  let expandedReason: String

  struct Row: Equatable {
    let id: String
    let title: String
  }
}
