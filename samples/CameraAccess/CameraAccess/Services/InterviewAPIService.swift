import Foundation

/// REST client for the Expert Interviewer mode (`/api/expert/interview/*`).
/// Mirrors `ProcedureAPIService`'s conventions (explicit CodingKeys, plain
/// `URLSession.shared`, multipart built by hand).
@MainActor
final class InterviewAPIService {
  enum APIError: LocalizedError {
    case invalidURL
    case serverError(Int)

    var errorDescription: String? {
      switch self {
      case .invalidURL: return "Invalid server URL"
      case .serverError(let code): return "Interview server error (HTTP \(code))"
      }
    }
  }

  var serverBaseURL: String { ServerEndpoint.shared.resolvedBaseURL }

  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()

  // MARK: - Lifecycle

  func start(voice: String, transport: String, taskHint: String) async throws -> InterviewSessionStartResponse {
    var request = try jsonRequest(path: "/api/expert/interview/session/start", method: "POST")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "voice": voice,
      "transport": transport,
      "task_hint": taskHint,
    ])
    request.timeoutInterval = 20
    return try await send(request, as: InterviewSessionStartResponse.self)
  }

  func briefingInject(sessionId: String) async throws -> String {
    let request = try jsonRequest(path: "/api/expert/interview/session/\(sessionId)/briefing-inject", method: "GET")
    return try await send(request, as: InterviewBriefingInjectResponse.self).injectText
  }

  /// One planner tick. Every part is optional server-side; `videoT` is nil in
  /// pre-roll. `speaking` is the phone's own mic-activity read so the planner
  /// never proposes mid-sentence.
  func observe(
    sessionId: String,
    frameJPEG: Data?,
    audioWAV: Data?,
    sampleRate: Int,
    videoT: Double?,
    phase: String,
    speaking: Bool
  ) async throws -> InterviewObserveResponse {
    guard let url = URL(string: "\(serverBaseURL)/api/expert/interview/session/\(sessionId)/observe") else {
      throw APIError.invalidURL
    }
    let boundary = "Boundary-\(UUID().uuidString)"
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    // Planner call is capped at 10 s server-side; leave headroom for upload.
    request.timeoutInterval = 18

    var body = Data()
    func field(_ name: String, _ value: String) {
      body.append("--\(boundary)\r\n".data(using: .utf8)!)
      body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
      body.append(value.data(using: .utf8)!)
      body.append("\r\n".data(using: .utf8)!)
    }
    func file(_ name: String, filename: String, type: String, data: Data) {
      body.append("--\(boundary)\r\n".data(using: .utf8)!)
      body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
      body.append("Content-Type: \(type)\r\n\r\n".data(using: .utf8)!)
      body.append(data)
      body.append("\r\n".data(using: .utf8)!)
    }
    if let frameJPEG { file("frame", filename: "frame.jpg", type: "image/jpeg", data: frameJPEG) }
    if let audioWAV { file("audio", filename: "chunk.wav", type: "audio/wav", data: audioWAV) }
    field("sample_rate", String(sampleRate))
    if let videoT { field("video_t", String(format: "%.3f", videoT)) }
    field("phase", phase)
    field("speaking", speaking ? "true" : "false")
    body.append("--\(boundary)--\r\n".data(using: .utf8)!)
    request.httpBody = body

    return try await send(request, as: InterviewObserveResponse.self)
  }

  func answer(sessionId: String, report: InterviewAnswerReport) async throws {
    var request = try jsonRequest(path: "/api/expert/interview/session/\(sessionId)/answer", method: "POST")
    request.httpBody = try encoder.encode(report)
    _ = try await sendRaw(request)
  }

  func debrief(sessionId: String, maxQuestions: Int) async throws -> InterviewDebriefResponse {
    var request = try jsonRequest(path: "/api/expert/interview/session/\(sessionId)/debrief", method: "POST")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["max_questions": maxQuestions])
    return try await send(request, as: InterviewDebriefResponse.self)
  }

  /// Server view of the log with Flash-extracted facts. Slow-ish (one model
  /// call); the caller merges it with the phone's own copy.
  func finalize(sessionId: String) async throws -> InterviewLog {
    var request = try jsonRequest(path: "/api/expert/interview/session/\(sessionId)/finalize", method: "POST")
    request.timeoutInterval = 40
    return try await send(request, as: InterviewLog.self)
  }

  /// Best-effort; the server session is a cache, losing it costs nothing.
  func end(sessionId: String) async {
    guard let request = try? jsonRequest(path: "/api/expert/interview/session/\(sessionId)", method: "DELETE") else { return }
    _ = try? await sendRaw(request)
  }

  // MARK: - Plumbing

  private func jsonRequest(path: String, method: String) throws -> URLRequest {
    guard let url = URL(string: "\(serverBaseURL)\(path)") else { throw APIError.invalidURL }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 15
    return request
  }

  private func sendRaw(_ request: URLRequest) async throws -> Data {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw APIError.serverError((response as? HTTPURLResponse)?.statusCode ?? -1)
    }
    return data
  }

  private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
    try decoder.decode(T.self, from: try await sendRaw(request))
  }
}
