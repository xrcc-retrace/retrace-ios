//
// GlassesNavigationCoordinator.swift
//
// Single owner of the glasses-first navigation session. Holds the
// `NavigatorViewModel` (lens nav state) and is the one object that:
//   - enters/exits glasses mode (activates `.navigator` on `LensSession`,
//     drives the phone "Session on glasses" standby presentation),
//   - (E3) swaps in a runtime VM for Record / Coaching and returns to the
//     navigator on exit.
//
// Injected as a `@StateObject` in `CameraAccessApp` and read by
// `ModeSelectionView` (entry button + standby cover) and
// `GlassesSessionStandbyView` (the ditto screen).
//
// The coordinator is always present but inert until `enterGlassesMode()`,
// reached from the "Launch on Display" entry button on the mode selector.
//

import AVFoundation
import Combine
import Foundation
import MWDATCore

@MainActor
final class GlassesNavigationCoordinator: ObservableObject {

  /// Lifecycle of a glasses-first launch.
  /// - `.idle`     — not launched; phone behaves normally.
  /// - `.preparing`— "Launch on Display" tapped; the readiness gate is up,
  ///                 running registration / connection / display-capability
  ///                 checks. The lens is NOT activated yet.
  /// - `.active`   — all checks passed; lens navigator is live and the phone
  ///                 shows the "Session on glasses" standby.
  enum Phase: Equatable {
    case idle
    case preparing
    case active
  }

  /// What the phone standby must host/draw. `.none` = pure nav (just the
  /// "Session on glasses" mirror). `.expertRecording` hosts the
  /// `StreamSessionViewModel` behind the "Recording on glasses" ditto.
  /// `.learnerCoaching` hosts the `CoachingSessionViewModel` (procedure carried
  /// separately in `coachingProcedure` so this enum stays trivially Equatable).
  /// `.troubleshootSession` hosts the `DiagnosticSessionViewModel`; a fix found
  /// there hands off into `.learnerCoaching` (reusing the same coaching host).
  /// `.askAI` hosts the audio-only `AskAISessionViewModel`; picking a result
  /// hands off into `.learnerCoaching`.
  enum RuntimeMode: Equatable {
    case none
    case expertRecording
    case learnerCoaching
    case troubleshootSession
    case askAI
  }

  /// Health of the glasses-native audio (HFP) pipeline. `.ok` normally; set to a
  /// failure case when the persistent HFP session can't deliver mic buffers, so
  /// the standby can show a warning overlay. Auto-recovers to `.ok` when buffers
  /// resume (via the `persistentAudio.$micStalled` subscription).
  enum AudioPipelineStatus: Equatable { case ok, micPermissionDenied, hfpNotFlowing }

  /// Health of the active runtime's camera branch, mirrored from whichever VM
  /// is hosted behind the standby (`GeminiLiveSessionBase.cameraHealth` for
  /// coaching/troubleshoot, `StreamSessionViewModel.cameraConnectionLost` for
  /// expert recording). Those VMs run invisibly behind the ditto screen, so
  /// this is the only way their frame-starvation watchdog reaches the
  /// phone-visible standby. See `observeCameraHealth(_:)`.
  enum CameraPipelineStatus: Equatable { case ok, disconnected }

  @Published private(set) var phase: Phase = .idle
  @Published private(set) var runtimeMode: RuntimeMode = .none

  /// Observable audio-pipeline health for the HFP warning overlay (phone-side).
  @Published private(set) var audioPipelineStatus: AudioPipelineStatus = .ok

  /// Observable camera-pipeline health for the standby's health banner.
  @Published private(set) var cameraPipelineStatus: CameraPipelineStatus = .ok

  /// A short "which step/phase am I on" label for the active runtime, shown
  /// alongside the health banner so a demo operator can tell where a failure
  /// happened (e.g. "Step 3 of 7", "Diagnose"). `nil` when the active runtime
  /// has no step/phase concept (expert recording, Ask AI) or none is active.
  /// See `observeStepLabel(_:)`.
  @Published private(set) var currentStepLabel: String?

  /// The procedure to coach while `runtimeMode == .learnerCoaching`.
  @Published private(set) var coachingProcedure: ProcedureResponse?

  /// True when the active coaching session was handed off FROM troubleshoot, so
  /// `exitCoaching()` returns to the troubleshoot intro instead of the Learner
  /// hub ("still in troubleshoot mode"). Reset on every coaching launch/exit.
  private var coachingFromTroubleshoot = false

  let navigatorVM: NavigatorViewModel
  /// Drives upload + processing poll after a glasses-first recording. Owned
  /// here so it survives the recording VM's teardown.
  let uploadService = UploadService()

  /// The just-recorded clip awaiting the user's Upload/Discard decision on the
  /// `.expertReview` lens gate. Held here (not in the VM) so the VM stays pure
  /// nav state and the coordinator owns the file lifecycle + upload.
  private var pendingRecordingURL: URL?
  private var pendingRecordingDuration: TimeInterval = 0

  private weak var lensSession: LensSession?
  private var uploadCancellables: Set<AnyCancellable> = []
  private let wearables: WearablesInterface
  /// Shared session owner — used to force a clean slate (no lens/DeviceSession
  /// holding the BT radio) before arming HFP.
  private let sessionManager: DeviceSessionManager

  /// The in-flight `enterGlassesMode()` arming Task. Held so `exitGlassesMode()`
  /// can await it first — otherwise an exit during `.preparing` could be overtaken
  /// by the arming Task, reviving audio + lens + `.active` after the user exited.
  private var enterTask: Task<Void, Never>?

  /// Combine subscription to `persistentAudio.$micStalled` for mid-session HFP
  /// loss → drives `audioPipelineStatus` while a glasses session is live.
  private var audioHealthCancellable: AnyCancellable?

  /// Combine subscription installed by the active runtime host, mirroring its
  /// VM's camera-health signal into `cameraPipelineStatus`. See
  /// `observeCameraHealth(_:)`.
  private var cameraHealthCancellable: AnyCancellable?

  /// Combine subscription installed by the active runtime host, mirroring its
  /// VM's current step/phase into `currentStepLabel`. See `observeStepLabel(_:)`.
  private var stepLabelCancellable: AnyCancellable?

  /// Glasses-native persistent audio. Armed ONCE in `enterGlassesMode()` —
  /// before the navigator Display — and kept alive for the whole glasses
  /// session, so every runtime (coaching / troubleshoot / Ask-AI / expert
  /// recording) BORROWS it instead of re-arming HFP per session. That removes
  /// the Display↔HFP radio handoff that starved the mic on a fast end→restart.
  /// Released in `exitGlassesMode()`. nil only before launch / after exit.
  private(set) var persistentAudio: AudioSessionManager?

  init(lensSession: LensSession, api: ProcedureAPIService, wearables: WearablesInterface, sessionManager: DeviceSessionManager) {
    self.lensSession = lensSession
    self.wearables = wearables
    self.sessionManager = sessionManager
    self.navigatorVM = NavigatorViewModel(api: api, progressStore: LocalProgressStore())
    // Record on the lens delegates here so the coordinator owns the session
    // swap (navigator → expert recording → navigator).
    self.navigatorVM.onRecordRequested = { [weak self] in
      self?.startExpertRecording()
    }
    // "Start coaching" on the Learner lens delegates here.
    self.navigatorVM.onCoachRequested = { [weak self] procedure in
      self?.startLearnerCoaching(procedure: procedure)
    }
    // "Start now" on the Troubleshoot intro delegates here.
    self.navigatorVM.onTroubleshootRequested = { [weak self] in
      self?.startTroubleshoot()
    }
    // "Ask AI" on the Learner hub delegates here.
    self.navigatorVM.onAskAIRequested = { [weak self] in
      self?.startAskAI()
    }
    // Upload-or-discard gate (`.expertReview`) intents delegate here so the
    // coordinator owns the recorded file + the upload pipeline.
    self.navigatorVM.onUploadRecording = { [weak self] in
      self?.confirmUploadPendingRecording()
    }
    self.navigatorVM.onDiscardRecording = { [weak self] in
      self?.discardPendingRecording()
    }
  }

  /// True once the lens navigator is live (used by the standby mirror).
  var isActive: Bool { phase == .active }

  /// Whether the active coaching session was handed off from troubleshoot
  /// (read by the standby mirror label).
  var isCoachingFromTroubleshoot: Bool { coachingFromTroubleshoot }

  /// The runtime VM currently hosted behind the standby (coaching / troubleshoot
  /// / Ask AI / recording). Set by each host on `.onAppear`. Weak — the host's
  /// `@StateObject` owns it; the host is still mounted when an exit begins, so
  /// this is valid through the awaited `shutdown()`. The single source of truth
  /// for "what do I need to tear down on exit."
  weak var activeRuntime: GlassesRuntime?

  /// Re-entrancy guard so a double-tap on "Take back on phone" can't run two
  /// teardowns concurrently.
  private var isExiting = false

  /// Fully tear down the active runtime and AWAIT completion (camera off +
  /// `gemini-live`/`expert` lease released) before the caller proceeds to tear
  /// down the lens or dismiss the cover. Idempotent — the host's `.onDisappear`
  /// backstop may also fire, harmlessly.
  private func teardownActiveRuntime() async {
    await activeRuntime?.shutdown()
    activeRuntime = nil
  }

  // MARK: - Launch lifecycle

  /// Phone "Launch on Display" → present the readiness gate. Does NOT touch
  /// the lens yet — we register + connect + verify a Display-capable device
  /// first (`GlassesReadinessGateView`), then call `enterGlassesMode()`.
  func beginLaunch() {
    guard phase == .idle else { return }
    phase = .preparing
  }

  /// Called by the readiness gate once registration + a connected,
  /// Display-capable device are confirmed. Activates the lens navigator and
  /// flips the phone to the "Session on glasses" standby.
  func enterGlassesMode() {
    guard phase == .preparing, !isExiting else { return }
    navigatorVM.reset()
    runtimeMode = .none
    // Arm HFP FIRST, then bring up the navigator Display — the documented
    // HFP-before-Display order. The phone stays on the preparing/readiness state
    // until the mic pipeline is up (≤~2 s on the SCO warmup ceiling).
    enterTask = Task { @MainActor [weak self] in
      guard let self, !self.isExiting, self.phase == .preparing else { return }
      // CLEAN SLATE before HFP: the glasses share ONE Bluetooth radio between the
      // HFP mic and the DAT Display/Stream capabilities, and HFP must come up
      // first — a residual lens or DeviceSession would starve the mic. Tear down
      // anything still running (safe no-op if nothing is) so HFP negotiates on a
      // free radio.
      await self.lensSession?.teardown()
      await self.sessionManager.resetForFreshSession(reason: "pre-HFP clean slate")
      guard !self.isExiting, self.phase == .preparing else { return }

      var locked = await self.armPersistentAudio()

      // First-buffer miss: the SCO link never proved it was carrying data within
      // the budget. Attaching the navigator Display now would perturb the shared
      // BT radio and tear down the not-yet-flowing HFP link, starving the mic for
      // the whole session. Retry the arm ONCE on a freshly-freed radio before
      // falling through to the Display attach. (If an exit overtakes during the
      // retry, the exit guard right below rolls the arm back.)
      if !locked, !self.isExiting, self.phase == .preparing {
        print("[GlassesNav] first mic buffer missed — retrying HFP arm once before Display attach")
        if let audio = self.persistentAudio {
          audio.stopCapture()
          audio.deactivate()
          self.persistentAudio = nil
        }
        self.audioHealthCancellable = nil
        await self.sessionManager.resetForFreshSession(reason: "pre-HFP retry clean slate")
        if !self.isExiting, self.phase == .preparing {
          locked = await self.armPersistentAudio()
        }
      }

      // An exit may have overtaken us during the SCO warmup — roll back the
      // arm and bail rather than reviving the session after the user exited.
      guard !self.isExiting, self.phase == .preparing else {
        if let audio = self.persistentAudio {
          audio.stopCapture()
          audio.deactivate()
          self.persistentAudio = nil
        }
        self.audioHealthCancellable = nil
        print("[GlassesNav] enter aborted post-arm (exit overtook); audio rolled back")
        return
      }

      // Still not flowing after the retry: proceed into the navigator anyway (the
      // user explicitly chose the glasses launch), but the `.hfpNotFlowing` status
      // is already surfaced via `audioPipelineStatus` so the standby UI warns and
      // the manager's config-change restart can still recover the mic late.
      if !locked {
        print("[GlassesNav] HFP still not confirmed after retry — entering navigator with mic warning surfaced")
      }

      // No `await` between here and `phase = .active` → atomic on the main actor.
      self.lensSession?.activate(.navigator, vm: self.navigatorVM)
      self.phase = .active
    }
  }

  /// Bring up the long-lived glasses HFP audio session. Mirrors
  /// `GeminiLiveSessionBase`'s proven arm sequence (configure → HFP warmup →
  /// startCapture → first-buffer wait) but with NO consumer attached: the engine
  /// runs and holds the SCO link idle until a runtime installs its
  /// `onAudioBuffer` endpoint. The readiness gate already confirmed a connected,
  /// Display-capable device, so the glasses HFP route can come up here.
  ///
  /// The `awaitFirstMicBuffer` wait is load-bearing: `awaitHFPRouteReady` only
  /// proves the HFP route *exists*, not that the SCO link is carrying data. The
  /// caller (`enterGlassesMode`) attaches the navigator Display capability right
  /// after this returns, and attaching Display on the shared BT radio tears down
  /// a route-ready-but-not-yet-flowing HFP link — starving the mic for the whole
  /// session ("No mic buffers since capture started"). Waiting for the first
  /// actual buffer here "locks in" HFP so the Display attach can't kill it —
  /// mirrors the runtime path's `awaitAudioReady` gate before its camera/Display
  /// branch.
  /// Returns `true` once the mic is confirmed flowing (first buffer landed),
  /// `false` on the first-buffer timeout or a missing mic permission — the
  /// caller uses this to decide whether it's safe to attach the Display.
  @discardableResult
  private func armPersistentAudio() async -> Bool {
    let audio = AudioSessionManager(mode: .coaching)
    audio.preferredGlassesNames = DeviceSessionManager.pairedDeviceNames(from: wearables)
    // CHECK the mic permission — do NOT request it here. Granting is a
    // deliberate, up-front step done in Settings / the home screen via
    // `MicrophonePermissionCTA`, not a lazy prompt buried in the session flow.
    // We still verify: arming the engine on a denied/undetermined mic starts
    // capture on a dead route (buffers never flow — "No mic buffers since
    // capture started") while the HFP route still looks healthy, so bail with
    // an actionable log instead of standing up a silent session.
    guard AVAudioApplication.shared.recordPermission == .granted else {
      print("[GlassesNav] ⚠ Microphone permission not granted — skipping audio arm so we don't "
        + "stand up a silent glasses session. Grant it in Settings › Microphone access "
        + "(or the home screen) before launching.")
      persistentAudio = nil
      audioPipelineStatus = .micPermissionDenied
      return false
    }
    audio.configureSessionOnly()
    // Budgets match the coaching runtime path (`GeminiLiveSessionBase`'s 8 s
    // `awaitAudioReady`): a cold Display-glasses SCO warmup routinely needs
    // more than the old 2 s / 3 s, and the engine's post-start configuration
    // change (restarted inside `AudioSessionManager`) can push the first buffer
    // out further still.
    _ = await audio.awaitHFPRouteReady(timeout: 4.0)
    audio.startCapture()
    // Lock in HFP: don't return (and let the caller attach the Display) until the
    // mic is actually delivering buffers, not just route-ready.
    let locked = await audio.awaitFirstMicBuffer(timeout: 8.0)
    persistentAudio = audio
    // Drive the HFP warning overlay off the manager's live mic-stall signal:
    // `micStalled` is true at startup if the first buffer never arrived (set in
    // `awaitFirstMicBuffer`'s timeout) and mid-session if buffers stop; it
    // auto-recovers to false when buffers flow, so the overlay clears itself.
    audioHealthCancellable = audio.$micStalled
      .receive(on: DispatchQueue.main)
      .sink { [weak self] stalled in
        self?.audioPipelineStatus = stalled ? .hfpNotFlowing : .ok
      }
    print("[GlassesNav] persistent glasses audio armed (HFP \(locked ? "locked in — buffers flowing" : "NOT confirmed — no buffer in 3s"), idle until a runtime attaches)")
    // On a first-buffer miss, dump the full audio state (permission, route,
    // VPIO, input format) so a silent mic is diagnosable from one console paste
    // — the coaching path already does this; the navigator used to fly blind.
    if !locked { print(audio.dumpAudioDiagnostics()) }
    return locked
  }

  /// Resend the current lens to the glasses display (recover the HUD after an
  /// accidental system back-gesture dismiss). Only meaningful while a glasses
  /// session is live.
  func resendLensToDisplay() {
    guard phase == .active else { return }
    lensSession?.resendLensToDisplay()
  }

  /// Called by the active runtime host on `.onAppear` to mirror its VM's
  /// camera-health signal (`true` == camera branch down) into
  /// `cameraPipelineStatus`, so the standby's health banner can see a failure
  /// that's otherwise invisible behind the `Color.clear` host.
  func observeCameraHealth<P: Publisher>(_ publisher: P) where P.Output == Bool, P.Failure == Never {
    cameraHealthCancellable = publisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] disconnected in
        self?.cameraPipelineStatus = disconnected ? .disconnected : .ok
      }
  }

  /// Called by the active runtime host on `.onAppear` to mirror its VM's
  /// current step/phase into `currentStepLabel`.
  func observeStepLabel<P: Publisher>(_ publisher: P) where P.Output == String?, P.Failure == Never {
    stepLabelCancellable = publisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] label in
        self?.currentStepLabel = label
      }
  }

  /// Cancel from the gate, or "Take back on phone" from the standby → tear the
  /// lens navigator down (if it was active) and return the phone to normal.
  func exitGlassesMode() {
    guard !isExiting else { return }
    isExiting = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      // Let any in-flight enter (arming HFP during `.preparing`) observe
      // `isExiting` and unwind FIRST, so it can't revive audio/lens after we exit.
      await self.enterTask?.value
      self.enterTask = nil
      // Tear the active runtime down FIRST and await it — the camera + Gemini
      // must be provably off and the DeviceSession lease released before we drop
      // the lens and return the phone to normal. (Was the bug: the cover
      // dismissed while a fire-and-forget teardown got abandoned mid-flight.)
      await self.teardownActiveRuntime()
      // HARD-detach the lens: suppress re-attach + release the "lens" lease,
      // AWAITED. The old `deactivate()` here only cleared the renderer and fired
      // an empty `send`, which lazily RE-ACQUIRED the DeviceSession the exit was
      // releasing (createSession vs WARP-drain race → sessionAlreadyExists).
      // `teardown()` releases it for real and blocks any trailing send from
      // reviving the Bluetooth session.
      if self.phase == .active {
        await self.lensSession?.teardown()
      }
      // Release the persistent HFP session LAST — after the active runtime is
      // down and the lens Display is released — so the radio is free and the
      // in-call/mic indicator clears.
      if let audio = self.persistentAudio {
        audio.stopCapture()
        audio.deactivate()
        self.persistentAudio = nil
        print("[GlassesNav] persistent glasses audio released")
      }
      self.audioHealthCancellable = nil
      self.audioPipelineStatus = .ok
      self.cameraHealthCancellable = nil
      self.cameraPipelineStatus = .ok
      self.stepLabelCancellable = nil
      self.currentStepLabel = nil
      self.uploadCancellables.removeAll()
      self.runtimeMode = .none
      self.coachingProcedure = nil
      self.coachingFromTroubleshoot = false
      self.phase = .idle
      self.isExiting = false
    }
  }

  /// Mount a full-duplex audio runtime (coaching / troubleshoot / Ask AI) behind
  /// the standby. HFP was armed BEFORE the navigator Display at launch
  /// (`armPersistentAudio`) and every runtime BORROWS that running session — no
  /// route reconfigure, no new audio capability. The documented "Display starts
  /// last, after HFP" order is already satisfied, so we KEEP the navigator
  /// Display attached and the host just swaps the lens renderer (navigator →
  /// runtime), with no teardown/re-push flicker. A camera runtime's `Stream`
  /// attaches onto the shared, already-Display-attached session — a supported
  /// case: `setupCameraStream`'s `acquire("gemini-live", .requiresDisplay)`
  /// reuses the session the `"lens"` consumer already holds rather than creating
  /// a private one.
  ///
  /// Expert recording uses the simplex `.recording` audio mode and is
  /// intentionally not routed through here.
  private func startAudioRuntime(_ mount: @escaping () -> Void) {
    // Clear any health/step signal left over from a prior mode (e.g. a
    // troubleshoot → coaching or Ask AI → coaching handoff) — the new host's
    // `.onAppear` re-subscribes immediately, but without this the banner
    // could briefly (or, if the new host never re-subscribes for some
    // reason, indefinitely) show a stale failure from the mode just exited.
    cameraHealthCancellable = nil
    cameraPipelineStatus = .ok
    stepLabelCancellable = nil
    currentStepLabel = nil
    Task { @MainActor [weak self] in
      guard let self else { return }
      mount()
    }
  }

  // MARK: - Expert recording (glasses-first)

  /// Lens "Record" tapped → host the recording VM behind the ditto. The host
  /// view (in `GlassesSessionStandbyView`) mounts `StreamSessionViewModel`,
  /// runs warmup, and activates the `.expert` lens renderer.
  func startExpertRecording() {
    guard phase == .active else { return }
    uploadService.reset()
    // See the matching reset in `startAudioRuntime` — same rationale, this
    // mode just isn't routed through that helper (simplex `.recording` audio).
    cameraHealthCancellable = nil
    cameraPipelineStatus = .ok
    stepLabelCancellable = nil
    currentStepLabel = nil
    runtimeMode = .expertRecording
  }

  /// Stop confirmed on the lens → finalize, return the lens to the navigator on
  /// the upload-or-discard gate (`.expertReview`), and stop hosting the
  /// recording VM. The upload does NOT fire yet — it waits for the user to tap
  /// Upload (mirrors the phone's `ExpertRecordingReviewView`).
  func reviewExpertRecording(url: URL, duration: TimeInterval) {
    pendingRecordingURL = url
    pendingRecordingDuration = duration
    navigatorVM.showRecordingReview(duration: duration)
    lensSession?.activate(.navigator, vm: navigatorVM)
    runtimeMode = .none
  }

  /// "Upload" tapped on the gate → show Processing and kick the upload. The lens
  /// is already on the navigator (activated in `reviewExpertRecording`).
  func confirmUploadPendingRecording() {
    guard let url = pendingRecordingURL else { return }
    navigatorVM.showProcessing()
    observeUpload()
    Task { await uploadService.uploadRecording(fileURL: url) }
    pendingRecordingURL = nil
  }

  /// "Discard" tapped on the gate → delete the temp clip and return to the
  /// Expert hub without uploading (mirrors the phone Discard).
  func discardPendingRecording() {
    if let url = pendingRecordingURL {
      try? FileManager.default.removeItem(at: url)
    }
    pendingRecordingURL = nil
    navigatorVM.goExpertHub()
  }

  /// Exit requested from the lens during pre-flight/recording → drop back to
  /// the Expert hub without uploading.
  func cancelExpertRecording() {
    runtimeMode = .none
    navigatorVM.goExpertHub()
    lensSession?.activate(.navigator, vm: navigatorVM)
  }

  // MARK: - Learner coaching (glasses-first)

  /// Lens "Start coaching" tapped → host the coaching VM behind the ditto. The
  /// host view (`GlassesCoachingHost`) mounts `CoachingSessionViewModel`, runs
  /// the Gemini Live session, and activates the `.coaching` lens renderer.
  func startLearnerCoaching(procedure: ProcedureResponse) {
    guard phase == .active else { return }
    coachingFromTroubleshoot = false
    startAudioRuntime { [weak self] in
      self?.coachingProcedure = procedure
      self?.runtimeMode = .learnerCoaching
    }
  }

  /// Exit confirmed on the lens (or coaching ended) → stop hosting the coaching
  /// VM and return the lens to the navigator. Lands on the troubleshoot intro
  /// when coaching was handed off from troubleshoot, else the Learner hub.
  func exitCoaching() {
    let fromTroubleshoot = coachingFromTroubleshoot
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.teardownActiveRuntime()
      self.runtimeMode = .none
      self.coachingProcedure = nil
      self.coachingFromTroubleshoot = false
      if fromTroubleshoot {
        self.navigatorVM.goTroubleshootIntro()
      } else {
        self.navigatorVM.goLearnerHub()
      }
      self.lensSession?.activate(.navigator, vm: self.navigatorVM)
    }
  }

  // MARK: - Troubleshoot (glasses-first)

  /// Lens "Start now" tapped → host the diagnostic VM behind the ditto. The host
  /// (`GlassesTroubleshootHost`) starts the Gemini Live session and activates
  /// the `.troubleshoot` lens renderer once `isReadyForNativeLens` flips.
  func startTroubleshoot() {
    guard phase == .active else { return }
    startAudioRuntime { [weak self] in self?.runtimeMode = .troubleshootSession }
  }

  /// Exit confirmed on the lens (or diagnostic ended) → stop hosting and return
  /// the lens to the navigator on the troubleshoot intro.
  func exitTroubleshoot() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.teardownActiveRuntime()
      self.runtimeMode = .none
      self.navigatorVM.goTroubleshootIntro()
      self.lensSession?.activate(.navigator, vm: self.navigatorVM)
    }
  }

  /// A fix was found and "Start" tapped on the lens → swap the diagnostic host
  /// for the coaching host (reusing `.learnerCoaching`), flagged so exit returns
  /// to troubleshoot. The diagnostic Gemini + camera were already torn down
  /// inside `executeHandoff`; a brief settle lets the shared camera/WARP threads
  /// drain before the coaching session re-acquires them (mirrors the phone's
  /// `TroubleshootSessionContainer` transitioning hold).
  func handoffToCoaching(procedure: ProcedureResponse) {
    coachingFromTroubleshoot = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      // Fully tear down the diagnostic runtime (camera + `gemini-live` lease)
      // and AWAIT it before coaching re-acquires — `executeHandoff` already
      // stopped Gemini/camera; this guarantees the lease is released first so
      // the new session can't race the old one for the shared session.
      await self.teardownActiveRuntime()
      self.runtimeMode = .none   // unmount the diagnostic host
      try? await Task.sleep(nanoseconds: 350_000_000)
      guard self.coachingFromTroubleshoot else { return }
      // HFP is already up (persistent audio armed at launch) and coaching borrows
      // it, so we keep the troubleshoot lens Display attached (no teardown/re-arm),
      // matching every other coaching entry point.
      self.coachingProcedure = procedure
      self.runtimeMode = .learnerCoaching   // mount the coaching host
    }
  }

  // MARK: - Ask AI (glasses-first voice search)

  /// Lens "Ask AI" tapped → host the audio-only Ask-AI VM behind the ditto. The
  /// host (`GlassesAskAIHost`) starts the Gemini Live session and activates the
  /// `.askAI` lens renderer.
  func startAskAI() {
    guard phase == .active else { return }
    startAudioRuntime { [weak self] in self?.runtimeMode = .askAI }
  }

  /// A result was picked on the Ask-AI lens → unmount the Ask-AI host (tears
  /// down its audio + Gemini), fetch the full procedure, then hand off into
  /// coaching (reusing the coaching host). The unmount-before-mount + fetch
  /// latency lets the shared HFP audio route settle before coaching re-acquires
  /// it (mirrors the troubleshoot `handoffToCoaching` settle). Falls back to the
  /// Learner hub if the fetch fails.
  func askAIDidSelect(procedureId: String) {
    guard runtimeMode == .askAI else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      // Tear down + await the Ask-AI runtime (release the `gemini-live` lease)
      // before coaching re-acquires it.
      await self.teardownActiveRuntime()
      self.runtimeMode = .none   // unmount the Ask-AI host
      try? await Task.sleep(nanoseconds: 350_000_000)
      if let proc = try? await ProcedureAPIService().fetchProcedure(id: procedureId) {
        self.startLearnerCoaching(procedure: proc)
      } else {
        self.exitAskAI()
      }
    }
  }

  /// Exit confirmed on the Ask-AI lens (or fetch failed) → stop hosting and
  /// return the lens to the navigator on the Learner hub.
  func exitAskAI() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.teardownActiveRuntime()
      self.runtimeMode = .none
      self.navigatorVM.goLearnerHub()
      self.lensSession?.activate(.navigator, vm: self.navigatorVM)
    }
  }

  /// Bridge the upload result into the navigator's Done / Failed screens.
  private func observeUpload() {
    uploadCancellables.removeAll()
    uploadService.$uploadResult
      .compactMap { $0 }
      .receive(on: DispatchQueue.main)
      .sink { [weak self] proc in
        self?.navigatorVM.showDone(
          title: proc.title,
          stepCount: proc.steps.count,
          procedureId: proc.id
        )
      }
      .store(in: &uploadCancellables)

    uploadService.$uploadError
      .compactMap { $0 }
      .receive(on: DispatchQueue.main)
      .sink { [weak self] reason in
        self?.navigatorVM.showRecordingFailed(reason: reason)
      }
      .store(in: &uploadCancellables)
  }
}
