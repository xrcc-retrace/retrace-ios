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

  /// Set true when the pre-session DAT glasses-permissions gate fails
  /// (camera and/or microphone not granted) on a `.glasses` transport
  /// session. The session view binds this to a `.sheet(isPresented:)`
  /// and presents a `PermissionRequiredSheet` containing the same
  /// `DATCameraPermissionCTA` used elsewhere in the app — which now
  /// grants BOTH camera and mic in one flow. On grant inside the
  /// sheet, the view calls `retryAfterPermissionGrant()` to re-run
  /// session start in place.
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

  // MARK: - Inputs

  let wearables: WearablesInterface
  let serverBaseURL: String

  // MARK: - Shared Services (set during startGeminiLiveSession, nilled in teardown)

  var audioManager: AudioSessionManager?
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

  var streamSession: MWDATCamera.Stream?
  var deviceSession: DeviceSession?
  var stateListenerToken: AnyListenerToken?
  var videoFrameListenerToken: AnyListenerToken?
  /// Phase 4: subscription to the shared `DeviceSessionManager`'s
  /// `sessionErrors` fan-out, when the manager path is active. Replaces
  /// the per-consumer `errorStream` observation we never had. Cleared in
  /// `stopCameraStream`.
  var sessionErrorsCancellable: AnyCancellable?
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
  let videoMinInterval: TimeInterval = 2.0
  let videoJpegQuality: CGFloat = 0.5

  // MARK: - Combine

  var cancellables: Set<AnyCancellable> = []

  // MARK: - Init

  /// Phase 4: optional shared `DeviceSessionManager`. When the
  /// `deviceSessionManagerEnabled` toggle is ON, camera session lifecycle
  /// goes through the manager so it can be shared with the lens display
  /// (issue #180). When OFF (default during migration) we fall back to
  /// the original `wearables.createSession` inline path.
  let sessionManager: DeviceSessionManager?

  /// Reads the live debug toggle. Re-read on each `setupCameraStream`
  /// call so a flip in Settings takes effect on the next session
  /// (no app relaunch required).
  var deviceSessionManagerEnabled: Bool {
    UserDefaults.standard.bool(forKey: "deviceSessionManagerEnabled") && sessionManager != nil
  }

  init(wearables: WearablesInterface, serverBaseURL: String, sessionManager: DeviceSessionManager? = nil) {
    self.wearables = wearables
    self.serverBaseURL = serverBaseURL
    self.sessionManager = sessionManager
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
    let audio = audioManager
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
    // 0. DAT camera permission gate (glasses transport only). Per the
    //    DAT 0.7 contract, devices don't appear in `wearables.devices`
    //    until `Permission.camera` is granted via Meta AI — so without
    //    this the camera setup would later fail with `noEligibleDevice`
    //    regardless of how patiently we wait. Non-prompting check: the
    //    prompt belongs in onboarding (eager) or a Profile CTA (opt-in).
    //    Mid-session-start bouncing to Meta AI would be jarring.
    if transport == .glasses, let manager = sessionManager {
      do {
        // Check BOTH camera and microphone — the DAT 0.7 docs only
        // explicitly require camera for device visibility, but Display
        // glasses BT HFP audio appears to silently no-op without the
        // DAT mic grant. Treating both as prerequisites removes the
        // silent "mic configured but no buffers" failure mode.
        let granted = try await manager.allGlassesPermissionsGranted()
        guard granted else {
          voiceStatus = "Glasses permissions required"
          pendingGlassesPermissions = true
          print("[GeminiLive] DAT glasses permissions not fully granted — aborting session start, surfacing recovery sheet")
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
    let audio = AudioSessionManager(mode: audioSessionMode)
    self.audioManager = audio

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
    // session that requires audio functionality." The canonical worked
    // example uses ~2 seconds between session activation and stream
    // start. Without it, `engine.start()` on the glasses BT HFP path
    // returns success but `isRunning` flips false (the input audio
    // unit attaches to a half-negotiated route and bails) — exactly
    // the silent-mic failure we saw in the diagnostic dump.
    //
    // We split the previous single `startCapture()` call into:
    //   1. `configureSessionOnly()` — runs setCategory + setActive only
    //   2. 2 s sleep — gives the BT SCO link time to fully come up
    //   3. `startCapture()` — runs the engine setup (skips its own
    //      configure step via the `didConfigureSession` guard)
    audio.configureSessionOnly()
    if transport == .glasses {
      try? await Task.sleep(nanoseconds: 2_000_000_000)
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

    // 2. Camera — awaited end-to-end. Returns true once the first frame
    //    has actually arrived (or false on timeout / acquire failure).
    voiceStatus = "Starting camera..."
    let cameraReady: Bool
    switch transport {
    case .glasses:
      cameraReady = await setupCameraStream()
    case .iPhone:
      cameraReady = await setupIPhoneCameraStream()
    }
    guard cameraReady else {
      voiceStatus = "Camera failed"
      print("[GeminiLive] Camera did not come up — aborting session start before Gemini connect")
      audio.stopCapture()
      audioManager = nil
      return
    }

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
      self?.audioManager?.playPcm16Audio(data)
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
      let gateOpen = sendingOk && noTool && ready

      if gateOpen != self.audioGateWasOpen {
        self.audioGateWasOpen = gateOpen
        if gateOpen {
          print("[GeminiLive] Audio send gate OPEN — mic → Gemini live")
        } else {
          let reason: String
          if !ready { reason = "Gemini not ready" }
          else if !noTool { reason = "pending tool call" }
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
    cancellables.removeAll()

    audioManager?.stopCapture()
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

    didEndSession()
  }

  // MARK: - Camera Stream (glasses via DAT SDK)

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
    if let pending = firstFrameContinuation {
      firstFrameContinuation = nil
      pending.resume(returning: false)
    }

    let prior = cameraLifecycleTask
    cameraLifecycleTask = Task { [weak self] in
      await prior?.value
      guard let self = self else { return }

      // Reset per-attach local state shared by both paths. Inline-path
      // also stops the prior SDK objects below; manager-path doesn't
      // because the manager owns DeviceSession lifecycle.
      self.handLandmarkerService?.stop()
      self.handLandmarkerService = nil
      self.glassesCoachingSource = nil
      self.glassesPreviewFrame = nil

      let session: DeviceSession
      let stream: MWDATCamera.Stream

      if self.deviceSessionManagerEnabled, let manager = self.sessionManager {
        // Manager path (Phase 4). The session is shared with any other
        // active consumer (e.g. lens) so adding capabilities here doesn't
        // require a private DeviceSession.
        do {
          let acquired = try await manager.acquire(consumerLabel: "gemini-live")
          let config = StreamConfiguration(
            videoCodec: .raw,
            resolution: .low,
            frameRate: 24
          )
          guard let s = try acquired.addStream(config: config) else {
            print("[GeminiLive] Could not attach stream capability to the device session")
            await manager.release(consumerLabel: "gemini-live")
            await MainActor.run { self.cameraSetupFailed = true }
            return
          }
          session = acquired
          stream = s
        } catch {
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
      } else {
        // Inline path (pre-Phase-4 behavior, preserved as the toggle-OFF
        // fallback). Defensive: tear down a prior session before creating.
        if let existing = self.streamSession {
          await existing.stop()
          self.streamSession = nil
          self.videoFrameListenerToken = nil
          self.stateListenerToken = nil
        }
        if let existing = self.deviceSession {
          existing.stop()
          self.deviceSession = nil
        }

        let deviceSelector = AutoDeviceSelector(wearables: self.wearables)
        let config = StreamConfiguration(
          videoCodec: .raw,
          resolution: .low,
          frameRate: 24
        )
        do {
          let created = try self.wearables.createSession(deviceSelector: deviceSelector)
          // CRITICAL ordering: session.start() + await .started MUST run
          // before addStream(config:). createSession returns a session
          // in `.idle`; addStream on an idle session returns nil per
          // SDK contract. Mirrors the canonical lifecycle in
          // `StreamSessionViewModel.startSession()` (the expert path).
          // The DSM-enabled branch above doesn't need this because
          // `manager.acquire(...)` awaits `.started` internally.
          do {
            try created.start()
          } catch {
            print("[GeminiLive] Inline path: session.start() threw \(error)")
            await MainActor.run { self.cameraSetupFailed = true }
            return
          }
          do {
            try await Self.awaitDeviceSessionStarted(created, timeout: 5.0)
          } catch {
            print("[GeminiLive] Inline path: session never reached .started — \(error.localizedDescription)")
            created.stop()
            await MainActor.run { self.cameraSetupFailed = true }
            return
          }
          guard let s = try created.addStream(config: config) else {
            print("[GeminiLive] Inline path: addStream returned nil even after .started — eligible device dropped?")
            created.stop()
            await MainActor.run { self.cameraSetupFailed = true }
            return
          }
          session = created
          stream = s
        } catch {
          print("[GeminiLive] Failed to create glasses stream session: \(error)")
          await MainActor.run { self.cameraSetupFailed = true }
          return
        }
      }

      self.deviceSession = session
      self.streamSession = stream

      // Hand tracking on the glasses transport — mirrors the iPhone init in
      // setupIPhoneCameraStream(). Kept in sync so the lens HUD's pinch /
      // double-pinch back gestures behave identically regardless of which
      // camera is feeding frames into Gemini.
      //
      // Additional gate: when `lensOutputEnabled` is on, the user's input
      // for the lens UI flows through the Neural Band (which the DAT SDK
      // auto-routes to FlexBox.onTap callbacks). MediaPipe-driven phone-
      // side hand tracking is then redundant and just burns CPU + frames
      // that could be competing with audio over the same BT pipe. Skip it.
      let lensOutputActive = UserDefaults.standard.bool(forKey: "lensOutputEnabled")
      if HandTrackingConfig.isAvailable && !HandGestureService.isDisabled && !lensOutputActive {
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
          print("[GeminiLive] Hand tracking started on glasses path — pinch-drag recognizer armed")
        } catch {
          print("[GeminiLive] Hand tracking disabled on glasses path: \(error.localizedDescription)")
          self.handLandmarkerService = nil
        }
      } else if lensOutputActive {
        print("[GeminiLive] Hand tracking suppressed — lens output active, input routes through Neural Band (glasses path)")
      } else if HandGestureService.isDisabled {
        print("[GeminiLive] Hand tracking suppressed by user setting (glasses path)")
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
            return self.isGeminiReady && self.pendingToolCallIds.isEmpty
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
      self.stateListenerToken = stream.statePublisher.listen { state in
        print("[GeminiLive] Stream.state → \(state)")
      }

      // Count incoming video frames so we can confirm the camera is actually
      // delivering data (vs. an attached-but-silent stream). On the very
      // first frame, hop to MainActor and resolve `firstFrameContinuation`
      // (or set `firstFrameSeen` if no continuation was installed yet —
      // covers the race where the frame arrives before the outer wrapper
      // begins its wait).
      var frameCountDiag = 0
      self.videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self, weak source] videoFrame in
        frameCountDiag &+= 1
        if frameCountDiag == 1 {
          print("[GeminiLive] First glasses frame received ✓ ")
          Task { @MainActor [weak self] in
            guard let self = self else { return }
            if let pending = self.firstFrameContinuation {
              self.firstFrameContinuation = nil
              pending.resume(returning: true)
            } else {
              self.firstFrameSeen = true
            }
          }
        } else if frameCountDiag % 60 == 0 {
          print("[GeminiLive] Glasses frames delivered: \(frameCountDiag)")
        }
        source?.submit(videoFrame)
      }

      // Manager and inline paths both deliver a `.started` session by this
      // point (DSM: `manager.acquire` awaits started; inline: explicit
      // `start()` + `awaitDeviceSessionStarted` above before `addStream`).
      // Now kick the stream.
      print("[GeminiLive] stream.start() → … (currentState=\(stream.state))")
      await stream.start()
      print("[GeminiLive] stream.start() returned (state=\(stream.state))")
    }

    // Wait for the setup task to complete (or its early-return failure
    // path to flip `cameraSetupFailed`), then either short-circuit or
    // wait for first frame proof.
    await cameraLifecycleTask?.value
    if cameraSetupFailed { return false }
    return await awaitCameraReady(timeout: 8.0)
  }

  /// Handler for `DeviceSessionError`s fanned out by the manager on the
  /// Phase 4 path. Currently logs + lets the existing error UI catch up;
  /// extend as we surface specific errors in coaching/troubleshoot.
  @MainActor
  private func handleCameraSessionError(_ error: DeviceSessionError) {
    print("[GeminiLive] camera session error → \(error)")
    // The Lens path already wires the same fan-out and decides whether to
    // flip `requiresDATAppUpdate`. Here we just log so a mid-coaching
    // BT/thermal/peakPowerShutdown can be diagnosed from the console.
    // Subclasses (Coaching/Diagnostic VMs) can override or observe via
    // `sessionManager?.sessionErrors` if they need to surface a user-
    // visible alert.
  }

  /// Wait for `session.state` to transition to `.started` (with a timeout).
  /// Used only by the inline (DSM-disabled) fallback path — the DSM
  /// `manager.acquire(...)` does the equivalent wait internally.
  ///
  /// Background: `DeviceSession.start()` is `throws` but returns
  /// synchronously after flipping the state to `.starting`. The transition
  /// to `.started` is async (BT/WiFi handshake). Calling `addStream(config:)`
  /// before `.started` returns nil — the SDK's documented contract. This
  /// helper subscribes to `statePublisher`, bridges to AsyncStream, and
  /// awaits the transition with a watchdog timer.
  ///
  /// Modeled on `StreamSessionViewModel.awaitDeviceSessionStarted(_:timeout:)`.
  fileprivate static func awaitDeviceSessionStarted(
    _ session: DeviceSession,
    timeout: TimeInterval
  ) async throws {
    if session.state == .started { return }

    let (stateStream, continuation) = AsyncStream<DeviceSessionState>.makeStream()
    let listenerToken = session.statePublisher.listen { state in
      continuation.yield(state)
    }
    defer { _ = listenerToken }

    // Recheck after subscribing to catch a transition that landed between
    // the entry check and the listener install.
    if session.state == .started {
      continuation.finish()
      return
    }

    let started: Bool = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
      group.addTask {
        for await state in stateStream {
          if state == .started { return true }
          if state == .stopped { return false }
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

    if !started {
      throw DeviceSessionError.unexpectedError(description: "Session never reached .started within \(timeout)s")
    }
  }

  /// iPhone-native video source. Throttled at the shared 0.5 fps / 0.5 quality
  /// so the token budget math carries over from the glasses path. Returns
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
          return self.isGeminiReady && self.pendingToolCallIds.isEmpty
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
          }
        }
        source?.submit(sampleBuffer)
      }

      // MILESTONE 2 wiring — feed the hand-tracking output into MediaPipe,
      // ingest each frame into the Meta XR micro-gesture recognizer, and
      // log any emitted event. No HUD binding yet (deferred to the next
      // milestone once reliability is validated on-device).
      //
      // Same lens-output gate as the glasses path above: when sending
      // trees to the lens, Neural Band drives input.
      let lensOutputActive = UserDefaults.standard.bool(forKey: "lensOutputEnabled")
      if HandTrackingConfig.isAvailable && !HandGestureService.isDisabled && !lensOutputActive {
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
      } else if lensOutputActive {
        print("[GeminiLive] Hand tracking suppressed — lens output active, input routes through Neural Band")
      } else if HandGestureService.isDisabled {
        print("[GeminiLive] Hand tracking suppressed by user setting")
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

    // Same readiness-wait pattern as the glasses path.
    await cameraLifecycleTask?.value
    if cameraSetupFailed { return false }
    return await awaitCameraReady(timeout: 8.0)
  }

  /// Enqueue camera teardown onto the lifecycle chain. Safe to call while a
  /// prior setup Task is still running — this one awaits it first, so start
  /// and stop never race for the same streamSession / iPhoneCamera refs.
  func stopCameraStream() {
    let prior = cameraLifecycleTask
    cameraLifecycleTask = Task { [weak self] in
      await prior?.value
      guard let self = self else { return }

      // Capture whether the active session was acquired via the manager
      // BEFORE we drop any references. Reads the same toggle that
      // setupCameraStream branched on so start/stop stay symmetric.
      let usedManager = self.deviceSessionManagerEnabled

      // Tokens FIRST so any trailing publisher events stop hitting the
      // frame fan-out closures (which may be mid-teardown themselves).
      self.videoFrameListenerToken = nil
      self.stateListenerToken = nil
      self.sessionErrorsCancellable?.cancel()
      self.sessionErrorsCancellable = nil

      if let session = self.streamSession {
        await session.stop()
      }
      self.streamSession = nil

      // DeviceSession lifecycle: under the manager, release the lease and
      // let the manager decide whether to stop the underlying session
      // (it stays alive if another consumer like lens still holds it).
      // Under the inline path, stop it ourselves like before.
      if usedManager, let manager = self.sessionManager {
        self.deviceSession = nil
        await manager.release(consumerLabel: "gemini-live")
      } else {
        self.deviceSession?.stop()
        self.deviceSession = nil
      }

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
