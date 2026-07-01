//
// CoachingLensRenderer.swift
//
// Subscribes to `CoachingSessionViewModel`'s published state and emits
// `FlexBox` trees through `LensSession.send(_:)`. Owns the lens-side
// local UI state (`expansion`, `descPage`) — these are independent of
// the SwiftUI emulator's own state (the lens and the emulator are two
// surfaces of the same VM, each with its own focus/expansion).
//
// Celebration sequencing is fully driven by VM state — the VM owns the
// 1.5s + 0.3s timeline by toggling `celebratingStepIndex` and
// `displayedStepIndex`. The renderer just dispatches the right tree per
// snapshot; no `Task.sleep` here.
//
// Conforms to `LensRenderer` (defined in `Services/Lens/LensRendererProtocol.swift`)
// so `LensSession` can hold and cancel it generically.
//

import Combine
import Foundation
import MWDATDisplay

@MainActor
final class CoachingLensRenderer: LensRenderer {

  // MARK: - Inputs

  private let viewModel: CoachingSessionViewModel
  private weak var lensSession: LensSession?

  // MARK: - Local UI state (lens-side only — does NOT mirror the phone emulator's @State)

  private var expansion: CoachingLensSnapshot.LensCoachingExpansion = .collapsed
  private var descPage: Int = 0
  /// Transient: set when a reference clip fails to load (404, bad URL,
  /// display detached). Painted as an error card in the inline reference
  /// panel; cleared on the next toggle or retry.
  private var clipErrorMessage: String?
  /// Lens-side exit-confirmation overlay flag. When true, `tree()` renders
  /// `exitConfirmationTree` over the step page. Toggled by the Exit pill and
  /// the overlay's Cancel/Confirm buttons — the confirmation lives ON the
  /// glasses, not the phone.
  private var showExitConfirmation = false

  // MARK: - Subscriptions

  private var cancellables: Set<AnyCancellable> = []

  // MARK: - Init

  init(viewModel: CoachingSessionViewModel, lensSession: LensSession) {
    self.viewModel = viewModel
    self.lensSession = lensSession
    // Let the back-gesture path interrupt an in-flight clip: while
    // `isClipPlaying`, "back" routes here (→ sendVideoStop) instead of the
    // exit-session overlay. The resulting `.stopped` event runs the same
    // `onEnded` path that resumes Gemini and repaints the step.
    viewModel.onClipDismissRequested = { [weak lensSession] in
      Task { await lensSession?.dismissReferenceClip() }
    }
    subscribe()
  }

  // MARK: - LensRenderer

  func cancel() {
    viewModel.onClipDismissRequested = nil
    cancellables.removeAll()
  }

  // MARK: - Subscription wiring

  /// Combine pipeline that re-renders on any relevant @Published change.
  /// Throttle to 120ms collapses rapid bursts (a single step-advance
  /// transition fires `currentStepIndex`, `displayedStepIndex`,
  /// `celebratingStepIndex`, and `slideDirection` within one frame).
  private func subscribe() {
    // Publishers.CombineLatest takes at most 4 sources — chain via
    // CombineLatest{4,3,2} as needed.
    let stepState = Publishers.CombineLatest4(
      viewModel.$currentStepIndex,
      viewModel.$displayedStepIndex,
      viewModel.$isCompleted,
      viewModel.$celebratingStepIndex
    )
    let mutedAndConnection = Publishers.CombineLatest(
      viewModel.$isMuted,
      viewModel.$geminiConnectionState
    )

    Publishers.CombineLatest(stepState, mutedAndConnection)
      .throttle(for: .milliseconds(120), scheduler: DispatchQueue.main, latest: true)
      .sink { [weak self] _ in
        self?.scheduleSend()
      }
      .store(in: &cancellables)
  }

  // MARK: - Snapshot projection

  private func projectSnapshot() -> CoachingLensSnapshot {
    let step = viewModel.displayedStep
    let description = step?.description ?? ""
    let pages = LensComponents.paginate(description, chunkSize: 180)
    let insights = buildInsights(from: step)

    // Bound descPage to the actual page count (in case the description
    // shrunk after a step transition).
    let safePage = pages.indices.contains(descPage) ? descPage : 0

    // Resolve the step's REAL reference media (video clip vs. manual page
    // image vs. none) from clip_url + source_type — never reconstruct a
    // .mp4 URL. For a video, the still poster is the .jpg first-frame route;
    // for a manual image, the poster IS the image itself.
    let media = resolveReferenceMedia()
    let referenceIsVideo: Bool
    let referenceVideoURL: String?
    let referencePosterURL: String?
    switch media {
    case .video(let url):
      referenceIsVideo = true
      referenceVideoURL = url.absoluteString
      referencePosterURL = step.map {
        LensImageURL.clipPosterURL(procedureId: viewModel.lensProcedureId, stepIndex: $0.stepNumber)
      } ?? nil
    case .image(let url):
      referenceIsVideo = false
      referenceVideoURL = nil
      referencePosterURL = url.absoluteString
    case .none:
      referenceIsVideo = false
      referenceVideoURL = nil
      referencePosterURL = nil
    }

    return CoachingLensSnapshot(
      pageKind: viewModel.isCompleted ? .completion : .step,
      isMuted: viewModel.isMuted,
      connection: connectionStatus(),
      showDismissConfirmation: showExitConfirmation,
      stepIndex: viewModel.displayedStepIndex,
      totalSteps: viewModel.lensTotalSteps,
      stepTitle: step?.title ?? "",
      stepDescription: description,
      expansion: expansion,
      hasReference: media != .none,
      referenceIsVideo: referenceIsVideo,
      referencePosterURL: referencePosterURL,
      referenceVideoURL: referenceVideoURL,
      clipErrorMessage: clipErrorMessage,
      insights: insights,
      descPage: safePage,
      descPagesTotal: pages.count,
      celebratingStepIndex: viewModel.celebratingStepIndex,
      procedureTitle: viewModel.lensProcedureTitle,
      formattedSessionDuration: viewModel.formattedSessionDuration
    )
  }

  /// Resolve the displayed step's reference media from its authoritative
  /// `clip_url` + the procedure's `source_type`. Shared by snapshot
  /// projection and the clip-tap handler so both agree on video-vs-image.
  private func resolveReferenceMedia() -> StepReferenceMedia {
    guard let step = viewModel.displayedStep else { return .none }
    let media = step.referenceMedia(
      sourceType: viewModel.lensProcedureSourceType,
      baseURL: ServerEndpoint.shared.resolvedBaseURL
    )
    // The native lens streams over the Bluetooth Display link, so request the
    // small `?profile=lens` server variant (~8x fewer bytes) for faster, smoother
    // first-frame playback. Only `.video` is rewritten — manual-page `.image`
    // and `.none` pass through. The phone PiP resolves its own URL in
    // CoachingSessionView and intentionally keeps the full-res clip. Falls back
    // to the original URL if it doesn't parse; the server also degrades an
    // unknown/failed profile back to the full clip, so this is purely additive.
    guard case .video(let url) = media,
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return media }
    components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "profile", value: "lens")]
    return components.url.map { .video($0) } ?? media
  }

  private func buildInsights(from step: ProcedureStepResponse?) -> [CoachingLensSnapshot.InsightItem] {
    guard let step else { return [] }
    var items: [CoachingLensSnapshot.InsightItem] = []
    items.append(contentsOf: step.tips.map { .init(category: "Tip", text: $0) })
    items.append(contentsOf: step.warnings.map { .init(category: "Warning", text: $0) })
    items.append(contentsOf: step.errorCriteria.map { .init(category: "Red flag", text: $0) })
    return items
  }

  private func connectionStatus() -> LensConnectionStatus {
    switch viewModel.geminiConnectionState {
    case .connected:    return .connected
    case .connecting:   return .connecting
    case .disconnected: return .idle
    case .error(let reason): return .failed(reason: reason)
    }
  }

  // MARK: - Send pipeline

  /// Build the current snapshot, dispatch through the right tree function,
  /// and send to LensSession. Called from the throttled subscriber AND
  /// from local-state mutations (toggle taps, page changes).
  private func scheduleSend() {
    let snapshot = projectSnapshot()
    let callbacks = makeCallbacks()
    let tree = CoachingLensTrees.tree(snapshot: snapshot, callbacks: callbacks)
    Task { [weak self] in
      await self?.lensSession?.send(tree)
    }
  }

  // MARK: - Reference video playback

  /// Hand the step's reference clip off to the full-screen `VideoPlayer`.
  /// Invoked directly when the user taps the Reference pill on a VIDEO step
  /// (one tap — there is no intermediate inline poster panel). Only a genuine
  /// `.video` resolves here; manual page images show inline. Uses the REAL
  /// server clip URL (never a reconstructed `.mp4`, which 404s for manual).
  private func playReferenceVideo() {
    guard case .video(let url) = resolveReferenceMedia() else { return }
    clipErrorMessage = nil

    // The step's clip length sizes the playback watchdog in LensSession
    // (fires at duration + 5s if no terminal event arrives). nil/≤0 → 60s cap.
    let expectedDuration: TimeInterval? = viewModel.displayedStep.map {
      $0.timestampEnd - $0.timestampStart
    }

    Task { [weak self] in
      await self?.lensSession?.presentReferenceClip(
        uri: url.absoluteString,
        expectedDuration: expectedDuration,
        onStarted: { [weak self] in
          // Clip is committed to the lens — pause the Gemini loop
          // (mic/voice/frames) so the clip's audio isn't fed back, the
          // model doesn't talk over it, and frames can't trip advance.
          self?.viewModel.setReferenceClipPlaying(true)
        },
        onEnded: { [weak self] in
          // Resume the Gemini loop and return to the DEFAULT (collapsed) step
          // screen — not the reference panel — per the requested UX.
          guard let self else { return }
          self.viewModel.setReferenceClipPlaying(false)
          self.expansion = .collapsed
          self.scheduleSend()
        },
        onError: { [weak self] _ in
          // Resume the loop (the clip never actually played) and surface a
          // visible error card inline instead of failing silently.
          // (The concrete reason is logged in LensSession.)
          guard let self else { return }
          self.viewModel.setReferenceClipPlaying(false)
          self.clipErrorMessage = "Couldn't load clip"
          self.expansion = .referenceInline
          self.scheduleSend()
        }
      )
    }
  }

  // MARK: - Callbacks (lens-side intents)

  private func makeCallbacks() -> CoachingLensCallbacks {
    CoachingLensCallbacks(
      onToggleReference: { [weak self] in
        guard let self else { return }
        // If an inline reference panel is already open (image panel OR a video
        // error card), tapping the pill closes it — "Hide ref". This is also
        // what dismisses a video error card.
        if self.expansion == .referenceInline {
          self.expansion = .collapsed
          self.descPage = 0
          self.clipErrorMessage = nil
          self.scheduleSend()
          return
        }
        // Opening. A VIDEO reference plays full-screen immediately (one tap —
        // no intermediate poster panel). An IMAGE reference opens inline as
        // before. `.none` can't reach here (pill is hidden).
        if case .video = self.resolveReferenceMedia() {
          self.playReferenceVideo()
          return
        }
        self.expansion = .referenceInline
        self.descPage = 0
        self.clipErrorMessage = nil  // fresh open — drop any stale error
        self.scheduleSend()
      },
      onToggleInsights: { [weak self] in
        guard let self else { return }
        self.expansion = (self.expansion == .insightsInline) ? .collapsed : .insightsInline
        self.descPage = 0
        self.clipErrorMessage = nil
        self.scheduleSend()
      },
      onExpandStep: { [weak self] in
        guard let self else { return }
        self.expansion = .stepExpanded
        self.descPage = 0
        self.scheduleSend()
      },
      onCollapse: { [weak self] in
        guard let self else { return }
        self.expansion = .collapsed
        self.descPage = 0
        self.scheduleSend()
      },
      onDescPagePrev: { [weak self] in
        guard let self else { return }
        self.descPage = max(0, self.descPage - 1)
        self.scheduleSend()
      },
      onDescPageNext: { [weak self] in
        guard let self else { return }
        let description = self.viewModel.displayedStep?.description ?? ""
        let pages = LensComponents.paginate(description, chunkSize: 180)
        self.descPage = min(max(0, pages.count - 1), self.descPage + 1)
        self.scheduleSend()
      },
      onMuteToggle: { [weak viewModel] in
        Task { @MainActor in
          viewModel?.toggleMute()
        }
      },
      onExit: { [weak self] in
        Task { @MainActor in
          // Show the exit confirmation ON the lens (was: route to the phone
          // overlay via viewModel.onBackGesture).
          guard let self else { return }
          self.showExitConfirmation = true
          self.scheduleSend()
        }
      },
      onRetryClip: { [weak self] in
        guard let self else { return }
        // "Try again" from the video error card → re-attempt full-screen
        // playback. Drop the error + the inline panel first; a repeat failure
        // re-opens the error card via `playReferenceVideo`'s onError.
        self.clipErrorMessage = nil
        self.expansion = .collapsed
        self.playReferenceVideo()
      },
      onCompletionExit: { [weak viewModel] in
        Task { @MainActor in
          // Completion is terminal: run the host-installed exit (endSession +
          // dismiss), same as the phone's "Return to workflows". Do NOT route
          // through onBackGesture — that only opens the phone-local exit-confirm
          // overlay, which leaves the lens unchanged and never ends the session.
          viewModel?.onExitConfirmed?()
        }
      },
      onExitConfirmCancel: { [weak self] in
        guard let self else { return }
        self.showExitConfirmation = false
        self.scheduleSend()
      },
      onExitConfirmConfirm: { [weak self] in
        guard let self else { return }
        self.showExitConfirmation = false
        // Run the host-installed terminal exit (endSession + dismiss). The
        // phone view tears down the session and pops itself; the lens flow
        // returns to idle as the session ends.
        self.viewModel.onExitConfirmed?()
      }
    )
  }
}
