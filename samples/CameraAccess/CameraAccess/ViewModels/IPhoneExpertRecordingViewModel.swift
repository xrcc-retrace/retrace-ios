import AVFoundation
import Combine
import CoreMedia
import Foundation
import MWDATCore
import SwiftUI

/// The captured recording, ready to hand to the review flow. Published by
/// `IPhoneExpertRecordingViewModel.handoff` once the mp4 is finalized AND
/// (when the interviewer is on) the debrief has finished.
struct RecordingHandoff: Equatable {
  let url: URL
  let duration: TimeInterval
}

/// iPhone-native counterpart to `StreamSessionViewModel`. Owns an
/// `AVCaptureSession` (via `IPhoneCameraCapture`), the same `ExpertRecordingManager`
/// the glasses path uses, and an `AudioSessionManager` pinned to the built-in mic.
///
/// Lifecycle:
///   1. User lands on `IPhoneRecordingView` → `prepare()` requests camera + mic
///      permission and starts the capture session (preview goes live).
///   2. User taps record → `startRecording()` fires the existing
///      `ExpertRecordingManager.startRecording()` (writer + audio capture).
///      Sample buffers already flowing from the capture session feed into
///      `recordingManager.appendVideoFrame(_:)` while `isRecording` is true.
///   3. User taps stop → `finishRecording()` finalizes the `.mp4`, runs the
///      interviewer's debrief if one is active, and publishes `handoff` so
///      the view can dismiss and route into the sibling review cover.
///   4. On view disappear → `teardown()` stops the capture session + unsets
///      the sample-buffer callback.
///
/// **Expert interviewer** (`InterviewerMode` ≠ `.off`): this VM also owns the
/// shared audio session for the interviewer. The audio manager runs in
/// `.interview` (full-duplex, AEC, loudspeaker) and capture starts in
/// `prepare()` — before recording — so the Live socket can connect for the
/// pre-roll briefing. The recorder is constructed `borrowedSession: true` so
/// its Stop doesn't kill capture (the debrief needs the mic afterwards); this
/// VM stops capture in `teardown()`. Camera frames are tee'd at 1 fps into
/// the interviewer via `IPhoneCoachingCameraSource`. If the `.interview`
/// session fails to start, we fall back to today's `.recordingPhoneOnly`
/// recorder — the recording always wins.
@MainActor
final class IPhoneExpertRecordingViewModel: ObservableObject {
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published var isPreviewLive: Bool = false
  /// True from Stop until the debrief finished (interviewer on) — the view
  /// shows the debrief overlay and waits for `handoff`.
  @Published private(set) var isDebriefing: Bool = false
  /// Set exactly once per recording when the review flow may begin.
  @Published private(set) var handoff: RecordingHandoff?

  let interviewerMode: InterviewerMode
  private(set) var audioSessionManager: AudioSessionManager
  private(set) var recordingManager: ExpertRecordingManager
  /// nil when `interviewerMode == .off`.
  let interviewer: ExpertInterviewViewModel?
  let uploadService: UploadService
  let camera = IPhoneCameraCapture()

  /// State layer behind the Expert HUD — tip rotation, audio meter
  /// smoothing, mic-source. Bound to the audio manager in `init`.
  let hudViewModel = ExpertRecordingHUDViewModel()

  /// MediaPipe hand-landmark service. Shares the same `HandTrackingConfig`
  /// gate as the Learner Coaching path — model file bundled → available.
  /// Owned here so the lifecycle matches the camera's. Mirrors
  /// `GeminiLiveSessionBase.handLandmarkerService`.
  private var handLandmarkerService: HandLandmarkerService?

  /// 1 fps JPEG tee feeding the interviewer (planner + Live). Reuses the
  /// coaching source: same throttle, same re-entry guard, own queue — it
  /// never touches the writer's `recordingQueue`.
  private var frameTee: IPhoneCoachingCameraSource?

  private var recordingManagerCancellable: AnyCancellable?
  private var interviewerCancellable: AnyCancellable?
  /// Owns capture when the interviewer is on (see class doc).
  private var ownsAudioCapture = false
  private var pendingHandoff: RecordingHandoff?

  init(
    uploadService: UploadService,
    wearables: WearablesInterface,
    sessionManager: DeviceSessionManager,
    interviewerMode: InterviewerMode = .stored()
  ) {
    self.uploadService = uploadService
    self.interviewerMode = interviewerMode

    let audio = AudioSessionManager(mode: interviewerMode == .off ? .recordingPhoneOnly : .interview)
    self.audioSessionManager = audio
    self.recordingManager = ExpertRecordingManager(
      audioSessionManager: audio,
      borrowedSession: interviewerMode != .off
    )
    self.interviewer = interviewerMode == .off ? nil : ExpertInterviewViewModel(
      mode: interviewerMode,
      wearables: wearables,
      serverBaseURL: ServerEndpoint.shared.resolvedBaseURL,
      sessionManager: sessionManager
    )

    bindRecordingManager()
    hudViewModel.bind(audioSessionManager: audio)

    if let interviewer {
      interviewer.videoTimeProvider = { [weak self] in self?.recordingManager.videoTimeNow }
      interviewer.isStopCountdownActive = { [weak self] in self?.hudViewModel.stopCountdownActive ?? false }
      // Debrief done → write the sidecar log → release the hand-off.
      interviewerCancellable = interviewer.$finalLog
        .compactMap { $0 }
        .receive(on: RunLoop.main)
        .sink { [weak self] log in
          self?.completeHandoff(with: log)
        }
    }
  }

  var previewLayer: AVCaptureVideoPreviewLayer {
    camera.previewLayer
  }

  // SwiftUI doesn't chain observation into nested ObservableObjects, so
  // without this bridge the Start/Stop toggle and timer overlay never
  // redraw when `recordingManager.isRecording` / `recordingDuration` flip.
  // Re-emit its objectWillChange through the outer VM so any subview
  // observing `self` rebuilds.
  private func bindRecordingManager() {
    recordingManagerCancellable = recordingManager.objectWillChange
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.objectWillChange.send() }
  }

  // MARK: - Session lifecycle

  /// Request permissions and bring up the capture session. Safe to call more
  /// than once — `IPhoneCameraCapture.start()` is idempotent.
  func prepare() async {
    // Defensive reset in case SwiftUI ever caches this @StateObject across
    // presentations. Today a new VM is built on each fullScreenCover, but
    // these resets cost nothing and guard the invariant.
    showError = false
    errorMessage = ""

    let cameraGranted = await camera.requestPermission()
    guard cameraGranted else {
      surfaceError("Camera permission denied — open Settings to grant access.")
      return
    }

    let micGranted = await audioSessionManager.requestMicrophonePermission()
    guard micGranted else {
      surfaceError("Microphone permission denied — open Settings to grant access.")
      return
    }

    // Pre-warm the audio session NOW, while the user is still landing on
    // this screen. By the time they tap Start, the session is in `.record`,
    // the input AU has cached the real hardware format, and any queued
    // route-change notifications have drained — eliminating the -10868
    // race that was producing silent recordings.
    await audioSessionManager.prewarm()

    if interviewer != nil {
      await startInterviewerAudioAndSession()
    }

    // Capture the tee by value: this closure runs on the capture queue and
    // must not read main-actor state. The tee is created (or nil) before
    // this point and only ever dropped after `onSampleBuffer` is cleared.
    let tee = frameTee
    camera.onSampleBuffer = { [weak self] sampleBuffer in
      guard let self else { return }
      // Tee BEFORE the main-actor hop: the source throttles to 1 fps and
      // encodes on its own queue, so this is a lock + compare per frame.
      tee?.submit(sampleBuffer)
      // Hop to MainActor so we can read `recordingManager.isRecording` and call
      // the @MainActor API; `appendVideoFrame` itself dispatches to its serial
      // `recordingQueue`, so the hop only pays for the gate check.
      Task { @MainActor in
        guard self.recordingManager.isRecording else { return }
        self.recordingManager.appendVideoFrame(sampleBuffer)
      }
    }

    startHandTrackingIfAvailable()

    do {
      try await camera.start()
      isPreviewLive = camera.isRunning
    } catch {
      surfaceError("Could not start iPhone camera: \(error.localizedDescription)")
    }
  }

  /// Start the shared `.interview` capture early and connect the interviewer.
  /// Any failure here degrades to a plain recording — never to no recording.
  private func startInterviewerAudioAndSession() async {
    guard let interviewer else { return }
    do {
      try await audioSessionManager.startCaptureAsync()
      ownsAudioCapture = true
    } catch {
      print("[Expert] .interview audio failed to start (\(error)) — falling back to plain recording")
      fallBackToPlainRecording()
      return
    }

    if let tee = makeFrameTee(for: interviewer) {
      frameTee = tee
    }
    await interviewer.start(borrowing: audioSessionManager)
    if !interviewer.isInterviewerAvailable {
      print("[Expert] interviewer unavailable — recording continues with notes-only planner off")
    }
  }

  private func makeFrameTee(for interviewer: ExpertInterviewViewModel) -> IPhoneCoachingCameraSource? {
    IPhoneCoachingCameraSource(minInterval: 1.0, jpegQuality: 0.85) { [weak interviewer] jpeg in
      await MainActor.run { interviewer?.ingestFrame(jpeg) }
    }
  }

  /// The `.interview` session couldn't start. Swap in the pre-interviewer
  /// pipeline: a fresh `.recordingPhoneOnly` manager and a recorder that owns
  /// its own capture start/stop. The HUD and the recorder bridge rebind.
  private func fallBackToPlainRecording() {
    audioSessionManager.stopCapture()
    let audio = AudioSessionManager(mode: .recordingPhoneOnly)
    audioSessionManager = audio
    recordingManager = ExpertRecordingManager(audioSessionManager: audio, borrowedSession: false)
    bindRecordingManager()
    hudViewModel.bind(audioSessionManager: audio)
    ownsAudioCapture = false
    frameTee = nil
    Task { await audio.prewarm() }
    objectWillChange.send()
  }

  /// Spin up the MediaPipe hand landmarker and wire the camera's secondary
  /// BGRA output into it. Feeds each detection into the HUD view model,
  /// which handles both the landmark-overlay publish and the gesture
  /// recognizer. No-op when `HandTrackingConfig.isAvailable` is false
  /// (model file not bundled, previews, etc.) so the rest of the pipeline
  /// runs unchanged on devices without the `.task` asset.
  private func startHandTrackingIfAvailable() {
    // Routed through the shared `HandGestureService.shouldStart(for:)`
    // helper so every start site (Coaching iPhone path, Troubleshoot
    // iPhone path, Expert iPhone path) shares one truth table — and
    // glasses-transport call sites never start MediaPipe.
    guard HandGestureService.shouldStart(for: .iPhone) else {
      if !HandTrackingConfig.isAvailable {
        print("[Expert] Hand tracking unavailable — model not bundled")
      } else if HandGestureService.isDisabled {
        print("[Expert] Hand tracking suppressed by user setting")
      }
      return
    }

    // Fresh recognizer state + cleared debug log per camera session so
    // no stale TRACKING state carries over from a prior recording view.
    // Tip cycling is now installed by the focus engine (see
    // `ExpertTipPageHandler` on `ExpertNarrationTipPage`), not via a
    // service-level `onEvent` hook.
    hudViewModel.resetHandTracking()

    let service = HandLandmarkerService()
    do {
      try service.start()
    } catch {
      print("[Expert] Hand tracking disabled: \(error.localizedDescription)")
      return
    }

    service.onResult = { [weak self] frame in
      Task { @MainActor in
        self?.hudViewModel.ingestHandFrame(frame)
      }
    }
    handLandmarkerService = service

    camera.onHandSampleBuffer = { [weak service] sampleBuffer in
      service?.submit(sampleBuffer: sampleBuffer)
    }
    print("[Expert] Hand tracking started — pinch-drag recognizer armed")
  }

  /// Start the mp4 writer + audio tap. Video frames are already arriving from
  /// the capture session; `ExpertRecordingManager` only forwards them once
  /// `isRecording` is true. The manager's `startRecording()` is `async` so
  /// that the AVAssetWriter + audio session setup can run off the main
  /// thread; we fire-and-forget the Task here — the manager flips
  /// `isStarting` / `isRecording` published flags as it progresses.
  ///
  /// `landscape` picks the writer dimensions (1280×720 landscape vs 720×1280
  /// portrait). The caller must have already flipped
  /// `camera.setCaptureLandscapeOutput(_:)` so frames arrive at the matching
  /// rotation before the writer sees them.
  func startRecording(landscape: Bool) {
    guard isPreviewLive else {
      surfaceError("Camera isn't ready yet.")
      return
    }
    let size = landscape
      ? ExpertRecordingManager.landscapeSize
      : ExpertRecordingManager.portraitSize
    Task { [weak self] in
      guard let self else { return }
      // `startRecording` returns nil on success, or an error describing
      // why the recording could not begin (audio engine wedged, writer
      // setup failed, …). Surface it through the existing alert so the
      // user knows to tap Start again instead of getting a silent mp4.
      if let err = await self.recordingManager.startRecording(width: size.width, height: size.height) {
        self.surfaceError(err.errorDescription ?? "Couldn't start recording.")
        return
      }
      self.interviewer?.recordingDidStart()
    }
  }

  /// Finalize the mp4. Returns the captured `(URL, duration)` on success.
  /// Prefer `finishRecording()` from the UI — it also runs the debrief.
  func stopRecording() async -> (URL, TimeInterval)? {
    let duration = recordingManager.recordingDuration
    _ = await recordingManager.stopRecording()
    if let url = recordingManager.recordingURL {
      return (url, duration)
    }
    surfaceError("Recording failed — no usable video was captured.")
    return nil
  }

  /// Stop tapped. Finalizes the mp4, then either hands off immediately or
  /// (interviewer on) runs the debrief on the still-open socket and hands
  /// off when `ExpertInterviewViewModel.finalLog` lands.
  func finishRecording() async {
    guard handoff == nil, pendingHandoff == nil else { return }
    guard let (url, duration) = await stopRecording() else { return }
    let result = RecordingHandoff(url: url, duration: duration)

    guard let interviewer, interviewer.phase == .recording || interviewer.phase == .preroll else {
      handoff = result
      return
    }
    pendingHandoff = result
    isDebriefing = true
    await interviewer.recordingDidStop()
    // Completion arrives via the `$finalLog` sink → `completeHandoff`.
  }

  /// "Done" on the debrief overlay.
  func skipDebrief() {
    Task { await interviewer?.endDebrief() }
  }

  private func completeHandoff(with log: InterviewLog) {
    guard let result = pendingHandoff else { return }
    pendingHandoff = nil
    do {
      try InterviewLogStore.save(log, besides: result.url)
    } catch {
      print("[Expert] failed to save interview sidecar: \(error)")
    }
    isDebriefing = false
    handoff = result
  }

  /// Stop capture session and drop the sample-buffer callback. Call from
  /// `onDisappear` so the AVCaptureSession doesn't keep running when the
  /// user backs out. Also fully deactivates the AVAudioSession so leaving
  /// Expert mode lets other apps' background audio resume cleanly —
  /// `AudioSessionManager.stopCapture()` only flips the category for
  /// recording modes, it doesn't deactivate.
  func teardown() async {
    camera.onSampleBuffer = nil
    camera.onHandSampleBuffer = nil
    frameTee = nil
    await camera.stop()
    handLandmarkerService?.stop()
    handLandmarkerService = nil
    hudViewModel.resetHandTracking()
    if let interviewer {
      await interviewer.shutdown()
    }
    if ownsAudioCapture {
      audioSessionManager.stopCapture()
      ownsAudioCapture = false
    }
    audioSessionManager.deactivate()
    isPreviewLive = false
  }

  // MARK: - Error surfacing

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  private func surfaceError(_ message: String) {
    errorMessage = message
    showError = true
  }
}
