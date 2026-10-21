import Foundation

/// Fixed-capacity ring of Int16 mono PCM bytes, written from the audio tap
/// thread and read from the main actor. The expert interviewer keeps the
/// last few seconds of the expert's narration here and ships a WAV snapshot
/// to the server-side planner on every observe tick — the planner, not
/// Gemini Live, transcribes the narration (see docs/expert-interviewer-design.md
/// §4.3 for why Live must never hear it).
///
/// Lock-protected rather than an actor so `append` can run synchronously on
/// the tap thread with no hop.
final class PCMRingBuffer: @unchecked Sendable {
  let sampleRate: Int
  let capacityBytes: Int

  private let lock = NSLock()
  private var bytes = Data()

  init(seconds: Double, sampleRate: Int = 16_000) {
    self.sampleRate = sampleRate
    self.capacityBytes = Int(seconds * Double(sampleRate)) * 2
    bytes.reserveCapacity(capacityBytes)
  }

  func append(_ pcm16: Data) {
    guard !pcm16.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    bytes.append(pcm16)
    if bytes.count > capacityBytes {
      bytes.removeFirst(bytes.count - capacityBytes)
    }
  }

  func reset() {
    lock.lock()
    bytes.removeAll(keepingCapacity: true)
    lock.unlock()
  }

  /// Seconds of audio currently held.
  var seconds: Double {
    lock.lock()
    defer { lock.unlock() }
    return Double(bytes.count / 2) / Double(sampleRate)
  }

  /// The most recent `lastSeconds` of audio as a WAV file, or nil when the
  /// ring holds less than `minSeconds`.
  func snapshotWAV(lastSeconds: Double, minSeconds: Double = 0.5) -> Data? {
    lock.lock()
    let count = bytes.count
    let want = min(count, Int(lastSeconds * Double(sampleRate)) * 2)
    guard want >= Int(minSeconds * Double(sampleRate)) * 2 else {
      lock.unlock()
      return nil
    }
    let slice = bytes.suffix(want)
    let pcm = Data(slice)
    lock.unlock()
    return Self.wav(pcm16: pcm, sampleRate: sampleRate)
  }

  /// Wrap raw little-endian Int16 mono PCM in a 44-byte WAV header.
  static func wav(pcm16: Data, sampleRate: Int) -> Data {
    var out = Data(capacity: pcm16.count + 44)
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    out.append(contentsOf: Array("RIFF".utf8))
    u32(UInt32(36 + pcm16.count))
    out.append(contentsOf: Array("WAVE".utf8))
    out.append(contentsOf: Array("fmt ".utf8))
    u32(16)                       // PCM fmt chunk size
    u16(1)                        // PCM
    u16(1)                        // mono
    u32(UInt32(sampleRate))
    u32(UInt32(sampleRate * 2))   // byte rate
    u16(2)                        // block align
    u16(16)                       // bits per sample
    out.append(contentsOf: Array("data".utf8))
    u32(UInt32(pcm16.count))
    out.append(pcm16)
    return out
  }
}
