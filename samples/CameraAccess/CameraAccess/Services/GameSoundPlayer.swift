//
// GameSoundPlayer.swift
//
// Lightweight SFX player for the hidden "Retrace" mini-game: 9 per-tile melodic
// tones (`tone_0`…`tone_8`) so the watch sequence plays as a melody, plus a
// `wrong` buzzer. Mirrors `VoicePreviewPlayer`'s simple pooled-`AVAudioPlayer`
// approach.
//
// IMPORTANT: this does NOT configure or activate the `AVAudioSession`. The
// glasses HFP audio route is assumed to already be up at launch (owned
// elsewhere), so tones follow whatever output route is currently active.
// Keeping session management out of here avoids stomping that setup.
//

import AVFoundation
import Foundation

@MainActor
final class GameSoundPlayer {

  /// A few players kept alive at once so a tone can overlap a tap without the
  /// previous one being cut off. FIFO-evicted past the cap.
  private var players: [AVAudioPlayer] = []
  private let maxConcurrent = 3

  /// The victory fanfare gets its OWN retained player so the tone pool's FIFO
  /// eviction can never cut it off mid-celebration, and it plays at full volume
  /// independent of the tone mix.
  private var fanfarePlayer: AVAudioPlayer?

  /// Decoded WAV bytes cached by resource name (the tone set is tiny).
  private var cache: [String: Data] = [:]

  /// Play the tone for grid cell `index` (0..<9). Out-of-range is a no-op.
  func playTone(_ index: Int) {
    guard index >= 0, index < 9 else { return }
    play(resource: "tone_\(index)")
  }

  /// Play the wrong-answer buzzer.
  func playWrong() { play(resource: "wrong") }

  /// Play the loud victory fanfare — the new-high-score win sting. Uses a
  /// dedicated player (not the tone pool) at full volume so it can't be evicted.
  func playFanfare() {
    guard let data = data(for: "fanfare") else { return }
    do {
      let player = try AVAudioPlayer(data: data)
      player.volume = 1.0
      player.prepareToPlay()
      fanfarePlayer = player
      player.play()
    } catch {
      print("[GameSound] failed to play fanfare: \(error)")
    }
  }

  private func play(resource: String) {
    guard let data = data(for: resource) else { return }
    do {
      let player = try AVAudioPlayer(data: data)
      player.prepareToPlay()
      if players.count >= maxConcurrent { players.removeFirst() }
      players.append(player)
      player.play()
    } catch {
      print("[GameSound] failed to play \(resource): \(error)")
    }
  }

  private func data(for resource: String) -> Data? {
    if let cached = cache[resource] { return cached }
    guard let url = Bundle.main.url(forResource: resource, withExtension: "wav") else {
      print("[GameSound] missing asset \(resource).wav")
      return nil
    }
    let data = try? Data(contentsOf: url)
    cache[resource] = data
    return data
  }
}
