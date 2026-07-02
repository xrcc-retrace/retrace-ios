import AVFoundation
import Foundation

/// How the AudioSessionManager should configure its AVAudioSession.
///
/// - `.coaching`: full-duplex with AEC and speaker fallback — Gemini Live voice
///   chat when glasses (BT HFP) are the preferred route if available.
/// - `.coachingPhoneOnly`: full-duplex with AEC + forced built-in mic +
///   loudspeaker. Used when the learner explicitly picked the iPhone transport
///   and we must ignore any connected HFP glasses.
/// - `.recording`: simplex capture — no playback, no AEC, no `.defaultToSpeaker`
///   override. Expert recording via glasses (HFP) or iPhone mic fallback.
/// - `.recordingPhoneOnly`: simplex capture, forced built-in mic. Used for
///   iPhone-native expert recording — ignores HFP even if glasses are paired.
enum AudioSessionMode {
  case coaching
  case coachingPhoneOnly
  case recording
  case recordingPhoneOnly
}

@MainActor
class AudioSessionManager: ObservableObject {
  @Published var isCapturing = false
  @Published var isBluetoothConnected = false
  @Published var isAISpeaking = false

  /// True when the mic pipeline is NOT delivering buffers while it should be —
  /// set at startup if the first buffer never arrives (`awaitFirstMicBuffer`
  /// timeout) and mid-session by the silent-mic watchdog; reset the moment a
  /// buffer arrives and on `stopCapture`. This is the observable "HFP broken"
  /// signal a view/coordinator binds to for the audio-failure warning overlay
  /// (the detection used to be `print`-only). Glasses (BT-HFP) modes are where
  /// this matters; phone modes rarely stall but the same watchdog applies.
  @Published private(set) var micStalled = false
  /// Peak sample amplitude from the most recent mic buffer, in `0...1`.
  /// Fed to the Expert HUD's audio meter. Cheap to compute (one pass over
  /// the buffer in `recordCapturedBuffer`); the HUD smooths it further.
  @Published var lastBufferPeak: Float = 0

  /// EMA-smoothed peak amplitude of the AI's voice output, in `0...1`.
  /// Updated each time a Gemini Live PCM buffer is scheduled to the player
  /// node, then reset to 0 when the queue empties (the consuming meter's
  /// own rolling buffer handles the visual fade-out). Drives the audio
  /// meter in coaching + troubleshoot.
  @Published var aiOutputPeak: Float = 0

  /// EMA-smoothed peak amplitude of the user's mic input, in `0...1`.
  /// Parallel to `aiOutputPeak` — drives the "listening" state of the
  /// audio meter so the lens has a visible signal that the mic is
  /// hearing the user (white meter), distinct from the AI-speaking
  /// pastel palette. Updated from `recordCapturedBuffer` with the same
  /// asymmetric attack/release as the AI peak.
  @Published var userInputPeak: Float = 0

  /// Timestamp of the most recent audio activity in either direction —
  /// AI playback chunk enqueue OR mic input peak crossing the
  /// "user speaking" floor. Used by the coaching heartbeat as a
  /// foolproof "is anyone talking right now" gate: peak booleans flip
  /// off in inter-chunk gaps, but this timestamp only moves forward
  /// when something real happened, so a debounce window over it
  /// reliably bridges those gaps.
  @Published private(set) var lastAudioActivityAt: Date = .distantPast

  /// Mic-peak floor above which `recordCapturedBuffer` pings
  /// `lastAudioActivityAt`. Below this, room tone / AEC residue is
  /// ignored so the timestamp doesn't stay permanently fresh.
  private static let userSpeakingFloor: Float = 0.05

  let mode: AudioSessionMode

  /// Names of the DAT-paired Meta glasses (from `Device.nameOrId()`), supplied
  /// by the caller for glasses-transport sessions. Used in the glasses modes
  /// (`.coaching` / `.recording`) to explicitly `setPreferredInput` the glasses'
  /// BT HFP port so a second connected HFP device (e.g. AirPods) can't win the
  /// input route. Empty in iPhone-transport sessions — the `*PhoneOnly` modes
  /// pin the built-in mic instead and never consult this. See
  /// `selectGlassesInput(from:names:)` for the matching strategy.
  var preferredGlassesNames: [String] = []

  /// True for the glasses-transport modes that should prefer the glasses' BT
  /// HFP input over any other connected HFP device.
  private var isGlassesMode: Bool { mode == .coaching || mode == .recording }

  private let engine = AVAudioEngine()
  private var inputNode: AVAudioInputNode { engine.inputNode }

  // MARK: - Playback

  private let playerNode = AVAudioPlayerNode()
  private let playbackFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 24_000,
    channels: 1,
    interleaved: true
  )!

  /// Tracks scheduled buffers so we know when AI stops speaking.
  private var scheduledBufferCount = 0

  // MARK: - Lobby music (overlaps Gemini, ducked)

  /// Second player node mixed into the same engine as `playerNode`, used for
  /// looping "lobby" music during the troubleshoot online-search wait. It plays
  /// UNDERNEATH Gemini (ducked via `volume`) rather than pausing it — both nodes
  /// fan into `mainMixerNode` and out the glasses/phone speaker.
  private let musicNode = AVAudioPlayerNode()
  /// Ducked low so Gemini stays intelligible if it speaks over the music.
  private let musicVolume: Float = 0.10
  /// True while a lobby loop is scheduled/playing. Guards idempotent start/stop.
  private var musicPlaying = false

  // MARK: - Observability

  private var captureBuffersSinceLastFlush = 0
  private var lastBufferReceivedAt: Date?
  private var silentMicWarned = false
  private var invalidFormatWarned = false
  private var playbackAllocFailures = 0
  private var statsTask: Task<Void, Never>?

  // MARK: - Send format (mic → Gemini)

  private let sendFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 16_000,
    channels: 1,
    interleaved: true
  )!
  private var audioConverter: AVAudioConverter?
  /// Input format the current `audioConverter` was built against. Used to
  /// short-circuit route-change rebinds when the live format hasn't changed
  /// (see `rebindMicTapIfCapturing(reason:)`).
  private var converterInputFormat: AVAudioFormat?

  /// True once `prewarm()` has put the audio session in its target category
  /// AND the input audio unit has been instantiated against a settled
  /// hardware format. `startCaptureAsync()` skips the off-main session
  /// reconfigure when this is set, so it doesn't queue a fresh
  /// route-change cascade right under `engine.start()` — the original
  /// -10868 race. Reset by `stopCapture()`.
  private var didPrewarm = false

  /// True once `configureAudioSession()` has run successfully (whether
  /// from `startCapture()` directly, `prewarm()`, or the new public
  /// `configureSessionOnly()` entry point). Callers that need to insert
  /// a delay between session activation and `engine.start()` (e.g. the
  /// HFP warmup required by Meta's official iOS sample) call
  /// `configureSessionOnly()` first; the subsequent `startCapture()`
  /// then sees this flag set and skips re-running the configure step
  /// (which would post a fresh route-change cascade and undo the
  /// warmup). Reset by `stopCapture()`.
  private var didConfigureSession = false

  /// Bounded poll armed when an engine restart was deferred because the input
  /// format hadn't settled (rate 0 mid-route-flux). Usually the settle posts
  /// another route/config change that restarts naturally, but the field shows
  /// cases with no follow-up notification — this task is the backstop so the
  /// mic doesn't stay dead for the rest of the session. Nil when idle.
  private var deferredRestartTask: Task<Void, Never>?

  /// True between AVAudioSession interruption `.began` and `.ended` (phone
  /// lock, incoming call, Siri). While set, `restartEngineAfterStopIfNeeded`
  /// defers — restarting the engine graph against an interrupted (deactivated)
  /// session is what raised the fatal `AVAudioEngineGraph::_Connect`
  /// NSException in TestFlight build 1.0(9). Cleared on `.ended` (which then
  /// triggers the deferred restart) and in `stopCapture()`.
  private var isAudioSessionInterrupted = false

  /// Pending waiter for `awaitHFPRouteReady(_:)` — the event-driven
  /// replacement for the fixed HFP warmup sleep. Resolved `true` by
  /// `handleRouteChange` the instant the glasses BT HFP route comes up with
  /// a settled input format, or `false` by the caller's timeout / teardown.
  /// All access is `@MainActor`, so there's no resume race.
  private var hfpReadyContinuation: CheckedContinuation<Bool, Never>?

  /// Resumed by `recordCapturedBuffer` when the FIRST mic PCM buffer actually
  /// arrives (SCO link carrying data), or `false` on the caller's timeout /
  /// teardown. Distinct from `hfpReadyContinuation`, which only proves the HFP
  /// route exists — not that it's delivering audio. Callers who must have the
  /// mic "locked in" before doing something that could disturb the BT radio
  /// (e.g. attaching the Display capability) await this. `@MainActor` access,
  /// so no resume race.
  private var firstBufferContinuation: CheckedContinuation<Bool, Never>?

  /// Called on the audio capture queue with each PCM buffer.
  var onAudioBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

  /// Optional second consumer fired AFTER `onAudioBuffer`. Lets a caller
  /// piggyback on the same mic tap as the writer/primary without risking
  /// starvation — the primary is invoked first. Install via
  /// `installSecondaryAudioConsumer`. Currently unused; left in place so
  /// future side-channel listeners (analytics, mic diagnostics, etc.) can
  /// hook in without changing the audio plumbing.
  var onAudioBufferSecondary: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

  /// Install a secondary audio consumer (see `onAudioBufferSecondary`).
  func installSecondaryAudioConsumer(
    _ consumer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
  ) {
    onAudioBufferSecondary = consumer
  }

  /// Remove the secondary audio consumer. Safe to call when none is installed.
  func removeSecondaryAudioConsumer() {
    onAudioBufferSecondary = nil
  }

  /// The actual hardware sample rate (read after configureAudioSession).
  var hardwareSampleRate: Double {
    AVAudioSession.sharedInstance().sampleRate
  }

  /// The hardware input format (read after configureAudioSession + engine prep).
  var inputFormat: AVAudioFormat {
    inputNode.inputFormat(forBus: 0)
  }

  init(mode: AudioSessionMode = .coaching, preferredGlassesNames: [String] = []) {
    self.mode = mode
    self.preferredGlassesNames = preferredGlassesNames

    // Attach player node only for coaching modes. Recording has no playback
    // and attaching the node forces `.playAndRecord`, which pulls in output-port
    // negotiation and triggers the route-change cascade we're trying to avoid.
    if mode == .coaching || mode == .coachingPhoneOnly {
      engine.attach(playerNode)
      engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
      // Lobby-music node shares the same mixer/output, ducked low. Connected
      // with a nil format so the mixer adopts the scheduled buffer's format
      // (the music file may be 44.1k stereo) and sample-rate-converts to the
      // hardware route.
      engine.attach(musicNode)
      engine.connect(musicNode, to: engine.mainMixerNode, format: nil)
      musicNode.volume = musicVolume
    }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleRouteChange),
      name: AVAudioSession.routeChangeNotification,
      object: nil
    )

    // The engine self-stops on a configuration change — most commonly when the
    // Display glasses' BT-HFP SCO link finishes negotiating to its 16 kHz mono
    // format right AFTER `engine.start()`. Without this observer the engine
    // stays stopped (`isRunning=false`) forever, the tap never fires, and no
    // mic buffers arrive — the "HFP not locked in" failure. Restart on it.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleEngineConfigurationChange),
      name: .AVAudioEngineConfigurationChange,
      object: engine
    )

    // Interruptions (phone lock, incoming call, Siri) stop the engine AND
    // deactivate the session. Without this observer the config-change
    // restart path fires blindly mid-interruption and the engine-graph
    // reconnect raises an uncatchable NSException (the TestFlight crash);
    // it also left the mic dead after unlock because nothing resumed it.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleInterruption),
      name: AVAudioSession.interruptionNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Audio Session

  /// Mac-route demo. When true, `.coachingPhoneOnly` stops forcing the
  /// iPhone speaker (uses `.default` instead of `.voiceChat`, drops `.defaultToSpeaker`,
  /// skips `overrideOutputAudioPort(.speaker)`) and disables VPIO/AEC, so Gemini
  /// Live's output can leave the phone over the QuickTime-over-USB / HDMI virtual
  /// route to a connected Mac. The mic side is handled by walkie-talkie push-to-talk
  /// (`GeminiLiveSessionBase.isPushToTalkActive`), which closes the mic while the AI
  /// speaks, so hardware AEC isn't needed. Same UserDefaults key the Settings toggle
  /// writes; `nonisolated static` so both the main-actor and off-main config paths read it.
  nonisolated static var routeAudioToMacForDemo: Bool {
    UserDefaults.standard.bool(forKey: "debug.routeAudioToMacForDemo")
  }

  func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    let demoRoute = (mode == .coachingPhoneOnly) && Self.routeAudioToMacForDemo
    do {
      switch mode {
      case .coaching:
        // Aligned with Meta's official iOS audio sample for Display
        // glasses (https://wearables.developer.meta.com/docs/develop/
        // dat/microphones-and-speakers#ios-sample-code). Was previously
        // `.voiceChat` mode with A2DP + defaultToSpeaker options — the
        // combination silently broke `engine.start()` on BT HFP from
        // Display glasses (engine returned success but `isRunning`
        // immediately flipped false, no buffers ever delivered to the
        // tap). Both Meta's sample AND the deprecated SmartSight
        // working pattern omit explicit voice-processing enable and
        // use a narrower option set.
        //
        // Trade-off: we lose hardware AEC. In practice glasses speakers
        // are open-ear with physical separation from the temple mic,
        // and Gemini's server-side VAD filters short bleed. If
        // self-barge-in becomes a real problem in field use, follow up
        // with a software ducking filter on the player node output.
        try session.setCategory(
          .playAndRecord,
          mode: .default,
          options: [.allowBluetoothHFP]
        )
      case .coachingPhoneOnly:
        // Full-duplex with AEC, forced to built-in mic + loudspeaker even when
        // HFP glasses are paired. The learner explicitly chose the iPhone transport.
        // Demo route (`demoRoute`): `.default` mode + no `.defaultToSpeaker` so the
        // output can take the Mac's QuickTime-USB / HDMI virtual route instead of
        // being pinned to the phone loudspeaker.
        try session.setCategory(
          .playAndRecord,
          mode: demoRoute ? .default : .voiceChat,
          options: demoRoute ? [] : [.defaultToSpeaker]  // no HFP / A2DP
        )
      case .recording:
        // Simplex capture. No `.voiceChat` (no AEC processing), no `.defaultToSpeaker`
        // (nothing to play, and this option forces an override-to-speaker that
        // triggers the categoryChange cascade which detaches the mic tap).
        // No `.allowBluetoothA2DP` — A2DP is an output-only sink profile;
        // pairing it with `.record` (input-only) makes iOS reject the whole
        // setCategory call with kAudio_ParamError (-50). DAT SDK glasses
        // route their mic through BT HFP anyway; HFP is the bidirectional
        // voice profile both Ray-Bans and AirPods use for capture.
        try session.setCategory(
          .record,
          mode: .default,
          options: [.allowBluetoothHFP]
        )
      case .recordingPhoneOnly:
        // Simplex capture forced to the built-in mic. Ignores any paired HFP
        // glasses — the expert explicitly chose the iPhone transport.
        try session.setCategory(
          .record,
          mode: .default,
          options: []  // no HFP / A2DP
        )
      }
      // Per Meta's mic+speakers sample (verbatim):
      //   setActive(true, options: .notifyOthersOnDeactivation)
      // Hint to competing audio apps (Music, podcast players) that they
      // should resume when we deactivate. Without it, music stays paused
      // until the user manually taps play. Activation-time option, not
      // deactivation-time — iOS associates it with the session lifecycle.
      try session.setActive(true, options: .notifyOthersOnDeactivation)
      if mode == .coachingPhoneOnly, !demoRoute {
        // Belt-and-suspenders: even with `.defaultToSpeaker`, an actively routed
        // HFP output could sneak through if the user paired glasses mid-session.
        // This override forces the loudspeaker for the life of this activation.
        // Skipped in the DEBUG demo route so output can reach the Mac.
        try session.overrideOutputAudioPort(.speaker)
      }
      if mode == .coachingPhoneOnly || mode == .recordingPhoneOnly {
        forceBuiltInMicPreferred(session)
      }
      if isGlassesMode {
        // Pin the glasses' BT HFP input so a second connected HFP device
        // (e.g. AirPods) can't win the route. Done before the caller's
        // HFP warmup delay so iOS brings up the *glasses* SCO link.
        forceGlassesInputPreferred(session)
      }
      checkBluetoothRoute()

      // Surface the actual route iOS picked so silent-audio bugs are
      // diagnosable from the console. If a `.coaching` session ends up
      // with `Built-in Mic` + `Speaker` instead of BT HFP ports, the
      // glasses didn't engage their HFP profile — and the user will hear
      // nothing through the glasses speakers / mic.
      let route = session.currentRoute
      let inputs = route.inputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
      let outputs = route.outputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
      print("[AudioSession] configured mode=\(mode), category=playAndRecord, inputs=[\(inputs)], outputs=[\(outputs)]")
      didConfigureSession = true
    } catch {
      print("[AudioSession] Failed to configure audio session: \(error)")
    }
  }

  /// Public entry point that runs ONLY the session configure step (no
  /// engine, no tap, no playback). Used by callers that need to wait for
  /// the HFP route to come up between session activation and
  /// `engine.start()`. The Meta DAT iOS docs at
  /// https://wearables.developer.meta.com/docs/develop/dat/microphones-and-speakers#ios-sample-code
  /// state: "When planning to use HFP and streaming simultaneously,
  /// ensure that HFP is fully configured before initiating any
  /// streaming session that requires audio functionality." The sample
  /// uses a fixed ~2 s delay; we instead drive that wait off the actual
  /// route-up event:
  /// `configureSessionOnly()` → `await awaitHFPRouteReady(timeout:)` →
  /// `startCapture()` (which short-circuits its own configure step via
  /// the `didConfigureSession` flag set above).
  ///
  /// Idempotent — re-calling after a successful configure is a no-op.
  func configureSessionOnly() {
    guard !didConfigureSession else { return }
    configureAudioSession()
  }

  /// Event-driven replacement for the fixed HFP warmup sleep. After
  /// `configureSessionOnly()` has pinned the glasses' BT HFP input, iOS
  /// negotiates the SCO link asynchronously and posts a route change when
  /// it's up. Suspend until the glasses HFP route is the active input with
  /// a settled (non-zero) format — proof it's safe for `startCapture()`'s
  /// `engine.start()` to attach without hitting the half-negotiated-route
  /// silent-stop. Returns:
  ///   - `true` immediately when the route is already up (warm reuse), or
  ///     as soon as the route-up event lands (often well under the ceiling);
  ///   - `false` if `timeout` elapses first — the caller still proceeds, and
  ///     the downstream first-PCM-buffer wait + recovery sheet are the
  ///     backstop, exactly as with the old fixed sleep. So the ceiling can
  ///     only make startup faster, never slower, than the constant it
  ///     replaces.
  ///
  /// Glasses modes only; phone-only modes return `true` at once (built-in
  /// mic, no SCO negotiation).
  func awaitHFPRouteReady(timeout: TimeInterval) async -> Bool {
    guard isGlassesMode else { return true }
    if glassesHFPRouteReady() { return true }
    return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
      self.hfpReadyContinuation = cont
      Task { @MainActor [self] in
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        if let pending = self.hfpReadyContinuation {
          self.hfpReadyContinuation = nil
          print("[AudioSession] HFP route not confirmed within \(timeout)s — proceeding on the ceiling (first-buffer wait is the backstop)")
          pending.resume(returning: false)
        }
      }
    }
  }

  /// Suspend until the FIRST mic PCM buffer arrives — proof the SCO link is
  /// actually carrying audio, not merely that the route exists and the engine
  /// started. Returns `true` on the first buffer (or immediately if one already
  /// arrived), `false` if `timeout` elapses first. Callers that must have the
  /// mic "locked in" before disturbing the shared BT radio (e.g. attaching the
  /// Display capability, which can tear down a route-ready-but-not-yet-flowing
  /// HFP link) await this after `startCapture()`. Glasses modes only; phone-only
  /// modes return `true` at once. Requires `startCapture()` to have been called.
  func awaitFirstMicBuffer(timeout: TimeInterval) async -> Bool {
    guard isGlassesMode else { return true }
    if lastBufferReceivedAt != nil { return true }
    return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
      self.firstBufferContinuation = cont
      Task { @MainActor [self] in
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        if let pending = self.firstBufferContinuation {
          self.firstBufferContinuation = nil
          self.micStalled = true   // startup: SCO never carried data — surface it
          print("[AudioSession] ⚠ First mic buffer not seen within \(timeout)s — HFP not locked in")
          pending.resume(returning: false)
        }
      }
    }
  }

  /// True when the glasses' BT HFP port is the active input AND its format
  /// has settled (non-zero sample rate — the same pre-start validity gate
  /// `ensureValidInputFormat()` uses). Prefers an exact glasses-port match
  /// so a second connected HFP device (e.g. AirPods) can't satisfy the gate;
  /// falls back to "any BT HFP input" only when the glasses port couldn't be
  /// named (the `wearables.devices` list is briefly empty), in which case
  /// the input was already pinned to the glasses.
  private func glassesHFPRouteReady() -> Bool {
    guard inputNode.inputFormat(forBus: 0).sampleRate > 0 else { return false }
    let session = AVAudioSession.sharedInstance()
    let current = session.currentRoute.inputs
    if let glasses = Self.selectGlassesInput(from: session, names: preferredGlassesNames) {
      return current.contains { $0.uid == glasses.uid }
    }
    return current.contains { $0.portType == .bluetoothHFP }
  }

  /// Match heuristics applied (in `selectGlassesInput`) to a `.bluetoothHFP`
  /// port name when no DAT device name matched — covers the window where
  /// `wearables.devices` is briefly empty but the glasses are BT-paired.
  /// Lowercased substrings checked against a lowercased port name.
  private static let glassesNameHeuristics = [
    "meta", "ray-ban", "rayban", "rb display", "vanguard",
  ]

  /// Find the BT HFP input port that belongs to the Meta glasses, among the
  /// session's `availableInputs`. Match strategy, most → least specific:
  ///   1. Exact (case-insensitive) `portName == datName`.
  ///   2. One name contains the other (minor suffix/prefix drift).
  ///   3. Heuristic: an HFP port whose name contains a known glasses token.
  /// Returns nil when nothing matches — caller then leaves routing to iOS
  /// rather than pinning a non-glasses device.
  nonisolated static func selectGlassesInput(
    from session: AVAudioSession,
    names: [String]
  ) -> AVAudioSessionPortDescription? {
    let inputs = session.availableInputs ?? []
    let datNames = names.map { $0.lowercased() }

    // 1 + 2: match against the DAT-reported glasses names.
    for port in inputs {
      let portName = port.portName.lowercased()
      for datName in datNames where !datName.isEmpty {
        if portName == datName
            || portName.contains(datName)
            || datName.contains(portName) {
          return port
        }
      }
    }

    // 3: heuristic fallback, restricted to HFP ports so we never grab the
    // built-in mic or a non-glasses device.
    for port in inputs where port.portType == .bluetoothHFP {
      let portName = port.portName.lowercased()
      if glassesNameHeuristics.contains(where: { portName.contains($0) }) {
        return port
      }
    }

    return nil
  }

  /// Pin the AVAudioSession input to the Meta glasses' BT HFP port. Called from
  /// the glasses modes (`.coaching` / `.recording`) so a second connected HFP
  /// device (e.g. AirPods) can't steal the input route. No-op (leaves iOS
  /// default routing) when no glasses port is found.
  private func forceGlassesInputPreferred(_ session: AVAudioSession) {
    guard let glasses = Self.selectGlassesInput(from: session, names: preferredGlassesNames) else {
      let available = (session.availableInputs ?? [])
        .map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
      print("[AudioSession] ⚠ No glasses input found to pin (names=\(preferredGlassesNames), available=[\(available)]) — leaving routing to iOS")
      return
    }
    do {
      try session.setPreferredInput(glasses)
      print("[AudioSession] glasses input pinned: \(glasses.portName)")
    } catch {
      print("[AudioSession] Failed to pin glasses input \(glasses.portName): \(error)")
    }
  }

  /// Pin the AVAudioSession input to the built-in iPhone mic. Called only from
  /// the `*PhoneOnly` modes so HFP glasses (even if paired) don't steal the
  /// input route.
  private func forceBuiltInMicPreferred(_ session: AVAudioSession) {
    guard
      let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic })
    else {
      print("[AudioSession] ⚠ No built-in mic input available to pin")
      return
    }
    do {
      try session.setPreferredInput(builtIn)
    } catch {
      print("[AudioSession] Failed to pin built-in mic input: \(error)")
    }
  }

  // MARK: - Permissions

  func requestMicrophonePermission() async -> Bool {
    return await withCheckedContinuation { continuation in
      AVAudioApplication.requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  /// Multi-line snapshot of every audio subsystem state that could
  /// explain a silent-mic failure. Called from `GeminiLiveSessionBase`
  /// when the readiness gate times out, so a single console paste
  /// surfaces:
  ///   - The live (post-Settings-toggle) iOS record permission state.
  ///   - Every input port iOS picked for the current route, with
  ///     `portType` and UID — diagnoses "BT route shown but actually
  ///     built-in" cases.
  ///   - Input-node format the tap is actually receiving — a 0-rate
  ///     format means the engine started but the input chain didn't.
  ///   - `isVoiceProcessingEnabled` on the input node — diagnoses VPIO
  ///     not engaging on the BT HFP input route.
  ///   - System-level flags: `isInputAvailable`, `isOtherAudioPlaying`,
  ///     `secondaryAudioShouldBeSilencedHint`. Eliminates "iOS muted
  ///     us because another app holds the mic" hypotheses.
  ///
  /// Output is single-call-site, plain text — paste-into-bug-report
  /// shaped, not machine-parsed.
  func dumpAudioDiagnostics() -> String {
    let session = AVAudioSession.sharedInstance()
    let route = session.currentRoute
    let inputs = route.inputs.map {
      "    - \($0.portName) [type=\($0.portType.rawValue), uid=\($0.uid)]"
    }.joined(separator: "\n")
    let outputs = route.outputs.map {
      "    - \($0.portName) [type=\($0.portType.rawValue), uid=\($0.uid)]"
    }.joined(separator: "\n")
    let inFmt = inputNode.inputFormat(forBus: 0)
    let perm: String
    switch AVAudioApplication.shared.recordPermission {
    case .granted: perm = "granted"
    case .denied: perm = "denied"
    case .undetermined: perm = "undetermined"
    @unknown default: perm = "unknown(\(AVAudioApplication.shared.recordPermission.rawValue))"
    }
    return """
    ───── Audio diagnostic dump (mode=\(mode)) ─────
      Engine state: isRunning=\(engine.isRunning), isCapturing=\(isCapturing)
      iOS recordPermission: \(perm)
      VPIO enabled on inputNode: \(inputNode.isVoiceProcessingEnabled)
      Input-node format: rate=\(inFmt.sampleRate), channels=\(inFmt.channelCount), commonFormat=\(inFmt.commonFormat.rawValue)
      Buffers since capture started: \(captureBuffersSinceLastFlush)
      Last buffer received at: \(lastBufferReceivedAt.map { "\($0)" } ?? "nil (never)")
      AVAudioSession.category: \(session.category.rawValue)
      AVAudioSession.mode: \(session.mode.rawValue)
      AVAudioSession.isInputAvailable: \(session.isInputAvailable)
      AVAudioSession.isOtherAudioPlaying: \(session.isOtherAudioPlaying)
      AVAudioSession.secondaryAudioShouldBeSilencedHint: \(session.secondaryAudioShouldBeSilencedHint)
      Current route inputs (\(route.inputs.count)):
    \(inputs.isEmpty ? "    (none — input chain is empty!)" : inputs)
      Current route outputs (\(route.outputs.count)):
    \(outputs.isEmpty ? "    (none)" : outputs)
      Available inputs (\(session.availableInputs?.count ?? 0)):
    \((session.availableInputs ?? []).map { "    - \($0.portName) [type=\($0.portType.rawValue)]" }.joined(separator: "\n"))
    ─────────────────────────────────────────────────
    """
  }

  /// Errors thrown out of `startCaptureAsync()`. Surfaced so the recording
  /// path can abort cleanly instead of silently producing audio-less mp4s
  /// when `engine.start()` fails (the original `-10868` symptom).
  enum AudioStartError: LocalizedError {
    case engineFailedAfterRetry(NSError)
    case invalidInputFormat

    var errorDescription: String? {
      switch self {
      case .engineFailedAfterRetry(let underlying):
        return "Audio engine failed to start (\(underlying.code))."
      case .invalidInputFormat:
        return "Audio input is not available (rate=0)."
      }
    }
  }

  // MARK: - Capture

  /// Pre-warm the audio session and input audio unit ahead of the first
  /// `startCapture` call. Called from the recording VM's `prepare()` so by
  /// the time the user can tap **Start Recording** the session is already
  /// in `.record`, the input AU is instantiated against the real hardware
  /// format, and any queued route-change notifications have drained.
  ///
  /// This eliminates the original `-10868` race: previously the FIRST
  /// access of `engine.inputNode` happened on `MainActor` BEFORE the
  /// session was switched to `.record`, so the AU cached a stale format
  /// (`.solo_ambient` rate 0 / `.playback` from a prior voice preview),
  /// then `engine.start()` validated the input chain against that stale
  /// format mid-route-change cascade and failed.
  ///
  /// Idempotent — early-out if already pre-warmed and the session is still
  /// in our target category.
  func prewarm() async {
    if didPrewarm { return }

    let capturedMode = mode
    let capturedNames = preferredGlassesNames

    // 1) Move the audio session into our target category off-main so the
    //    main thread keeps rendering the camera preview while
    //    setCategory + setActive + setPreferredInput run.
    await Task.detached(priority: .userInitiated) {
      Self.configureSessionOffMain(mode: capturedMode, preferredGlassesNames: capturedNames)
    }.value

    // 2) FIRST access of `engine.inputNode` — now the audio session is in
    //    `.record` (or `.playAndRecord`), so the lazily-instantiated input
    //    AU caches the real hardware format instead of a stale one.
    let node = inputNode

    // 3) Force the AU into the right voice-processing mode for this
    //    session. Recording mode pins it to plain RemoteIO so a prior
    //    coaching session can't leave a 5-channel VPIO format behind that
    //    would later fail input-chain validation.
    //    Coaching mode mirrors `startCapture`'s VPIO+HFP bypass — if
    //    the active input is BT HFP from Display glasses, skip VPIO
    //    or `engine.start()` will return success but the engine will
    //    immediately stop (see comment in `startCapture` for the
    //    diagnostic background).
    do {
      if capturedMode == .coaching || capturedMode == .coachingPhoneOnly {
        let isBTHFPInput = AVAudioSession.sharedInstance().currentRoute.inputs
          .contains { $0.portType == .bluetoothHFP }
        let demoRoute = (capturedMode == .coachingPhoneOnly) && Self.routeAudioToMacForDemo
        try Self.safeSetVoiceProcessing(node, enabled: !isBTHFPInput && !demoRoute)
      } else {
        try Self.safeSetVoiceProcessing(node, enabled: false)
      }
    } catch {
      print("[AudioSession] prewarm: setVoiceProcessingEnabled failed: \(error)")
    }

    // 4) Drain queued route-change notifications. setCategory + setActive +
    //    setPreferredInput each post a notification; iOS delivers them
    //    asynchronously on the main run loop. Yield + sleep so they land
    //    BEFORE any subsequent engine.start sees the input chain.
    await Task.yield()
    try? await Task.sleep(nanoseconds: 50_000_000)  // 50 ms

    didPrewarm = true
    print("[AudioSession] prewarm complete (mode=\(capturedMode))")
  }

  /// Off-main variant of `startCapture()` used by the recording path. Moves
  /// the ~200 ms of `AVAudioSession` + `AVAudioEngine` setup onto a user-
  /// initiated background task so the UI thread doesn't freeze while the
  /// user waits for "Start recording" to flip. The sync `startCapture()`
  /// above is kept for the coaching-path call sites that already run inside
  /// larger async flows.
  ///
  /// Throws `AudioStartError` on terminal failure (after one automatic
  /// retry) so the recording path can surface "Audio failed to start"
  /// instead of silently producing a silent mp4.
  func startCaptureAsync() async throws {
    guard !isCapturing else { return }

    let capturedMode = mode
    let capturedNames = preferredGlassesNames

    // Phase 1 — bring the audio session + input AU into the right state.
    // If `prewarm()` already ran, this is a cheap no-op; otherwise we
    // do the same work synchronously here as a fallback.
    if !didPrewarm {
      await Task.detached(priority: .userInitiated) { [inputNode = self.inputNode] in
        Self.configureSessionOffMain(mode: capturedMode, preferredGlassesNames: capturedNames)
        do {
          if capturedMode == .coaching || capturedMode == .coachingPhoneOnly {
            // Same VPIO+HFP bypass as `startCapture`. Display glasses
            // BT HFP input crashes the VPIO unit silently — engine.start
            // returns success but `isRunning` flips false immediately.
            let isBTHFPInput = AVAudioSession.sharedInstance().currentRoute.inputs
              .contains { $0.portType == .bluetoothHFP }
            let demoRoute = (capturedMode == .coachingPhoneOnly) && Self.routeAudioToMacForDemo
            try Self.safeSetVoiceProcessing(inputNode, enabled: !isBTHFPInput && !demoRoute)
          } else {
            try Self.safeSetVoiceProcessing(inputNode, enabled: false)
          }
        } catch {
          print("[AudioSession] ⚠ setVoiceProcessingEnabled failed: \(error)")
        }
      }.value
      // Same drain as in prewarm.
      try? await Task.sleep(nanoseconds: 50_000_000)
      didPrewarm = true
    }

    // Phase 2 — sanity-check the input format before installing the tap.
    // If the format is degenerate, kick the session config once and
    // re-check. Bail loudly rather than silently capturing nothing.
    if !ensureValidInputFormat() {
      // One recovery pass: re-run session config + drain.
      await Task.detached(priority: .userInitiated) {
        Self.configureSessionOffMain(mode: capturedMode, preferredGlassesNames: capturedNames)
      }.value
      try? await Task.sleep(nanoseconds: 100_000_000)  // 100 ms
      if !ensureValidInputFormat() {
        throw AudioStartError.invalidInputFormat
      }
    }

    // Phase 3 — install the mic tap on main. Tap installation is a few-µs
    // op on AVAudioInputNode; doing it on main matches the existing
    // `installMicTap()` pattern.
    installMicTap()

    // Phase 4 — engine.prepare() + engine.start(), with one retry on
    // failure. `prepare()` gives the engine an explicit format-negotiation
    // pass against the now-settled input chain; without it, start() can
    // race a not-yet-finalized AU format and emit -10868.
    do {
      try await startEngineWithRetry()
    } catch {
      inputNode.removeTap(onBus: 0)
      throw error
    }

    if capturedMode == .coaching || capturedMode == .coachingPhoneOnly {
      playerNode.play()
    }
    isCapturing = true

    initializeConverterIfNeeded()

    let inFmt = inputNode.inputFormat(forBus: 0)
    if inFmt.sampleRate == 0 || inFmt.channelCount == 0, !invalidFormatWarned {
      invalidFormatWarned = true
      print(
        "[AudioSession] ⚠ Invalid input format after engine start "
        + "(rate=\(inFmt.sampleRate), channels=\(inFmt.channelCount)) — "
        + "capture will be silent"
      )
    }

    checkBluetoothRoute()
    startStatsTimer()
  }

  /// Validate the live input format before we commit to a tap install /
  /// engine start. A 0-rate format means the session hasn't actually
  /// engaged the input route yet — proceeding silently captures nothing.
  private func ensureValidInputFormat() -> Bool {
    let f = inputNode.inputFormat(forBus: 0)
    return f.sampleRate > 0 && f.channelCount > 0
  }

  /// Run `engine.prepare()` + `engine.start()`. On failure: reset the
  /// engine, re-run the session config, drain route-change notifications,
  /// re-install the tap, retry once. Throws `AudioStartError.engineFailedAfterRetry`
  /// if the second attempt also fails so the caller can surface a clear
  /// error instead of silently producing a silent recording.
  private func startEngineWithRetry() async throws {
    let capturedMode = mode
    let capturedEngine = engine
    let capturedNames = preferredGlassesNames

    let firstAttempt: NSError? = await Task.detached(priority: .userInitiated) {
      capturedEngine.prepare()
      do {
        try capturedEngine.start()
        return nil
      } catch {
        return error as NSError
      }
    }.value

    if firstAttempt == nil { return }

    print("[AudioSession] engine.start failed (\(firstAttempt!.code)), recovering and retrying")

    // Recovery: tear down everything that could be in a bad state and
    // re-run the session config to nudge iOS into re-publishing the
    // route. Then retry start once.
    inputNode.removeTap(onBus: 0)
    capturedEngine.reset()

    await Task.detached(priority: .userInitiated) { [inputNode = self.inputNode] in
      Self.configureSessionOffMain(mode: capturedMode, preferredGlassesNames: capturedNames)
      do {
        let demoRoute = (capturedMode == .coachingPhoneOnly) && Self.routeAudioToMacForDemo
        // Honor the same BT-HFP VPIO-disable gate as the main path — re-enabling
        // VPIO on the Display glasses route re-triggers the engine self-stop the
        // retry is trying to recover from.
        let isBTHFPInput = AVAudioSession.sharedInstance().currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
        let shouldUseVPIO = (capturedMode == .coaching || capturedMode == .coachingPhoneOnly) && !demoRoute && !isBTHFPInput
        try Self.safeSetVoiceProcessing(inputNode, enabled: shouldUseVPIO)
      } catch {
        print("[AudioSession] retry: setVoiceProcessingEnabled failed: \(error)")
      }
    }.value

    // Generous drain — the failure mode is route-change cascade.
    try? await Task.sleep(nanoseconds: 150_000_000)  // 150 ms

    installMicTap()

    let secondAttempt: NSError? = await Task.detached(priority: .userInitiated) {
      capturedEngine.prepare()
      do {
        try capturedEngine.start()
        return nil
      } catch {
        return error as NSError
      }
    }.value

    if let err = secondAttempt {
      print("[AudioSession] engine.start failed on retry too (\(err.code))")
      throw AudioStartError.engineFailedAfterRetry(err)
    }
    print("[AudioSession] engine.start retry succeeded")
  }

  /// Background-safe session setup called from `startCaptureAsync()`'s
  /// detached task. Mirrors the category/active/preferred-input work of
  /// `configureAudioSession()` without touching any `@Published` state, so
  /// it's safe to run off the main actor. `AVAudioSession` APIs are
  /// documented thread-safe.
  nonisolated private static func configureSessionOffMain(
    mode: AudioSessionMode,
    preferredGlassesNames: [String] = []
  ) {
    let session = AVAudioSession.sharedInstance()
    let demoRoute = (mode == .coachingPhoneOnly) && routeAudioToMacForDemo
    do {
      switch mode {
      case .coaching:
        // Match the main-actor `configureAudioSession()` `.coaching` branch:
        // `.default` + `[.allowBluetoothHFP]` only. `.voiceChat` + A2DP +
        // `.defaultToSpeaker` silently self-stops `engine.start()` on the
        // Display glasses' BT-HFP route (engine returns success but `isRunning`
        // flips false, no buffers) — the exact failure this off-main configure
        // path must not re-introduce on a retry.
        try session.setCategory(
          .playAndRecord,
          mode: .default,
          options: [.allowBluetoothHFP]
        )
      case .coachingPhoneOnly:
        // Mirror the main-actor demo-route branch (see `configureAudioSession()`).
        try session.setCategory(
          .playAndRecord,
          mode: demoRoute ? .default : .voiceChat,
          options: demoRoute ? [] : [.defaultToSpeaker]
        )
      case .recording:
        // A2DP is invalid with `.record` (output-only profile); see the
        // sibling `configureAudioSession()` for the full reasoning. HFP
        // alone is what DAT SDK glasses actually route their mic through.
        try session.setCategory(
          .record,
          mode: .default,
          options: [.allowBluetoothHFP]
        )
      case .recordingPhoneOnly:
        try session.setCategory(
          .record,
          mode: .default,
          options: []
        )
      }
      // See `configureAudioSession` for the rationale — Meta's mic+speakers
      // sample bakes `.notifyOthersOnDeactivation` into activation so Music
      // resumes cleanly when we tear down.
      try session.setActive(true, options: .notifyOthersOnDeactivation)
      if mode == .coachingPhoneOnly, !demoRoute {
        try session.overrideOutputAudioPort(.speaker)
      }
      if mode == .coachingPhoneOnly || mode == .recordingPhoneOnly {
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
          do {
            try session.setPreferredInput(builtIn)
          } catch {
            print("[AudioSession] Failed to pin built-in mic input: \(error)")
          }
        }
      }
      if mode == .coaching || mode == .recording {
        // Glasses modes: prefer the glasses' BT HFP port over any other
        // connected HFP device. Mirrors `forceGlassesInputPreferred` on the
        // main-thread path (kept inline here since this is `nonisolated static`).
        if let glasses = selectGlassesInput(from: session, names: preferredGlassesNames) {
          do {
            try session.setPreferredInput(glasses)
            print("[AudioSession] glasses input pinned (off-main): \(glasses.portName)")
          } catch {
            print("[AudioSession] Failed to pin glasses input \(glasses.portName): \(error)")
          }
        }
      }
    } catch {
      print("[AudioSession] Failed to configure audio session: \(error)")
    }
  }

  func startCapture() {
    guard !isCapturing else { return }

    // Skip if a prior `configureSessionOnly()` already ran the
    // configure step — we don't want to re-post the route-change
    // cascade (which would undo any HFP warmup delay the caller
    // inserted between configure and start).
    if !didConfigureSession {
      configureAudioSession()
    }

    // For coaching modes, decide whether to enable hardware voice
    // processing (AEC + noise suppression + AGC). VPIO is great when
    // the input route is built-in mic or AirPods, but it has a known
    // incompatibility with BT HFP from Meta Ray-Ban Display glasses:
    // `engine.start()` returns success, but the underlying VPIO input
    // unit can't initialize against that HFP route, the engine
    // immediately stops itself (`isRunning` flips false), no buffers
    // are ever delivered to the input tap. Diagnosed 2026-05-23 via
    // the audio diagnostic dump.
    //
    // Trade-off when we skip VPIO on the glasses route: no hardware
    // AEC for the BT speaker → BT mic loop. In practice Display
    // glasses speakers are open-ear and point at the user's ears,
    // and the BT HFP mic is in the temple front — physical separation
    // is good enough that audible feedback is rare. Server-side VAD
    // catches whatever residual echo bleeds through.
    applyVoiceProcessingForCurrentRoute()

    installMicTap()

    do {
      try engine.start()
      if mode == .coaching || mode == .coachingPhoneOnly {
        playerNode.play()
      }
      isCapturing = true

      // Lazily initialize audio converter now that we know the hardware format
      initializeConverterIfNeeded()

      // Flag a silent-capture failure mode early.
      let inFmt = inputNode.inputFormat(forBus: 0)
      if inFmt.sampleRate == 0 || inFmt.channelCount == 0, !invalidFormatWarned {
        invalidFormatWarned = true
        print(
          "[AudioSession] ⚠ Invalid input format after engine start "
          + "(rate=\(inFmt.sampleRate), channels=\(inFmt.channelCount)) — "
          + "capture will be silent"
        )
      }

      startStatsTimer()
    } catch {
      print("[AudioSession] Audio engine start error: \(error)")
      inputNode.removeTap(onBus: 0)
    }
  }

  /// Install the mic tap at the current input-node format.
  /// Safe to call repeatedly — removes any existing tap first.
  /// Used both at `startCapture()` time and when a route change alters
  /// the input format, so the tap stays bound to the live bus.
  private func installMicTap() {
    inputNode.removeTap(onBus: 0)
    // Use nil format to accept the hardware's native format; avoids format mismatch on BT HFP.
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, time in
      guard let self = self else { return }
      self.recordCapturedBuffer(buffer)
      // Primary (writer) first — it must never be starved by a slow secondary.
      self.onAudioBuffer?(buffer, time)
      // Optional secondary consumer (currently no installer in tree).
      self.onAudioBufferSecondary?(buffer, time)
    }
  }

  /// `setVoiceProcessingEnabled` forces a full engine-graph teardown +
  /// reconnect; during route flux that reconnect can raise an Objective-C
  /// NSException (`AVAudioEngineGraph::_Connect`) that Swift's do/catch CANNOT
  /// catch — the TestFlight build 1.0(9) crash. Every VPIO toggle in this file
  /// must go through here: the ObjC catcher converts a raised NSException into
  /// a thrown Swift error, and the equality early-out skips no-op toggles
  /// (which still rebuild the graph and carry the same throw risk for nothing).
  nonisolated private static func safeSetVoiceProcessing(
    _ node: AVAudioInputNode, enabled: Bool
  ) throws {
    guard node.isVoiceProcessingEnabled != enabled else {
      print("[AudioSession] VPIO toggle skipped — already enabled=\(enabled) (no-op graph rebuild avoided)")
      return
    }
    print("[AudioSession] VPIO toggle attempt → enabled=\(enabled) | \(vpioContextSnapshot(node))")
    var swiftError: Error?
    do {
      try ObjCExceptionCatcher.catchException {
        do { try node.setVoiceProcessingEnabled(enabled) }
        catch { swiftError = error }
      }
    } catch {
      // This exact NSException was the fatal TestFlight 1.0(9) crash
      // (AVAudioEngineGraph::_Connect). Now it's caught — log the full
      // context so a recurrence is diagnosable from one console paste.
      print("[AudioSession] 🚨 CAUGHT ObjC NSException from setVoiceProcessingEnabled(\(enabled)) "
        + "— this WAS the TestFlight crash. \(error) | \(vpioContextSnapshot(node))")
      throw error
    }
    if let swiftError {
      print("[AudioSession] VPIO toggle threw Swift error: \(swiftError) | \(vpioContextSnapshot(node))")
      throw swiftError
    }
    print("[AudioSession] VPIO toggle succeeded → enabled=\(enabled)")
  }

  /// One-line route/format/session snapshot for the VPIO toggle logs — the
  /// state that decides whether the engine-graph reconnect is safe. Static
  /// so the nonisolated/detached call sites can use it (AVAudioSession APIs
  /// are documented thread-safe).
  nonisolated private static func vpioContextSnapshot(_ node: AVAudioInputNode) -> String {
    let session = AVAudioSession.sharedInstance()
    let fmt = node.inputFormat(forBus: 0)
    let route = session.currentRoute
    let inputs = route.inputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ",")
    let outputs = route.outputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ",")
    return "vpio=\(node.isVoiceProcessingEnabled), inFmt=\(fmt.sampleRate)Hz/\(fmt.channelCount)ch, "
      + "cat=\(session.category.rawValue)/\(session.mode.rawValue), "
      + "inputs=[\(inputs)], outputs=[\(outputs)], otherAudio=\(session.isOtherAudioPlaying)"
  }

  /// Enable hardware voice processing (AEC/NS/AGC) only when it's safe for the
  /// current input route. VPIO is incompatible with the Display glasses' BT-HFP
  /// route — `engine.start()` returns success but the input unit fails to
  /// initialize and the engine self-stops with no buffers — so we disable it
  /// whenever the active input is `.bluetoothHFP` (and for the Mac-route demo,
  /// whose voice-processing IO unit won't take the QuickTime-USB route). For
  /// non-coaching modes VPIO is forced off defensively so a leaked 5-ch VPIO
  /// format from a prior coaching session can't fail `-10868` input-chain
  /// validation. Shared by `startCapture()`, the configuration-change restart,
  /// and (inline-mirrored) `startEngineWithRetry()` so no path re-enables VPIO
  /// on the glasses route and re-triggers the self-stop.
  private func applyVoiceProcessingForCurrentRoute() {
    if mode == .coaching || mode == .coachingPhoneOnly {
      let session = AVAudioSession.sharedInstance()
      let isBTHFPInput = session.currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
      let demoRoute = (mode == .coachingPhoneOnly) && Self.routeAudioToMacForDemo
      let shouldUseVPIO = !isBTHFPInput && !demoRoute
      do {
        try Self.safeSetVoiceProcessing(inputNode, enabled: shouldUseVPIO)
        if !shouldUseVPIO {
          print("[AudioSession] VPIO disabled (BT-HFP input or Mac-route demo) — avoids Display-glasses HFP incompatibility / keeps demo output on the Mac route")
        }
      } catch {
        // The frame that was fatal in TestFlight 1.0(9) — dump everything.
        print("[AudioSession] ⚠ Failed to set voice processing enabled=\(shouldUseVPIO): \(error)")
        print(dumpAudioDiagnostics())
      }
    } else {
      do {
        try Self.safeSetVoiceProcessing(inputNode, enabled: false)
      } catch {
        print("[AudioSession] ⚠ Failed to disable voice processing: \(error)")
        print(dumpAudioDiagnostics())
      }
    }
  }

  @objc private func handleEngineConfigurationChange(notification: Notification) {
    Task { @MainActor in
      // Log unconditionally so a recurrence is diagnosable from the console
      // alone: this proves the notification fired and shows whether the engine
      // actually self-stopped (`isRunning=false` → we restart) or is still
      // healthy (`isRunning=true` → no-op). The input format tells us which
      // route the change settled on (16 kHz mono = the glasses HFP SCO link).
      let fmt = self.inputNode.inputFormat(forBus: 0)
      print("[AudioSession] configurationChange observed (isRunning=\(self.engine.isRunning), "
        + "isCapturing=\(self.isCapturing), input rate=\(fmt.sampleRate), ch=\(fmt.channelCount))")
      self.restartEngineAfterStopIfNeeded(reason: "configurationChange")
    }
  }

  /// Poll for the input format settling after a deferred restart: 8 × 500 ms.
  /// Idempotent — a second deferral while a poll is in flight is a no-op.
  /// Ends early the moment the engine is back (a notification-driven restart
  /// won the race) or capture stopped. On give-up, dumps full diagnostics.
  private func scheduleDeferredRestartRetry(reason: String) {
    guard deferredRestartTask == nil else { return }
    deferredRestartTask = Task { @MainActor [weak self] in
      for attempt in 1...8 {
        try? await Task.sleep(nanoseconds: 500_000_000)  // 500 ms
        guard let self, !Task.isCancelled else { return }
        guard self.isCapturing, !self.engine.isRunning else {
          self.deferredRestartTask = nil
          return
        }
        if self.ensureValidInputFormat(), !self.isAudioSessionInterrupted {
          self.deferredRestartTask = nil
          print("[AudioSession] deferred restart retry #\(attempt) — input format settled, restarting")
          self.restartEngineAfterStopIfNeeded(reason: "\(reason)+retry\(attempt)")
          return
        }
      }
      guard let self else { return }
      self.deferredRestartTask = nil
      print("[AudioSession] ⚠ deferred restart gave up after 8 retries (4s) — input format never settled")
      print(self.dumpAudioDiagnostics())
    }
  }

  @objc private func handleInterruption(notification: Notification) {
    guard let info = notification.userInfo,
          let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue)
    else { return }
    let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)

    Task { @MainActor in
      switch type {
      case .began:
        // iOS already stopped the engine; just remember we're interrupted so
        // the restart path defers instead of reconnecting a dead graph.
        self.isAudioSessionInterrupted = true
        print("[AudioSession] interruption began (isCapturing=\(self.isCapturing))")
      case .ended:
        self.isAudioSessionInterrupted = false
        print("[AudioSession] interruption ended (shouldResume=\(options.contains(.shouldResume)), isCapturing=\(self.isCapturing))")
        guard options.contains(.shouldResume), self.isCapturing else { return }
        // Re-activate before restarting — the interruption deactivated us.
        do {
          try AVAudioSession.sharedInstance().setActive(true)
        } catch {
          print("[AudioSession] ⚠ re-activation after interruption failed: \(error)")
        }
        self.restartEngineAfterStopIfNeeded(reason: "interruptionEnded")
      @unknown default:
        break
      }
    }
  }

  /// Restart the engine after it self-stopped while we're still meant to be
  /// capturing (the post-`engine.start()` HFP configuration change). No-op if we
  /// aren't capturing or the engine is already running. Shared by the
  /// config-change observer and the route-change handler — route-change and
  /// engine-config-change are distinct notifications and either may be the one
  /// that fires for a given stop.
  private func restartEngineAfterStopIfNeeded(reason: String) {
    guard isCapturing, !engine.isRunning else { return }

    // Defer while an interruption is active (phone lock, call, Siri) — the
    // session is deactivated and any engine-graph work can raise the fatal
    // reconnect NSException. `handleInterruption(.ended)` re-enters here.
    guard !isAudioSessionInterrupted else {
      print("[AudioSession] restart after \(reason) deferred — audio session interrupted")
      return
    }

    // Mid-route-flux the input chain can be degenerate (rate 0). Toggling
    // VPIO or starting the engine against it raises the same fatal
    // graph-reconnect NSException. Defer and poll: the settle usually posts
    // another route/config change that re-enters here, but not always (seen
    // in the field: AURemoteIO '!pri' failure with no follow-up notification,
    // leaving the mic dead) — so a bounded retry re-checks on its own.
    guard ensureValidInputFormat() else {
      print("[AudioSession] restart after \(reason) deferred — input format not settled")
      scheduleDeferredRestartRetry(reason: reason)
      return
    }

    // Never re-enable VPIO on the BT-HFP route — that is what self-stops the
    // engine in the first place.
    applyVoiceProcessingForCurrentRoute()

    // Rebuild the tap + converter against the now-settled input format.
    installMicTap()
    audioConverter = nil
    converterInputFormat = nil
    initializeConverterIfNeeded()

    // Re-arm the first-buffer / stall detection so `recordCapturedBuffer`
    // resolves `firstBufferContinuation` and clears `micStalled` when real
    // buffers land on the restarted engine.
    silentMicWarned = false
    lastBufferReceivedAt = nil

    engine.prepare()
    do {
      try engine.start()
      if mode == .coaching || mode == .coachingPhoneOnly {
        playerNode.play()
      }
      let fmt = inputNode.inputFormat(forBus: 0)
      print("[AudioSession] engine restarted after \(reason) (input rate=\(fmt.sampleRate), ch=\(fmt.channelCount)) — awaiting buffers")
    } catch {
      // A failed restart is the worst case (mic stays dead); dump the full
      // route/permission/VPIO/format snapshot so it's diagnosable in one paste.
      print("[AudioSession] ⚠ engine restart after \(reason) failed: \(error)")
      print(dumpAudioDiagnostics())
    }
  }

  func stopCapture() {
    // Tear down even if capture never started. `configureSessionOnly()`
    // activates the shared `AVAudioSession` (`setActive(true)`) as a SEPARATE
    // step from `startCapture()`, and `isCapturing` only flips true once
    // `engine.start()` succeeds. So there's a real window — still connecting,
    // or a silent `engine.start()` failure on the BT/HFP path — where the
    // session is ACTIVE but `isCapturing == false`. If we early-returned on
    // `isCapturing` there, exiting would leave the session active; the next
    // flow (e.g. glasses recording) then stacks its `.record`+HFP activation
    // ON TOP of the still-active session, which makes the glasses show their
    // native "on a call" UI. `didConfigureSession` is true exactly when the
    // session was activated, so gate on either. The engine/tap teardown below
    // is a safe no-op when nothing was started.
    guard isCapturing || didConfigureSession else { return }
    // Release any in-flight HFP warmup waiter so a teardown mid-warmup
    // doesn't leave a suspended continuation hanging until its timeout.
    if let pending = hfpReadyContinuation {
      hfpReadyContinuation = nil
      pending.resume(returning: false)
    }
    // Same for a first-mic-buffer waiter — a teardown before the first buffer
    // must release it rather than let it hang until timeout.
    if let pending = firstBufferContinuation {
      firstBufferContinuation = nil
      pending.resume(returning: false)
    }
    inputNode.removeTap(onBus: 0)
    // Flush pending playback buffers FIRST so the player-node stop can't be
    // racing with a scheduled buffer callback (only applies to coaching modes).
    if mode == .coaching || mode == .coachingPhoneOnly {
      playerNode.stop()
      scheduledBufferCount = 0
      // Lobby music can never outlive the session.
      musicNode.stop()
      musicPlaying = false
    }
    engine.stop()
    isCapturing = false
    isAISpeaking = false
    micStalled = false   // not capturing → no stall warning
    isAudioSessionInterrupted = false  // stale flag must not block the next session
    deferredRestartTask?.cancel()      // a pending restart poll must not outlive the session
    deferredRestartTask = nil
    scheduledBufferCount = 0
    onAudioBuffer = nil  // drop any capture handler so trailing taps can't fire
    onAudioBufferSecondary = nil
    lastBufferPeak = 0
    aiOutputPeak = 0
    userInputPeak = 0
    stopStatsTimer()
    audioConverter = nil
    converterInputFormat = nil
    // Pre-warm state belongs to a single capture cycle. Reset so the next
    // recording's `prewarm()` actually re-engages the input AU instead of
    // early-returning against a category we just flipped to `.playback`.
    didPrewarm = false
    // Same rationale for `didConfigureSession`: this cycle's configure is
    // about to be undone by the `.playback` switch below; the next cycle
    // needs to re-configure from scratch.
    didConfigureSession = false

    // Leave AVAudioSession in a state that plays nicely with whatever comes
    // next — review sheet's AVPlayer, another capture session, or idle.
    //
    // For recording modes: flip to `.playback` so AVPlayer in the review sheet
    // can play the just-captured file.
    // For coaching modes: also flip to `.playback`, then deactivate — otherwise
    // the session stays in `.playAndRecord/.voiceChat` with `.defaultToSpeaker`
    // and downstream audio gets stuck on the loudspeaker at phone-call volume.
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .default, options: [])
      try session.setActive(true)
    } catch {
      print("[AudioSession] Failed to switch to .playback: \(error)")
    }

    if mode == .coaching || mode == .coachingPhoneOnly {
      do {
        // `.notifyOthersOnDeactivation` wakes any other audio app we bumped
        // during `.voiceChat` so system routing snaps back cleanly.
        try session.setActive(false, options: .notifyOthersOnDeactivation)
      } catch {
        print("[AudioSession] Failed to deactivate: \(error)")
      }
    }
  }

  /// Fully release the shared `AVAudioSession`. Recording-mode `stopCapture`
  /// intentionally leaves the session active in `.playback` so the review
  /// sheet's `AVPlayer` can play the just-captured file. When the user
  /// finally backs out of the recording flow entirely, call this so other
  /// apps' background audio resumes cleanly. Idempotent.
  func deactivate() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setActive(false, options: .notifyOthersOnDeactivation)
    } catch {
      print("[AudioSession] Failed to deactivate: \(error)")
    }
    // Deactivating throws away the route we pre-warmed against, so the
    // next entry into the recording flow needs a fresh `prewarm()`.
    didPrewarm = false
  }

  // MARK: - Capture telemetry

  /// Called from the tap thread on every captured buffer.
  /// Extract primitives here so we don't capture the non-Sendable
  /// `AVAudioPCMBuffer` into the main-actor hop closure.
  nonisolated private func recordCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
    let peak = Self.peakAmplitude(of: buffer)
    Task { @MainActor [weak self] in
      guard let self = self else { return }
      let wasFirstBuffer = self.lastBufferReceivedAt == nil
      self.lastBufferReceivedAt = Date()
      self.captureBuffersSinceLastFlush += 1
      self.silentMicWarned = false  // buffers are flowing; re-arm watchdog
      self.micStalled = false       // buffers flowing → clear the HFP warning
      if wasFirstBuffer, let pending = self.firstBufferContinuation {
        // SCO is now carrying data — release any `awaitFirstMicBuffer` waiter.
        self.firstBufferContinuation = nil
        pending.resume(returning: true)
      }
      self.lastBufferPeak = peak
      // EMA shape mirrors `aiOutputPeak`: faster attack than release so a
      // sharp utterance pops the meter, then it tails off softly.
      let alpha: Float = peak > self.userInputPeak ? 0.6 : 0.2
      self.userInputPeak += alpha * (peak - self.userInputPeak)
      if self.userInputPeak >= Self.userSpeakingFloor {
        self.lastAudioActivityAt = Date()
      }
    }
  }

  /// Max absolute sample value across the buffer, normalized to 0...1.
  /// Handles the common Float32 and Int16 cases; returns 0 for unsupported
  /// formats so the UI meter just stays dark instead of misreporting.
  nonisolated private static func peakAmplitude(of buffer: AVAudioPCMBuffer) -> Float {
    let frameLength = Int(buffer.frameLength)
    guard frameLength > 0 else { return 0 }
    let channelCount = Int(buffer.format.channelCount)

    if let floatPtr = buffer.floatChannelData {
      var peak: Float = 0
      for channel in 0..<channelCount {
        let samples = floatPtr[channel]
        for i in 0..<frameLength {
          let mag = abs(samples[i])
          if mag > peak { peak = mag }
        }
      }
      return min(1.0, peak)
    }

    if let int16Ptr = buffer.int16ChannelData {
      var peak: Int32 = 0
      for channel in 0..<channelCount {
        let samples = int16Ptr[channel]
        for i in 0..<frameLength {
          let mag = Int32(samples[i].magnitude)
          if mag > peak { peak = mag }
        }
      }
      return min(1.0, Float(peak) / Float(Int16.max))
    }

    return 0
  }

  private func startStatsTimer() {
    guard statsTask == nil else { return }
    statsTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 s
        if Task.isCancelled { return }
        self?.flushCaptureStats()
        self?.checkSilentMicWatchdog()
      }
    }
  }

  private func stopStatsTimer() {
    statsTask?.cancel()
    statsTask = nil
    captureBuffersSinceLastFlush = 0
    silentMicWarned = false
    invalidFormatWarned = false
    lastBufferReceivedAt = nil
    playbackAllocFailures = 0
  }

  private func flushCaptureStats() {
    guard isCapturing else { return }
    captureBuffersSinceLastFlush = 0
  }

  private func checkSilentMicWatchdog() {
    guard isCapturing, !silentMicWarned else { return }
    if let last = lastBufferReceivedAt,
       Date().timeIntervalSince(last) > 3.0 {
      silentMicWarned = true
      micStalled = true   // mid-session: buffers stopped → surface the warning
      print(
        "[AudioSession] ⚠ No mic buffers for 3s — check BT HFP route or "
        + "glasses mic permission"
      )
    } else if lastBufferReceivedAt == nil,
              Date().timeIntervalSince(Date().addingTimeInterval(-3.0)) >= 0,
              captureBuffersSinceLastFlush == 0 {
      // Engine started but no first buffer ever arrived.
      silentMicWarned = true
      micStalled = true   // startup: engine up but no buffers → surface the warning
      print(
        "[AudioSession] ⚠ No mic buffers since capture started — "
        + "check mic permission / hardware route"
      )
    }
  }

  // MARK: - Playback (PCM16LE 24kHz mono from Gemini)

  /// Play raw PCM16 Int16 audio data received from Gemini Live.
  /// Thread-safe — can be called from any thread. No-op in recording modes.
  func playPcm16Audio(_ data: Data) {
    guard mode == .coaching || mode == .coachingPhoneOnly else {
      print("[AudioSession] ⚠ playPcm16Audio called in recording mode — ignoring")
      return
    }
    let bytesPerFrame = 2  // Int16
    let frameCount = AVAudioFrameCount(data.count / bytesPerFrame)
    guard frameCount > 0 else {
      Task { @MainActor [weak self] in
        guard let self = self else { return }
        self.playbackAllocFailures += 1
        if self.playbackAllocFailures == 1 {
          print("[AudioSession] ⚠ playPcm16Audio: zero-frame chunk (bytes=\(data.count))")
        }
      }
      return
    }

    guard let buffer = AVAudioPCMBuffer(
      pcmFormat: playbackFormat,
      frameCapacity: frameCount
    ) else {
      Task { @MainActor [weak self] in
        guard let self = self else { return }
        self.playbackAllocFailures += 1
        print(
          "[AudioSession] ⚠ Failed to allocate playback buffer "
          + "(frames=\(frameCount), total failures=\(self.playbackAllocFailures))"
        )
      }
      return
    }

    buffer.frameLength = frameCount
    data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      memcpy(buffer.int16ChannelData![0], base, data.count)
    }

    // Sample the buffer's amplitude here so the audio meter responds to
    // the AI's actual voice volume. Cheap one-pass scan, same primitive
    // used on the input path.
    let rawPeak = Self.peakAmplitude(of: buffer)

    // Start of an AI speaking burst (queue was empty). Used to log playback
    // health once per turn — NOT once per session: this manager is long-lived
    // and borrowed across Ask AI / coaching sessions, so a session-scoped
    // one-shot would only ever log on the very first turn after arm.
    let burstStart = (scheduledBufferCount == 0)
    scheduledBufferCount += 1
    Task { @MainActor [weak self] in
      guard let self = self else { return }
      self.isAISpeaking = true
      // Ping the activity timestamp on every chunk enqueue so
      // inter-chunk gaps in `scheduledBufferCount` can't reset the
      // "AI is talking" signal mid-utterance.
      self.lastAudioActivityAt = Date()
      // EMA: fast attack (0.6) so the meter spikes immediately when AI
      // starts a phoneme; slower release (0.2) so it doesn't strobe in
      // the silences between syllables. The consuming meter additionally
      // smooths via its own rolling buffer.
      let alpha: Float = rawPeak > self.aiOutputPeak ? 0.6 : 0.2
      self.aiOutputPeak += alpha * (rawPeak - self.aiOutputPeak)
    }

    // Playback health, logged once per AI turn (burst start). Confirms the
    // engine/player are live and where output routes. NOTE: a BluetoothHFP
    // output is EXPECTED whenever the glasses mic is open (mic capture forces
    // the glasses off A2DP onto HFP for both directions). The HFP downlink is
    // audible but rides a separate "call" volume that defaults low — if the
    // coach can't be heard, raise the in-call volume, don't assume a bug.
    if burstStart {
      let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        .map { "\($0.portName)(\($0.portType.rawValue))" }
        .joined(separator: ",")
      print("[AudioSession] AI-turn playback start (\(data.count) bytes): "
        + "engineRunning=\(engine.isRunning), playerPlaying=\(playerNode.isPlaying), out=[\(outs)]")
    }
    // Self-heal: the borrowed persistent-audio engine may have self-stopped
    // (post-start config change) or the player may not be transporting.
    if !engine.isRunning {
      // Engine died — schedule a restart on the main actor; this chunk is lost
      // but subsequent ones play once the engine is back.
      Task { @MainActor [weak self] in self?.restartEngineAfterStopIfNeeded(reason: "playback") }
    } else if !playerNode.isPlaying {
      playerNode.play()
    }

    playerNode.scheduleBuffer(buffer) { [weak self] in
      guard let self = self else { return }
      Task { @MainActor in
        self.scheduledBufferCount -= 1
        if self.scheduledBufferCount <= 0 {
          self.scheduledBufferCount = 0
          self.isAISpeaking = false
          // Hand off to the meter's roll-off — set source to 0 and the
          // meter's rolling buffer drains over ~630 ms.
          self.aiOutputPeak = 0
        }
      }
    }
  }

  /// Flush all queued playback buffers and restart the player.
  func clearPlaybackBuffer(reason: String = "unspecified") {
    guard mode == .coaching || mode == .coachingPhoneOnly else {
      print("[AudioSession] ⚠ clearPlaybackBuffer called in recording mode — ignoring")
      return
    }
    playerNode.stop()
    scheduledBufferCount = 0
    isAISpeaking = false
    aiOutputPeak = 0
    // Only re-prime the player if the engine is still running. Barge-in can
    // fire after stopCapture() has torn the engine down; calling
    // playerNode.play() on a stopped engine is a no-op that logs an
    // AVAudioEngine error (AVAudioPlayerNodeImpl.mm line-noise) without
    // any meaningful signal for the caller.
    if engine.isRunning {
      playerNode.play()
    }
  }

  // MARK: - Lobby music

  /// Start (or restart) looping lobby music UNDERNEATH Gemini. Always seeds
  /// from the top of the track — calling this while already playing re-starts
  /// it from frame 0. No-op unless we're in a coaching playback mode with a
  /// running engine, and a no-op (logged once) if no bundled track is present
  /// so the rest of the feature works before the asset lands.
  func startLobbyMusic() {
    guard mode == .coaching || mode == .coachingPhoneOnly else { return }
    guard engine.isRunning else {
      print("[AudioSession] startLobbyMusic skipped — engine not running")
      return
    }
    guard let url = Self.lobbyMusicURL() else {
      print("[AudioSession] startLobbyMusic — no bundled lobby track found (add Resources/lobby_music.*)")
      return
    }

    // Always restart from the beginning.
    musicNode.stop()
    musicPlaying = false

    do {
      let file = try AVAudioFile(forReading: url)
      let format = file.processingFormat
      let frames = AVAudioFrameCount(file.length)
      guard frames > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
        print("[AudioSession] startLobbyMusic — empty/invalid track")
        return
      }
      try file.read(into: buffer)
      musicNode.volume = musicVolume
      // `.loops` re-plays the buffer seamlessly until `stop()`.
      musicNode.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
      musicNode.play()
      musicPlaying = true
      print("[AudioSession] lobby music started (looping, vol \(musicVolume))")
    } catch {
      print("[AudioSession] startLobbyMusic failed: \(error)")
    }
  }

  /// Stop lobby music. Safe to call when not playing.
  func stopLobbyMusic() {
    guard musicPlaying else { return }
    musicNode.stop()
    musicPlaying = false
    print("[AudioSession] lobby music stopped")
  }

  /// Locate a bundled lobby-music track. Accepts a few common containers so a
  /// designer can drop in whatever they have.
  private static func lobbyMusicURL() -> URL? {
    for ext in ["m4a", "mp3", "caf", "wav"] {
      if let url = Bundle.main.url(forResource: "lobby_music", withExtension: ext) {
        return url
      }
    }
    return nil
  }

  // MARK: - Format Conversion (mic → PCM16 16kHz mono for Gemini)

  /// Convert a mic capture buffer to PCM16 16kHz mono Data for sending to Gemini.
  /// Returns nil if conversion fails.
  func convertBufferForSend(_ buffer: AVAudioPCMBuffer) -> Data? {
    guard let converter = audioConverter else {
      // Fallback: try to initialize now
      initializeConverterIfNeeded()
      guard let converter = audioConverter else { return nil }
      return convertWithConverter(converter, buffer: buffer)
    }
    return convertWithConverter(converter, buffer: buffer)
  }

  /// Convert a mic capture buffer to a PCM16 16 kHz mono `AVAudioPCMBuffer`
  /// for muxing as LinearPCM directly into an AVAssetWriter audio track.
  /// Same converter + target format as `convertBufferForSend(_:)`; this
  /// variant returns the buffer instead of extracting bytes into Data, so
  /// the caller can hand it to a CMSampleBuffer builder.
  ///
  /// Used by glasses Expert recording — packaging PCM directly avoids the
  /// AAC-at-HFP-rate encoder failure that poisons AVAssetWriter status with
  /// `OSStatus -12651`.
  func convertBufferToPcmRecording(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    if audioConverter == nil { initializeConverterIfNeeded() }
    guard let converter = audioConverter else { return nil }

    let ratio = sendFormat.sampleRate / buffer.format.sampleRate
    let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
    guard outputFrameCount > 0 else { return nil }

    guard let outputBuffer = AVAudioPCMBuffer(
      pcmFormat: sendFormat,
      frameCapacity: outputFrameCount
    ) else { return nil }

    var error: NSError?
    var hasData = false
    converter.convert(to: outputBuffer, error: &error) { _, outStatus in
      if hasData {
        outStatus.pointee = .noDataNow
        return nil
      }
      hasData = true
      outStatus.pointee = .haveData
      return buffer
    }
    if let error = error {
      print("[AudioSession] PCM recording conversion error: \(error)")
      return nil
    }
    guard outputBuffer.frameLength > 0 else { return nil }
    return outputBuffer
  }

  private func convertWithConverter(_ converter: AVAudioConverter, buffer: AVAudioPCMBuffer) -> Data? {
    let ratio = sendFormat.sampleRate / buffer.format.sampleRate
    let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
    guard outputFrameCount > 0 else { return nil }

    guard let outputBuffer = AVAudioPCMBuffer(
      pcmFormat: sendFormat,
      frameCapacity: outputFrameCount
    ) else { return nil }

    var error: NSError?
    var hasData = false

    converter.convert(to: outputBuffer, error: &error) { _, outStatus in
      if hasData {
        outStatus.pointee = .noDataNow
        return nil
      }
      hasData = true
      outStatus.pointee = .haveData
      return buffer
    }

    if let error = error {
      print("[AudioSession] Audio conversion error: \(error)")
      return nil
    }

    guard outputBuffer.frameLength > 0 else { return nil }

    // Extract raw Int16 bytes
    let byteCount = Int(outputBuffer.frameLength) * 2  // Int16 = 2 bytes
    guard let channelData = outputBuffer.int16ChannelData else { return nil }
    return Data(bytes: channelData[0], count: byteCount)
  }

  private func initializeConverterIfNeeded() {
    guard audioConverter == nil else { return }
    let hwFormat = inputNode.inputFormat(forBus: 0)
    guard hwFormat.sampleRate > 0 else { return }
    audioConverter = AVAudioConverter(from: hwFormat, to: sendFormat)
    converterInputFormat = hwFormat
  }

  // MARK: - Route Monitoring

  @objc private func handleRouteChange(notification: Notification) {
    guard let info = notification.userInfo,
          let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
    else { return }

    let reasonLabel = routeChangeReasonLabel(reason)

    // NOTE: Do NOT call configureAudioSession() from inside a route-change handler.
    // Reconfiguring the session here triggers another categoryChange notification,
    // which cascades and can leave the mic tap orphaned from the live input format.
    // Let iOS own the routing; we just rebind the tap to the new input format.

    Task { @MainActor in
      self.checkBluetoothRoute()

      // Event-driven HFP warmup: if a caller is suspended in
      // `awaitHFPRouteReady`, resolve it the instant the glasses BT HFP
      // route is actually up with a settled format. Gated by
      // `glassesHFPRouteReady()`, so intermediate route changes (built-in
      // mic, half-negotiated SCO) don't fire it early.
      if self.hfpReadyContinuation != nil, self.glassesHFPRouteReady() {
        let pending = self.hfpReadyContinuation
        self.hfpReadyContinuation = nil
        print("[AudioSession] HFP glasses route confirmed (reason=\(reasonLabel)) — releasing warmup wait")
        pending?.resume(returning: true)
      }

      // Route changes that can alter the input format or invalidate the tap.
      // When capturing, drop the old tap, reinit the converter against the new
      // input format, and reinstall — so the tap stays bound to the live bus.
      switch reason {
      case .newDeviceAvailable,
           .oldDeviceUnavailable,
           .override,
           .categoryChange,
           .routeConfigurationChange:
        // Glasses modes: if another HFP device (e.g. AirPods connecting
        // mid-session) grabbed the route, re-pin the glasses input. The
        // subsequent setPreferredInput re-fires this handler; the
        // already-pinned guard below makes that a no-op so we don't loop.
        self.reassertGlassesInputIfNeeded()
        self.rebindMicTapIfCapturing(reason: reasonLabel)
      default:
        break
      }
    }
  }

  /// Re-pin the glasses' BT HFP input when in a glasses mode and the current
  /// input isn't already the glasses. No-op otherwise — including when the
  /// glasses are already the active input, which breaks the
  /// setPreferredInput → routeConfigurationChange → re-pin feedback loop.
  private func reassertGlassesInputIfNeeded() {
    guard isGlassesMode, isCapturing else { return }
    let session = AVAudioSession.sharedInstance()
    guard let glasses = Self.selectGlassesInput(from: session, names: preferredGlassesNames) else {
      return
    }
    let alreadyGlasses = session.currentRoute.inputs.contains { $0.uid == glasses.uid }
    guard !alreadyGlasses else { return }
    do {
      try session.setPreferredInput(glasses)
      print("[AudioSession] glasses input re-pinned after route change: \(glasses.portName)")
    } catch {
      print("[AudioSession] Failed to re-pin glasses input \(glasses.portName): \(error)")
    }
  }

  /// Re-bind the mic tap to the current input-node format after a route change.
  /// Safe no-op when we aren't capturing or the engine isn't running.
  ///
  /// Short-circuits when the live input format matches the format the converter
  /// was built against. This collapses the startup cascade where `setCategory`
  /// + `setActive` + `overrideOutputAudioPort` + `setPreferredInput` + engine
  /// start all queue route-change notifications that the run loop delivers
  /// *after* `startCapture()` returns — each previously rebuilt tap + converter
  /// against an unchanged format. Real route swaps (HFP ↔ built-in) change
  /// rate or channel count and still fall through to the rebuild path.
  private func rebindMicTapIfCapturing(reason: String) {
    guard isCapturing else { return }
    // If the engine self-stopped (config change during HFP warmup), restart it
    // rather than bail — otherwise the mic stays dead for the whole session.
    guard engine.isRunning else {
      restartEngineAfterStopIfNeeded(reason: "routeChange:\(reason)")
      return
    }

    let liveFmt = inputNode.inputFormat(forBus: 0)

    if let built = converterInputFormat,
       built.sampleRate == liveFmt.sampleRate,
       built.channelCount == liveFmt.channelCount,
       built.commonFormat == liveFmt.commonFormat {
      return
    }

    // Install at the new format. `installMicTap()` removes any existing tap first.
    installMicTap()

    // The hardware format changed (HFP ↔ built-in); rebuild the converter.
    audioConverter = nil
    converterInputFormat = nil
    initializeConverterIfNeeded()

    // Re-arm the silent-mic watchdog so it evaluates against the new route.
    silentMicWarned = false
    lastBufferReceivedAt = nil
  }

  private func routeChangeReasonLabel(_ reason: AVAudioSession.RouteChangeReason) -> String {
    switch reason {
    case .unknown: return "unknown"
    case .newDeviceAvailable: return "newDeviceAvailable"
    case .oldDeviceUnavailable: return "oldDeviceUnavailable"
    case .categoryChange: return "categoryChange"
    case .override: return "override"
    case .wakeFromSleep: return "wakeFromSleep"
    case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
    case .routeConfigurationChange: return "routeConfigurationChange"
    @unknown default: return "other(\(reason.rawValue))"
    }
  }

  private func checkBluetoothRoute() {
    let route = AVAudioSession.sharedInstance().currentRoute
    let hasBluetoothInput = route.inputs.contains { input in
      input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP
    }
    let hasBluetoothOutput = route.outputs.contains { output in
      output.portType == .bluetoothHFP || output.portType == .bluetoothA2DP
    }
    isBluetoothConnected = hasBluetoothInput || hasBluetoothOutput
  }


}
