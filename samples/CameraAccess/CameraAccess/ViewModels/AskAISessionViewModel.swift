import Combine
import Foundation
import MWDATCore
import SwiftUI

/// Ask-AI mode: a lightweight, AUDIO-ONLY learner discovery session. The AI
/// greets the learner, they describe what they want to do, Gemini searches the
/// library by voice (no camera), and the lens shows the top matches. Selection
/// is a lens tap → the coordinator handles the handoff into coaching.
///
/// Inherits all Gemini Live machinery from `GeminiLiveSessionBase`; the only
/// mode-specific bits are the search state, the audio-only override, and the
/// scripted greeting.
@MainActor
class AskAISessionViewModel: GeminiLiveSessionBase {

  /// Which Ask-AI surface the lens shows. There is intentionally NO `.searching`
  /// state — the library search is fast, so the lens stays on `.listening`
  /// until results land, then jumps straight to `.results`.
  enum SearchState: Equatable {
    case listening      // greeting + waiting for the learner / search in flight
    case results        // top matches shown
    case expanded       // one match expanded (Start / Go back)
    case notFound       // search returned nothing
  }

  @Published private(set) var searchState: SearchState = .listening
  @Published private(set) var candidates: [CandidateProcedure] = []
  @Published private(set) var expandedCandidate: CandidateProcedure?

  /// Learner picked a procedure (Start on the expanded card). The host wires
  /// this to `GlassesNavigationCoordinator.askAIDidSelect(procedureId:)`.
  var onSelected: ((String) -> Void)?

  /// Lens "Go back" from a top-level Ask-AI screen → exit Ask AI. The host
  /// wires this to `GlassesNavigationCoordinator.exitAskAI()`.
  var onExitRequested: (() -> Void)?

  // MARK: - Lifecycle

  func startSession() async {
    searchState = .listening
    sessionDidEnd = false
    candidates = []
    expandedCandidate = nil
    await startGeminiLiveSession()
  }

  func endSession() {
    // Idempotent — see `sessionDidEnd`. Explicit exit + host `.onDisappear`
    // backstop both call this; run the real teardown once.
    guard !sessionDidEnd else { return }
    sessionDidEnd = true
    if let sid = sessionId {
      Task { @MainActor in
        await ProcedureAPIService().endAskAISession(sessionId: sid)
      }
    }
    stopCameraStream()
    stopGeminiLiveSession()
  }

  /// `GlassesRuntime` teardown: end the session, then AWAIT the camera teardown
  /// so the coordinator can guarantee the camera is off before exiting.
  override func shutdown() async {
    endSession()
    await awaitCameraTeardown()
  }

  // MARK: - Lens intents

  /// Tap a result row → expand it (UI-only, no network).
  func expand(procedureId: String) {
    guard let c = candidates.first(where: { $0.procedureId == procedureId }) else { return }
    expandedCandidate = c
    searchState = .expanded
  }

  /// "Go back" from the expanded card → back to the results list.
  func collapse() {
    expandedCandidate = nil
    searchState = candidates.isEmpty ? .listening : .results
  }

  /// "Start" on the expanded card → hand the chosen procedure to the coordinator.
  func startSelected() {
    guard let c = expandedCandidate else { return }
    onSelected?(c.procedureId)
  }

  /// Lens "Go back": collapse from the expanded card, otherwise exit Ask AI.
  func back() {
    if searchState == .expanded {
      collapse()
    } else {
      onExitRequested?()
    }
  }

  // MARK: - Base overrides (template hooks)

  override func mintSession() async throws -> SessionStartPayload {
    let voice = VoiceSettings.storedVoice()
    let response = try await ProcedureAPIService().startAskAISession(voice: voice)
    return SessionStartPayload(
      sessionId: response.sessionId,
      ephemeralToken: response.ephemeralToken
    )
  }

  override var toolCallURLSuffix: String {
    guard let sid = sessionId else { return "/api/ask_ai/session//tool-call" }
    return "/api/ask_ai/session/\(sid)/tool-call"
  }

  /// Greet first. The system prompt mandates the exact opener; any seed turn
  /// triggers the model to deliver it instead of waiting for the learner.
  override var introSeedText: String? { "(The learner just opened Ask AI.)" }

  /// Glasses-first: the learner talks hands-free through the glasses HFP mic.
  override var transport: CaptureTransport { .glasses }
  override var audioSessionMode: AudioSessionMode { .coaching }

  /// Audio-only — no camera Stream is started; Gemini only hears the learner.
  override var streamsCameraToGemini: Bool { false }

  override func handleToolCallExtras(name: String, args: [String: Any], result: [String: Any]) async {
    guard name == "search_procedures" else { return }
    let found = (result["candidates"] as? [[String: Any]])?
      .compactMap { CandidateProcedure(fromAskAIJSON: $0) } ?? []
    candidates = found
    expandedCandidate = nil
    searchState = found.isEmpty ? .notFound : .results
  }
}

// MARK: - JSON helper

private extension CandidateProcedure {
  init?(fromAskAIJSON dict: [String: Any]) {
    guard let id = dict["procedure_id"] as? String,
          let title = dict["title"] as? String else { return nil }
    self.procedureId = id
    self.title = title
    self.matchReason = dict["match_reason"] as? String
    self.confidence = dict["confidence"] as? String
  }
}
