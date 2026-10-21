import Foundation

/// Sidecar persistence for the phone-owned `InterviewLog`.
///
/// The log lives NEXT TO the recording as `<recording>.interview.json` so it
/// survives the recording VM being torn down (the review cover is a sibling
/// of the recording view, and "Keep working in the background" uploads from
/// `ExpertTabView` much later). Upload reads it by deriving the path from the
/// mp4 URL; Discard deletes both.
enum InterviewLogStore {
  static let sidecarExtension = "interview.json"

  static func sidecarURL(for recordingURL: URL) -> URL {
    recordingURL.deletingPathExtension().appendingPathExtension(sidecarExtension)
  }

  static func save(_ log: InterviewLog, besides recordingURL: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(log)
    try data.write(to: sidecarURL(for: recordingURL), options: .atomic)
    print("[Interview] log saved: \(sidecarURL(for: recordingURL).lastPathComponent) (\(log.facts.count) facts, \(log.qa.count) qa, \(log.aiSpeechWindows.count) windows)")
  }

  static func load(besides recordingURL: URL) -> InterviewLog? {
    let url = sidecarURL(for: recordingURL)
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(InterviewLog.self, from: data)
  }

  static func exists(besides recordingURL: URL) -> Bool {
    FileManager.default.fileExists(atPath: sidecarURL(for: recordingURL).path)
  }

  static func delete(besides recordingURL: URL) {
    try? FileManager.default.removeItem(at: sidecarURL(for: recordingURL))
  }
}
