//
// AskAISessionModels.swift
//
// Codable mirrors of the lightweight Ask-AI mode API (/api/ask_ai/*). The
// candidate shape is identical to troubleshoot's `CandidateProcedure`, so that
// model is reused for Ask-AI search results rather than duplicated.
//

import Foundation

/// Response from `POST /api/ask_ai/session/start`. Same shape as
/// `DiagnosticSessionStartResponse` (no procedure — the learner hasn't picked
/// one yet); the learner session is created later via the handoff endpoint.
struct AskAISessionStartResponse: Codable {
  let sessionId: String
  let systemPrompt: String
  let tools: [GeminiToolDefinitionResponse]
  let geminiConfig: GeminiConfigResponse
  let ephemeralToken: EphemeralTokenResponse

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case systemPrompt = "system_prompt"
    case tools
    case geminiConfig = "gemini_config"
    case ephemeralToken = "ephemeral_token"
  }
}
