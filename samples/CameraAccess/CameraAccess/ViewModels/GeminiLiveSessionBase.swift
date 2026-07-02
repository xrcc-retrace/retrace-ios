import AVFoundation
import Combine
import MWDATCamera
import MWDATCore
import SwiftUI

/// Transcript + tool-call entry surfaced in the activity feed.
///
/// Lives here (not in CoachingSessionViewModel) so every mode VM that
/// inherits from `GeminiLiveSessionBase` shares the same type.
struct ActivityEntry: Identifiable, Equatable {
  enum Kind: Equatable {
    case toolCall(name: String)
    case learner
    case assistant
  }

  let id = UUID()
  let kind: Kind
  var text: String
  let timestamp: Date
}

/// Mode-agnostic base for any Gemini Live session (learner coaching,
/// diagnostic troubleshooting, future on-site worker / Iron Man HUD).
///
/// Absorbs the duplicated machinery that every mode needs:
///   - Audio session setup (mic permission, AEC, gated send)
///   - Camera setup for both transports (.glasses via DAT SDK, .iPhone via AVCaptureSession)
///   - Ephemeral token mint + WebSocket lifecycle + Combine observation
///   - Shared callbacks (audio in, transcripts, barge-in, resumption handle)
///   - Tool-call HTTP ceremony (POST, unwrap, send toolResponse ACK)
///   - Transcript + tool-call coalescing in the activity feed
///   - Teardown order (close gate → drop subs → stop audio → disconnect)
///
/// Subclasses override the `open`/`internal` template hooks below to plug
/// in mode-specific behavior without touching the shared plumbing:
///   - `mintSession()` — what REST endpoint to hit for the initial token
///   - `toolCallURLSuffix` — which `/api/<mode>/session/{id}/tool-call` path
///   - `toolCallTimeoutSeconds` — learner 10s, diagnostic 90s (PDF ingest)
///   - `introSeedText` — first synthetic user turn on initial .connected
///   - `onTurnCompleteExtra()` — coaching schedules heartbeats; others no-op
///   - `handleToolCallExtras(...)` — mode-specific state updates per tool
///   - `audioSessionMode` — `.coaching` on glasses, `.coachingPhoneOnly` elsewhere
///   - `transport` — `.glasses` vs `.iPhone`
///   - `contextSummaryForReconnect()` — coaching fetches from server; others nil
///   - `didEndSession()` — mode cleanup after teardown
@MainActor
class GeminiLiveSessionBase: ObservableObject {

  // MARK: - Published State (observed by views)

  @Published var isMuted = false
  @Published var voiceStatus = "Connecting..."
  @Published var isAISpeaking = false
  /// Smoothed peak amplitude of the AI's voice output, in `0...1`. Mirrored
  /// from `AudioSessionManager.aiOutputPeak` so the audio meter in the
  /// controls bar can react to actual speech volume instead of a flat
  /// "is speaking" Boolean.
  @Published private(set) var aiOutputPeak: Float = 0
  /// Smoothed peak amplitude of the user's mic input, in `0...1`. Mirrored
  /// from `AudioSessionManager.userInputPeak`. Drives the listening (white)
  /// state of `RetraceAudioMeter` — pinned to 0 while muted so a paused mic
  /// can't read as "listening".
  @Published private(set) var userInputPeak: Float = 0
  /// Mirrored from `AudioSessionManager.lastAudioActivityAt`. Coaching's
  /// heartbeat reads this to enforce a quiet-streak window — peaks flicker
  /// off in inter-chunk gaps, but this timestamp only moves forward when
  /// real audio activity happens.
  @Published private(set) var lastAudioActivityAt: Date = .distantPast
  /// Mirrored from `GeminiLiveService.modelGenerationActive`. Wire-level
  /// truth for "Gemini is producing a turn right now" — independent of
  /// local playback. Coaching's heartbeat gate uses it to never ship
  /// `[check]` while the model is mid-generation.
  @Published private(set) var isModelGenerating: Bool = false
  @Published var geminiConnectionState: GeminiLiveService.ConnectionState = .disconnected
  @Published var activity: [ActivityEntry] = []

  /// Gate for starting the on-glasses native lens Display. Flips true only
  /// once the session's glasses HFP mic AND camera stream are both up and
  /// settled. The native lens (a separate, View-triggered consumer of the
  /// shared glasses DeviceSession) must not call `addDisplay()/start()`
  /// before this — the Display capability claims the glasses' high-bandwidth
  /// BT link, and bringing it up *during* the HFP warmup makes iOS silently
  /// drop the glasses HFP route and fall back to another connected BT device
  /// (e.g. AirPods), so no mic buffers ever arrive. Meta's docs are explicit:
  /// "ensure that HFP is fully configured before initiating any streaming
  /// session that requires audio functionality." Sequencing the Display
  /// behind this flag makes the Display the LAST glasses BT capability to
  /// start, after audio is established — the documented coexistence order.
  /// Views observe this and defer `LensSession.activate(...)` until it's true.
  @Published private(set) var isReadyForNativeLens = false

  /// Idempotency guard against a DOUBLE teardown. On "Take back on phone" the
  /// explicit exit calls `shutdown()` → `endSession(...)`, and then setting
  /// `runtimeMode = .none` unmounts the SwiftUI host, whose `.onDisappear`
  /// backstop calls `endSession(...)` a second time — producing a second
  /// `release(gemini-live)` + server DELETE. Subclasses gate `endSession(...)`
  /// on this; it's reset when a fresh session starts. (Named `sessionDidEnd` to
  /// avoid colliding with the `didEndSession()` subclass-hook method below.)
  var sessionDidEnd = false

  /// True when a `.glasses` session is running but the connected glasses are
  /// NOT Display-capable — so the (always-on) on-glasses lens can't render and
  /// the session runs camera-only with the phone-side UI. This is the observable
  /// difference between "Phone + non-display Ray-Bans" and "Phone + display
  /// Ray-Bans": without it the
  /// non-display Ray-Bans" and "Phone + display Ray-Bans": without it the
  /// non-display case silently no-ops the lens (only a `print`). The
  /// coaching/troubleshoot views bind this to a one-line, non-blocking notice.
  /// Never set on the iPhone transport or in the glasses-navigator (Launch on
  /// Display) flow — that path's readiness gate already requires a Display
  /// device, so this condition can't arise there.
  @Published private(set) var glassesLensUnavailable = false

  /// Health of the camera branch (glasses Stream or iPhone capture),
  /// independent of the Gemini voice socket. `.failed` means the camera died
  /// (startup stall, mid-session frame starvation, stream drop, session
  /// invalidation) and the session is running voice-only until the user
  /// retries. Drives the camera banner + alert in Coaching/Troubleshoot.
  /// `geminiConnectionState.error` now means voice-socket problems ONLY.
  enum CameraHealth: Equatable { case ok, reconnecting, failed }
  @Published private(set) var cameraHealth: CameraHealth = .ok

  /// One-shot trigger for the blocking "camera lost" alert. Fired once per
  /// failure episode by `handleCameraBranchFailure`; the persistent banner is
  /// driven by `cameraHealth` and survives the alert's dismissal.
  @Published var showCameraLostAlert = false

  /// Mirrors `AudioSessionManager.micStalled` for THIS session's audio manager
  /// (own or borrowed). Drives a non-blocking "audio pipeline broken" banner in
  /// the phone coaching/troubleshoot views; auto-clears when buffers resume. The
  /// glasses-navigator standby uses the coordinator's own signal instead.
  @Published private(set) var micStalled = false

  /// Set true when the pre-session DAT camera-permission gate fails on
  /// a `.glasses` transport session. The session view binds this to a
  /// `.sheet(isPresented:)` and presents a `PermissionRequiredSheet`
  /// containing the same `DATCameraPermissionCTA` used elsewhere in
  /// the app. (Microphone permission is iOS-native and prompted in
  /// step 1 of `startGeminiLiveSession` — not part of this gate.)
  /// On grant inside the sheet, the view calls
  /// `retryAfterPermissionGrant()` to re-run session start in place.
  ///
  /// This is the recovery layer of the defense-in-depth strategy — the
  /// pre-flight CTAs on `LearnerProcedureDetailView` and the troubleshoot
  /// transport picker catch the 99% case before the user ever taps. This
  /// flag catches the residual case (revoked permission between picker
  /// tap and session start, or app-backgrounded into Meta AI).
  @Published var pendingGlassesPermissions: Bool = false

  /// Set true when audio readiness times out (no first PCM buffer within
  /// the timeout window). Distinct from `pendingGlassesPermissions`
  /// because the recovery action is different: this isn't a permission
  /// problem (those have been verified by the time we get here), it's
  /// a BT HFP SCO setup delay or a transient audio-route issue. The
  /// session view binds this to a sheet presenting an `AudioRecoverySheet`
  /// with a "Try again" CTA that calls `retryAfterAudioFailure()`.
  @Published var pendingAudioRetry: Bool = false

  /// Set true when `manager.acquire(consumerLabel: "gemini-live")` throws
  /// `DeviceSessionError.datAppOnTheGlassesUpdateRequired` — the SDK's
  /// signal that the DAT helper app on the glasses is out of date and
  /// needs to be updated through Meta AI before sessions can start.
  ///
  /// Distinct from `pendingGlassesPermissions` (where the user fixes it
  /// in iOS Settings via Meta AI) and `pendingAudioRetry` (transient BT
  /// SCO issue). This one requires the user to launch Meta AI on the
  /// phone, navigate to the glasses' device card, and tap Update —
  /// the recovery sheet (`DATHelperUpdateRequiredSheet`) walks them
  /// through it with a Meta AI deep link.
  ///
  /// Mirrors `LensDisplayCoordinator.requiresDATAppUpdate` — same SDK
  /// signal, surfaced through the parallel coaching/troubleshoot path.
  @Published var pendingDATHelperUpdate: Bool = false

  // MARK: - Inputs

  let wearables: WearablesInterface
  let serverBaseURL: String

  // MARK: - Shared Services (set during startGeminiLiveSession, nilled in teardown)

  var audioManager: AudioSessionManager?

  /// Glasses-native persistent audio. When set (by the glasses-native runtime
  /// hosts via `GlassesNavigationCoordinator.persistentAudio`), this runtime
  /// BORROWS an already-armed, already-running `AudioSessionManager` instead of
  /// creating + arming its own. The borrowed session is owned by the
  /// coordinator and outlives this runtime: `startGeminiLiveSession()` skips the
  /// configure/HFP-warmup/startCapture and only attaches its endpoint closures;
  /// `stopGeminiLiveSession()` detaches them but leaves the session running for
  /// the next runtime. nil ⇒ legacy per-session arm/teardown (phone flows + the
  /// flag-OFF glasses path), unchanged.
  var externalAudioManager: AudioSessionManager?

  var geminiService: GeminiLiveService?
  var tokenManager: GeminiTokenManager?
  var sessionId: String?

  // MARK: - Gate state

  var pendingToolCallIds: Set<String> = []
  /// Names of tools currently in flight, by id. Subclasses observe this to
  /// drive stage-aware UI (e.g. the Troubleshoot searching page flips
  /// between "library" and "web" stages based on which tool is running).
  @Published private(set) var pendingToolCallNames: [String: String] = [:]
  var isGeminiReady = false
  var isSendingAudio = true
  var audioGateWasOpen = false
  var hasSeededIntro = false
  /// True while a native-lens reference clip is playing full-screen on the
  /// glasses. Folds into all three send gates (audio + both video) so the
  /// clip's own AAC audio isn't fed back as learner speech, Gemini doesn't
  /// talk over the clip, and a static mid-task frame can't trip a spurious
  /// `advance_step`. Set via `setReferenceClipPlaying(_:)` from the clip's
  /// start/terminal events; only the native-lens path drives it.
  var isClipPlaying = false

  // MARK: - Push-to-talk (walkie-talkie) — demo mode only

  /// True while the mic is sending via push-to-talk (finger held, or latched on
  /// by a quick tap). Observed by the Talk capsule for its engaged styling.
  @Published var isTalkEngaged = false
  /// A quick tap latches Talk ON until the next tap. Distinct from a momentary
  /// hold, which stops on release.
  private var isTalkLatched = false
  private var talkPressStartedAt: Date?
  /// Bumped on every press / scheduled close so a re-press cancels a pending
  /// release "tail" (see `endTalkWithTail`).
  private var talkCloseGeneration = 0

  /// Subclass opt-in. Only Coaching shows a Talk button; Troubleshoot stays
  /// always-listening even in demo mode.
  var supportsPushToTalk: Bool { false }

  /// Push-to-talk is active only for the iPhone Mac-route demo. Reads
  /// UserDefaults directly (no `#if`) — the key is only ever written by the
  /// DEBUG-only Settings toggle, so it stays false in Release ⇒ shipped
  /// behavior is unchanged.
  var isPushToTalkActive: Bool {
    supportsPushToTalk
      && transport == .iPhone
      && UserDefaults.standard.bool(forKey: "debug.routeAudioToMacForDemo")
  }

  // MARK: - Transcript coalescing

  var learnerTurnOpen = false
  var assistantTurnOpen = false

  // MARK: - Video forwarding (glasses + iPhone, same throttle)

  var glassesStream: MWDATCamera.Stream?
  var deviceSession: DeviceSession?
  var stateListenerToken: AnyListenerToken?
  var videoFrameListenerToken: AnyListenerToken?
  /// Phase 4: subscription to the shared `DeviceSessionManager`'s
  /// `sessionErrors` fan-out, when the manager path is active. Replaces
  /// the per-consumer `errorStream` observation we never had. Cleared in
  /// `stopCameraStream`.
  var sessionErrorsCancellable: AnyCancellable?
  /// Subscription to the manager's `sessionInvalidated` fan-out — a forced
  /// out-of-band session drop (e.g. another consumer detected the transport is
  /// dead). The SDK's `errorStream` never fires for a WARP transport death, so
  /// this is how a sibling consumer's detection reaches us. Cleared in
  /// `stopCameraStream`.
  var sessionInvalidatedCancellable: AnyCancellable?
  var iPhoneCamera: IPhoneCameraCapture?
  var iPhoneVideoSource: IPhoneCoachingCameraSource?
  /// Off-MainActor frame fan-out for the glasses transport. Owns the JPEG
  /// throttle, preview decode, and hand-tracking handoff so `setupCameraStream`'s
  /// publisher listener body stays a one-line `submit(_:)` call.
  var glassesCoachingSource: GlassesCoachingFrameSource?
  var cameraLifecycleTask: Task<Void, Never>?

  /// One-shot signal that the active camera pipeline (glasses or iPhone)
  /// has delivered its first video frame. Set on the MainActor by the
  /// frame listener / sample-buffer closure. Read by `awaitCameraReady(_:)`
  /// which the new sequential `startGeminiLiveSession` order awaits before
  /// opening the Gemini WebSocket. Cleared at the start of each camera
  /// setup so a previous session's `true` doesn't satisfy a new wait.
  ///
  /// Why first-frame instead of stream-state: on the glasses transport,
  /// `Stream.state == .streaming` flips a beat before any actual video
  /// data arrives over the BT pipe. We want the proof that data flows,
  /// not the proof that the SDK think it should.
  private var firstFrameSeen = false
  private var firstFrameContinuation: CheckedContinuation<Bool, Never>?

  // MARK: - Mid-session frame-starvation watchdog
  //
  // The startup first-frame wait (`firstFrameContinuation`) only covers the
  // window before the Gemini socket opens. A WARP transport death MID-session
  // (frames flowing, then silently stopping) never surfaces on the SDK's
  // `errorStream`/`statePublisher`, so this watchdog — armed once the first
  // frame lands — is the only detector. On a stall it force-invalidates the
  // shared glasses session (so Retry rebuilds a fresh one) and flips the
  // connection state to an error/Retry card.

  /// Stamped (off-MainActor, lock-guarded) on every delivered video frame.
  private let lastVideoFrameAtLock = NSLock()
  nonisolated(unsafe) private var _lastVideoFrameAt: Date = .distantPast

  private nonisolated func stampVideoFrame() {
    lastVideoFrameAtLock.lock()
    _lastVideoFrameAt = Date()
    lastVideoFrameAtLock.unlock()
  }

  private func readLastVideoFrameAt() -> Date {
    lastVideoFrameAtLock.lock()
    defer { lastVideoFrameAtLock.unlock() }
    return _lastVideoFrameAt
  }

  /// Repeating starvation-check task, armed on first frame, cancelled in
  /// `stopCameraStream` / on starvation.
  private var videoWatchdogTask: Task<Void, Never>?
  /// Guards against re-firing the starvation handler (also covers the echo
  /// from our own `invalidate` arriving back on the `sessionInvalidated` sink).
  private var cameraStarvationSurfaced = false
  /// Tolerated gap before declaring the video transport dead.
  private static let videoStallThreshold: TimeInterval = 5.0
  /// Hard ceiling for a mid-session frame gap. DAT 0.8 migrates video onto a
  /// WiFi Direct/SoftAP link seconds after stream start (and on bandwidth
  /// jumps); frames PAUSE during that multi-second join. A >5s gap is
  /// therefore "possibly migrating", not "dead" — the watchdog holds
  /// teardown (probation, `.reconnecting` UI) until this ceiling.
  private static let videoStallHardThreshold: TimeInterval = 30.0
  /// Non-nil while in the soft-stall probation window (gap >5s, <30s).
  private var videoStallProbationStartedAt: Date?
  /// The stale frame stamp at probation entry — lets the recovery log print
  /// the exact survived gap length (the WiFi-migration measurement).
  private var videoStallProbationLastFrameAt: Date?

  /// Set by the camera setup Task when an unrecoverable setup-time error
  /// hits (failed `manager.acquire`, `addStream` returning nil, iPhone
  /// permission denied, etc.). Read by the outer `setupCameraStream` /
  /// `setupIPhoneCameraStream` async wrapper to short-circuit the
  /// first-frame wait — no point waiting 8s for a frame that will never
  /// arrive when the camera never came up.
  private var cameraSetupFailed = false

  /// Audio analogue of `firstFrameSeen` / `firstFrameContinuation`. Set
  /// when the first PCM buffer arrives from the active `AudioSessionManager`,
  /// awaited by `startGeminiLiveSession` step 2 before proceeding to the
  /// camera. The wait is short (2 s) because `AVAudioEngine.start()`
  /// succeeding usually means buffers begin flowing within ~50 ms — but on
  /// the BT HFP path with the glasses' mic, the SCO link can take longer
  /// to actually carry audio, so the explicit wait removes the silent
  /// "Gemini connected but no mic data" failure mode for that case.
  private var firstMicBufferSeen = false
  private var firstMicBufferContinuation: CheckedContinuation<Bool, Never>?

  // Hand tracking: owns the MediaPipe service. The pinch-drag recognizer
  // and its plumbing (frame log, orientation log throttle, debug-provider
  // forwards) live on `HandGestureService.shared` — see
  // `HandTracking/HandGestureService.swift`. We just route MediaPipe
  // results into it from the camera-frame closure below.
  var handLandmarkerService: HandLandmarkerService?

  /// Fired when the gesture pipeline emits a `.back` event — a double
  /// index-finger pinch detected by `PinchDragRecognizer`. Hosts (e.g.
  /// `CoachingSessionView`) set this to drive the exit-confirmation
  /// overlay. Equivalent semantically to `RayBanHUDEmulator`'s
  /// `onLensBackGesture` finger-tap fallback — both inputs converge on
  /// the same UI action. Wired through to `HandGestureService.shared`
  /// in start/stop session so the call-site contract stays unchanged.
  var onBackGesture: (() -> Void)?

  /// Set by the active native-lens renderer to a closure that stops an
  /// in-flight reference clip (→ `LensSession.dismissReferenceClip()`).
  /// The back-gesture path calls this *instead of* the exit-session overlay
  /// while `isClipPlaying` is true, so "back" during a clip returns to the
  /// step rather than ending the session.
  var onClipDismissRequested: (() -> Void)?

  /// Preview layer bound to the live iPhone capture session, or nil when
  /// transport is `.glasses` or the camera hasn't been set up yet. Attaches
  /// to a `UIView` via `IPhoneCameraPreview`. Hardware-composited — reading
  /// it introduces no cost to the JPEG → Gemini send path. @Published so
  /// the iPhone camera-first layout redraws once the capture session comes
  /// up after permission grants.
  @Published var iPhonePreviewLayer: AVCaptureVideoPreviewLayer?
  /// Latest decoded glasses video frame, published so the phone-side
  /// `GlassesCameraPreview` can render the live glasses feed behind the
  /// HUD emulator. Throttled to ~10 Hz inside `GlassesCoachingFrameSource`
  /// (off-main) so the MainActor only pays for the `@Published` assignment
  /// and not the UIImage decode. Nil for iPhone transport.
  @Published var glassesPreviewFrame: UIImage?
  /// Latest interface orientation pushed by the view. Cached here so that
  /// orientation updates arriving before the async camera start can be
  /// replayed onto `iPhoneCamera` the moment it becomes available.
  private var pendingPreviewOrientation: UIInterfaceOrientation?

  // MARK: - Resumption (also used by coaching's goAway → reconnect path)

  var resumptionHandle: String?
  var isResuming = false

  // MARK: - Constants

  let activityMaxEntries = 200
  let videoMinInterval: TimeInterval = 1.0
  let videoJpegQuality: CGFloat = 0.85

  // MARK: - Combine

  var cancellables: Set<AnyCancellable> = []

  // MARK: - Init

  /// Shared `DeviceSessionManager` — the single owner of every DAT
  /// `DeviceSession`. Camera session lifecycle goes through the manager so
  /// the same `DeviceSession` carries both `Stream` (camera) and `Display`
  /// (lens) capabilities, per the SDK's capability-composition model.
  let sessionManager: DeviceSessionManager

  init(
    wearables: WearablesInterface,
    serverBaseURL: String,
    sessionManager: DeviceSessionManager,
    externalAudioManager: AudioSessionManager? = nil
  ) {
    self.wearables = wearables
    self.serverBaseURL = serverBaseURL
    self.sessionManager = sessionManager
    self.externalAudioManager = externalAudioManager
  }

  /// Backstop for the abnormal-dismiss path: if the owning view is dropped
  /// without `.onDisappear` firing (memory pressure, scene yank, fullScreenCover
  /// host removed), `endSession()` never runs and the WebSocket / audio
  /// session / capture session keep going until ARC catches up. The happy
  /// path still tears down via `endSession()` first; this only fires when
  /// that didn't happen.
  ///
  /// Capturing services by value (concrete reference types) keeps them
  /// alive long enough for the heap-allocated `Task` to run. Cancelling
  /// `cameraLifecycleTask` is critical — without it, a setup-in-flight
  /// closure spins up a new `IPhoneCameraCapture` even after the VM is
  /// gone, and the deinit-time `cam` would be nil when that camera is
  /// finally born.
  deinit {
    let task = cameraLifecycleTask
    let svc = geminiService
    // Never stop a BORROWED persistent session from deinit — the coordinator
    // owns it and other runtimes will reuse it. Only the legacy per-session
    // manager is torn down here.
    let audio = (externalAudioManager == nil) ? audioManager : nil
    let cam = iPhoneCamera
    task?.cancel()
    Task { @MainActor in
      svc?.disconnect()
      audio?.stopCapture()
      await cam?.stop()
    }
  }

  // MARK: - Template-method hooks (override in subclass)

  /// Payload returned by the subclass's initial REST call. Carries the
  /// session id + ephemeral token + anything the subclass needs to stash
  /// (e.g. coaching keeps the procedure for the current-step computed property).
  struct SessionStartPayload {
    let sessionId: String
    let ephemeralToken: EphemeralTokenResponse
  }

  /// Subclass hits the mode's `POST /session/start` endpoint, returns
  /// session id + ephemeral token. Called once from `startGeminiLiveSession`.
  func mintSession() async throws -> SessionStartPayload {
    fatalError("GeminiLiveSessionBase.mintSession() must be overridden")
  }

  /// URL suffix for POST tool-call forwarding. Default targets the learner
  /// namespace; diagnostic overrides with `/api/troubleshoot/...`.
  var toolCallURLSuffix: String {
    guard let sid = sessionId else { return "/api/learner/session//tool-call" }
    return "/api/learner/session/\(sid)/tool-call"
  }

  /// Round-trip timeout for tool-call forwarding. Coaching's three tools
  /// return in <1s; diagnostic's `generate_sop_from_manual` takes 30-60s
  /// for PDF ingest.
  var toolCallTimeoutSeconds: TimeInterval { 10 }

  /// First synthetic user turn seeded on the initial `.connected` transition.
  /// Returning nil skips the seed (the user must speak first).
  var introSeedText: String? { nil }

  /// Fires after the base's `onTurnComplete` bookkeeping. Coaching uses this
  /// to reschedule heartbeats; other modes leave it as a no-op.
  func onTurnCompleteExtra() async {}

  /// Fired on the MainActor for every encoded JPEG frame handed to the Live
  /// service (both transports), regardless of the send gate. Coaching taps
  /// this to cache the latest frame for the server-side visual oracle so it
  /// can reuse the existing capture pipeline rather than a second camera.
  /// Default no-op.
  func onEncodedFrame(_ jpeg: Data) {}

  /// Called after every tool call completes. Subclass updates its
  /// mode-specific state (step index, phase, resolution, etc.) before the
  /// tool-response ACK is sent back to Gemini. Runs on @MainActor so state
  /// mutations are safe.
  func handleToolCallExtras(name: String, args: [String: Any], result: [String: Any]) async {}

  /// Whether a tool call should flush queued AI playback (`clearPlaybackBuffer`)
  /// so a half-spoken reply doesn't continue over the next turn. Default `true`
  /// — Coaching keeps this behavior unchanged in every state, including the
  /// Mac-route demo. Troubleshoot overrides it to skip the flush in the
  /// push-to-talk demo: it fires tool calls (identify/confirm/search) back-to-back
  /// while the AI is still narrating, and with the mic gated closed by push-to-talk
  /// there's no open-mic self-echo for the flush to defend against — so flushing on
  /// every tool call only chops the AI's voice (and, in the AEC-off demo graph, can
  /// leave the player stopped → total silence). Barge-in (line ~499) and the
  /// Talk-button flush (line ~341) are unaffected.
  var flushPlaybackOnToolCall: Bool { true }

  /// Audio-session mode for the current transport. Coaching picks
  /// `.coaching` with HFP glasses or `.coachingPhoneOnly` with iPhone.
  /// Default `.coachingPhoneOnly` works for iPhone-only modes.
  var audioSessionMode: AudioSessionMode { .coachingPhoneOnly }

  /// Which camera transport to drive. Default iPhone. Coaching overrides
  /// to its stored `transport` property.
  var transport: CaptureTransport { .iPhone }

  /// Whether this session streams camera frames to Gemini. Default true.
  /// Audio-only modes (Ask AI) override to false so the camera/lens branch is
  /// never launched — the model only hears the user. The HFP mic + Display
  /// lens are unaffected (those come up independently of the camera Stream).
  var streamsCameraToGemini: Bool { true }

  /// Context summary injected after a successful resumption reconnect.
  /// Coaching fetches the learner-session summary; other modes return nil
  /// (the reconnect still happens, just without the re-orient).
  func contextSummaryForReconnect() async -> String? { nil }

  /// Wrapping text around the summary when re-injecting on a resumption
  /// reconnect. Default matches the original learner wording. Subclasses
  /// can override for mode-specific phrasing.
  func resumptionInjectText(summary: String) -> String {
    return "Session resumed after a brief interruption. Current coaching context:\n\(summary)"
  }

  /// Called at the very top of `stopGeminiLiveSession`, BEFORE the base's
  /// teardown sequence. Coaching uses this to cancel its heartbeat scheduler
  /// before Combine subs drop (so an in-flight Task.sleep can't wake up
  /// into a half-torn-down service).
  func willStopGeminiLiveSession() {}

  /// Called at the very end of `stopGeminiLiveSession`, after all services
  /// have been nilled. Subclass hook for any final mode-local cleanup.
  func didEndSession() {}

  // MARK: - Public control

  func toggleMute() {
    setMuted(!isMuted)
  }

  func setMuted(_ muted: Bool) {
    guard isMuted != muted else { return }
    isMuted = muted
    recomputeSendGate()
    if isMuted {
      voiceStatus = "Muted"
      userInputPeak = 0
    } else if geminiConnectionState == .connected {
      voiceStatus = isTalkEngaged ? "Talking…" : idleListeningStatus
    }
  }

  /// Single source of truth for the mic send gate. Normal mode: mute controls
  /// everything. Push-to-talk mode: send only while Talk is engaged and not muted.
  func recomputeSendGate() {
    isSendingAudio = isPushToTalkActive ? (isTalkEngaged && !isMuted) : !isMuted
  }

  /// Status shown when connected, unmuted, and the AI isn't speaking.
  var idleListeningStatus: String {
    isPushToTalkActive ? "Tap or hold to talk" : "Listening"
  }

  // MARK: - Push-to-talk control (called from the Talk capsule's gestures)

  /// Touch-down on Talk: open the mic and take the floor. No-op while muted
  /// (Mute is a hard override) or when PTT isn't active.
  func talkPressBegan() {
    guard isPushToTalkActive, !isMuted else { return }
    talkCloseGeneration += 1            // cancel any pending release tail
    talkPressStartedAt = Date()
    audioManager?.clearPlaybackBuffer(reason: "push-to-talk")  // interrupt AI, take floor
    isTalkEngaged = true
    recomputeSendGate()
    voiceStatus = "Talking…"
  }

  /// Touch-up on Talk. A quick tap (<300 ms) toggles a latch; a longer hold is
  /// momentary and stops on release.
  func talkPressEnded() {
    // No-op while muted (the matching press was also a no-op) or when PTT is off.
    guard isPushToTalkActive, !isMuted else { return }
    let held = talkPressStartedAt.map { Date().timeIntervalSince($0) } ?? 0
    talkPressStartedAt = nil
    if held < 0.3 {                     // quick tap → toggle latch
      isTalkLatched.toggle()
      if isTalkLatched {
        isTalkEngaged = true
        recomputeSendGate()
        voiceStatus = "Talking…"
        return
      }
    }
    isTalkLatched = false
    endTalk()                           // momentary release, or tap-to-unlatch
  }

  /// End the user's turn: keep the gate open a short tail so in-flight audio
  /// flushes, then close it and send `audioStreamEnd` so Gemini's automatic VAD
  /// finalizes the turn and replies immediately (just stopping the byte stream
  /// is unreliable — auto VAD often never endpoints). A re-press bumps
  /// `talkCloseGeneration` and cancels this close.
  private func endTalk(_ tail: TimeInterval = 0.2) {
    talkCloseGeneration += 1
    let gen = talkCloseGeneration
    voiceStatus = "…"
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64(tail * 1_000_000_000))
      guard self.talkCloseGeneration == gen else { return }  // re-engaged → abort
      self.isTalkEngaged = false
      self.recomputeSendGate()                               // stop sending audio
      try? await self.geminiService?.sendAudioStreamEnd()    // force turn end → reply
      if self.geminiConnectionState == .connected, !self.isMuted {
        self.voiceStatus = self.idleListeningStatus
      }
    }
  }

  func retryGemini() {
    Task { await reconnectWithResumption(reason: "user retry") }
  }

  /// Forward a new interface orientation to the iPhone capture preview
  /// (glasses transport is a no-op). Keeps the Gemini-facing JPEG pipeline
  /// portrait-normalized — only the on-screen preview rotates.
  func setPreviewInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
    pendingPreviewOrientation = orientation
    iPhoneCamera?.setPreviewInterfaceOrientation(orientation)
  }

  /// Re-run `startGeminiLiveSession()` after the user granted DAT
  /// glasses permissions (camera + mic) via the recovery sheet on the
  /// session view. Safe to call from the sheet's `onGranted` callback
  /// because the prior gate failure returned before any state was
  /// initialized (no audio, no camera, no Gemini service exist yet) —
  /// so this is a clean restart, not a resume.
  func retryAfterPermissionGrant() async {
    pendingGlassesPermissions = false
    await startGeminiLiveSession()
  }

  /// Re-run `startGeminiLiveSession()` after the user taps "Try again"
  /// on the audio recovery sheet. Same reasoning as
  /// `retryAfterPermissionGrant` — the audio readiness check fails
  /// late enough that an `AudioSessionManager` was created and
  /// `startCapture()` was called, but a fresh `startGeminiLiveSession`
  /// will tear that down by creating a new one (the existing reference
  /// is overwritten). No leak.
  func retryAfterAudioFailure() async {
    pendingAudioRetry = false
    await startGeminiLiveSession()
  }

  /// Re-run `startGeminiLiveSession()` after the user updated the DAT
  /// helper app on their glasses via Meta AI.
  ///
  /// Unlike `retryAfterPermissionGrant` / `retryAfterAudioFailure` (which
  /// abort in the prologue, before audio or Gemini exist, so a bare restart
  /// is clean), the DAT-helper signal now arrives from the BACKGROUNDED
  /// camera/lens branch — which can flip `pendingDATHelperUpdate` after audio
  /// is live and the Gemini socket is already connected. Restarting on top of
  /// that would stand up a second `AudioSessionManager` + Gemini service, so
  /// tear the live session (and any in-flight camera lease) down first, then
  /// restart clean. `stopCameraStream` chains onto `cameraLifecycleTask`, so
  /// the fresh `setupCameraStream` serializes safely behind this teardown.
  func retryAfterDATHelperUpdate() async {
    pendingDATHelperUpdate = false
    stopGeminiLiveSession()
    stopCameraStream()
    await startGeminiLiveSession()
  }

  // MARK: - Readiness gates

  /// Await proof that the camera pipeline is delivering data — used by
  /// `setupCameraStream` / `setupIPhoneCameraStream` after the setup Task
  /// completes successfully. Returns `true` if a frame arrived within the
  /// timeout, `false` otherwise. Idempotent w.r.t. early arrival: if a
  /// frame landed before this method was called, `firstFrameSeen` will
  /// already be true and we return immediately.
  ///
  /// The continuation pattern (instead of polling a `@Published` bool)
  /// avoids both busy-wait CPU and the SwiftUI runloop tax of a bound
  /// `@Published` flip we don't otherwise need to observe.
  @MainActor
  private func awaitCameraReady(timeout: TimeInterval) async -> Bool {
    if firstFrameSeen {
      firstFrameSeen = false
      return true
    }
    return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
      self.firstFrameContinuation = cont
      // Strong self capture. While the continuation is suspended the
      // awaiter (a method call on self) already retains self, so this
      // doesn't extend lifetime in normal use. It defends against any
      // future refactor that could call this from outside an instance-
      // method context: with `[weak self]`, a nil self at watchdog-fire
      // time would skip the resume and leave the continuation hanging
      // forever (CheckedContinuation contract: must resume exactly once).
      Task { @MainActor [self] in
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        if let pending = self.firstFrameContinuation {
          self.firstFrameContinuation = nil
          pending.resume(returning: false)
        }
      }
    }
  }

  /// Audio analogue of `awaitCameraReady`. Returns `true` if the first
  /// PCM buffer arrived from the active `AudioSessionManager` within the
  /// timeout, `false` otherwise.
  @MainActor
  private func awaitAudioReady(timeout: TimeInterval) async -> Bool {
    if firstMicBufferSeen {
      firstMicBufferSeen = false
      return true
    }
    return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
      self.firstMicBufferContinuation = cont
      // Strong self capture — same reasoning as `awaitCameraReady`.
      Task { @MainActor [self] in
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        if let pending = self.firstMicBufferContinuation {
          self.firstMicBufferContinuation = nil
          pending.resume(returning: false)
        }
      }
    }
  }

  /// Tear down JUST the camera path (and its DSM lease) without touching
  /// audio, Gemini, or any per-session bookkeeping. Used by
  /// `startGeminiLiveSession` to clean up when `mintSession` fails after
  /// the camera came up successfully — otherwise we'd leave an orphaned
  /// DAT session + stream alive until the next teardown.
  ///
  /// Implementation note: `stopCameraStream()` is fire-and-forget by
  /// design (chains onto `cameraLifecycleTask`). Here we explicitly
  /// await that chain so the caller knows the camera is fully released
  /// before it returns and the audio/Gemini cleanup proceeds.
  private func teardownCameraOnly() async {
    stopCameraStream()
    await cameraLifecycleTask?.value
  }

  // MARK: - Session lifecycle

  /// Brings up audio + camera + WebSocket and wires callbacks. Called by
  /// the subclass's public `startSession(...)` after it has reset its own
  /// mode-specific state.
  ///
  /// Strict sequential order — the Gemini WebSocket cannot open until
  /// camera + audio are both confirmed running. Prior behavior fired
  /// camera setup as a concurrent fire-and-forget Task and connected
  /// Gemini regardless; a silent camera failure (e.g. missing DAT camera
  /// permission) then left us in a Gemini Live session with audio-only,
  /// which is the worst failure mode because the model behaves as if it
  /// has vision when it doesn't.
  func startGeminiLiveSession() async {
    // Native lens stays gated until audio + camera are confirmed up (see
    // `isReadyForNativeLens`). Reset here so a restart re-arms the gate.
    isReadyForNativeLens = false
    // Fresh session, fresh camera-failure episode.
    cameraHealth = .ok
    showCameraLostAlert = false
    // 0. DAT camera permission gate (glasses transport only). Per the
    //    DAT 0.7 contract, devices don't appear in `wearables.devices`
    //    until `Permission.camera` is granted via Meta AI — so without
    //    this the camera setup would later fail with `noEligibleDevice`
    //    regardless of how patiently we wait. Non-prompting check: the
    //    prompt belongs in onboarding (eager) or a Profile CTA (opt-in).
    //    Mid-session-start bouncing to Meta AI would be jarring.
    if transport == .glasses {
      do {
        // DAT camera permission is the gate that unlocks `wearables.devices`.
        // Microphone access is iOS-native (not in MWDATCore.Permission) and
        // is prompted separately in step 1 below.
        let granted = try await sessionManager.allGlassesPermissionsGranted()
        guard granted else {
          voiceStatus = "Camera access needed"
          pendingGlassesPermissions = true
          print("[GeminiLive] DAT camera permission not granted — aborting session start, surfacing recovery sheet")
          return
        }
      } catch {
        voiceStatus = "Permission check failed"
        pendingGlassesPermissions = true
        print("[GeminiLive] DAT permission check threw: \(error) — surfacing recovery sheet")
        return
      }
    }

    // 1. Audio — pick the mode based on transport override, request iOS
    //    mic, start capture, AND wait for the first PCM buffer so we
    //    know the mic pipeline is actually delivering data — not just
    //    that AVAudioEngine started without throwing. The BT HFP path
    //    with glasses can take time to carry audio over the SCO link,
    //    and Gemini connecting in that window leaves us with an open
    //    socket that hears nothing — the audio analogue of the silent
    //    camera-failure mode we're also fixing.
    let audio: AudioSessionManager
    if let external = externalAudioManager {
      // BORROW (glasses-native persistent audio): the session is already armed
      // by `GlassesNavigationCoordinator` — HFP is up and the engine is running
      // and delivering buffers. Skip create / configure / HFP-warmup /
      // startCapture entirely; just adopt it and attach this runtime's endpoint
      // closures below (step 5). This is the whole point of the persistent path:
      // no per-runtime HFP re-arm, so no Display↔HFP radio race on restart.
      audio = external
      self.audioManager = audio
      voiceStatus = "Starting audio..."
      print("[GeminiLive] Borrowing persistent glasses audio (no re-arm)")
    } else {
      audio = AudioSessionManager(mode: audioSessionMode)
      self.audioManager = audio

      // Glasses transport: hand the audio layer the paired-glasses names so it
      // can pin the glasses' BT HFP input over any other connected HFP device
      // (e.g. AirPods). Set before `configureSessionOnly()` so the pin is in
      // place before the HFP warmup brings up the SCO link.
      if transport == .glasses {
        audio.preferredGlassesNames = DeviceSessionManager.pairedDeviceNames(from: wearables)
      }

      let micGranted = await audio.requestMicrophonePermission()
      guard micGranted else {
        voiceStatus = "Mic denied"
        print("[GeminiLive] Microphone permission denied")
        audioManager = nil
        return
      }

      // Temporary first-buffer detector. Replaced in step 5 with the real
      // gemini-forwarding closure; until then this is the only listener
      // and the only thing it does is resume the readiness continuation.
      firstMicBufferSeen = false
      audio.onAudioBuffer = { [weak self] _, _ in
        Task { @MainActor [weak self] in
          guard let self = self else { return }
          if let pending = self.firstMicBufferContinuation {
            self.firstMicBufferContinuation = nil
            pending.resume(returning: true)
          } else {
            self.firstMicBufferSeen = true
          }
        }
      }
      voiceStatus = "Starting audio..."
      // HFP warmup per Meta's official iOS sample at
    // https://wearables.developer.meta.com/docs/develop/dat/microphones-and-speakers#ios-sample-code:
    // "When planning to use HFP and streaming simultaneously, ensure
    // that HFP is fully configured before initiating any streaming
    // session that requires audio functionality." Without it,
    // `engine.start()` on the glasses BT HFP path returns success but
    // `isRunning` flips false (the input audio unit attaches to a
    // half-negotiated route and bails) — the silent-mic failure we saw
    // in the diagnostic dump.
    //
    // We split the single `startCapture()` into three steps:
    //   1. `configureSessionOnly()` — setCategory + setActive + pin glasses
    //   2. `awaitHFPRouteReady(timeout:)` — EVENT-DRIVEN wait for the BT SCO
    //      link to actually come up (resolved off the AVAudioSession route-
    //      change notification), replacing the old fixed 2 s sleep. Returns
    //      as soon as the glasses HFP route is the active input with a
    //      settled format — usually well under the ceiling, immediately on a
    //      warm reuse. The 2 s ceiling is the upper bound only, so this can
    //      only be faster than the old constant, never slower; on the rare
    //      timeout the downstream first-buffer wait below is the backstop.
    //   3. `startCapture()` — engine setup (skips its own configure step
    //      via the `didConfigureSession` guard)
    audio.configureSessionOnly()
    if transport == .glasses {
      _ = await audio.awaitHFPRouteReady(timeout: 2.0)
    }
    audio.startCapture()
    // 8 s readiness timeout is the safety net — if the HFP warmup
    // wasn't enough on this device/cycle, the recovery sheet still
    // surfaces and the user can retry.
    let audioReady = await awaitAudioReady(timeout: 8.0)
    // Clear the temp closure either way — step 5 installs the real one,
    // and on failure we don't want a stale first-buffer hook left behind.
    audio.onAudioBuffer = nil
    guard audioReady else {
      voiceStatus = "Audio not connecting"
      pendingAudioRetry = true
      print("[GeminiLive] Mic capture did not deliver a buffer within 8 s — aborting session start, surfacing audio recovery sheet")
      // Single-shot diagnostic dump. Tap delivers ~64 ms-spaced silent
      // buffers when the route is genuinely capturing, so 8 s of zero
      // buffers means the system is broken below the user-input layer.
      // Dump every state that could explain it (VPIO engagement, route
      // contents, system mute flags, etc.) so we can identify the
      // root cause without instrumenting more code.
      print(audio.dumpAudioDiagnostics())
      audio.stopCapture()
      audioManager = nil
      return
      }
    }

    // 2. Camera / lens — launched in the BACKGROUND so neither the voice
    //    connection nor the on-glasses lens HUD waits on the 3–15 s DAT
    //    camera handshake (DeviceSession acquire + Stream attach + first
    //    frame). This used to run inline before the Gemini connect, putting
    //    the slowest BT step squarely on the path to "ready to talk".
    //
    //    Audio (and therefore the glasses HFP route) is confirmed up by this
    //    point, so it's now safe to bring up the glasses Stream + Display BT
    //    capabilities — the documented HFP-before-Display coexistence order
    //    (see `isReadyForNativeLens`). The Gemini connect below runs
    //    concurrently with this branch; the lens HUD comes up as soon as the
    //    shared DeviceSession reaches `.started` (flipped inside
    //    `setupCameraStream`), NOT when the first video frame arrives — the
    //    lens renderer draws from coaching state + server URLs, not frames.
    //    Visual auto-advance comes online later, when frames actually flow.
    //
    //    A camera failure here is NON-FATAL: voice coaching keeps running.
    //    The one actionable case (DAT helper app out of date) still surfaces
    //    its recovery sheet via `pendingDATHelperUpdate` from inside the
    //    setup task. Generic acquire/stream failures are logged and leave
    //    voice-only coaching running rather than killing a live session.
    launchCameraLensBranch()

    // 3. Mint session via subclass.
    voiceStatus = "Starting session..."
    let payload: SessionStartPayload
    do {
      payload = try await mintSession()
    } catch {
      voiceStatus = "Session error"
      print("[GeminiLive] Failed to mint session: \(error)")
      audio.stopCapture()
      audioManager = nil
      // The background camera/lens branch may already have flipped the lens
      // gate when its DeviceSession reached `.started`; reset it so the view
      // doesn't try to activate a lens against the session we're tearing down.
      isReadyForNativeLens = false
      await teardownCameraOnly()
      return
    }
    self.sessionId = payload.sessionId

    // 4. Token manager.
    let tm = GeminiTokenManager(
      sessionId: payload.sessionId,
      serverBaseURL: serverBaseURL
    )
    await tm.setInitialToken(payload.ephemeralToken)
    self.tokenManager = tm

    // 5. Gemini Live service + shared callbacks.
    let gemini = GeminiLiveService(tokenManager: tm)
    self.geminiService = gemini

    gemini.onAudioData = { [weak self] data in
      guard let self = self else { return }
      // Suppress inbound Gemini speech while a reference clip is playing.
      // `setReferenceClipPlaying(true)` flushes already-queued buffers via
      // `clearPlaybackBuffer`; this guard stops *new* chunks from a turn
      // that's still streaming server-side from being scheduled, so Gemini
      // can't talk over the clip even mid-utterance. Mirrors the off-thread
      // flag reads on the mic/video send gates.
      if self.isClipPlaying { return }
      self.audioManager?.playPcm16Audio(data)
    }

    gemini.onTurnComplete = { [weak self] in
      Task { @MainActor in
        guard let self = self else { return }
        self.isAISpeaking = false
        self.assistantTurnOpen = false
        self.learnerTurnOpen = false
        if !self.isMuted, !self.isTalkEngaged {
          self.voiceStatus = self.idleListeningStatus
        }
        await self.onTurnCompleteExtra()
      }
    }

    gemini.onToolCall = { [weak self] id, name, args in
      Task { @MainActor in
        await self?.handleToolCall(id: id, name: name, args: args)
      }
    }

    gemini.onInputTranscript = { [weak self] text in
      Task { @MainActor in
        self?.appendTranscript(kind: .learner, delta: text)
      }
    }

    gemini.onOutputTranscript = { [weak self] text in
      Task { @MainActor in
        self?.appendTranscript(kind: .assistant, delta: text)
      }
    }

    gemini.onResumptionUpdate = { [weak self] handle in
      Task { @MainActor in
        self?.resumptionHandle = handle
      }
    }

    gemini.onGoAway = { [weak self] timeLeft in
      Task { @MainActor in
        await self?.reconnectWithResumption(reason: "goAway (timeLeft=\(timeLeft)s)")
      }
    }

    gemini.onInterrupted = { [weak self] in
      Task { @MainActor in
        print("[GeminiLive] Barge-in → clearing playback buffer")
        self?.audioManager?.clearPlaybackBuffer(reason: "barge-in")
      }
    }

    observeGeminiConnectionState(gemini)

    // Audio mic-tap → Gemini (same three-gate check as before).
    audio.onAudioBuffer = { [weak self] buffer, _ in
      guard let self = self else { return }
      let sendingOk = self.isSendingAudio
      let noTool = self.pendingToolCallIds.isEmpty
      let ready = self.isGeminiReady
      let noClip = !self.isClipPlaying
      let gateOpen = sendingOk && noTool && ready && noClip

      if gateOpen != self.audioGateWasOpen {
        self.audioGateWasOpen = gateOpen
        if gateOpen {
          print("[GeminiLive] Audio send gate OPEN — mic → Gemini live")
        } else {
          let reason: String
          if !ready { reason = "Gemini not ready" }
          else if !noTool { reason = "pending tool call" }
          else if !noClip { reason = "reference clip playing" }
          else { reason = "muted" }
          print("[GeminiLive] Audio send gate CLOSED — \(reason)")
        }
      }

      guard gateOpen else { return }
      guard let pcmData = self.audioManager?.convertBufferForSend(buffer) else { return }

      Task {
        try? await self.geminiService?.sendAudio(pcmData)
      }
    }

    // In push-to-talk (demo) mode the session must start NOT sending — the mic
    // opens only while the Talk button is engaged.
    recomputeSendGate()

    // 6. Connect. Setup-complete flips state to .connected inside the service;
    // our observer (below) picks that up and gates the audio send path open.
    // Audio capture is already running (step 1) — no second start.
    voiceStatus = "Connecting..."
    await gemini.connect()

    // Mirror audio manager's isAISpeaking onto the VM via Combine.
    observeAudioIsAISpeaking(audio)
  }

  /// Silence / un-silence the Gemini loop around native-lens reference-clip
  /// playback. Flips `isClipPlaying` (which all three send gates AND the
  /// inbound `onAudioData` handler read) and, on start, flushes any
  /// already-queued Gemini speech via `clearPlaybackBuffer`. Together those
  /// stop the model the instant the clip takes over: the flush kills queued
  /// buffers, and the `onAudioData` guard drops new chunks from a turn still
  /// streaming server-side, so Gemini can't resume over the clip. Idempotent.
  /// Driven only from the native-lens clip lifecycle (`CoachingLensRenderer`),
  /// paired with the clip's start (`onStarted`) and terminal (`onEnded`/
  /// `onError`) events so the gate can't latch open or closed.
  ///
  /// The glasses camera Stream is deliberately LEFT RUNNING during the clip:
  /// on DAT 0.8 video rides the WiFi link, not the BT radio the clip's audio
  /// uses, so there's no contention to relieve by stopping it. The send gates
  /// (`!isClipPlaying`) already keep those frames from reaching Gemini, so the
  /// model stays blind/silent without a stop→restart cycle.
  @MainActor
  func setReferenceClipPlaying(_ playing: Bool) {
    guard isClipPlaying != playing else { return }
    isClipPlaying = playing
    if playing {
      audioManager?.clearPlaybackBuffer(reason: "reference-clip-start")
    }
  }

  /// Canonical teardown order — see inline comments. Order matters:
  ///   1. Close audio send gate so mic closures stop queueing into a dying WS.
  ///   2. Drop Combine subs so no state handler re-enters mid-teardown.
  ///   3. Stop audio capture BEFORE disconnecting Gemini — no races on WS close.
  ///   4. Disconnect Gemini, then nil services so callbacks can't reach a dead socket.
  ///   5. Wipe per-session state so subsequent startSession() starts clean.
  func stopGeminiLiveSession() {
    willStopGeminiLiveSession()
    isSendingAudio = false
    isGeminiReady = false
    audioGateWasOpen = false
    isClipPlaying = false
    cancellables.removeAll()

    if externalAudioManager != nil {
      // BORROWED persistent session: detach only THIS runtime's endpoints and
      // leave the HFP pipeline running for the next runtime. Tearing it down
      // here would re-introduce the per-runtime arm/teardown race we removed.
      audioManager?.onAudioBuffer = nil
      audioManager?.clearPlaybackBuffer(reason: "runtime-detach")
    } else {
      audioManager?.stopCapture()
    }
    geminiService?.disconnect()

    geminiService = nil
    audioManager = nil
    tokenManager = nil
    sessionId = nil
    pendingToolCallIds.removeAll()
    pendingToolCallNames.removeAll()
    learnerTurnOpen = false
    assistantTurnOpen = false
    resumptionHandle = nil
    isResuming = false
    hasSeededIntro = false
    voiceStatus = "Ended"
    geminiConnectionState = .disconnected
    isReadyForNativeLens = false
    cameraHealth = .ok
    showCameraLostAlert = false

    didEndSession()
  }

  // MARK: - Camera Stream (glasses via DAT SDK)

  /// Fire-and-forget the camera/lens pipeline so it can't block the voice
  /// connection or the lens HUD. Called from `startGeminiLiveSession` once
  /// audio is confirmed up (the glasses HFP route must settle before the
  /// Stream/Display BT capabilities start). The heavy lifting still runs
  /// inside `setupCameraStream` / `setupIPhoneCameraStream` (which serialize
  /// on `cameraLifecycleTask`, so a rapid dismiss/restart can't race two
  /// streams, and `stopCameraStream` / `deinit` cancel it cleanly).
  ///
  /// Failure is intentionally NON-FATAL — a backgrounded camera that never
  /// comes up must not tear down a live voice session. The actionable
  /// DAT-helper-out-of-date case already raised `pendingDATHelperUpdate`
  /// from inside the setup task; everything else is logged so coaching
  /// continues voice-only (visual auto-advance + lens HUD simply unavailable).
  private func launchCameraLensBranch() {
    // Re-arm the per-attach lens-availability notice; the branches below flip it
    // true only if the lens was wanted but the glasses can't display it.
    glassesLensUnavailable = false
    // Audio-only sessions (Ask AI) never bring up a camera Stream — the model
    // only hears the user. They STILL need the glasses Display lens, though:
    // the camera branch below is normally the only place that acquires the
    // shared DeviceSession and flips `isReadyForNativeLens`, so an audio-only
    // session would otherwise leave the lens dark (the glasses fall back to the
    // Meta OS home screen). Bring up a Display-only session instead.
    guard streamsCameraToGemini else {
      print("[GeminiLive] audio-only session — bringing up Display-only lens session")
      bringUpDisplayOnlyLensSession()
      return
    }
    Task { [weak self] in
      guard let self = self else { return }
      let ok: Bool
      switch self.transport {
      case .glasses:
        ok = await self.setupCameraStream()
      case .iPhone:
        ok = await self.setupIPhoneCameraStream()
      }
      if !ok {
        // Startup stall: setup failed outright, or the stream came up at the
        // control level but never delivered a frame within the 30s ceiling —
        // the "started-but-dead media path" zombie (WARP receiver never
        // activated / RTP depacketizer missing stream info). Silently
        // continuing voice-only here used to pin the zombie under our lease
        // forever; the failure sink invalidates it (unpinning it for the next
        // acquire) and surfaces the alert + banner so the user knows Gemini
        // can't see and can retry.
        print("[GeminiLive] Camera/lens branch did not come up — surfacing camera failure (voice continues)")
        self.handleCameraBranchFailure(
          reason: self.cameraSetupFailed
            ? "camera setup failed" : "no first frame within 30s of stream start")
      }
    }
  }

  /// Audio-only runtimes (Ask AI) skip the camera `Stream` but still need the
  /// glasses Display lens. The camera branch is normally the only place that
  /// acquires the shared `DeviceSession` and flips `isReadyForNativeLens`, so
  /// without this an audio-only session leaves the lens dark — the glasses fall
  /// back to the Meta OS home screen. Acquire a Display-capable session WITHOUT
  /// attaching a `Stream`, then flip the gate. Same contract as the camera path
  /// (`setupCameraStream`): the shared session is `.started` when the gate
  /// flips, so the host re-attaches the lens last, AFTER HFP has settled (this
  /// runs in step 2 of `startGeminiLiveSession`, post-`awaitHFPRouteReady`),
  /// preserving the documented HFP-before-Display order. Reuses the
  /// `"gemini-live"` consumer label so `stopCameraStream`'s unconditional
  /// `release("gemini-live")` tears it down symmetrically — no extra teardown.
  private func bringUpDisplayOnlyLensSession() {
    guard transport == .glasses else { return }
    guard sessionManager.hasDisplayCapableDevice else {
      print("[GeminiLive] Display-only lens session skipped (no display-capable device)")
      // Audio-only runtimes always want the lens; connected glasses can't
      // display it → surface the camera-only / no-lens notice.
      glassesLensUnavailable = true
      return
    }
    Task { [weak self] in
      guard let self = self else { return }
      do {
        let acquired = try await self.sessionManager.acquire(
          consumerLabel: "gemini-live", requirements: .requiresDisplay)
        print("[GeminiLive] Display-only lens session acquired: state=\(acquired.state) deviceId=\(acquired.deviceId)")
        self.deviceSession = acquired
        await MainActor.run { self.isReadyForNativeLens = true }
      } catch DeviceSessionManager.AcquireError.sessionStartFailed(.datAppOnTheGlassesUpdateRequired) {
        // Same dedicated recovery path as the camera branch.
        print("[GeminiLive] Display-only lens session → datAppOnTheGlassesUpdateRequired; surfacing recovery sheet")
        await MainActor.run { self.pendingDATHelperUpdate = true }
      } catch {
        // Non-fatal: the voice session continues audio-only, just without a lens.
        print("[GeminiLive] Display-only lens session failed — audio-only, no lens: \(error)")
      }
    }
  }

  /// Bring up the glasses camera path end-to-end. Returns `true` once a
  /// video frame has actually arrived from the DAT `Stream` capability,
  /// or `false` on setup failure / first-frame timeout. The function is
  /// awaited by `startGeminiLiveSession` step 3 — the Gemini WebSocket
  /// cannot open until this resolves true.
  ///
  /// Internally the heavy lifting still runs inside a Task chained onto
  /// `cameraLifecycleTask` so a rapid stop / restart still serializes
  /// safely (the lifecycle task is reused by `stopCameraStream` to await
  /// any in-flight setup). The outer wrapper layers the first-frame wait
  /// on top of the lifecycle task.
  @discardableResult
  func setupCameraStream() async -> Bool {
    // Reset the per-attach readiness signals so a previous session's
    // `true` can't satisfy this wait. Must happen on MainActor before
    // any frame listener could fire, since the listener resumes on the
    // same actor.
    firstFrameSeen = false
    cameraSetupFailed = false
    cameraStarvationSurfaced = false
    stopVideoWatchdog()
    if let pending = firstFrameContinuation {
      firstFrameContinuation = nil
      pending.resume(returning: false)
    }

    let prior = cameraLifecycleTask
    cameraLifecycleTask = Task { [weak self] in
      await prior?.value
      guard let self = self else { return }

      // Reset per-attach local state. The manager owns DeviceSession
      // lifecycle, so we only clear our derived per-attach objects here.
      self.handLandmarkerService?.stop()
      self.handLandmarkerService = nil
      self.glassesCoachingSource = nil
      self.glassesPreviewFrame = nil

      let session: DeviceSession
      let stream: MWDATCamera.Stream
      var adoptedFromLoan = false

      do {
        // The session is shared with any other active consumer (e.g. lens)
        // so adding capabilities here doesn't require a private DeviceSession.
        let manager = self.sessionManager
        do {
          // Intent-aware acquire: when a Display-capable device is reachable,
          // bias the camera path to `.requiresDisplay` so the shared
          // `DeviceSession` is guaranteed to land on the Display glasses.
          // Without this, in multi-paired setups (Display + Vanguard both
          // registered) the filterless selector's "first connected" tiebreak
          // could pick the non-display device — and the lens consumer would
          // then throw `requirementsConflictWithActiveSession`, leaving the
          // lens dark even though Display is present.
          //
          // When no Display is reachable, fall back to `.any` — that preserves
          // Step 13 behavior on non-display DAT glasses (Vanguard, regular RBM
          // Wayfarer/Skyler): they speak PSM 129 and support Stream + BT-HFP
          // audio, so Coaching + Troubleshoot still run with the phone-side
          // SwiftUI emulator as the UI.
          //
          // Trade-off (only when falling back to `.any`): if a Stories
          // peripheral is paired, the filterless selector will probe it
          // and log "Unknown error: 436 — No known channel matching peer
          // …". Console noise only, no functional regression.
          // Log the cached Local Network grant state (DAT 0.8's WiFi video
          // lease dies silently when denied). Deliberately NOT an active
          // probe: probing publishes + browses Bonjour with P2P enabled,
          // which would contend with the SDK's own WiFi link negotiation
          // happening right now. The active probe runs at app launch.
          Task { @MainActor in LocalNetworkPermission.shared.logStatus(context: "glasses-session-start") }

          let prefersDisplay = manager.hasDisplayCapableDevice
          let req: DeviceSessionManager.DeviceRequirements = prefersDisplay ? .requiresDisplay : .any
          print("[GeminiLive] acquire requirements=\(req) (hasDisplay=\(manager.hasDisplayCapableDevice))")
          let acquired = try await manager.acquire(consumerLabel: "gemini-live", requirements: req)
          print("[GeminiLive] acquire returned: deviceSession.state=\(acquired.state) deviceId=\(acquired.deviceId)")
          if let device = self.wearables.deviceForIdentifier(acquired.deviceId) {
            print("[GeminiLive] selected device: name=\(device.nameOrId()) type=\(device.deviceType().rawValue) supportsDisplay=\(device.supportsDisplay()) compatibility=\(device.compatibility())")
            let route = AVAudioSession.sharedInstance().currentRoute
            let inputs = route.inputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
            let outputs = route.outputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
            let lensWillRender = device.supportsDisplay()
            // Mode-differentiation notice: lens output is always on now, so on a
            // glasses session the lens is always wanted — fire the camera-only
            // notice purely on whether THESE glasses can display it, instead of
            // silently no-op'ing the lens. (Non-display Ray-Bans, mode 2/3.)
            await MainActor.run { self.glassesLensUnavailable = !lensWillRender }
            print("[GeminiLive] ════════ SESSION START VERIFICATION ════════")
            print("[GeminiLive]   transport       : glasses")
            print("[GeminiLive]   glasses model   : \(device.nameOrId())")
            print("[GeminiLive]   supportsDisplay : \(device.supportsDisplay())")
            print("[GeminiLive]   audio inputs    : [\(inputs)]")
            print("[GeminiLive]   audio outputs   : [\(outputs)]")
            print("[GeminiLive]   lens will render: \(lensWillRender) \(lensWillRender ? "(glasses display)" : "(phone emulator only)")")
            print("[GeminiLive] ═════════════════════════════════════════════")
          }
          // ⚠️ Resolution .high (720×1280) is LOAD-BEARING for the DAT 0.8
          // WiFi video transport — do NOT lower it for quality/token
          // reasons. Empirically verified 2026-07-01: with .medium the
          // stream intermittently starves after ~1 frame (Stream.state
          // stuck .streaming, no error, never recovers); with .high it
          // streams reliably. Matches MWDATCamera's own classification —
          // streams "require medium (BTC) or high (WiFi) bandwidth link":
          // a .medium stream is BT-class and gets stranded at the BT→WiFi
          // link boundary, while .high is WiFi-class from bring-up.
          // Also required: the Meta AI app's per-glasses "allow WiFi
          // connection" permission (glasses settings — undocumented).
          //
          // frameRate 2 is the SDK's lowest valid value ({2,7,15,24,30});
          // it's a Gemini token/latency budget, not a bandwidth setting —
          // the videoMinInterval = 1.0s throttle drops every other frame so
          // Gemini sees 1 fps net. Going above 2 fps would require
          // frameRate 7 here. Re-run the token math before raising either.
          // First-frame ramp-up at .high can reach ~10s; the 30s
          // awaitCameraReady ceiling covers it.
          //
          // Phone preview will display 2 fps (matches the DAT emit rate).
          // Camera loan (troubleshoot→coaching handoff): a donor VM left its
          // Stream running and its "gemini-live" lease held — the acquire
          // above just refreshed that same label-keyed lease. Adopt the live
          // stream instead of addStream+start: keeps the WiFi link + camera
          // alive across the handoff, and stopping + re-adding a Stream
          // back-to-back on a shared DeviceSession lands the successor on a
          // half-drained WARP pipe (one frame, then starvation).
          var loanedStream: MWDATCamera.Stream?
          if let loan = await MainActor.run(body: { Self.claimCameraLoan() }) {
            if loan.session.deviceId == acquired.deviceId, loan.stream.state == .streaming {
              print("[GeminiLive] adopted live camera stream from handoff (state=\(loan.stream.state)) — skipping addStream/start")
              loanedStream = loan.stream
            } else {
              // Stale loan: session replaced between deposit and claim, or the
              // loaned stream is no longer streaming (abandoned handoff, died
              // while parked). Adopting a dead stream = instant starvation —
              // best-effort stop and attach a fresh stream below.
              print("[GeminiLive] camera loan unusable (device loan=\(loan.session.deviceId) acquired=\(acquired.deviceId), streamState=\(loan.stream.state)) — retiring loan, attaching fresh stream")
              loan.stream.stop()
              // Drain anchor: stop→addStream back-to-back on a shared session
              // lands the successor on a half-drained WARP pipe (one frame,
              // then starvation) — the exact invariant stopCameraStream
              // protects everywhere else. Wait for .stopped + settle before
              // the fresh addStream below.
              await self.awaitStreamStopped(loan.stream, timeout: 2.0)
              try? await Task.sleep(nanoseconds: 300_000_000)
            }
          }

          if let adopted = loanedStream {
            session = acquired
            stream = adopted
            adoptedFromLoan = true
          } else {
            let config = StreamConfiguration(
              videoCodec: .raw,
              resolution: .high,
              frameRate: 2
            )
            guard let s = try acquired.addStream(config: config) else {
              print("[GeminiLive] Could not attach stream capability to the device session")
              await manager.release(consumerLabel: "gemini-live")
              await MainActor.run { self.cameraSetupFailed = true }
              return
            }
            session = acquired
            stream = s
          }
          // Lens HUD readiness: the shared DeviceSession is now `.started`
          // and the Stream capability is attached — that's all the native
          // lens needs to `addDisplay()` and render (it draws from coaching
          // state + server URLs, NOT camera frames). Flip the gate now so
          // the on-glasses HUD comes up at acquire time instead of waiting
          // the extra 0.5–10 s for the first video frame. Audio HFP is
          // already settled (this branch only runs after `awaitAudioReady`),
          // so this preserves the documented HFP-before-Display order.
          // Glasses-only: the iPhone path never sets this (no Display).
          await MainActor.run { self.isReadyForNativeLens = true }
        } catch DeviceSessionManager.AcquireError.sessionStartFailed(.datAppOnTheGlassesUpdateRequired) {
          // The DAT helper app on the glasses is out of date. Don't lump
          // this in with the generic "camera failed" path — the recovery
          // action is specific (update via Meta AI) and the user can act
          // on it, unlike most other camera failures. Mirrors
          // `LensDisplayCoordinator`'s typed catch on the same error.
          print("[GeminiLive] manager.acquire('gemini-live') → datAppOnTheGlassesUpdateRequired; surfacing recovery sheet")
          await MainActor.run { self.pendingDATHelperUpdate = true }
          return
        } catch {
          print("[GeminiLive] manager.acquire('gemini-live') threw — type=\(String(describing: type(of: error))) value=\(error)")
          if let acquireError = error as? DeviceSessionManager.AcquireError {
            switch acquireError {
            case .sessionStartFailed(let underlying):
              print("[GeminiLive]   AcquireError.sessionStartFailed underlying type=\(String(describing: type(of: underlying))) value=\(underlying)")
            case .requirementsConflictWithActiveSession(let req):
              print("[GeminiLive]   AcquireError.requirementsConflictWithActiveSession req=\(req)")
            case .permissionCheckFailed(let msg):
              print("[GeminiLive]   AcquireError.permissionCheckFailed message=\(msg)")
            case .noEligibleDevice, .startTimedOut, .cancelled, .cameraPermissionDenied:
              print("[GeminiLive]   AcquireError leaf case=\(acquireError)")
            }
          }
          print("[GeminiLive] manager.acquire('gemini-live') failed: \(error)")
          await MainActor.run { self.cameraSetupFailed = true }
          return
        }

        // Subscribe to the manager's session-error fan-out so a mid-session
        // DeviceSessionError (BT drop, thermal, peakPowerShutdown, DAT-app
        // update required) surfaces in our UI immediately instead of being
        // discovered only when the next tool call fails.
        self.sessionErrorsCancellable?.cancel()
        self.sessionErrorsCancellable = manager.sessionErrors
          .receive(on: DispatchQueue.main)
          .sink { [weak self] error in
            self?.handleCameraSessionError(error)
          }

        // Also react to a forced out-of-band invalidation (a sibling consumer —
        // lens / expert — detected the shared transport is dead via frame
        // starvation, which the SDK never surfaces as a `DeviceSessionError`).
        self.sessionInvalidatedCancellable?.cancel()
        self.sessionInvalidatedCancellable = manager.sessionInvalidated
          .receive(on: DispatchQueue.main)
          .sink { [weak self] reason in
            self?.handleSessionInvalidated(reason)
          }
      }

      self.deviceSession = session
      self.glassesStream = stream

      // Hand tracking is NEVER started on the glasses transport. The
      // Neural Band drives DAT input directly (FlexBox.onTap /
      // Button.onClick auto-routed by the SDK), so MediaPipe would just
      // burn CPU + frames competing with audio over the same BT pipe —
      // and the OpenGL/MediaPipe init concurrent with the Stream attach
      // is part of the camera-failure mode this fix addresses (see
      // Step 6b root cause). Gate kept as a function call rather than a
      // hard `return` so future flag flips on the helper take effect
      // uniformly across every start site.
      if HandGestureService.shouldStart(for: .glasses) {
        assertionFailure("shouldStart(for: .glasses) should always be false; helper logic regressed")
      } else {
        print("[GeminiLive] Hand tracking suppressed — glasses transport, input routes through Neural Band")
      }

      // Off-MainActor frame fan-out — mirrors the iPhone path
      // (`IPhoneCoachingCameraSource`). `HandLandmarkerService.submit(_:)`
      // is documented Sendable-safe; capture a local strong ref so the
      // Sendable closure can call it without re-reading the
      // `@MainActor`-isolated `self.handLandmarkerService` property.
      let handForSource = self.handLandmarkerService
      let source = GlassesCoachingFrameSource(
        minInterval: self.videoMinInterval,
        jpegQuality: self.videoJpegQuality,
        submitHand: { [weak handForSource] sampleBuffer in
          handForSource?.submit(sampleBuffer: sampleBuffer)
        },
        sendJpeg: { [weak self] jpeg in
          let gate = await MainActor.run { [weak self] () -> Bool in
            guard let self = self else { return false }
            // Cache the latest encoded frame for the visual oracle before the
            // send gate — the oracle wants the freshest frame even when video
            // send is gated (e.g. a tool call is in flight).
            self.onEncodedFrame(jpeg)
            return self.isGeminiReady && self.pendingToolCallIds.isEmpty && !self.isClipPlaying
          }
          guard gate else { return }
          try? await self?.geminiService?.sendVideoFrame(jpeg)
        },
        sendPreview: { [weak self] image in
          await MainActor.run { [weak self] in
            self?.glassesPreviewFrame = image
          }
        }
      )
      self.glassesCoachingSource = source

      // Wire stream-state observation so we can see in the console exactly
      // when the Stream capability transitions (.waitingForDevice → .starting
      // → .streaming) and any error events. Previously these were silent —
      // we only saw DeviceSession state but had no visibility into the
      // camera capability itself.
      //
      // Also: detect unexpected `.stopped` AFTER reaching `.streaming` and
      // surface as a connection-state error so the UI flips out of
      // "Listening…" the moment the BT pipe drops mid-session. Per the
      // documented Stream sequence (`mwdat-ios:camera-streaming`):
      //   stopped → waitingForDevice → starting → streaming → paused → stopped
      // — `.streaming → .stopped` without an intervening `.paused` means
      // the device/SDK dropped the capability (BT, thermal, the AudioSession
      // reorder bug Step 6b.1 fixed, etc.). We don't try to auto-resume;
      // the user taps Retry. The flag persists across listener invocations
      // because `statePublisher.listen` reuses the same closure scope.
      var sawStreaming = false
      self.stateListenerToken = stream.statePublisher.listen { [weak self] state in
        print("[GeminiLive] Stream.state → \(state)")
        if state == .streaming {
          sawStreaming = true
        } else if state == .stopped && sawStreaming {
          sawStreaming = false  // avoid re-firing on idempotent stops during teardown
          Task { @MainActor [weak self] in
            guard let self = self else { return }
            // A Stream-capability drop kills the camera, not the voice
            // socket — route to the camera failure sink (alert + banner +
            // camera-only retry) instead of the socket error state, whose
            // Reconnect can't fix a dead camera. Only while we still
            // believed the session was live (exit races land here after
            // teardown flips the state).
            if self.geminiConnectionState == .connected || self.geminiConnectionState == .connecting {
              self.handleCameraBranchFailure(reason: "stream dropped (.streaming → .stopped)")
            }
          }
        }
      }

      // Count incoming video frames so we can confirm the camera is actually
      // delivering data (vs. an attached-but-silent stream). On the very
      // first frame, hop to MainActor and resolve `firstFrameContinuation`
      // (or set `firstFrameSeen` if no continuation was installed yet —
      // covers the race where the frame arrives before the outer wrapper
      // begins its wait).
      var frameCountDiag = 0
      self.videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self, weak source] videoFrame in
        self?.stampVideoFrame()  // liveness stamp for the starvation watchdog
        frameCountDiag &+= 1
        if frameCountDiag == 1 {
          print("[GeminiLive] First glasses frame received ✓ ")
          WiFiLinkMonitor.shared.logSnapshot(context: "first-frame")
          Task { @MainActor [weak self] in
            guard let self = self else { return }
            if let pending = self.firstFrameContinuation {
              self.firstFrameContinuation = nil
              pending.resume(returning: true)
            } else {
              self.firstFrameSeen = true
            }
            self.armVideoWatchdog()
          }
        } else if frameCountDiag % 60 == 0 {
          print("[GeminiLive] Glasses frames delivered: \(frameCountDiag)")
        }
        source?.submit(videoFrame)
      }

      if adoptedFromLoan {
        // Loaned stream is already streaming — no start(). Stamp liveness so
        // the watchdog doesn't inherit a stale timestamp from before the
        // listeners re-attached; the first-frame wait resolves on the next
        // 2 fps frame (≤500 ms).
        print("[GeminiLive] loaned stream already live (state=\(stream.state)) — start() skipped")
        self.stampVideoFrame()
        WiFiLinkMonitor.shared.start(context: "gemini-live camera stream (adopted)")
      } else {
        // The manager delivers a `.started` session by this point
        // (`manager.acquire` awaits started internally). Now kick the stream.
        // 0.8: start() is synchronous fire-and-forget — readiness is proven by
        // the first-frame wait below, never by start() returning.
        print("[GeminiLive] stream.start() → … (currentState=\(stream.state))")
        stream.start()
        print("[GeminiLive] stream.start() returned (state=\(stream.state))")
        WiFiLinkMonitor.shared.start(context: "gemini-live camera stream")
      }
    }

    // Wait for the setup task to complete (or its early-return failure
    // path to flip `cameraSetupFailed`), then either short-circuit or
    // wait for first frame proof.
    //
    // Timeout bumped from 8s → 30s (2026-06-14) after the DAT Stream
    // config moved to `.high` + 2 fps for the manager-path glasses route.
    // At larger frame size + lower polling rate the SDK's first-frame
    // delivery is observably ~10s on Vanguard despite Stream.state →
    // streaming arriving quickly. The timeout is purely an upper bound —
    // healthy sessions resolve as soon as the frame arrives — so a
    // generous ceiling costs nothing and stops a real race from killing
    // session start.
    await cameraLifecycleTask?.value
    if cameraSetupFailed { return false }
    return await awaitCameraReady(timeout: 30.0)
  }

  /// Handler for `DeviceSessionError`s fanned out by the manager on the
  /// Phase 4 path. Currently logs + lets the existing error UI catch up;
  /// extend as we surface specific errors in coaching/troubleshoot.
  // MARK: - Mid-session frame-starvation watchdog

  /// Arm the watchdog. Called from the first-frame handler so we only watch
  /// once frames have actually started (startup is covered by the first-frame
  /// wait + `cameraSetupFailed`).
  @MainActor
  func armVideoWatchdog() {
    guard videoWatchdogTask == nil else { return }
    clearVideoStallProbation()
    stampVideoFrame()  // seed so the first tick isn't an instant false positive
    videoWatchdogTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2 s tick
        guard let self else { return }
        self.checkVideoStarvation()
      }
    }
  }

  @MainActor
  func stopVideoWatchdog() {
    videoWatchdogTask?.cancel()
    videoWatchdogTask = nil
    clearVideoStallProbation()
  }

  @MainActor
  private func checkVideoStarvation() {
    guard videoWatchdogTask != nil, !cameraStarvationSurfaced else { return }
    // The camera now stays running through reference-clip playback (video is
    // on WiFi, so there's no radio to free by stopping it). Frames keep
    // arriving and are stamped upstream of the send gate, so the watchdog runs
    // normally during a clip — a genuine link death mid-clip is still caught.
    guard geminiConnectionState == .connected || geminiConnectionState == .connecting else { return }

    let lastFrame = readLastVideoFrameAt()
    let gap = Date().timeIntervalSince(lastFrame)

    if gap <= Self.videoStallThreshold {
      // Healthy — or just recovered from a soft stall. The survived-gap log
      // is the measurement that tells us how long the WiFi link migration
      // actually takes; keep it precise.
      if videoStallProbationStartedAt != nil {
        let survived = lastFrame.timeIntervalSince(videoStallProbationLastFrameAt ?? lastFrame)
        clearVideoStallProbation()
        print(String(format: "[GeminiLive] ✓ frames resumed after %.1fs gap (WiFi link migration survived)", survived))
        WiFiLinkMonitor.shared.logSnapshot(context: "frame-gap-recovered")
        if cameraHealth == .reconnecting { cameraHealth = .ok }
      }
      return
    }

    if videoStallProbationStartedAt == nil {
      // Soft stage: hold teardown — this may be the SDK migrating video onto
      // the WiFi Direct link, which pauses frames for seconds. Voice keeps
      // running; the banner shows "Reconnecting camera…".
      videoStallProbationStartedAt = Date()
      videoStallProbationLastFrameAt = lastFrame
      print("[GeminiLive] ⚠️ frame gap >\(Int(Self.videoStallThreshold))s — possible WiFi link migration; holding teardown up to \(Int(Self.videoStallHardThreshold))s")
      WiFiLinkMonitor.shared.logSnapshot(context: "frame-gap-soft")
      if cameraHealth == .ok { cameraHealth = .reconnecting }
      return
    }

    if gap > Self.videoStallHardThreshold {
      handleVideoStarvation()
    }
  }

  @MainActor
  private func clearVideoStallProbation() {
    videoStallProbationStartedAt = nil
    videoStallProbationLastFrameAt = nil
  }

  /// Frames stopped mid-session past the hard ceiling — the transport is
  /// genuinely dead, not migrating.
  @MainActor
  private func handleVideoStarvation() {
    guard !cameraStarvationSurfaced else { return }
    print("[GeminiLive] ⚠️ video frame starvation — camera transport appears dead")
    WiFiLinkMonitor.shared.logSnapshot(context: "frame-starvation")
    clearVideoStallProbation()
    // Probation set `.reconnecting`; handleCameraBranchFailure's one-episode
    // guard requires `.ok`, so hand the transition back before escalating.
    if cameraHealth == .reconnecting { cameraHealth = .ok }
    handleCameraBranchFailure(reason: "frame starvation (no frames for \(Int(Self.videoStallHardThreshold))s)")
  }

  /// A sibling consumer (lens / expert) force-invalidated the shared session.
  /// Our held `DeviceSession` is now a corpse. Guarded so our own `invalidate`
  /// echo (we just surfaced) doesn't double-fire.
  @MainActor
  private func handleSessionInvalidated(_ reason: String) {
    print("[GeminiLive] session invalidated externally → \(reason)")
    guard !cameraStarvationSurfaced else { return }
    handleCameraBranchFailure(
      reason: "session invalidated externally: \(reason)", alreadyInvalidated: true)
  }

  /// Single sink for every camera-branch death: startup stall (no first frame),
  /// mid-session frame starvation, stream `.streaming → .stopped`, sibling
  /// invalidation, and terminal `DeviceSessionError`s. Invalidates the shared
  /// session (glasses only — the iPhone path holds no manager session) so the
  /// zombie can't be reused by the next acquire, then surfaces a blocking alert
  /// plus the persistent camera banner. No silent auto-retry: recovery is
  /// user-initiated via `retryCameraBranch()`. Voice is untouched — the Gemini
  /// socket keeps running and the session continues voice-only.
  @MainActor
  private func handleCameraBranchFailure(reason: String, alreadyInvalidated: Bool = false) {
    // The DAT-helper-update case has its own dedicated recovery sheet with a
    // specific user action; don't stack the generic camera alert on top.
    guard !pendingDATHelperUpdate else { return }
    // One episode at a time: a failure detected while we're already failed or
    // mid-retry must not re-invalidate or re-alert (e.g. the stream-state
    // listener echoing the teardown our own invalidate just caused).
    guard cameraHealth == .ok else { return }
    print("[GeminiLive] camera branch failure: \(reason)")
    cameraStarvationSurfaced = true
    stopVideoWatchdog()
    if !alreadyInvalidated, deviceSession != nil {
      sessionManager.invalidate(reason: "gemini-live camera branch failure: \(reason)")
    }
    cameraHealth = .failed
    showCameraLostAlert = true
  }

  /// User tapped Retry on the camera-lost alert or banner. Rebuilds ONLY the
  /// camera branch on the live voice session.
  func retryCameraBranch() {
    guard cameraHealth == .failed else { return }
    cameraHealth = .reconnecting
    Task { [weak self] in await self?.restartCameraBranch() }
  }

  /// Tear down and rebuild the camera branch (glasses Stream or iPhone
  /// capture) without touching the Gemini socket or audio. Serializes on
  /// `cameraLifecycleTask` via `stopCameraStream`/`setupCameraStream`; the
  /// WARP-drain wait after an invalidate is the manager's post-forced-teardown
  /// settle, not an ad-hoc sleep here. A successful rebuild re-flips
  /// `isReadyForNativeLens` and re-arms the watchdog on first frame.
  @MainActor
  private func restartCameraBranch() async {
    stopCameraStream()
    await awaitCameraTeardown()
    let ok: Bool
    switch transport {
    case .glasses: ok = await setupCameraStream()
    case .iPhone: ok = await setupIPhoneCameraStream()
    }
    print("[GeminiLive] camera branch restart → \(ok ? "recovered" : "failed again")")
    // Restart failure maps straight to .failed — it never re-enters
    // handleCameraBranchFailure, so there is no invalidate/alert loop.
    cameraHealth = ok ? .ok : .failed
  }

  @MainActor
  private func handleCameraSessionError(_ error: DeviceSessionError) {
    print("[GeminiLive] camera session error → \(error)")
    // Specific recovery affordances. Mirror `LensDisplayCoordinator`'s
    // `handleSessionError` — the user-facing failure modes match across
    // the two consumers of the shared session, so the surfaced UI should
    // too. Other errors (BT/thermal/peakPowerShutdown) stay as console
    // logs for diagnosis; subclasses can override if they need to alert.
    switch error {
    case .datAppOnTheGlassesUpdateRequired:
      pendingDATHelperUpdate = true
    default:
      // Mid-session BT/thermal/peakPowerShutdown / generic session failures
      // kill the DAT session (camera + lens), not the Gemini socket or the
      // HFP mic — route to the camera failure sink so the user gets the
      // camera alert + banner with a camera-only Retry. Per
      // `mwdat-ios:session-lifecycle` the session reaches terminal `.stopped`
      // after these; the manager's own `.stopped` observer runs the teardown,
      // so no extra invalidate from us (`alreadyInvalidated: true`). Only
      // while we still believed the session was live — avoids surfacing on
      // errors echoing an intentional exit.
      if geminiConnectionState == .connected || geminiConnectionState == .connecting {
        handleCameraBranchFailure(
          reason: "DeviceSessionError: \(error)", alreadyInvalidated: true)
      }
    }
  }

  /// iPhone-native video source. Throttled at the shared `videoMinInterval` /
  /// `videoJpegQuality` (1 fps / 0.85) so the token budget math carries over
  /// from the glasses path. Returns
  /// `true` once the first sample buffer arrives from `AVCaptureSession`,
  /// `false` on permission denial / start failure / first-buffer timeout.
  /// Awaited by `startGeminiLiveSession` step 3 — same contract as the
  /// glasses path.
  @discardableResult
  func setupIPhoneCameraStream() async -> Bool {
    // Reset the readiness signals — see `setupCameraStream` for why this
    // must happen on MainActor before any sample buffer could fire.
    firstFrameSeen = false
    cameraSetupFailed = false
    cameraStarvationSurfaced = false
    stopVideoWatchdog()
    if let pending = firstFrameContinuation {
      firstFrameContinuation = nil
      pending.resume(returning: false)
    }

    let prior = cameraLifecycleTask
    cameraLifecycleTask = Task { [weak self] in
      await prior?.value
      guard let self = self else { return }

      self.iPhoneCamera?.onSampleBuffer = nil
      self.iPhoneCamera?.onHandSampleBuffer = nil
      await self.iPhoneCamera?.stop()
      self.iPhoneCamera = nil
      self.iPhoneVideoSource = nil
      self.iPhonePreviewLayer = nil
      self.handLandmarkerService?.stop()
      self.handLandmarkerService = nil

      let camera = IPhoneCameraCapture()
      let granted = await camera.requestPermission()
      guard granted else {
        self.voiceStatus = "Camera denied"
        print("[GeminiLive] iPhone camera permission denied")
        await MainActor.run { self.cameraSetupFailed = true }
        return
      }

      let source = IPhoneCoachingCameraSource(
        minInterval: self.videoMinInterval,
        jpegQuality: self.videoJpegQuality
      ) { [weak self] jpeg in
        let gate = await MainActor.run { [weak self] () -> Bool in
          guard let self = self else { return false }
          // Cache the latest encoded frame for the visual oracle before the
          // send gate — the oracle wants the freshest frame even when video
          // send is gated (e.g. a tool call is in flight).
          self.onEncodedFrame(jpeg)
          return self.isGeminiReady && self.pendingToolCallIds.isEmpty && !self.isClipPlaying
        }
        guard gate else { return }
        try? await self?.geminiService?.sendVideoFrame(jpeg)
      }
      self.iPhoneVideoSource = source

      // First-sample-buffer signal mirrors the glasses
      // `videoFramePublisher.listen` path: on count == 1, hop to MainActor
      // and resolve `firstFrameContinuation` (or set `firstFrameSeen` if
      // no waiter has installed yet — covers the race where the buffer
      // lands before the outer wrapper begins its wait).
      var iPhoneBufferCountDiag = 0
      camera.onSampleBuffer = { [weak self, weak source] sampleBuffer in
        self?.stampVideoFrame()  // liveness stamp for the starvation watchdog
        iPhoneBufferCountDiag &+= 1
        if iPhoneBufferCountDiag == 1 {
          print("[GeminiLive] First iPhone sample buffer received ✓")
          Task { @MainActor [weak self] in
            guard let self = self else { return }
            if let pending = self.firstFrameContinuation {
              self.firstFrameContinuation = nil
              pending.resume(returning: true)
            } else {
              self.firstFrameSeen = true
            }
            self.armVideoWatchdog()
          }
        }
        source?.submit(sampleBuffer)
      }

      // MILESTONE 2 wiring — feed the hand-tracking output into MediaPipe,
      // ingest each frame into the Meta XR micro-gesture recognizer, and
      // log any emitted event. No HUD binding yet (deferred to the next
      // milestone once reliability is validated on-device).
      //
      // Transport-keyed gate: iPhone path always uses MediaPipe (no
      // Neural Band available). Helper composes `transport == .iPhone`,
      // `!HandGestureService.isDisabled`, and `HandTrackingConfig.isAvailable`.
      if HandGestureService.shouldStart(for: .iPhone) {
        // Reset the shared gesture service so stale FSM state from any
        // prior session doesn't carry across. Wire `.back` events to the
        // VM's exposed `onBackGesture` so the existing call-site contract
        // (`viewModel.onBackGesture = { … }` in views) keeps working.
        //
        // The `!isDisabled` guard is the user kill switch (Server
        // Settings → Debug → "Disable hand tracking"). When on, don't
        // spin up MediaPipe — touch / lens swipes still work but the
        // pinch path is muted. Service-level `ingest(_:)` early-out is
        // the belt-and-suspenders for mid-session toggle flips.
        HandGestureService.shared.reset()
        HandGestureService.shared.onBackGesture = { [weak self] in
          self?.onBackGesture?()
        }
        let handService = HandLandmarkerService()
        do {
          try handService.start()
          handService.onResult = { frame in
            Task { @MainActor in
              HandGestureService.shared.ingest(frame)
            }
          }
          self.handLandmarkerService = handService
          camera.onHandSampleBuffer = { [weak handService] sampleBuffer in
            handService?.submit(sampleBuffer: sampleBuffer)
          }
          print("[GeminiLive] Hand tracking started — pinch-drag recognizer armed")
        } catch {
          print("[GeminiLive] Hand tracking disabled: \(error.localizedDescription)")
        }
      } else if HandGestureService.isDisabled {
        print("[GeminiLive] Hand tracking suppressed by user setting (iPhone path)")
      } else if !HandTrackingConfig.isAvailable {
        print("[GeminiLive] Hand tracking unavailable — model not bundled (iPhone path)")
      }

      do {
        try await camera.start()
      } catch {
        print("[GeminiLive] iPhone camera failed to start: \(error)")
        await MainActor.run { self.cameraSetupFailed = true }
        return
      }
      self.iPhoneCamera = camera
      // Replay any orientation the view pushed before the async camera
      // start finished — otherwise entering landscape-first leaves the
      // preview stuck at 90°.
      if let pending = self.pendingPreviewOrientation {
        camera.setPreviewInterfaceOrientation(pending)
      }
      // Publish the preview layer so the camera-first iPhone layout can
      // attach it as soon as the session is running. The layer composites
      // the same pixel stream the JPEG throttle drains — no extra capture.
      self.iPhonePreviewLayer = camera.previewLayer
    }

    // Same readiness-wait pattern as the glasses path. Same 30s upper
    // bound for symmetry — iPhone first-frame arrives in <1s in healthy
    // sessions, so the generous ceiling never bites here in practice.
    await cameraLifecycleTask?.value
    if cameraSetupFailed { return false }
    return await awaitCameraReady(timeout: 30.0)
  }

  /// Enqueue camera teardown onto the lifecycle chain. Safe to call while a
  /// prior setup Task is still running — this one awaits it first, so start
  /// and stop never race for the same glassesStream / iPhoneCamera refs.
  func stopCameraStream() {
    let prior = cameraLifecycleTask
    // STRONG `self` capture (not weak): teardown MUST run to completion even
    // when the owning view/VM is being deallocated this instant — e.g. the
    // glasses-first standby host unmounts the moment `runtimeMode` flips, so a
    // `[weak self]` task would resume after dealloc, hit `guard let self`, and
    // bail BEFORE `stream.stop()` / `release("gemini-live")` ever ran, leaving
    // the camera on. Mirrors `StreamSessionViewModel.teardown()`'s strong
    // capture. The self→task→self cycle is temporary; it resolves when this
    // finite task ends.
    cameraLifecycleTask = Task { [self] in
      await prior?.value

      // Tokens FIRST so any trailing publisher events stop hitting the
      // frame fan-out closures (which may be mid-teardown themselves).
      self.videoFrameListenerToken = nil
      self.stateListenerToken = nil
      self.sessionErrorsCancellable?.cancel()
      self.sessionErrorsCancellable = nil
      self.sessionInvalidatedCancellable?.cancel()
      self.sessionInvalidatedCancellable = nil
      self.stopVideoWatchdog()

      if let session = self.glassesStream {
        // 0.8: Stream.stop() is synchronous. Anchor on the stream actually
        // reaching .stopped plus a short settle: the SDK reports .stopped
        // before its WARP threads exit, and a successor Stream attached to
        // the same shared DeviceSession during that drain window comes up
        // poisoned (one frame → starvation). Protects retryCameraBranch,
        // rapid exit/re-enter, and the glasses-first handoff (all of which
        // funnel through awaitCameraTeardown before re-attaching).
        session.stop()
        await self.awaitStreamStopped(session, timeout: 2.0)
        try? await Task.sleep(nanoseconds: 300_000_000)  // WARP drain settle
        WiFiLinkMonitor.shared.stop(context: "gemini-live teardown")
      }
      self.glassesStream = nil

      // DeviceSession lifecycle: release the lease and let the manager
      // decide whether to stop the underlying session (it stays alive if
      // another consumer like lens still holds it).
      self.deviceSession = nil
      await self.sessionManager.release(consumerLabel: "gemini-live")

      self.iPhoneCamera?.onSampleBuffer = nil
      self.iPhoneCamera?.onHandSampleBuffer = nil
      await self.iPhoneCamera?.stop()
      self.iPhoneCamera = nil
      self.iPhoneVideoSource = nil
      self.iPhonePreviewLayer = nil
      self.glassesCoachingSource = nil
      self.glassesPreviewFrame = nil
      self.handLandmarkerService?.stop()
      self.handLandmarkerService = nil
      // Clear the shared gesture service's hooks so a teardown doesn't
      // leak this VM's closures into the next session (potentially in a
      // different mode).
      HandGestureService.shared.onBackGesture = nil
      HandGestureService.shared.onEvent = nil
    }
  }

  /// Await the in-flight camera lifecycle task (start or stop) to fully finish.
  /// Lets exit paths block until `stream.stop()` + the `gemini-live` lease
  /// release have actually completed, so a caller can guarantee the glasses
  /// camera is off before it tears down the lens or returns to the phone.
  func awaitCameraTeardown() async {
    await cameraLifecycleTask?.value
  }

  // MARK: - Camera loan (troubleshoot→coaching handoff)

  /// A live glasses camera branch left running by a donor VM across the
  /// troubleshoot→coaching handoff. The Stream keeps streaming and the
  /// donor's `"gemini-live"` DSM lease stays held — the claimant's
  /// `acquire("gemini-live")` refreshes that same label-keyed lease, and the
  /// claimant adopts the Stream instead of addStream+start. This keeps the
  /// WiFi link lease + camera alive across the handoff (no LED blink, no
  /// re-join) and avoids stop→re-add on a shared DeviceSession: the SDK
  /// reports `.stopped` before its WARP threads exit, and a successor
  /// attaches to a half-drained pipe (one frame, then starvation).
  struct CameraLoan {
    let stream: MWDATCamera.Stream
    let session: DeviceSession
    let depositedAt: Date
  }

  @MainActor private static var pendingCameraLoan: CameraLoan?
  @MainActor private static var cameraLoanSweepTask: Task<Void, Never>?

  /// Claim the pending loan (cancels the unclaimed-loan sweep). Called by
  /// the successor VM's `setupCameraStream()`.
  @MainActor static func claimCameraLoan() -> CameraLoan? {
    guard let loan = pendingCameraLoan else { return nil }
    pendingCameraLoan = nil
    cameraLoanSweepTask?.cancel()
    cameraLoanSweepTask = nil
    return loan
  }

  /// If the coaching VM never mounts (user bails mid-transition), the loaned
  /// stream must not keep the camera running forever: stop it and drop the
  /// transferred lease.
  @MainActor private static func armCameraLoanSweep(sessionManager: DeviceSessionManager) {
    cameraLoanSweepTask?.cancel()
    cameraLoanSweepTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 15_000_000_000)
      guard !Task.isCancelled, let loan = pendingCameraLoan else { return }
      pendingCameraLoan = nil
      cameraLoanSweepTask = nil
      print("[GeminiLive] camera loan unclaimed after 15s — stopping loaned stream, releasing lease")
      loan.stream.stop()
      try? await Task.sleep(nanoseconds: 1_000_000_000)  // drain grace
      await sessionManager.release(consumerLabel: "gemini-live")
    }
  }

  /// Donor side: detach this VM's listeners but leave the Stream running and
  /// the `"gemini-live"` lease held, depositing both for the successor VM.
  /// Returns false when there's nothing loanable (iPhone transport, no live
  /// stream, camera already failed) — caller must fall back to a full
  /// `stopCameraStream()` teardown. Chains on `cameraLifecycleTask` so it
  /// can't race an in-flight setup/stop/pause.
  func loanCameraForHandoff() async -> Bool {
    guard transport == .glasses, cameraHealth == .ok else { return false }
    let prior = cameraLifecycleTask
    let loanTask = Task<Bool, Never> { [self] in
      await prior?.value
      guard let stream = self.glassesStream, let session = self.deviceSession else { return false }

      // Detach OUR observers; the stream itself keeps flowing for the
      // successor. Mirrors stopCameraStream's token-first ordering.
      self.videoFrameListenerToken = nil
      self.stateListenerToken = nil
      self.sessionErrorsCancellable?.cancel()
      self.sessionErrorsCancellable = nil
      self.sessionInvalidatedCancellable?.cancel()
      self.sessionInvalidatedCancellable = nil
      self.stopVideoWatchdog()
      self.glassesCoachingSource = nil
      self.glassesPreviewFrame = nil
      self.glassesStream = nil
      self.deviceSession = nil

      await MainActor.run {
        Self.pendingCameraLoan = CameraLoan(stream: stream, session: session, depositedAt: Date())
        Self.armCameraLoanSweep(sessionManager: self.sessionManager)
      }
      print("[GeminiLive] camera loaned for handoff (state=\(stream.state)) — stream + gemini-live lease stay live")
      return true
    }
    cameraLifecycleTask = Task { _ = await loanTask.value }
    return await loanTask.value
  }

  // MARK: - GlassesRuntime

  /// Default full teardown for a Gemini Live runtime (conforms `GlassesRuntime`,
  /// declared in `GlassesRuntime.swift`). Stops Gemini + camera, then awaits the
  /// camera lifecycle task so the `gemini-live` lease is released before this
  /// returns. Subclasses override to PREPEND mode-specific cleanup (progress
  /// save, server session DELETE) and then await the camera teardown.
  func shutdown() async {
    stopGeminiLiveSession()
    stopCameraStream()
    await awaitCameraTeardown()
  }


  // MARK: - Stream drain helper

  /// Bounded wait for a camera `Stream` to reach `.stopped` after the
  /// (0.8, synchronous) `stop()` call. Mirrors
  /// `StreamSessionViewModel.awaitDeviceSessionStopped` but against
  /// `Stream.statePublisher`. Times out silently — the caller only needs a
  /// best-effort drain, not a guarantee. Used by the camera-loan retire path
  /// and the `stopCameraStream` teardown drain anchor.
  private func awaitStreamStopped(_ stream: MWDATCamera.Stream, timeout: TimeInterval) async {
    if stream.state == .stopped { return }

    let (states, continuation) = AsyncStream<StreamState>.makeStream()
    let listenerToken = stream.statePublisher.listen { state in
      continuation.yield(state)
    }

    if stream.state == .stopped {
      continuation.finish()
      await listenerToken.cancel()
      return
    }

    _ = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
      group.addTask {
        for await state in states {
          if state == .stopped { return true }
        }
        return false
      }
      group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      continuation.finish()
      return first
    }
    // Explicit unsubscribe (the token protocol exposes async cancel();
    // don't rely on deinit-based auto-removal keeping the closure off the
    // shared Stream's publisher).
    await listenerToken.cancel()
  }

  // MARK: - Tool call

  private func handleToolCall(id: String, name: String, args: [String: Any]) async {
    guard let sid = sessionId else { return }

    pendingToolCallIds.insert(id)
    pendingToolCallNames[id] = name
    if flushPlaybackOnToolCall {
      audioManager?.clearPlaybackBuffer(reason: "tool-call")
    }

    let startedAt = Date()
    print("[GeminiLive] ▶ Tool call START name=\(name) id=\(id) args=\(args)")

    let result = await forwardToolCallToServer(
      sessionId: sid,
      toolCallId: id,
      functionName: name,
      args: args
    )
    let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
    print("[GeminiLive] ◀ Tool call DONE  name=\(name) id=\(id) result=\(result) (\(elapsedMs)ms)")

    // Let the subclass react to the result (update step index, phase, etc.)
    // BEFORE we ACK the tool back to Gemini, so any dependent UI state has
    // flipped by the time Gemini asks follow-up questions.
    await handleToolCallExtras(name: name, args: args, result: result)

    appendToolCall(name: name, args: args, result: result)

    do {
      try await geminiService?.sendToolResponse(id: id, name: name, response: result)
      print("[GeminiLive] ✓ Tool response ACK sent to Gemini name=\(name) id=\(id)")
    } catch {
      print("[GeminiLive] ✗ Failed to send tool response name=\(name) id=\(id): \(error)")
    }

    pendingToolCallIds.remove(id)
    pendingToolCallNames.removeValue(forKey: id)
  }

  private func forwardToolCallToServer(
    sessionId: String,
    toolCallId: String,
    functionName: String,
    args: [String: Any]
  ) async -> [String: Any] {
    guard let url = URL(string: "\(serverBaseURL)\(toolCallURLSuffix)") else {
      return ["error": "Invalid URL", "retryable": false]
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = toolCallTimeoutSeconds

    let body: [String: Any] = [
      "tool_name": functionName,
      "arguments": args,
    ]

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, response) = try await URLSession.shared.data(for: request)

      guard let http = response as? HTTPURLResponse else {
        print("[GeminiLive] Tool call: non-HTTP response")
        return [
          "error": "transient_network_failure",
          "message": "No HTTP response from server",
          "retryable": true,
        ]
      }

      guard (200...299).contains(http.statusCode) else {
        let bodySnippet = String(data: data.prefix(200), encoding: .utf8) ?? "<non-utf8>"
        print("[GeminiLive] Tool call failed: HTTP \(http.statusCode) body=\(bodySnippet)")
        return [
          "error": "server_rejected_tool_call",
          "message": "HTTP \(http.statusCode): \(bodySnippet)",
          "retryable": http.statusCode >= 500,
        ]
      }

      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let inner = json["result"] as? [String: Any] {
          return inner
        }
        return json
      }
      return ["status": "ok"]
    } catch {
      print("[GeminiLive] Tool call forward error: \(error)")
      return [
        "error": "transient_network_failure",
        "message": error.localizedDescription,
        "retryable": true,
      ]
    }
  }

  // MARK: - Activity feed

  func appendTranscript(kind: ActivityEntry.Kind, delta: String) {
    let turnOpen: Bool
    switch kind {
    case .learner: turnOpen = learnerTurnOpen
    case .assistant: turnOpen = assistantTurnOpen
    case .toolCall: return
    }

    if turnOpen,
       let last = activity.last,
       last.kind == kind {
      var updated = last
      updated.text += delta
      activity[activity.count - 1] = updated
    } else {
      activity.append(ActivityEntry(kind: kind, text: delta, timestamp: Date()))
      switch kind {
      case .learner:
        learnerTurnOpen = true
        assistantTurnOpen = false
      case .assistant:
        assistantTurnOpen = true
        learnerTurnOpen = false
      case .toolCall:
        break
      }
      trimActivity()
    }
  }

  private func appendToolCall(name: String, args: [String: Any], result: [String: Any]) {
    let summary = toolCallSummary(name: name, args: args, result: result)
    activity.append(ActivityEntry(
      kind: .toolCall(name: name),
      text: summary,
      timestamp: Date()
    ))
    learnerTurnOpen = false
    assistantTurnOpen = false
    trimActivity()
  }

  /// Default summary is the raw tool name. Coaching overrides to render
  /// richer text ("Advanced to step 3: Remove the drip tray").
  func toolCallSummary(name: String, args: [String: Any], result: [String: Any]) -> String {
    return name
  }

  func trimActivity() {
    if activity.count > activityMaxEntries {
      activity.removeFirst(activity.count - activityMaxEntries)
    }
  }

  // MARK: - Connection state + intro seed

  private func observeGeminiConnectionState(_ gemini: GeminiLiveService) {
    gemini.$connectionState
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        guard let self = self else { return }
        print("[GeminiLive] Connection state → \(state)")
        self.geminiConnectionState = state
        switch state {
        case .connected:
          self.isGeminiReady = true
          self.voiceStatus = self.isMuted ? "Muted" : self.idleListeningStatus
          print("[GeminiLive] Gemini Live connected")
          self.sendIntroSeedIfNeeded()
          // Subclasses that want a turnComplete-scheduled heartbeat rely on
          // onTurnCompleteExtra; they can also kick-start via the subclass's
          // .connected handler if needed — see coaching's override.
          self.onConnectedExtra()
        case .connecting:
          self.isGeminiReady = false
          self.voiceStatus = "Connecting..."
        case .error(let msg):
          self.isGeminiReady = false
          self.voiceStatus = "Connection error"
          print("[GeminiLive] Gemini Live error: \(msg)")
          if self.resumptionHandle != nil, !self.isResuming {
            Task { @MainActor [weak self] in
              await self?.reconnectWithResumption(reason: "state=error")
            }
          }
        case .disconnected:
          self.isGeminiReady = false
        }
      }
      .store(in: &cancellables)

    gemini.$modelGenerationActive
      .receive(on: DispatchQueue.main)
      .sink { [weak self] active in
        self?.isModelGenerating = active
      }
      .store(in: &cancellables)
  }

  /// Fires after the base's .connected transition. Coaching overrides to
  /// start its heartbeat scheduler. Other modes leave as no-op.
  func onConnectedExtra() {}

  private func sendIntroSeedIfNeeded() {
    guard !hasSeededIntro, let seedText = introSeedText else { return }
    hasSeededIntro = true
    Task { [weak self] in
      guard let self = self, let gemini = self.geminiService else { return }
      do {
        try await gemini.sendClientTextTurn(seedText)
        print("[GeminiLive] Seeded intro turn on first .connected")
      } catch {
        print("[GeminiLive] Failed to seed intro turn: \(error)")
      }
    }
  }

  private func observeAudioIsAISpeaking(_ audio: AudioSessionManager) {
    audio.$isAISpeaking
      .receive(on: DispatchQueue.main)
      .sink { [weak self] speaking in
        guard let self = self else { return }
        self.isAISpeaking = speaking
        if speaking, !self.isMuted {
          self.voiceStatus = "AI speaking"
        }
      }
      .store(in: &cancellables)

    audio.$aiOutputPeak
      .receive(on: DispatchQueue.main)
      .sink { [weak self] peak in
        self?.aiOutputPeak = peak
      }
      .store(in: &cancellables)

    audio.$userInputPeak
      .receive(on: DispatchQueue.main)
      .sink { [weak self] peak in
        guard let self = self else { return }
        // Pin to 0 while muted — mic may still capture frames for VAD/AEC,
        // but visually we're not "listening".
        self.userInputPeak = self.isMuted ? 0 : peak
      }
      .store(in: &cancellables)

    audio.$lastAudioActivityAt
      .receive(on: DispatchQueue.main)
      .sink { [weak self] ts in
        self?.lastAudioActivityAt = ts
      }
      .store(in: &cancellables)

    audio.$micStalled
      .receive(on: DispatchQueue.main)
      .sink { [weak self] stalled in
        self?.micStalled = stalled
      }
      .store(in: &cancellables)
  }

  // MARK: - Resumption

  /// Reopen the WebSocket with the most recent resumption handle, then
  /// optionally inject a context summary from the subclass. Falls back to
  /// a plain token refresh + retry when no handle is yet available.
  func reconnectWithResumption(reason: String) async {
    guard !isResuming else {
      print("[GeminiLive] Reconnect requested (\(reason)) but already resuming")
      return
    }
    guard let tm = tokenManager, let gemini = geminiService, sessionId != nil else {
      return
    }
    guard let handle = resumptionHandle else {
      print("[GeminiLive] Reconnect (\(reason)): no handle yet, refreshing token + retrying")
      do {
        _ = try await tm.forceRefresh()
      } catch {
        print("[GeminiLive] Plain-retry token refresh failed: \(error)")
        voiceStatus = "Connection error"
        return
      }
      await gemini.retry()
      return
    }

    isResuming = true
    voiceStatus = "Reconnecting…"
    print("[GeminiLive] Reconnecting with resumption handle (\(reason))")

    do {
      _ = try await tm.forceRefresh(handle: handle)
    } catch {
      print("[GeminiLive] Resumption token mint failed: \(error)")
      voiceStatus = "Connection error"
      isResuming = false
      return
    }

    await gemini.retry()

    let deadline = Date().addingTimeInterval(5.0)
    while gemini.connectionState != .connected, Date() < deadline {
      try? await Task.sleep(nanoseconds: 100_000_000)
    }

    guard gemini.connectionState == .connected else {
      print("[GeminiLive] Resumed socket did not open in 5s; aborting summary inject")
      isResuming = false
      return
    }

    if let summary = await contextSummaryForReconnect() {
      do {
        try await gemini.sendClientTextTurn(resumptionInjectText(summary: summary))
        print("[GeminiLive] Resumed — injected context summary")
      } catch {
        print("[GeminiLive] Failed to inject context summary: \(error)")
      }
    }

    isResuming = false
  }
}

// `HandGestureDebugProvider` conformance now lives on `HandGestureService`,
// not the VM. Views pass `HandGestureService.shared` as the provider.
// See `HandTracking/HandGestureService.swift`.
