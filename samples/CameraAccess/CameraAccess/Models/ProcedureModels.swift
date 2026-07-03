import Foundation

struct UploadResponse: Codable {
  let id: String
  let status: String
}

/// One online source cited in a procedure built from the troubleshoot
/// web-search flow. The server returns these on `ProcedureResponse.sources`;
/// iOS renders them as a tappable footer that opens `url` in
/// `SafariBrowserView`.
struct OnlineSource: Codable, Identifiable, Hashable {
  let title: String
  let url: String
  let snippet: String

  /// `Identifiable` requires `id` for `ForEach` and `.sheet(item:)` use.
  /// URL is unique-per-source within a procedure (the backend dedupes).
  var id: String { url }
}

/// One entry in the procedure's visual parts glossary. Extracted by Gemini
/// from the expert video (and editable via `PUT /api/procedures/{id}`); the
/// server embeds these into the Gemini Live coaching prompt so the coach can
/// visually disambiguate parts ("is this the right piece?").
struct ProcedurePart: Codable, Hashable {
  var name: String
  var appearance: String
}

struct ProcedureResponse: Codable, Identifiable, Equatable {
  let id: String
  let title: String
  let description: String
  let steps: [ProcedureStepResponse]
  let totalDuration: Double
  let createdAt: String
  let status: String?
  let errorMessage: String?
  // Filename of the original upload (e.g. "{uuid}.mov"). Optional for
  // compatibility with older servers that don't return this field.
  let sourceVideo: String?
  // SF Symbol name + emoji fallback chosen by Gemini at extraction time.
  // Either may be empty / nil on legacy procedures.
  let iconSymbol: String?
  let iconEmoji: String?
  // Closed-enum category Gemini assigned at extraction time. Optional for
  // backward compatibility with servers that predate the field.
  let category: String?
  // Online sources cited by the troubleshoot web-search flow. Empty for
  // video- and manual-derived procedures. Optional for backward
  // compatibility with servers that predate the field.
  let sources: [OnlineSource]?
  // How this procedure was created: "video" (recorded) | "manual" (PDF
  // ingested) | "web" (troubleshoot web-search synthesis). Drives whether
  // the detail view shows the video player, per-step timestamps, the
  // total-duration metric, and the inline manual-page image. Optional
  // for backward compatibility — treat nil as "video" since legacy rows
  // predate the column.
  let sourceType: String?
  // Optional expert-attached reference photo (e.g. a circuit diagram).
  // Server path like "/api/reference_images/{id}.{ext}"; nil when no
  // image was uploaded. Optional for backward compatibility with
  // servers that predate the field.
  let referenceImageUrl: String?
  // Visual parts glossary. Empty/nil for manual/web procedures, legacy
  // rows, and servers that predate the field.
  let parts: [ProcedurePart]?

  enum CodingKeys: String, CodingKey {
    case id, title, description, steps, status, category, sources, parts
    case totalDuration = "total_duration"
    case createdAt = "created_at"
    case errorMessage = "error_message"
    case sourceVideo = "source_video"
    case iconSymbol = "icon_symbol"
    case iconEmoji = "icon_emoji"
    case sourceType = "source_type"
    case referenceImageUrl = "reference_image_url"
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    title = try c.decode(String.self, forKey: .title)
    description = try c.decode(String.self, forKey: .description)
    steps = try c.decode([ProcedureStepResponse].self, forKey: .steps)
    totalDuration = try c.decode(Double.self, forKey: .totalDuration)
    createdAt = try c.decode(String.self, forKey: .createdAt)
    status = try c.decodeIfPresent(String.self, forKey: .status)
    errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
    sourceVideo = try c.decodeIfPresent(String.self, forKey: .sourceVideo)
    iconSymbol = try c.decodeIfPresent(String.self, forKey: .iconSymbol)
    iconEmoji = try c.decodeIfPresent(String.self, forKey: .iconEmoji)
    category = try c.decodeIfPresent(String.self, forKey: .category)
    sources = try c.decodeIfPresent([OnlineSource].self, forKey: .sources)
    sourceType = try c.decodeIfPresent(String.self, forKey: .sourceType)
    referenceImageUrl = try c.decodeIfPresent(String.self, forKey: .referenceImageUrl)
    parts = try c.decodeIfPresent([ProcedurePart].self, forKey: .parts)
  }
}

struct ProcedureStepResponse: Codable, Identifiable, Equatable {
  var id: Int { stepNumber }
  let stepNumber: Int
  let title: String
  let description: String
  let timestampStart: Double
  let timestampEnd: Double
  let tips: [String]
  let warnings: [String]
  // Condensed 1-2 sentence version of `description` for the lens card
  // (≤160 chars, generated at extraction). Optional for backward
  // compatibility with servers that predate the column; empty/nil falls
  // back to `description` via `lensText`.
  let displaySummary: String?
  let errorCriteria: [String]
  let clipUrl: String?
  // How reliably this step's end-state can be verified from the camera by
  // the server-side visual oracle: "reliable" | "marginal" | "none"
  // ("none" = verbal-only, no visual auto-advance). Optional for backward
  // compatibility with servers that predate the column — defaults to
  // "reliable".
  let visualVerifiability: String

  enum CodingKeys: String, CodingKey {
    case title, description, tips, warnings
    case stepNumber = "step_number"
    case displaySummary = "display_summary"
    case timestampStart = "timestamp_start"
    case timestampEnd = "timestamp_end"
    case errorCriteria = "error_criteria"
    case clipUrl = "clip_url"
    case visualVerifiability = "visual_verifiability"
  }

  init(
    stepNumber: Int,
    title: String,
    description: String,
    timestampStart: Double,
    timestampEnd: Double,
    tips: [String] = [],
    warnings: [String] = [],
    displaySummary: String? = nil,
    errorCriteria: [String] = [],
    clipUrl: String? = nil,
    visualVerifiability: String = "reliable"
  ) {
    self.stepNumber = stepNumber
    self.title = title
    self.description = description
    self.timestampStart = timestampStart
    self.timestampEnd = timestampEnd
    self.tips = tips
    self.warnings = warnings
    self.displaySummary = displaySummary
    self.errorCriteria = errorCriteria
    self.clipUrl = clipUrl
    self.visualVerifiability = visualVerifiability
  }

  // Custom decoder so old servers that predate the error_criteria column
  // don't break the client — missing / null field decodes to []. New
  // servers always emit a list (possibly empty).
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    stepNumber = try c.decode(Int.self, forKey: .stepNumber)
    title = try c.decode(String.self, forKey: .title)
    description = try c.decode(String.self, forKey: .description)
    timestampStart = try c.decode(Double.self, forKey: .timestampStart)
    timestampEnd = try c.decode(Double.self, forKey: .timestampEnd)
    tips = try c.decode([String].self, forKey: .tips)
    warnings = try c.decode([String].self, forKey: .warnings)
    displaySummary = try c.decodeIfPresent(String.self, forKey: .displaySummary)
    errorCriteria = try c.decodeIfPresent([String].self, forKey: .errorCriteria) ?? []
    clipUrl = try c.decodeIfPresent(String.self, forKey: .clipUrl)
    visualVerifiability = try c.decodeIfPresent(String.self, forKey: .visualVerifiability) ?? "reliable"
  }

  /// What the lens (and its on-phone emulator) renders on the collapsed
  /// step card: the condensed summary when present, else the full
  /// description. Single fallback rule shared by every lens surface.
  var lensText: String {
    if let summary = displaySummary, !summary.isEmpty { return summary }
    return description
  }

  var hasAnyInsights: Bool {
    !tips.isEmpty || !warnings.isEmpty || !errorCriteria.isEmpty
  }

  var insightCategoryCount: Int {
    [tips, warnings, errorCriteria].filter { !$0.isEmpty }.count
  }
}

// MARK: - Reference media resolution

/// What a step's `clip_url` actually points at. The server returns the
/// authoritative path — an `.mp4` for video-sourced procedures, a page
/// `.png` for manual-sourced ones, or nothing. The client must NOT blindly
/// reconstruct a `.mp4` URL (that 404s for manual/web procedures); it should
/// resolve the real media type from `clip_url` + the procedure's
/// `source_type`. This is the single source of truth shared by both lens
/// surfaces (native glasses lens + on-phone emulator).
enum StepReferenceMedia: Equatable {
  case video(URL)   // playable clip — tap to play full-screen
  case image(URL)   // static reference image (manual page) — show, don't play
  case none         // no reference media for this step
}

extension ProcedureStepResponse {
  /// Resolve this step's reference media from its `clip_url` and the parent
  /// procedure's `source_type`. `baseURL` prefixes server-relative paths
  /// (the server emits `/api/...`; absolute `http(s)` URLs pass through).
  ///
  /// Mirrors the gating already used by `ProcedureChapterDetailContent`
  /// (`hasPlayableVideo` / `inlineManualImageURL`) and `PiPReferenceView`
  /// (`isImage`) so all surfaces agree on video-vs-image.
  func referenceMedia(sourceType: String?, baseURL: String) -> StepReferenceMedia {
    guard let path = clipUrl, !path.isEmpty else { return .none }
    let absolute = path.hasPrefix("http") ? path : baseURL + path
    guard let url = URL(string: absolute) else { return .none }
    let ext = (path as NSString).pathExtension.lowercased()
    if ext == "mp4" || (sourceType ?? "video").lowercased() == "video" {
      return .video(url)
    }
    if ["png", "jpg", "jpeg"].contains(ext) {
      return .image(url)
    }
    return .none
  }
}

// MARK: - List response (lighter model from GET /api/procedures)

struct ProcedureListItem: Codable, Identifiable {
  let id: String
  let title: String
  let description: String
  let totalDuration: Double
  let createdAt: String
  let status: String?
  let errorMessage: String?
  let stepCount: Int?
  let iconSymbol: String?
  let iconEmoji: String?
  // Closed-enum category Gemini assigned at extraction time (e.g.
  // "Maintenance", "Assembly", "Other"). Optional for backward
  // compatibility with servers that predate the field.
  let category: String?
  // "video" | "manual" | "web". Drives source-type-aware copy on the
  // processing-state card (e.g. "Analyzing video…" vs "Reading manual…").
  // Optional for backward compatibility.
  let sourceType: String?
  // Optional expert-attached reference photo path. Mirrors
  // `ProcedureResponse.referenceImageUrl`. Optional for backward
  // compatibility with servers that predate the field.
  let referenceImageUrl: String?

  enum CodingKeys: String, CodingKey {
    case id, title, description, status, category
    case totalDuration = "total_duration"
    case createdAt = "created_at"
    case errorMessage = "error_message"
    case stepCount = "step_count"
    case iconSymbol = "icon_symbol"
    case iconEmoji = "icon_emoji"
    case sourceType = "source_type"
    case referenceImageUrl = "reference_image_url"
  }
}

// MARK: - Edit requests

struct ProcedureUpdateRequest: Codable {
  var title: String?
  var description: String?
  var stepOrder: [Int]?
  // Defaulted so existing call sites that don't touch the glossary
  // keep compiling; nil = leave the server's parts unchanged.
  var parts: [ProcedurePart]? = nil

  enum CodingKeys: String, CodingKey {
    case title, description, parts
    case stepOrder = "step_order"
  }
}

struct StepUpdateRequest: Codable {
  var title: String?
  var description: String?
  var tips: [String]?
  var warnings: [String]?
  var timestampStart: Double?
  var timestampEnd: Double?
  var errorCriteria: [String]?
  var visualVerifiability: String? = nil
  var displaySummary: String? = nil

  enum CodingKeys: String, CodingKey {
    case title, description, tips, warnings
    case timestampStart = "timestamp_start"
    case timestampEnd = "timestamp_end"
    case errorCriteria = "error_criteria"
    case visualVerifiability = "visual_verifiability"
    case displaySummary = "display_summary"
  }
}

// MARK: - Verify (server-side visual oracle)

/// Response from `POST /api/learner/session/{id}/verify` — the server-side
/// visual step oracle. The phone POSTs the learner's latest camera JPEG on
/// a timer; the server runs a Flash model against the current step's spatial
/// end-state + error states and returns a verdict. Lenient (only `status`
/// is guaranteed) so partial / unknown payloads don't throw. On `advanced`/
/// `completed` the shape mirrors the `advance_step` tool-call result, so the
/// payload feeds straight into `applyLearnerToolResult`.
struct VerifyResponse: Codable {
  /// Poll: skip | pending | error | advanced | completed
  /// On-demand (check_step): adds not_confirmed | unverifiable | check_failed | already_completed
  let status: String
  let errorText: String?         // correction sentence (status == "error" / matched known error)
  let newStep: Int?              // 1-indexed step number (status == "advanced")
  let stepTitle: String?
  let stepDescription: String?
  let completionCriteria: String?
  let message: String?           // closing message (status == "completed")
  let reason: String?            // on-demand: the visible gap / why the check couldn't run
  let method: String?            // on-demand advance: "visual" | "verbal"
  let note: String?              // on-demand advance: insist-once / trust-on-failure marker

  enum CodingKeys: String, CodingKey {
    case status, message, reason, method, note
    case errorText = "error_text"
    case newStep = "new_step"
    case stepTitle = "step_title"
    case stepDescription = "step_description"
    case completionCriteria = "completion_criteria"
  }
}

// MARK: - Gemini Live session models

struct EphemeralTokenResponse: Codable {
  let token: String
  let expiresAt: String
  let websocketUrl: String

  enum CodingKeys: String, CodingKey {
    case token
    case expiresAt = "expires_at"
    case websocketUrl = "websocket_url"
  }
}

struct GeminiToolParam: Codable {
  let type: String
  let properties: [String: GeminiToolParamProperty]?
  let required: [String]?
}

struct GeminiToolParamProperty: Codable {
  let type: String
  let description: String?
}

struct GeminiToolDefinitionResponse: Codable {
  let name: String
  let description: String
  let parameters: GeminiToolParam
}

struct GeminiConfigResponse: Codable {
  let model: String
  let voice: String
}

struct LearnerSessionStartResponse: Codable {
  let sessionId: String
  let procedure: ProcedureResponse
  let systemPrompt: String
  let tools: [GeminiToolDefinitionResponse]
  let geminiConfig: GeminiConfigResponse
  let ephemeralToken: EphemeralTokenResponse

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case procedure
    case systemPrompt = "system_prompt"
    case tools
    case geminiConfig = "gemini_config"
    case ephemeralToken = "ephemeral_token"
  }
}

// MARK: - Voice options

struct VoiceOption: Codable, Identifiable {
  var id: String { name }
  let name: String
  let description: String
  let previewUrl: String
}

// MARK: - Local session tracking

enum SessionStatus: String, Codable {
  case inProgress = "in_progress"
  case completed
  case abandoned
}

struct SessionRecord: Codable, Identifiable {
  let id: String
  let procedureId: String
  let procedureTitle: String
  let startedAt: Date
  var completedAt: Date?
  var stepsCompleted: Int
  var totalSteps: Int
  var status: SessionStatus
}
