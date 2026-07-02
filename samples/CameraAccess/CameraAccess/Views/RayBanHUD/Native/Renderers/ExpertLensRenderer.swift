//
// ExpertLensRenderer.swift
//
// Lens renderer for the Expert recording mode. Two surfaces (narration
// tip page + stop-confirm overlay) per the plan, plus a handoff card
// while the recorder is warming up (pre-`isHUDActive`).
//
// Unlike the Coaching and Troubleshoot modes, Expert has two transports
// with two different recording VMs (`IPhoneExpertRecordingViewModel` /
// `StreamSessionViewModel`). Both expose the same `ExpertRecordingManager`
// and `ExpertRecordingHUDViewModel`, so the renderer takes those plus a
// stop-action closure via a small `ExpertLensContext` wrapper — keeps
// the per-transport divergence out of the renderer entirely (per the
// `feedback-composition-over-per-transport-vms` rule).
//
// The 3-second stop-confirm countdown lives here as a local Task: the
// renderer owns `stopFlowActive` + `stopCountdownRemaining` and pumps
// the FlexBox tree on each tick. Cancel-during-countdown sets the local
// state back to `nil`, kills the Task, and re-renders the tip page.
//

import Combine
import Foundation
import MWDATDisplay

// MARK: - Context

/// Per-engine handle the lens needs to drive its renderer. Constructed
/// at activate-time by each recording engine (`IPhoneRecordingEngine`,
/// `GlassesRecordingEngine`) so the lens-side state stays decoupled
/// from the specific recording VM type.
@MainActor
final class ExpertLensContext {
  let recordingManager: ExpertRecordingManager
  let hudViewModel: ExpertRecordingHUDViewModel
  let transport: CaptureTransport
  let onStopConfirmed: () -> Void
  let onExitRequested: () -> Void

  /// Glasses-first only: tapping Start on the lens pre-flight. When nil (the
  /// phone-launched flow), the pre-flight shows the "use your phone" handoff
  /// card and Start lives on the phone chrome instead.
  let onStart: (() -> Void)?
  /// Emits `true` once the recorder has finished warmup and a Start tap will
  /// succeed (drives the lens pre-flight Start enabled state). Nil → not lens-
  /// launched.
  let readinessPublisher: AnyPublisher<Bool, Never>?

  init(
    recordingManager: ExpertRecordingManager,
    hudViewModel: ExpertRecordingHUDViewModel,
    transport: CaptureTransport,
    onStopConfirmed: @escaping () -> Void,
    onExitRequested: @escaping () -> Void,
    onStart: (() -> Void)? = nil,
    readinessPublisher: AnyPublisher<Bool, Never>? = nil
  ) {
    self.recordingManager = recordingManager
    self.hudViewModel = hudViewModel
    self.transport = transport
    self.onStopConfirmed = onStopConfirmed
    self.onExitRequested = onExitRequested
    self.onStart = onStart
    self.readinessPublisher = readinessPublisher
  }
}

// MARK: - Renderer

@MainActor
final class ExpertLensRenderer: LensRenderer {

  // MARK: - Inputs

  private let context: ExpertLensContext
  private weak var lensSession: LensSession?

  // MARK: - Local UI state (lens-side only)

  /// True once the user taps "Stop recording" on the lens — drives the
  /// confirm overlay. Cleared on cancel or after countdown completion.
  private var stopFlowActive: Bool = false
  /// 3, 2, 1 — re-sent on each tick. `nil` when no countdown is running.
  private var stopCountdownRemaining: Int? = nil
  /// The countdown driver. Cancelled on cancel-tap; nil when the flow
  /// isn't active.
  private var stopCountdownTask: Task<Void, Never>?

  /// Last snapshot we actually sent. The 120ms throttle can still fire the
  /// sink several times per second (tip carousel, warmup flips), so we skip
  /// sends whose projected snapshot is byte-identical to the last — collapsing
  /// them to one BT send per real, visible state change.
  private var lastSentSnapshot: ExpertLensSnapshot?

  /// Latest value from `context.readinessPublisher` (glasses-first only).
  /// Drives the lens pre-flight Start enabled state.
  private var isReadyToRecord: Bool = false

  // MARK: - Subscriptions

  private var cancellables: Set<AnyCancellable> = []

  // MARK: - Init

  init(context: ExpertLensContext, lensSession: LensSession) {
    self.context = context
    self.lensSession = lensSession
    subscribe()
  }

  // MARK: - LensRenderer

  func cancel() {
    cancellables.removeAll()
    stopCountdownTask?.cancel()
    stopCountdownTask = nil
  }

  /// Recover the HUD after a system back-gesture dismiss: clear the dedupe cache
  /// (an unchanged snapshot would otherwise be suppressed) and re-send.
  func repaint() {
    lastSentSnapshot = nil
    scheduleSend()
  }

  // MARK: - Subscription wiring

  /// CombineLatest over the published signals the lens cares about:
  /// recording state (drives the handoff/tip routing + the warmup gate) and
  /// the tip index (carousel).
  ///
  /// The recording duration is deliberately NOT observed here. The on-lens
  /// timer used to re-render every second, and during glasses recording those
  /// `display.send`s share the ONE BT radio with the live video stream (+ HFP
  /// audio) — enough contention to choke the WARP transport (the
  /// `service_not_found` death). The lens now shows a static "REC" indicator,
  /// so it only sends on real state changes (start/stop, tip, stop-confirm).
  private func subscribe() {
    let recording = Publishers.CombineLatest(
      context.recordingManager.$isRecording,
      context.recordingManager.$isWarmingUp
    )
    Publishers.CombineLatest(recording, context.hudViewModel.$tipIndex)
      .throttle(for: .milliseconds(120), scheduler: DispatchQueue.main, latest: true)
      .sink { [weak self] _ in
        // `lastSentSnapshot` equality in `scheduleSend()` suppresses sends
        // when nothing visible actually changed.
        self?.scheduleSend()
      }
      .store(in: &cancellables)

    // Glasses-first: re-render when the recorder becomes ready so the lens
    // pre-flight Start flips from "Preparing…" to enabled.
    if let readiness = context.readinessPublisher {
      readiness
        .removeDuplicates()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] ready in
          self?.isReadyToRecord = ready
          self?.scheduleSend()
        }
        .store(in: &cancellables)
    }
  }

  // MARK: - Snapshot projection

  private func projectSnapshot() -> ExpertLensSnapshot {
    let tip = context.hudViewModel.currentTip
    return ExpertLensSnapshot(
      isHUDActive: context.recordingManager.isHUDActive,
      canStartFromLens: context.onStart != nil,
      isReadyToRecord: isReadyToRecord,
      isRecording: context.recordingManager.isRecording,
      tipIndex: context.hudViewModel.tipIndex,
      totalTips: ExpertCoachingTips.pool.count,
      currentTipTitle: tip.title,
      currentTipBody: tip.body,
      stopFlowActive: stopFlowActive,
      stopCountdownRemaining: stopCountdownRemaining
    )
  }

  // MARK: - Send pipeline

  private func scheduleSend() {
    let snapshot = projectSnapshot()
    // With no live timer, snapshots only change on real state transitions
    // (start/stop, tip, stop-confirm). Equality check skips redundant BT sends.
    if let last = lastSentSnapshot, last == snapshot { return }
    lastSentSnapshot = snapshot
    let callbacks = makeCallbacks()
    let tree = ExpertLensTrees.tree(snapshot: snapshot, callbacks: callbacks)
    Task { [weak self] in
      await self?.lensSession?.send(tree)
    }
  }

  // MARK: - Callbacks (lens-side intents)

  private func makeCallbacks() -> ExpertLensCallbacks {
    ExpertLensCallbacks(
      onMuteToggle: {
        // No audio gate in Expert mode — narration is going to disk, not
        // to a live socket. Provided for shape parity with the shared
        // audioActionRow component but Expert uses a separate top row.
      },
      onExit: { [weak self] in
        Task { @MainActor [weak self] in
          self?.context.onExitRequested()
        }
      },
      onAdvanceTip: { [weak self] in
        Task { @MainActor [weak self] in
          self?.context.hudViewModel.advanceTip()
        }
      },
      onRetreatTip: { [weak self] in
        Task { @MainActor [weak self] in
          self?.context.hudViewModel.retreatTip()
        }
      },
      onStopTapped: { [weak self] in
        Task { @MainActor [weak self] in
          self?.beginStopCountdown()
        }
      },
      onStopCancel: { [weak self] in
        Task { @MainActor [weak self] in
          self?.cancelStopCountdown()
        }
      },
      onStart: { [weak self] in
        Task { @MainActor [weak self] in
          self?.context.onStart?()
        }
      }
    )
  }

  // MARK: - Stop-confirm countdown

  /// Start the 3 → 2 → 1 → stop sequence. Per the plan's Surface 16:
  /// each tick is a separate `display.send` (no animation primitive) and
  /// the loop is interruptible via `cancelStopCountdown()`.
  private func beginStopCountdown() {
    guard !stopFlowActive else { return }
    stopFlowActive = true
    stopCountdownRemaining = 3
    scheduleSend()

    stopCountdownTask?.cancel()
    stopCountdownTask = Task { [weak self] in
      do {
        for seconds in (1...2).reversed() {
          try await Task.sleep(nanoseconds: 1_000_000_000)
          guard let strong = self, strong.stopFlowActive else { return }
          strong.stopCountdownRemaining = seconds
          strong.scheduleSend()
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        guard let strong = self, strong.stopFlowActive else { return }
        // Countdown reached zero — fire the stop closure (recording
        // engine finalizes the .mp4 and bubbles up via `onRecordingComplete`).
        strong.stopFlowActive = false
        strong.stopCountdownRemaining = nil
        strong.context.onStopConfirmed()
      } catch {
        // Cancellation (cancel button or renderer cancel) — caller has
        // already reset the local state in `cancelStopCountdown`.
      }
    }
  }

  private func cancelStopCountdown() {
    stopFlowActive = false
    stopCountdownRemaining = nil
    stopCountdownTask?.cancel()
    stopCountdownTask = nil
    scheduleSend()
  }
}
