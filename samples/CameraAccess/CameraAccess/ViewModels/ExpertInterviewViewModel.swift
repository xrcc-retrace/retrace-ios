import AVFoundation
import Combine
import CoreMedia
import Foundation
import MWDATCore
import SwiftUI

/// Expert Interviewer: a Gemini Live session that runs ALONGSIDE expert
/// recording and asks the questions a learner would have needed.
///
/// Three loops, each with one job (docs/expert-interviewer-design.md §3):
///
///   • **Planner tick** (~5 s): posts the latest camera JPEG + the last ~6 s of
///     the expert's narration (from `micRing`) to `/observe`. The SERVER
///     decides whether there is a gap worth asking about and returns an
///     `InterviewAsk` with a TTL.
///   • **Pause gate** (250 ms): holds a returned ask until the expert has been
///     quiet for `policy.silenceBeforeAskSeconds`, nothing is playing, and the
///     HUD stop-countdown isn't showing — then injects `[ASK] …` into Live.
///     Expired asks are reported `deferred` (→ debrief), never dropped.
///   • **Answer window** state machine: Live voices the question → mic opens →
///     the expert answers → Live acknowledges (or asks ONE follow-up) → mic
///     closes → `/answer`. Between windows Live hears NOTHING: an open mic
///     makes it reply to every pause in the narration. `recomputeSendGate` is
///     overridden so `answerWindowOpen` is a hard input to the mic gate.
///
/// Audio/camera are BORROWED from the recording pipeline (`externalAudioManager`
/// + `usesExternalFrameSource`): one `AudioSessionManager` in `.interview` mode
/// feeds the writer (primary tap slot), this Live session (secondary slot) and
/// the planner ring (`onMicPCM16`); one `AVCaptureSession` feeds the writer and
/// a 1 fps JPEG tee. The recording VM owns capture start/stop so the debrief
/// can run on the same socket after Stop.
@MainActor
final class ExpertInterviewViewModel: GeminiLiveSessionBase {

  // MARK: - Published state (observed by the overlay)

  enum Phase: String { case idle, preroll, recording, debrief, finalized }

  @Published private(set) var phase: Phase = .idle
  /// Question currently being asked / answered (nil between windows).
  @Published private(set) var currentQuestion: String?
  /// True while the mic is open for an answer — the overlay shows a
  /// "listening" state so the expert always knows when the assistant hears.
  @Published private(set) var isListeningForAnswer = false
  @Published private(set) var quietMode = false
  @Published private(set) var openGaps = 0
  @Published private(set) var answeredCount = 0
  @Published private(set) var liveAsksUsed = 0
  /// False when the server session couldn't be minted or the socket never
  /// connected within the start timeout — recording continues unaffected.
  @Published private(set) var isInterviewerAvailable = true
  @Published private(set) var debriefQuestions: [InterviewAsk] = []
  @Published private(set) var debriefAnsweredIds: Set<String> = []
  /// Set once by `finalize()`; the recording VM writes it beside the mp4.
  @Published private(set) var finalLog: InterviewLog?

  // MARK: - Inputs

  let mode: InterviewerMode
  var taskHint: String = ""
  /// Seconds into the recording right now, or nil before the writer's
  /// timeline origin exists (pre-roll / after Stop). Injected by the owner.
  var videoTimeProvider: () -> Double? = { nil }
  /// True while the HUD's 3 s stop-confirm countdown is showing.
  var isStopCountdownActive: () -> Bool = { false }

  // MARK: - Private

  private let api = InterviewAPIService()
  private var policy: InterviewPolicyConfig = .fallback
  /// Written from the audio tap thread via `onMicPCM16`, read on tick.
  nonisolated private let micRing = PCMRingBuffer(seconds: 8)
  private var latestFrameJPEG: Data?
  private var tickerTask: Task<Void, Never>?
  private var gateTask: Task<Void, Never>?
  private var windowTimerTask: Task<Void, Never>?
  private var debriefCapTask: Task<Void, Never>?
  private var plannerBackoffUntil: Date = .distantPast
  private var ownCancellables: Set<AnyCancellable> = []

  // Pause gate
  private var pendingAsk: (ask: InterviewAsk, deadline: Date)?

  // Answer window
  private enum Window: Equatable {
    case idle
    case asking(InterviewAsk)      // inject sent; Live is voicing the question
    case listening(InterviewAsk)   // mic open, waiting for the expert
    case answering(InterviewAsk)   // expert spoke; waiting for Live's ack/follow-up
  }
  private var window: Window = .idle
  private var answerWindowOpen = false
  private var windowOpenedAt: Date?
  private var listeningSince: Date?
  private var lastLearnerSpeechAt: Date?
  private var answerBuffer = ""
  private var assistantTurnBuffer = ""
  private var followUps = 0
  private var windowTAsk: Double?
  private var pendingOutcome: InterviewAnswerOutcome?
  private var hasBriefed = false
  private var briefingAsk: InterviewAsk {
    InterviewAsk(questionId: "briefing", topicKey: "briefing", priority: "tip",
                 question: "What are you about to show, and what will you need?",
                 ttlSeconds: 0, injectText: "")
  }

  // Speech windows (video time) — the server ducks these out of every clip.
  private var speechWindows: [[Double]] = []
  private var speechStartT: Double?

  // Debrief
  private var debriefIndex = 0
  private var debriefCurrentAnswer = ""
  private var debriefAnswers: [String: String] = [:]
  private var debriefEnding = false

  // Local Q/A outcomes (merged into the log in case /answer calls were lost)
  private var localOutcomes: [String: (outcome: InterviewAnswerOutcome, transcript: String, tAsk: Double?, tClose: Double?)] = [:]
  private var diag: [String: Int] = [:]

  init(
    mode: InterviewerMode,
    wearables: WearablesInterface,
    serverBaseURL: String,
    sessionManager: DeviceSessionManager
  ) {
    self.mode = mode
    super.init(wearables: wearables, serverBaseURL: serverBaseURL, sessionManager: sessionManager)
  }

  // MARK: - Lifecycle (driven by IPhoneExpertRecordingViewModel)

  /// Connect, borrowing the recording pipeline's already-capturing audio
  /// manager. Never throws and never blocks recording: on any failure
  /// `isInterviewerAvailable` flips false and the owner records as usual.
  func start(borrowing audio: AudioSessionManager) async {
    guard mode != .off else { return }
    externalAudioManager = audio
    sessionDidEnd = false
    phase = .preroll
    observeSpeechWindows()

    await startGeminiLiveSession()

    guard sessionId != nil else {
      isInterviewerAvailable = false
      print("[Interview] session mint failed — recording continues without the interviewer")
      return
    }
    // Planner runs even if the voice socket is flaky: the ledger still fills
    // and the debrief can still happen as a text card.
    startTicker()
    if mode == .on { startGate() }
  }

  func recordingDidStart() {
    guard phase == .preroll else { return }
    phase = .recording
    micRing.reset()
  }

  /// Called after the writer finalized. Runs the debrief on the same socket;
  /// completion is signalled by `finalLog` becoming non-nil.
  func recordingDidStop() async {
    guard phase == .recording || phase == .preroll else { return }
    phase = .debrief
    tickerTask?.cancel()
    gateTask?.cancel()
    if let pending = pendingAsk {
      pendingAsk = nil
      await report(ask: pending.ask, outcome: .deferred, transcript: "", tAsk: nil, tClose: nil)
    }
    if window != .idle {
      await closeWindow(outcome: pendingOutcome ?? (answerBuffer.isEmpty ? .interrupted : .answered))
    }
    guard let sid = sessionId, isInterviewerAvailable else {
      await finalize()
      return
    }
    do {
      let debrief = try await api.debrief(sessionId: sid, maxQuestions: 5)
      debriefQuestions = debrief.questions
      guard !debrief.questions.isEmpty, geminiConnectionState == .connected else {
        await finalize()
        return
      }
      debriefIndex = 0
      debriefCurrentAnswer = ""
      debriefAnswers = [:]
      debriefEnding = false
      currentQuestion = nil
      // Debrief is a normal back-and-forth: mic stays open for its duration.
      setAnswerWindowOpen(true)
      try await geminiService?.sendClientTextTurn(debrief.injectText)
      debriefCapTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)
        guard !Task.isCancelled else { return }
        await self?.endDebrief()
      }
    } catch {
      print("[Interview] debrief failed (\(error)) — finalizing")
      await finalize()
    }
  }

  /// End the debrief early (Done button or "done" said aloud) or when the
  /// last question was answered.
  func endDebrief() async {
    guard phase == .debrief, !debriefEnding else { return }
    debriefEnding = true
    debriefCapTask?.cancel()
    setAnswerWindowOpen(false)
    if let sid = sessionId {
      // Report whatever was captured per question; the server merges.
      for (i, q) in debriefQuestions.enumerated() {
        let text = debriefAnswers[q.questionId] ?? (i == debriefIndex ? debriefCurrentAnswer : "")
        let outcome: InterviewAnswerOutcome = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .unanswered : .answered
        localOutcomes[q.questionId] = (outcome, text, nil, nil)
        try? await api.answer(sessionId: sid, report: InterviewAnswerReport(
          questionId: q.questionId, transcript: text, outcome: outcome, tAsk: nil, tClose: nil))
      }
    }
    await finalize()
  }

  /// `GlassesRuntime`-style teardown. The owner stops capture; we only detach.
  override func shutdown() async {
    tickerTask?.cancel(); gateTask?.cancel(); windowTimerTask?.cancel(); debriefCapTask?.cancel()
    ownCancellables.removeAll()
    if let sid = sessionId, phase != .finalized {
      let api = self.api
      Task { await api.end(sessionId: sid) }
    }
    sessionDidEnd = true
    stopGeminiLiveSession()
    stopCameraStream()
    await awaitCameraTeardown()
  }

  // MARK: - Frame tee entry

  /// Called ~1 fps by the recording VM's JPEG tee. Caches the frame for the
  /// planner and forwards it to Live through the base's send gate.
  func ingestFrame(_ jpeg: Data) {
    latestFrameJPEG = jpeg
    submitExternalFrame(jpeg)
  }

  // MARK: - Base overrides

  override func mintSession() async throws -> SessionStartPayload {
    let response = try await api.start(voice: "Kore", transport: "iphone", taskHint: taskHint)
    policy = response.policy ?? .fallback
    return SessionStartPayload(sessionId: response.sessionId, ephemeralToken: response.ephemeralToken)
  }

  override var toolCallURLSuffix: String {
    guard let sid = sessionId else { return "/api/expert/interview/session//tool-call" }
    return "/api/expert/interview/session/\(sid)/tool-call"
  }

  override func tokenRefreshPath(sessionId: String) -> String {
    "/api/expert/interview/session/\(sessionId)/token"
  }

  override var transport: CaptureTransport { .iPhone }
  override var audioSessionMode: AudioSessionMode { .interview }
  override var usesExternalFrameSource: Bool { true }
  override var usesSecondaryMicSlot: Bool { true }
  override var observesMicPCM: Bool { true }
  override var introSeedText: String? { nil }
  override var flushPlaybackOnToolCall: Bool { false }

  nonisolated override func onMicPCM16(_ pcm: Data) {
    micRing.append(pcm)
  }

  /// Mic → Live only inside an answer window (or while muted = never).
  override func recomputeSendGate() {
    isSendingAudio = !isMuted && answerWindowOpen
  }

  override func resumptionInjectText(summary: String) -> String {
    "Session resumed. You are the quiet production assistant; stay silent until the next bracketed event turn."
  }

  override func contextSummaryForReconnect() async -> String? { "" }

  override func onConnectedExtra() {
    voiceStatus = "Interviewer ready"
    // Optional one-question briefing before recording starts.
    guard mode == .on, phase == .preroll, !hasBriefed, let sid = sessionId else { return }
    hasBriefed = true
    Task { [weak self] in
      guard let self else { return }
      guard let text = try? await self.api.briefingInject(sessionId: sid) else { return }
      guard self.phase == .preroll, self.window == .idle else { return }
      await self.deliver(ask: self.briefingAsk, injectText: text)
    }
  }

  override func appendTranscript(kind: ActivityEntry.Kind, delta: String) {
    super.appendTranscript(kind: kind, delta: delta)
    switch kind {
    case .learner:
      lastLearnerSpeechAt = Date()
      if phase == .debrief {
        debriefCurrentAnswer += delta
        if matches(delta, Self.doneWords) { Task { await endDebrief() } }
        return
      }
      answerBuffer += delta
      if case .listening(let ask) = window { window = .answering(ask) }
      detectReplyKeywords()
    case .assistant:
      assistantTurnBuffer += delta
    default:
      break
    }
  }

  override func onTurnCompleteExtra() async {
    defer { assistantTurnBuffer = "" }
    switch window {
    case .asking(let ask):
      // Live finished voicing the question → open the mic for the answer.
      window = .listening(ask)
      listeningSince = Date()
      setAnswerWindowOpen(true)
      startWindowTimer()
    case .answering(let ask):
      // Live replied to the answer: either an ack (close) or ONE follow-up.
      let askedFollowUp = assistantTurnBuffer.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
      if askedFollowUp, followUps < 1, pendingOutcome == nil {
        followUps += 1
        window = .listening(ask)
        listeningSince = Date()
      } else {
        await closeWindow(outcome: pendingOutcome ?? .answered)
      }
    case .listening:
      break  // Live spoke without input (rare) — keep waiting
    case .idle:
      if phase == .debrief { debriefTurnCompleted() }
    }
  }

  // MARK: - Planner ticker

  private func startTicker() {
    tickerTask?.cancel()
    tickerTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
        guard !Task.isCancelled, let self else { return }
        await self.tick()
      }
    }
  }

  private func tick() async {
    guard let sid = sessionId, phase == .preroll || phase == .recording else { return }
    guard Date() >= plannerBackoffUntil else { return }
    let wav = micRing.snapshotWAV(lastSeconds: 6)
    let speaking = Date().timeIntervalSince(lastAudioActivityAt) < 0.8
    do {
      let resp = try await api.observe(
        sessionId: sid, frameJPEG: latestFrameJPEG, audioWAV: wav,
        sampleRate: micRing.sampleRate, videoT: videoTimeProvider(),
        phase: phase.rawValue, speaking: speaking)
      openGaps = resp.openGaps
      answeredCount = resp.answered
      liveAsksUsed = resp.liveAsksUsed
      quietMode = resp.quietMode
      switch resp.status {
      case "planner_unavailable":
        plannerBackoffUntil = Date().addingTimeInterval(15)
        diag["planner_unavailable", default: 0] += 1
      case "finalized":
        tickerTask?.cancel()
      default:
        break
      }
      if let ask = resp.ask, mode == .on {
        pendingAsk = (ask, Date().addingTimeInterval(ask.ttlSeconds))
        print("[Interview] ask queued: \(ask.topicKey) (\(ask.priority)) ttl=\(ask.ttlSeconds)s")
      }
    } catch {
      diag["tick_errors", default: 0] += 1
      print("[Interview] observe failed: \(error)")
    }
  }

  // MARK: - Pause gate

  private func startGate() {
    gateTask?.cancel()
    gateTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled, let self else { return }
        await self.evaluateGate()
      }
    }
  }

  private func evaluateGate() async {
    guard let pending = pendingAsk else { return }
    if Date() > pending.deadline {
      pendingAsk = nil
      diag["asks_expired", default: 0] += 1
      await report(ask: pending.ask, outcome: .deferred, transcript: "", tAsk: nil, tClose: nil)
      return
    }
    guard phase == .recording, window == .idle, !quietMode,
          geminiConnectionState == .connected, !isAISpeaking,
          !isStopCountdownActive(),
          Date().timeIntervalSince(lastAudioActivityAt) >= policy.silenceBeforeAskSeconds
    else { return }
    pendingAsk = nil
    await deliver(ask: pending.ask, injectText: pending.ask.injectText)
  }

  private func deliver(ask: InterviewAsk, injectText: String) async {
    guard let gemini = geminiService else { return }
    window = .asking(ask)
    currentQuestion = ask.question
    windowTAsk = videoTimeProvider()
    windowOpenedAt = Date()
    answerBuffer = ""
    followUps = 0
    pendingOutcome = nil
    do {
      try await gemini.sendClientTextTurn(injectText)
      print("[Interview] ASK delivered: \(ask.question)")
    } catch {
      print("[Interview] inject failed: \(error)")
      await closeWindow(outcome: .interrupted)
    }
  }

  // MARK: - Answer window

  private func setAnswerWindowOpen(_ open: Bool) {
    answerWindowOpen = open
    isListeningForAnswer = open
    recomputeSendGate()
  }

  private func startWindowTimer() {
    windowTimerTask?.cancel()
    windowTimerTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard !Task.isCancelled, let self else { return }
        guard let opened = self.windowOpenedAt else { return }
        let now = Date()
        // Hard cap from the moment the question started (question + answer + ack).
        if now.timeIntervalSince(opened) > self.policy.answerWindowHardCapSeconds + 10 {
          await self.closeWindow(outcome: self.answerBuffer.isEmpty ? .unanswered : .answered)
          return
        }
        if case .listening = self.window, let since = self.listeningSince,
           self.lastLearnerSpeechAt.map({ $0 < since }) ?? true,
           now.timeIntervalSince(since) > self.policy.answerWindowSeconds {
          await self.closeWindow(outcome: .unanswered)
          return
        }
      }
    }
  }

  private func closeWindow(outcome: InterviewAnswerOutcome) async {
    windowTimerTask?.cancel()
    let ask: InterviewAsk?
    switch window {
    case .asking(let a), .listening(let a), .answering(let a): ask = a
    case .idle: ask = nil
    }
    setAnswerWindowOpen(false)
    window = .idle
    currentQuestion = nil
    let transcript = answerBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
    let tAsk = windowTAsk
    let tClose = videoTimeProvider()
    answerBuffer = ""
    followUps = 0
    pendingOutcome = nil
    windowOpenedAt = nil
    listeningSince = nil
    guard let ask, ask.questionId != briefingAsk.questionId else { return }
    await report(ask: ask, outcome: outcome, transcript: transcript, tAsk: tAsk, tClose: tClose)
  }

  private func report(ask: InterviewAsk, outcome: InterviewAnswerOutcome, transcript: String, tAsk: Double?, tClose: Double?) async {
    localOutcomes[ask.questionId] = (outcome, transcript, tAsk, tClose)
    guard let sid = sessionId else { return }
    do {
      try await api.answer(sessionId: sid, report: InterviewAnswerReport(
        questionId: ask.questionId, transcript: transcript, outcome: outcome, tAsk: tAsk, tClose: tClose))
    } catch {
      diag["answer_report_failures", default: 0] += 1
      print("[Interview] answer report failed: \(error)")
    }
  }

  // Spoken replies that steer the window (mirrors voice_commands.yaml's
  // expert_interview entries — keep the two in sync).
  private static let laterWords = ["later", "not now", "at the end", "ask me later", "hold that"]
  private static let skipWords = ["skip", "never mind", "doesn't matter", "not relevant"]
  private static let quietWords = ["stop asking", "no more questions", "hold your questions", "save it for the end", "quiet please", "let me focus"]
  private static let doneWords = ["done", "that's all", "that's it", "we're good", "i'm done", "finish"]

  private func matches(_ text: String, _ words: [String]) -> Bool {
    let lowered = text.lowercased()
    return words.contains { lowered.contains($0) }
  }

  private func detectReplyKeywords() {
    if matches(answerBuffer, Self.quietWords) {
      quietMode = true
      pendingOutcome = .deferred
    } else if matches(answerBuffer, Self.laterWords) {
      pendingOutcome = .deferred
    } else if matches(answerBuffer, Self.skipWords) {
      pendingOutcome = .skipped
    }
  }

  // MARK: - Debrief turn tracking

  private func debriefTurnCompleted() {
    guard !debriefEnding else { return }
    let spoke = !debriefCurrentAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if spoke, debriefIndex < debriefQuestions.count {
      let q = debriefQuestions[debriefIndex]
      debriefAnswers[q.questionId] = debriefCurrentAnswer
      debriefAnsweredIds.insert(q.questionId)
      debriefIndex += 1
      debriefCurrentAnswer = ""
    }
    if debriefIndex >= debriefQuestions.count {
      Task { await endDebrief() }
    } else {
      currentQuestion = debriefQuestions[debriefIndex].question
    }
  }

  // MARK: - Speech windows

  private func observeSpeechWindows() {
    $isAISpeaking
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] speaking in
        guard let self else { return }
        if speaking {
          speechStartT = videoTimeProvider()
        } else if let start = speechStartT, let end = videoTimeProvider(), end > start {
          // Small pad: playback-queue drain lags the last audible sample.
          speechWindows.append([max(0, start - 0.1), end + 0.2])
          speechStartT = nil
        } else {
          speechStartT = nil
        }
      }
      .store(in: &ownCancellables)
  }

  // MARK: - Finalize

  private func finalize() async {
    guard phase != .finalized else { return }
    phase = .finalized
    setAnswerWindowOpen(false)
    currentQuestion = nil
    tickerTask?.cancel(); gateTask?.cancel(); windowTimerTask?.cancel(); debriefCapTask?.cancel()

    var log = InterviewLog()
    log.sessionId = sessionId
    log.briefing = taskHint
    if let sid = sessionId, isInterviewerAvailable {
      if let server = try? await api.finalize(sessionId: sid) {
        log = server
      }
    }
    // Phone-only knowledge, always wins.
    log.version = 1
    log.aiSpeechWindows = speechWindows
    for i in log.qa.indices {
      if let local = localOutcomes[log.qa[i].questionId], (log.qa[i].answer ?? "").isEmpty, !local.transcript.isEmpty {
        log.qa[i].answer = local.transcript
        log.qa[i].outcome = local.outcome.rawValue
      }
    }
    var clientDiag: [String: JSONValue] = [
      "interviewer_mode": .string(mode.rawValue),
      "speech_windows": .number(Double(speechWindows.count)),
      "socket_connected_at_finalize": .bool(geminiConnectionState == .connected),
    ]
    for (k, v) in diag { clientDiag[k] = .number(Double(v)) }
    log.diagnostics = log.diagnostics.merging(.object(["client": .object(clientDiag)]))
    finalLog = log

    if let sid = sessionId {
      let api = self.api
      Task { await api.end(sessionId: sid) }
    }
  }
}
