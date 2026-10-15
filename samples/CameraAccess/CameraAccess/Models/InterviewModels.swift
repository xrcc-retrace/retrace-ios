//
// InterviewModels.swift
//
// Codable mirrors of the Expert Interviewer API (/api/expert/interview/*) and
// the phone-owned `InterviewLog` that rides along with the video upload.
//
// Explicit snake_case CodingKeys throughout (project convention). Do NOT swap
// in a `.convertFromSnakeCase` decoder: `EphemeralTokenResponse` declares
// literal snake_case keys, and that strategy rewrites JSON keys before
// matching, so nested token decoding would silently fail.
//

import Foundation

/// Expert-side preference for the interviewer. Stored in UserDefaults under
/// `InterviewerMode.storageKey`; picked on the pre-record screen.
///
/// - `on`: live questions during recording + a short debrief after Stop.
/// - `quiet`: the planner still listens and logs gaps, but never interrupts;
///   everything is asked in the debrief.
/// - `off`: no interviewer at all. Recording runs exactly as before
///   (`.recordingPhoneOnly` audio, no Live socket).
enum InterviewerMode: String, CaseIterable, Identifiable {
  case on, quiet, off

  static let storageKey = "expertInterviewerMode"
  static let `default`: InterviewerMode = .on

  var id: String { rawValue }

  var label: String {
    switch self {
    case .on: return "Ask me"
    case .quiet: return "Debrief only"
    case .off: return "Off"
    }
  }

  var iconName: String {
    switch self {
    case .on: return "waveform.and.mic"
    case .quiet: return "text.bubble"
    case .off: return "mic.slash"
    }
  }

  static func stored(_ defaults: UserDefaults = .standard) -> InterviewerMode {
    InterviewerMode(rawValue: defaults.string(forKey: storageKey) ?? "") ?? .default
  }
}

// MARK: - Session start

/// Policy constants mirrored from the server so the phone's pause gate and
/// the server's budget agree. `fallback` is used if a start response ever
/// omits the block (older server).
struct InterviewPolicyConfig: Codable, Equatable {
  let minSecondsBetweenLiveAsks: Double
  let maxLiveAsks: Int
  let defaultTtlSeconds: Double
  let answerWindowSeconds: Double
  let answerWindowHardCapSeconds: Double
  let silenceBeforeAskSeconds: Double

  enum CodingKeys: String, CodingKey {
    case minSecondsBetweenLiveAsks = "min_seconds_between_live_asks"
    case maxLiveAsks = "max_live_asks"
    case defaultTtlSeconds = "default_ttl_seconds"
    case answerWindowSeconds = "answer_window_seconds"
    case answerWindowHardCapSeconds = "answer_window_hard_cap_seconds"
    case silenceBeforeAskSeconds = "silence_before_ask_seconds"
  }

  static let fallback = InterviewPolicyConfig(
    minSecondsBetweenLiveAsks: 60,
    maxLiveAsks: 6,
    defaultTtlSeconds: 20,
    answerWindowSeconds: 12,
    answerWindowHardCapSeconds: 30,
    silenceBeforeAskSeconds: 1.5
  )
}

struct InterviewSessionStartResponse: Codable {
  let sessionId: String
  let systemPrompt: String
  let tools: [GeminiToolDefinitionResponse]
  let geminiConfig: GeminiConfigResponse
  let ephemeralToken: EphemeralTokenResponse
  let policy: InterviewPolicyConfig?

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case systemPrompt = "system_prompt"
    case tools
    case geminiConfig = "gemini_config"
    case ephemeralToken = "ephemeral_token"
    case policy
  }
}

struct InterviewBriefingInjectResponse: Codable {
  let injectText: String

  enum CodingKeys: String, CodingKey {
    case injectText = "inject_text"
  }
}

// MARK: - Observe / ask / answer

/// One approved live question. `injectText` is what the phone sends to Live
/// as a user turn (`[ASK] …`) once the pause gate opens.
struct InterviewAsk: Codable, Equatable, Identifiable {
  let questionId: String
  let topicKey: String
  let priority: String
  let question: String
  let ttlSeconds: Double
  let injectText: String

  var id: String { questionId }

  enum CodingKeys: String, CodingKey {
    case questionId = "question_id"
    case topicKey = "topic_key"
    case priority
    case question
    case ttlSeconds = "ttl_seconds"
    case injectText = "inject_text"
  }
}

struct InterviewObserveResponse: Codable {
  /// ok | quiet | skipped | planner_unavailable | finalized
  let status: String
  let ask: InterviewAsk?
  let openGaps: Int
  let answered: Int
  let liveAsksUsed: Int
  let quietMode: Bool
  let openAnswerWindow: Bool

  enum CodingKeys: String, CodingKey {
    case status, ask, answered
    case openGaps = "open_gaps"
    case liveAsksUsed = "live_asks_used"
    case quietMode = "quiet_mode"
    case openAnswerWindow = "open_answer_window"
  }
}

enum InterviewAnswerOutcome: String, Codable {
  case answered, unanswered, skipped, interrupted, deferred
}

struct InterviewAnswerReport: Encodable {
  let questionId: String
  let transcript: String
  let outcome: InterviewAnswerOutcome
  let tAsk: Double?
  let tClose: Double?

  enum CodingKeys: String, CodingKey {
    case questionId = "question_id"
    case transcript, outcome
    case tAsk = "t_ask"
    case tClose = "t_close"
  }
}

struct InterviewDebriefResponse: Codable {
  let questions: [InterviewAsk]
  let injectText: String

  enum CodingKeys: String, CodingKey {
    case questions
    case injectText = "inject_text"
  }
}

// MARK: - Persisted log (phone-owned)

struct InterviewQAEntry: Codable, Equatable {
  let questionId: String
  let topicKey: String
  let priority: String
  let question: String
  var answer: String?
  var outcome: String
  let phase: String
  var tAsk: Double?
  var tClose: Double?

  enum CodingKeys: String, CodingKey {
    case questionId = "question_id"
    case topicKey = "topic_key"
    case priority, question, answer, outcome, phase
    case tAsk = "t_ask"
    case tClose = "t_close"
  }
}

struct InterviewFact: Codable, Equatable {
  let kind: String
  let value: String
  let part: String?
  let t: Double?
  let source: String
  let note: String
}

struct InterviewTranscriptEntry: Codable, Equatable {
  let t: Double?
  let text: String
  let source: String?
}

/// The server's `InterviewLog`. The phone is the owner: it merges the
/// server's `/finalize` view (facts, transcript, Q/A) with what only the
/// phone knows (AI speech windows in video time, client diagnostics), writes
/// the result next to the recording as `<name>.interview.json`, and uploads
/// it with the video. Server-side the model is strict (`extra="forbid"`), so
/// every key here must exist there — never add a field on one side only.
struct InterviewLog: Codable, Equatable {
  var version: Int = 1
  var sessionId: String?
  var transport: String = "iphone"
  var briefing: String = ""
  var aiSpeechWindows: [[Double]] = []
  var qa: [InterviewQAEntry] = []
  var facts: [InterviewFact] = []
  var transcript: [InterviewTranscriptEntry] = []
  var diagnostics: JSONValue = .object([:])

  enum CodingKeys: String, CodingKey {
    case version, transport, briefing, qa, facts, transcript, diagnostics
    case sessionId = "session_id"
    case aiSpeechWindows = "ai_speech_windows"
  }
}

/// Minimal JSON value for free-form dictionaries the server declares as
/// `dict` (`InterviewLog.diagnostics`). The server's finalize view nests
/// lists and objects here, so a fixed struct would fail to decode.
indirect enum JSONValue: Codable, Equatable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null; return }
    if let b = try? c.decode(Bool.self) { self = .bool(b); return }
    if let n = try? c.decode(Double.self) { self = .number(n); return }
    if let s = try? c.decode(String.self) { self = .string(s); return }
    if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
    if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
    throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let b): try c.encode(b)
    case .number(let n): try c.encode(n)
    case .string(let s): try c.encode(s)
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o)
    }
  }

  /// Merge `other`'s keys into this object (other wins). Non-objects are
  /// replaced wholesale.
  func merging(_ other: JSONValue) -> JSONValue {
    guard case .object(var base) = self, case .object(let add) = other else { return other }
    for (k, v) in add { base[k] = v }
    return .object(base)
  }
}
