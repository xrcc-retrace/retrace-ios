//
// RetraceGameEngine.swift
//
// State machine for "Retrace" — a hidden Simon-says path-memory game on the
// glasses native lens, reachable from the navigator Home screen's easter-egg
// sparkle button.
//
// The lens flashes a growing sequence of cells (the "watch" phase); the player
// retraces it by tapping the cells in order (the "input" phase). Each completed
// round appends one cell. A wrong tap ends the run. Best round persists.
//
// Design notes:
//   - Tap-only: on the real Display lens the app only receives taps (the Neural
//     Band moves the system focus ring; pinch = tap), so the grid is tapped, not
//     swiped. See `feedback_dat_lens_input_model`.
//   - The ONLY timed work is the watch-phase playback — a core mechanic (the game
//     can't function without showing the sequence). Same `Task` + `Task.sleep`
//     idiom as `TroubleshootLensRenderer.syncSearchAnimation`; there is no SDK
//     animation primitive on the lens. Every other state change is tap-driven.
//   - This engine owns ALL game logic so `NavigatorViewModel` stays a thin nav
//     shell (`feedback_mode_modularity`). `NavigatorLensRenderer` repaints on the
//     `@Published state` via a dedicated Combine sink.
//

import Combine
import Foundation

@MainActor
final class RetraceGameEngine: ObservableObject {

  enum Phase: Equatable {
    case watch      // replaying the sequence; taps are inert
    case input      // player's turn to retrace
    case gameOver   // wrong tap; show score + Play again
  }

  struct GameState: Equatable {
    var phase: Phase
    var sequence: [Int]      // cell indices 0..<9, grows by one each round
    var inputProgress: Int   // how many cells the player has correctly retraced this round
    var round: Int           // 1-based round currently being attempted
    var score: Int           // highest round COMPLETED this run
    var best: Int            // persisted high score
    var litCell: Int?        // currently flashing cell during .watch
    var wrongCell: Int?      // the cell that ended the run (for .gameOver feedback)
  }

  @Published private(set) var state: GameState

  // Per-tile melodic tones + wrong-answer buzzer. The audio route (glasses HFP)
  // is assumed to already be up at launch — this player does NOT configure the
  // AVAudioSession; it just plays through whatever output is active.
  private let sounds = GameSoundPlayer()

  // Watch-phase playback. Cancelled when a new round starts, the game stops, or
  // the engine is torn down.
  private var playbackTask: Task<Void, Never>?

  // Flash cadence RAMPS with the round so longer sequences feel like a real
  // Simon round instead of a slideshow — but ONLY the lit hold shrinks. The gap
  // is the tightest spacing between two Display sends (lit-off → next lit-on),
  // so it sets the rate the glasses link has to keep up with; it's floored at a
  // display-safe value (see `gapNanos`). The whole sequence plays at one tempo,
  // recomputed each watch from `round`.
  private let preRollNanos: UInt64 = 400_000_000  // beat before the replay starts

  // Length of the victory fanfare (`fanfare.wav`). When a new best is set we
  // delay the next watch by this much so the sting rings out before its tones.
  private let fanfareNanos: UInt64 = 2_000_000_000

  // Whether the new-best fanfare already fired this run. The win sting plays
  // ONCE — the first round the score crosses the previous best — not on every
  // subsequent record-breaking round. Reset in `start()`.
  private var celebratedThisRun = false

  /// How long a tile stays lit, by the round being shown (= sequence length).
  /// This is the lever that makes the replay feel faster past a score of 5;
  /// it stays well above the gap, so it never becomes the tightest send spacing.
  private func litNanos(forRound round: Int) -> UInt64 {
    switch round {
    case ...2:  return 1_100_000_000   // 1.1 s — learn the mechanic
    case 3...5: return 800_000_000     // 0.8 s
    case 6...8: return 550_000_000     // 0.55 s — past a score of 5, noticeably quicker
    default:    return 450_000_000     // 0.45 s — floor for long sequences
    }
  }

  /// Dark gap between consecutive tiles — the TIGHTEST spacing between two
  /// Display sends, so it caps the send rate the glasses must sustain.
  /// Empirically a ~0.20 s gap saturated the link and `display.send` started
  /// timing out past round 5; ~0.30 s (just above the 0.28 s that was stable
  /// through round 5) holds the send rate safe at every round. We deliberately
  /// do NOT shrink this with the round — speed comes from the lit hold above.
  private func gapNanos(forRound round: Int) -> UInt64 {
    switch round {
    case ...2: return 360_000_000     // 0.36 s — relaxed at the very start
    default:   return 300_000_000     // 0.30 s — display-safe floor, never tighter
    }
  }

  private let gridSize = 9
  private let bestKey = "retraceGameBest"

  init() {
    state = GameState(
      phase: .input,
      sequence: [],
      inputProgress: 0,
      round: 1,
      score: 0,
      best: UserDefaults.standard.integer(forKey: bestKey),
      litCell: nil,
      wrongCell: nil
    )
  }

  // MARK: - Lifecycle

  /// Begin a fresh run at round 1.
  func start() {
    playbackTask?.cancel()
    celebratedThisRun = false
    state = GameState(
      phase: .watch,
      sequence: [Int.random(in: 0..<gridSize)],
      inputProgress: 0,
      round: 1,
      score: 0,
      best: UserDefaults.standard.integer(forKey: bestKey),
      litCell: nil,
      wrongCell: nil
    )
    beginWatch()
  }

  /// Cancel playback and clear any lit cell (e.g. on Back / navigator reset).
  func stop() {
    playbackTask?.cancel()
    playbackTask = nil
    update { $0.litCell = nil }
  }

  // MARK: - Input

  /// A grid cell was tapped. Only meaningful during `.input`.
  func tapCell(_ idx: Int) {
    guard state.phase == .input else { return }
    guard state.sequence.indices.contains(state.inputProgress) else { return }

    if idx == state.sequence[state.inputProgress] {
      var s = state
      s.inputProgress += 1
      sounds.playTone(idx)   // hear the note you just hit (rebuild the melody)
      if s.inputProgress >= s.sequence.count {
        // Round complete — bank the score, grow the sequence, replay.
        s.score = s.round
        // New personal best the FIRST time this run's score passes the stored
        // record. `best` is bumped every record-breaking round (so it always
        // persists the true high), but the fanfare is gated to fire just once.
        let isNewBest = s.score > s.best
        if isNewBest {
          s.best = s.score
          UserDefaults.standard.set(s.best, forKey: bestKey)
        }
        s.sequence.append(Int.random(in: 0..<gridSize))
        s.round += 1
        s.inputProgress = 0
        s.phase = .watch
        state = s
        if isNewBest && !celebratedThisRun {
          // 🎉 You're past your record — play the loud win sting, and give it
          // room by delaying the next sequence until it has rung out. Default
          // best is 0 on a fresh install, so the first round completed beats it
          // and celebrates — intentional, so a new install can win every time.
          celebratedThisRun = true
          sounds.playFanfare()
          beginWatch(leadNanos: preRollNanos + fanfareNanos)
        } else {
          beginWatch()
        }
      } else {
        state = s
      }
    } else {
      sounds.playWrong()
      var s = state
      s.wrongCell = idx
      s.phase = .gameOver
      state = s
    }
  }

  // MARK: - Watch playback

  private func beginWatch(leadNanos: UInt64? = nil) {
    playbackTask?.cancel()
    let seq = state.sequence
    // One tempo for the whole replay, set by the current round — longer
    // sequences flash faster (see `litNanos`/`gapNanos`).
    let lit = litNanos(forRound: state.round)
    let gap = gapNanos(forRound: state.round)
    // Pause before the replay starts. Defaults to the pre-roll beat; a new-best
    // round passes a longer lead so the fanfare finishes first.
    let lead = leadNanos ?? preRollNanos
    playbackTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(nanoseconds: lead)
        for idx in seq {
          if Task.isCancelled { return }
          self.update { $0.litCell = idx }
          self.sounds.playTone(idx)   // the watch sequence becomes a melody
          try await Task.sleep(nanoseconds: lit)
          if Task.isCancelled { return }
          self.update { $0.litCell = nil }
          try await Task.sleep(nanoseconds: gap)
        }
        if Task.isCancelled { return }
        self.update {
          $0.phase = .input
          $0.inputProgress = 0
        }
      } catch {
        // Cancelled — a new round started, the game stopped, or teardown.
      }
    }
  }

  // MARK: - Helpers

  private func update(_ mutate: (inout GameState) -> Void) {
    var s = state
    mutate(&s)
    state = s
  }
}
