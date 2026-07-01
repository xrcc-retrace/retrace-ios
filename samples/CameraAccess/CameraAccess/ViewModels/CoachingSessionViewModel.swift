import Combine
import MWDATCamera
import MWDATCore
import SwiftUI

enum StepNavigationDirection: Equatable {
  case next
  case previous
}

enum HUDStepTransitionState: Equatable {
  case idle
  case syncing(direction: StepNavigationDirection, targetStepNumber: Int?)
}

/// Direction the step card slides during a step transition. Drives the
/// asymmetric `.transition(...)` on the lens step card. Forward = old
/// slides off-left, new arrives from the right; backward = inverse.
enum SlideDirection: Equatable {
  case none
  case forward
  case backward
}

/// Learner-mode coaching session. Inherits the shared Gemini Live
/// machinery from `GeminiLiveSessionBase` and plugs in coaching-specific
/// behavior via template-method overrides.
///
/// Mode-specific state: procedure-bound step tracking, `showPiP` reference
/// clips, oracle-poll scheduler (POSTs the latest camera JPEG to the
/// server-side `/verify` visual oracle on a timer, then relays advances /
/// corrections into Gemini Live as text turns), progress-store
/// integration, session-duration display. Everything else — audio, camera
/// (both transports), WebSocket, tool-call forwarding, transcripts,
/// barge-in, session resumption — lives on the base.
@MainActor
class CoachingSessionViewModel: GeminiLiveSessionBase {

  // MARK: - Mode-specific published state

  @Published var currentStepIndex = 0
  @Published var isCompleted = false
  @Published var showPiP = false
  @Published private(set) var hudStepTransitionState: HUDStepTransitionState = .idle
  @Published private(set) var stepJustCompletedTick: Int = 0

  /// Step index whose card the lens HUD should render. Lags
  /// `currentStepIndex` by 0.7s during a forward `advance_step`
  /// celebration so the OLD card stays on screen long enough to play
  /// the green-overlay + checkmark sequence before sliding off. For
  /// every other path (initial seed, `go_to_step`, completion-page
  /// swap) it tracks `currentStepIndex` synchronously.
  @Published private(set) var displayedStepIndex: Int = 0
  /// When non-nil, the card matching this index renders the
  /// celebration overlay (green fill → checkmark → "Step completed").
  /// Only set during forward `advance_step`. The OLD index goes here
  /// — the overlay rides the OLD card off-screen during the slide.
  @Published private(set) var celebratingStepIndex: Int? = nil
  /// Drives the asymmetric `.transition(...)` on the lens step card.
  /// `.none` while idle so SwiftUI doesn't apply a transition to the
  /// initial render.
  @Published private(set) var slideDirection: SlideDirection = .none

  // MARK: - Inputs

  private let procedure: ProcedureResponse
  private let _transport: CaptureTransport
  private var sessionStartTime: Date?
  private var sessionRecordId: String?
  private weak var progressStore: LocalProgressStore?
  private var pendingStartingStep: Int?

  // Active/Passive monitoring (read from "activeMonitoringEnabled" at session
  // start). The Active/Passive toggle is the master switch for proactive
  // visual monitoring: when false the `[check]` heartbeat is never armed, so
  // the model gets no silent-period evaluation turns — no visual interjection
  // and no visual step advance. Captured here so onConnectedExtra() (which also
  // fires on resumption reconnects) keeps honoring it.
  private var activeMonitoring = true

  // MARK: - Oracle poll (server-side visual verification)
  //
  // Visual step verification lives on the SERVER, not in Gemini Live. On the
  // same timer that used to send a `[check]` marker into the Live socket, we
  // now POST the learner's latest camera JPEG to
  // `/api/learner/session/{id}/verify`. A Flash model on the server compares
  // it against the step's spatial end-state + error states and returns a
  // verdict; on a confirmed completion the server advances the session and
  // returns the next-step payload, on a visible mistake it returns a
  // correction. The phone mirrors local UI and INJECTS a text turn into Live
  // (which stays purely conversational) so it speaks the event. Live no
  // longer receives `[check]` at all.
  //
  //   Primary path — onTurnComplete → sleep → poll. Fallback — a second
  //   sleep reschedules so a silent stretch doesn't stall the poll loop.
  //
  // These are coaching-only. Diagnostic / future modes don't poll.

  private var heartbeatTask: Task<Void, Never>?
  private var heartbeatEnabled = false
  private static let oraclePollIntervalSeconds: UInt64 = 4
  /// Cached most-recent encoded camera JPEG, updated from `onEncodedFrame`
  /// (the same throttled ~1fps frames the base already sends to Gemini Live).
  /// The oracle poll ships this; nil until the first frame arrives.
  private var lastFrameJPEG: Data?
  /// Quiet-streak window used by the poll gate. The gate refuses to poll
  /// if `lastAudioActivityAt` is within this window. 1.5s comfortably
  /// bridges the longest natural gaps between Gemini's audio chunks
  /// (~0.3-0.5s at sentence boundaries) and the local playback tail, so
  /// the gate cannot pass mid-utterance from either side — an oracle-
  /// injected turn can't collide with a real user or model turn.
  private static let heartbeatQuietWindow: TimeInterval = 1.5

  // MARK: - Computed

  var currentStep: ProcedureStepResponse? {
    guard currentStepIndex < procedure.steps.count else { return nil }
    return procedure.steps.sorted { $0.stepNumber < $1.stepNumber }[currentStepIndex]
  }

  /// Step the lens HUD should render. Equal to `currentStep` except
  /// during the brief celebration window after a forward `advance_step`,
  /// where it lags so the OLD card stays visible while the green
  /// overlay + checkmark play before the slide.
  var displayedStep: ProcedureStepResponse? {
    let sorted = procedure.steps.sorted { $0.stepNumber < $1.stepNumber }
    guard displayedStepIndex < sorted.count else { return nil }
    return sorted[displayedStepIndex]
  }

  // MARK: - Step transition timeline
  //
  // Forward `advance_step` runs a staged ~1.0s timeline (0.20s green
  // fade-in, 0.20s checkmark arrival, 0.30s hold, 0.30s slide). Other
  // step transitions just slide directionally with no overlay. The VM
  // owns the timeline so durations stay deterministic — view code
  // animates by reacting to published state changes, never by polling.

  private var transitionTask: Task<Void, Never>?

  private func startForwardCelebration(fromIndex: Int, toIndex: Int) {
    transitionTask?.cancel()
    // celebratingStepIndex is the only state that flips at t=0. We
    // intentionally do NOT touch slideDirection or displayedStepIndex
    // here — keeping every other binding stable until the moment of
    // the slide prevents SwiftUI from re-evaluating the host card's
    // `.transition(...)` mid-frame and producing a visible layout
    // twitch before the green overlay fades in.
    celebratingStepIndex = fromIndex
    CompletionFeedback.playStepComplete()  // no-op stub; sound asset deferred
    transitionTask = Task { @MainActor [weak self] in
      // 1.5s = 0.20 fade-in + 0.20 checkmark + 1.10 hold. The longer
      // hold lets the success beat actually register before the slide;
      // the prior 0.30 hold flashed by faster than the user could read
      // "Step completed". Then swap the displayed index so SwiftUI runs
      // the asymmetric slide transition.
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      guard let self, !Task.isCancelled else { return }
      // Set slideDirection and displayedStepIndex in the same
      // transaction so the .transition value is current at the moment
      // .id flips. `withAnimation` opens the spring context that
      // SwiftUI uses for the .id-driven slide.
      self.slideDirection = .forward
      withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
        self.displayedStepIndex = toIndex
      }
      // 0.30s slide window. Keep `celebratingStepIndex == fromIndex`
      // through the whole slide so the OLD card carries its overlay
      // off-screen; clearing it mid-slide would cross-fade the overlay
      // away while the card is still visible.
      try? await Task.sleep(nanoseconds: 300_000_000)
      guard !Task.isCancelled else { return }
      self.celebratingStepIndex = nil
      self.slideDirection = .none
    }
  }

  private func slideDisplayedIndex(to targetIndex: Int, direction: SlideDirection) {
    transitionTask?.cancel()
    celebratingStepIndex = nil
    // Set slideDirection and displayedStepIndex in the same
    // transaction so the .transition value is current at the moment
    // .id flips. `withAnimation` opens the spring context that
    // SwiftUI uses for the .id-driven slide.
    slideDirection = direction
    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
      displayedStepIndex = targetIndex
    }
    transitionTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 300_000_000)
      guard let self, !Task.isCancelled else { return }
      self.slideDirection = .none
    }
  }

  private func resetTransitionState(toIndex: Int) {
    transitionTask?.cancel()
    transitionTask = nil
    celebratingStepIndex = nil
    slideDirection = .none
    displayedStepIndex = toIndex
  }

  /// Frozen total duration, captured the moment the session completes so the
  /// "Procedure Complete" panel doesn't keep ticking.
  private var frozenSessionDuration: TimeInterval?

  // MARK: - Lens read accessors (Step 6 — Native lens renderer)
  //
  // `procedure` itself is `private`; these computed accessors expose
  // exactly what `CoachingLensRenderer` needs without giving the renderer
  // mutable access to internal state. No behavior change.

  var lensProcedureId: String { procedure.id }
  var lensProcedureTitle: String { procedure.title }
  var lensTotalSteps: Int { procedure.steps.count }
  /// Procedure-level `source_type` (`video` / `manual` / `web`). The lens
  /// renderer needs it to decide whether a step's reference is a playable
  /// clip or a static manual-page image. See `StepReferenceMedia`.
  var lensProcedureSourceType: String? { procedure.sourceType }

  /// Fired when the user confirms exit from the **native lens** exit overlay.
  /// The host (`CoachingSessionView`) installs the same terminal action its
  /// own overlay runs — `endSession(progressStore:)` + SwiftUI `dismiss()` —
  /// because both the progress store and the navigation dismiss live in the
  /// view layer and aren't reachable from the lens renderer. Mirrors the
  /// `onBackGesture` bridge pattern.
  var onExitConfirmed: (() -> Void)?

  var formattedSessionDuration: String {
    let elapsed: TimeInterval
    if let frozen = frozenSessionDuration {
      elapsed = frozen
    } else if let start = sessionStartTime {
      elapsed = Date().timeIntervalSince(start)
    } else {
      elapsed = 0
    }
    let mins = Int(elapsed) / 60
    let secs = Int(elapsed) % 60
    return String(format: "%d:%02d", mins, secs)
  }

  // MARK: - Init

  init(
    procedure: ProcedureResponse,
    wearables: WearablesInterface,
    serverBaseURL: String,
    transport: CaptureTransport = .glasses,
    sessionManager: DeviceSessionManager,
    externalAudioManager: AudioSessionManager? = nil
  ) {
    self.procedure = procedure
    self._transport = transport
    super.init(
      wearables: wearables,
      serverBaseURL: serverBaseURL,
      sessionManager: sessionManager,
      externalAudioManager: externalAudioManager
    )
  }

  // MARK: - Lifecycle (public entry / exit)

  func startSession(progressStore: LocalProgressStore, startingStep: Int? = nil) {
    print("[Coaching] ── session STARTED (transport=\(_transport), procedure=\(procedure.id), startingStep=\(startingStep.map(String.init) ?? "nil"))")
    // Reset mode-specific state. Base fields are handled by
    // startGeminiLiveSession → stopGeminiLiveSession.
    // Server is 1-indexed, VM is 0-indexed. `startingStep == nil` means fresh
    // session at step 1 → index 0.
    let seededIndex = max(0, (startingStep ?? 1) - 1)
    currentStepIndex = seededIndex
    isCompleted = false
    frozenSessionDuration = nil
    showPiP = false
    hudStepTransitionState = .idle
    pendingStartingStep = startingStep
    resetTransitionState(toIndex: seededIndex)

    self.progressStore = progressStore
    sessionStartTime = Date()
    let record = progressStore.startSession(
      procedureId: procedure.id,
      procedureTitle: procedure.title,
      totalSteps: procedure.steps.count,
      stepsCompleted: seededIndex
    )
    sessionRecordId = record.id

    Task {
      await startGeminiLiveSession()
    }
  }

  func endSession(progressStore: LocalProgressStore) {
    guard let recordId = sessionRecordId else { return }
    let status: SessionStatus = isCompleted ? .completed : .abandoned
    progressStore.updateSession(id: recordId, stepsCompleted: currentStepIndex, status: status)

    // Snapshot before stopGeminiLiveSession() nils sessionId, then fire the
    // DELETE in the background. Without this the server's in-memory _sessions
    // dict grows unboundedly — sessions are never cleaned up server-side
    // until the process restarts.
    let sidToDelete = sessionId
    let base = serverBaseURL
    if let sid = sidToDelete {
      Task.detached {
        await Self.deleteLearnerSession(sessionId: sid, serverBaseURL: base)
      }
    }

    stopGeminiLiveSession()
    stopCameraStream()
    print("[Coaching] ── session ENDED")
  }

  /// `GlassesRuntime` teardown: run the normal end-session cleanup using the
  /// stored progress store, then AWAIT the camera teardown so the coordinator
  /// can guarantee the glasses camera is off before returning to the phone.
  override func shutdown() async {
    if let store = progressStore {
      endSession(progressStore: store)
    } else {
      stopGeminiLiveSession()
      stopCameraStream()
    }
    await awaitCameraTeardown()
  }

  private static func deleteLearnerSession(sessionId: String, serverBaseURL: String) async {
    guard let url = URL(string: "\(serverBaseURL)/api/learner/session/\(sessionId)") else {
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.timeoutInterval = 5
    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      let code = (response as? HTTPURLResponse)?.statusCode ?? -1
      if !(200...299).contains(code) {
        print("[Coaching] Session DELETE returned HTTP \(code)")
      }
    } catch {
      // Best-effort. Server's in-memory state will be lost on restart anyway.
      print("[Coaching] Session DELETE failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Base overrides (template hooks)

  override func mintSession() async throws -> SessionStartPayload {
    // Single Active/Passive setting drives both wire flags: Active = monitoring
    // + auto-advance on; Passive = both off (fully reactive, verbal-only).
    activeMonitoring = UserDefaults.standard.object(forKey: "activeMonitoringEnabled") as? Bool ?? true
    print("[Coaching] active_monitoring = \(activeMonitoring) (from UserDefaults; auto_advance follows)")
    let selectedVoice = VoiceSettings.storedVoice()
    print("[Coaching] voice = \(selectedVoice) (from UserDefaults)")

    let apiService = ProcedureAPIService()
    let response = try await apiService.startLearnerSession(
      procedureId: procedure.id,
      voice: selectedVoice,
      autoAdvance: activeMonitoring,
      activeMonitoring: activeMonitoring,
      startingStep: pendingStartingStep
    )
    return SessionStartPayload(
      sessionId: response.sessionId,
      ephemeralToken: response.ephemeralToken
    )
  }

  override var toolCallURLSuffix: String {
    guard let sid = sessionId else { return "/api/learner/session//tool-call" }
    return "/api/learner/session/\(sid)/tool-call"
  }

  override var toolCallTimeoutSeconds: TimeInterval { 10 }

  override var introSeedText: String? { "Hi, I'm ready to begin." }

  override var transport: CaptureTransport { _transport }

  /// `.coaching` on glasses (allows HFP route), `.coachingPhoneOnly` on iPhone.
  override var audioSessionMode: AudioSessionMode {
    _transport == .iPhone ? .coachingPhoneOnly : .coaching
  }

  /// Coaching exposes the walkie-talkie Talk button (gated to the iPhone
  /// Mac-route demo by `isPushToTalkActive` in the base).
  override var supportsPushToTalk: Bool { true }

  override func onConnectedExtra() {
    // The oracle poll arms on every .connected transition (including
    // resumption reconnects). scheduleNextHeartbeat cancels any prior tick
    // before starting, so this is safe to call more than once.
    //
    // Passive mode (Active Monitoring off) is the master switch: never arm the
    // poll loop, so no frames are sent to the server oracle and no visual
    // interjection / advance happens — fully reactive, verbal-only.
    guard activeMonitoring else {
      heartbeatEnabled = false
      print("[Coaching] passive mode — oracle poll disabled")
      return
    }
    heartbeatEnabled = true
    scheduleNextHeartbeat()
  }

  override func onTurnCompleteExtra() async {
    // Poll cadence is anchored on turnComplete: this re-arms ~4s after the
    // model finishes replying, so the poll (and any advance/correction turn
    // it injects) naturally avoids colliding with the model mid-speech.
    scheduleNextHeartbeat()
  }

  override func willStopGeminiLiveSession() {
    // Stop the oracle-poll scheduler BEFORE the base drops Combine subs so
    // an in-flight Task.sleep can't wake up into a half-torn-down service.
    heartbeatEnabled = false
    heartbeatTask?.cancel()
    heartbeatTask = nil
  }

  override func handleToolCallExtras(name: String, args: [String: Any], result: [String: Any]) async {
    applyLearnerToolResult(name: name, args: args, result: result)
  }

  /// Cache the freshest encoded camera JPEG for the oracle poll. Runs on the
  /// MainActor for every frame the base hands to Gemini Live (both transports),
  /// so we reuse the existing ~1fps capture pipeline — no second camera.
  override func onEncodedFrame(_ jpeg: Data) {
    lastFrameJPEG = jpeg
  }

  override func toolCallSummary(name: String, args: [String: Any], result: [String: Any]) -> String {
    switch name {
    case "advance_step":
      if let status = result["status"] as? String, status == "completed" {
        return "Procedure complete"
      }
      if let newStep = result["new_step"] as? Int,
         let title = result["step_title"] as? String {
        return "Advanced to step \(newStep): \(title)"
      }
      return "Advanced step"
    case "go_to_step":
      if let step = result["current_step"] as? Int,
         let title = result["step_title"] as? String {
        return "Jumped to step \(step): \(title)"
      }
      if let step = args["step_number"] as? Int {
        return "Jumped to step \(step)"
      }
      return "Jumped step"
    case "get_reference_clip":
      if let step = result["step_number"] as? Int {
        return "Showing reference clip for step \(step)"
      }
      return "Showing reference clip"
    default:
      return name
    }
  }

  override func contextSummaryForReconnect() async -> String? {
    guard let sid = sessionId else { return nil }
    do {
      return try await ProcedureAPIService().fetchContextSummary(sessionId: sid)
    } catch {
      print("[Coaching] Failed to fetch context summary: \(error)")
      return nil
    }
  }

  /// Single source of truth for whether the HUD is allowed to mutate the
  /// learner session from a manual swipe. Gates both the swipe affordance and
  /// the commit-time action to prevent races against Gemini readiness and
  /// in-flight tool calls.
  var canPerformManualHUDNavigation: Bool {
    hudStepTransitionState == .idle
      && sessionId != nil
      && isGeminiReady
      && geminiConnectionState == .connected
      && pendingToolCallIds.isEmpty
      && !isCompleted
  }

  func navigateStepFromHUD(direction: StepNavigationDirection) async {
    guard canPerformManualHUDNavigation else { return }
    guard let sessionId else { return }

    let toolName: String
    let arguments: [String: Any]
    let targetStepNumber: Int?

    switch direction {
    case .next:
      toolName = "advance_step"
      arguments = [:]
      let predicted = currentStepIndex + 2
      targetStepNumber = predicted <= procedure.steps.count ? predicted : nil
    case .previous:
      guard currentStepIndex > 0 else { return }
      toolName = "go_to_step"
      arguments = ["step_number": currentStepIndex]
      targetStepNumber = currentStepIndex
    }

    hudStepTransitionState = .syncing(direction: direction, targetStepNumber: targetStepNumber)
    showPiP = false

    defer {
      hudStepTransitionState = .idle
    }

    let apiService = ProcedureAPIService()

    do {
      let result = try await apiService.invokeLearnerToolCall(
        sessionId: sessionId,
        toolName: toolName,
        arguments: arguments
      )
      applyLearnerToolResult(name: toolName, args: arguments, result: result)
      await syncGeminiAfterManualNavigation(direction: direction, result: result)
    } catch {
      print("[Coaching] Manual HUD navigation failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Oracle poll scheduling (coaching-only)

  private func scheduleNextHeartbeat() {
    guard heartbeatEnabled else { return }
    heartbeatTask?.cancel()
    heartbeatTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: Self.oraclePollIntervalSeconds * 1_000_000_000)
      guard !Task.isCancelled, let self = self, self.heartbeatEnabled else { return }
      // Foolproof gate: never poll (and never inject an advance/correction
      // turn) while either side is producing audio or a tool call is in
      // flight. See `canSendHeartbeatNow` for the truth table.
      guard self.canSendHeartbeatNow() else {
        // Activity within the quiet window (or the model is mid-turn,
        // or a tool is in flight). Bail this tick and let the fallback
        // re-arm us so a stuck silent stretch doesn't stall forever.
        self.scheduleHeartbeatFallback()
        return
      }
      await self.runOraclePoll()
      // Fallback: an oracle poll rarely triggers a model turn (no
      // onTurnComplete fires on a skip/pending), so re-arm ourselves.
      self.scheduleHeartbeatFallback()
    }
  }

  private func scheduleHeartbeatFallback() {
    heartbeatTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: Self.oraclePollIntervalSeconds * 1_000_000_000)
      guard !Task.isCancelled, let self = self, self.heartbeatEnabled else { return }
      self.scheduleNextHeartbeat()
    }
  }

  /// Single source of truth for whether an oracle poll is safe to run right
  /// now. Three independent gates — wire-level, local-playback, and
  /// quiet-streak — must all be quiet. Any one alone has a known race;
  /// together they're foolproof. Gating the poll (not just the send) keeps an
  /// oracle-injected `[ADVANCE]`/`[CORRECTION]` turn from colliding with a
  /// real user turn or the model's own in-flight generation.
  ///
  /// - `isModelGenerating`: Gemini wire flag, set on each inbound audio
  ///   chunk and cleared on `turnComplete` / `interrupted` / 2s watchdog.
  ///   Independent of `AVAudioPlayerNode` so it can't be fooled by gaps.
  /// - `isAISpeaking`: belt — local `scheduledBufferCount > 0`.
  /// - quiet streak on `lastAudioActivityAt`: catches inter-chunk gaps,
  ///   the playback tail, and active user speech (mic peak above floor).
  private func canSendHeartbeatNow() -> Bool {
    guard isGeminiReady, pendingToolCallIds.isEmpty else { return false }
    guard !isModelGenerating, !isAISpeaking else { return false }
    let sinceActivity = Date().timeIntervalSince(lastAudioActivityAt)
    return sinceActivity >= Self.heartbeatQuietWindow
  }

  /// One oracle tick: ship the latest camera JPEG to the server-side visual
  /// oracle, then act on the verdict. `advanced`/`completed` update local UI
  /// via the existing `applyLearnerToolResult` path (the server already
  /// advanced the session) and inject a congratulatory `[ADVANCE]` turn;
  /// `error` injects a `[CORRECTION]` turn without touching step state.
  private func runOraclePoll() async {
    guard activeMonitoring, canSendHeartbeatNow() else { return }
    guard let sessionId, let frame = lastFrameJPEG else { return }

    let resp: VerifyResponse
    do {
      resp = try await ProcedureAPIService().verifyStep(sessionId: sessionId, frameJPEG: frame)
    } catch {
      // Treat a failed / timed-out poll as a skipped tick.
      print("[Coaching] oracle verify failed: \(error)")
      return
    }

    guard let service = geminiService else { return }

    switch resp.status {
    case "skip", "pending":
      // Nothing confirmed this tick — verbal-only step, not auto-advancing,
      // or the end-state isn't visible yet.
      break

    case "error":
      let correction = resp.errorText ?? ""
      do {
        try await service.sendClientTextTurn(
          "[CORRECTION] \(correction). Tell the learner concisely how to fix it."
        )
        appendOracleActivity("Correction: \(correction)")
      } catch {
        print("[Coaching] oracle correction inject failed: \(error)")
      }

    case "advanced":
      // Server already advanced the session; mirror local UI exactly like a
      // tool-call advance, then tell Live to coach the next step.
      var result: [String: Any] = ["status": "advanced"]
      if let n = resp.newStep { result["new_step"] = n }
      if let t = resp.stepTitle { result["step_title"] = t }
      if let d = resp.stepDescription { result["step_description"] = d }
      if let c = resp.completionCriteria { result["completion_criteria"] = c }
      applyLearnerToolResult(name: "advance_step", args: [:], result: result)
      appendOracleActivity("Advanced to step \(resp.newStep.map(String.init) ?? "?")")
      do {
        try await service.sendClientTextTurn(
          "[ADVANCE] The learner just finished this step. Next step: "
          + "\(resp.stepTitle ?? "") — \(resp.stepDescription ?? ""). "
          + "Congratulate them briefly, then coach this next step."
        )
      } catch {
        print("[Coaching] oracle advance inject failed: \(error)")
      }

    case "completed":
      applyLearnerToolResult(
        name: "advance_step",
        args: [:],
        result: ["status": "completed", "message": resp.message ?? ""]
      )
      appendOracleActivity("Procedure complete")
      do {
        try await service.sendClientTextTurn(
          "[ADVANCE] The learner just finished the final step. "
          + "Give them a short, warm congratulations to close out."
        )
      } catch {
        print("[Coaching] oracle completion inject failed: \(error)")
      }

    default:
      break
    }
  }

  private func appendOracleActivity(_ text: String) {
    activity.append(ActivityEntry(
      kind: .toolCall(name: "verify"),
      text: text,
      timestamp: Date()
    ))
    trimActivity()
  }

  private func applyLearnerToolResult(name: String, args: [String: Any], result: [String: Any]) {
    switch name {
    case "advance_step":
      if let status = result["status"] as? String, status == "completed" {
        if let start = sessionStartTime {
          frozenSessionDuration = Date().timeIntervalSince(start)
        }
        isCompleted = true
        let finalIndex = max(0, procedure.steps.count - 1)
        currentStepIndex = finalIndex
        // Procedure-complete swaps the entire page set to
        // `[.completion]` (CoachingCompletionPage takes over). Skip our
        // celebration timeline — that page transition is the finale.
        resetTransitionState(toIndex: finalIndex)
        if let rid = sessionRecordId {
          progressStore?.updateSession(
            id: rid,
            stepsCompleted: procedure.steps.count,
            status: .completed
          )
        }
        stepJustCompletedTick &+= 1
      } else if let newStep = result["new_step"] as? Int {
        let targetIndex = max(0, newStep - 1)
        let oldIndex = currentStepIndex
        let didAdvance = targetIndex != oldIndex
        isCompleted = false
        currentStepIndex = targetIndex
        if let rid = sessionRecordId {
          progressStore?.updateSession(
            id: rid,
            stepsCompleted: currentStepIndex,
            status: .inProgress
          )
        }
        if didAdvance {
          stepJustCompletedTick &+= 1
          if targetIndex > oldIndex {
            startForwardCelebration(fromIndex: oldIndex, toIndex: targetIndex)
          } else {
            // Backward via advance_step is unusual but possible if Gemini
            // emits a lower step number — slide back without overlay.
            slideDisplayedIndex(to: targetIndex, direction: .backward)
          }
        }
      }

    case "get_reference_clip":
      showPiP = true

    case "go_to_step":
      if let stepNumber = result["current_step"] as? Int {
        let targetIndex = max(0, stepNumber - 1)
        let oldIndex = currentStepIndex
        isCompleted = false
        currentStepIndex = targetIndex
        if let rid = sessionRecordId {
          progressStore?.updateSession(
            id: rid,
            stepsCompleted: currentStepIndex,
            status: .inProgress
          )
        }
        if targetIndex != oldIndex {
          // `go_to_step` is a manual jump in either direction. No
          // celebration overlay — only forward `advance_step` marks an
          // actual completion. Slide direction matches travel direction.
          slideDisplayedIndex(
            to: targetIndex,
            direction: targetIndex > oldIndex ? .forward : .backward
          )
        }
      }

    default:
      break
    }
  }

  private func syncGeminiAfterManualNavigation(
    direction: StepNavigationDirection,
    result: [String: Any]
  ) async {
    guard let geminiService else {
      print("[Coaching] Manual step sync skipped: Gemini service unavailable")
      return
    }

    let syncText = manualNavigationSyncText(direction: direction, result: result)

    do {
      try await geminiService.sendClientTextTurn(syncText)
    } catch {
      print("[Coaching] Manual step sync message failed: \(error.localizedDescription)")
    }
  }

  private func manualNavigationSyncText(
    direction: StepNavigationDirection,
    result: [String: Any]
  ) -> String {
    if let stepNumber = (result["current_step"] as? Int) ?? (result["new_step"] as? Int),
       let title = result["step_title"] as? String {
      return "I manually moved to step \(stepNumber), \(title). Continue coaching from the current step."
    }

    switch direction {
    case .next:
      return "I manually moved to the next step. Continue coaching from the current step."
    case .previous:
      return "I manually went back one step. Continue coaching from the current step."
    }
  }
}
