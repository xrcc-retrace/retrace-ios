import MWDATCore
import SwiftUI

/// The Troubleshoot mode voice session. Voice-only for v1 (no camera, no
/// PiP, no step instruction panel). Peer to CoachingSessionView — fresh
/// layout, deliberate scope reduction.
struct TroubleshootSessionView: View {
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  @ObservedObject var progressStore: LocalProgressStore
  let serverBaseURL: String
  let transport: CaptureTransport
  /// Called when the diagnostic ends. Carries an optional learner-session
  /// payload — non-nil means the user found a fix and is being handed
  /// off to coaching; the parent dismisses this cover and presents
  /// `CoachingSessionView` so the two flows don't stack. Nil means a
  /// manual exit (X button, pinch-back, end-diagnostic alert) — parent
  /// just dismisses and stays on `TroubleshootIntroView`.
  let onExit: (LearnerSessionStartResponse?) -> Void

  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var appOrientationController: AppOrientationController
  @EnvironmentObject private var lensSession: LensSession
  @StateObject private var viewModel: DiagnosticSessionViewModel

  @State private var showDismissConfirmation = false
  // Demo flag — when on, the confirm overlay gets a third "Talk" option so the
  // user can answer the identification question by voice (push-to-talk).
  @AppStorage("debug.routeAudioToMacForDemo") private var routeAudioToMacForDemo = false
  // Drawer state for the camera-first layout. Both transports use the
  // same drawer — the camera feed (iPhone preview layer or glasses video
  // stream) sits behind the lens emulator; pull up the drawer for the
  // activity feed. Starts collapsed so the lens has the user's full
  // attention on session entry.
  @State private var drawerExpanded = false
  // Active lens page inside the Ray-Ban emulator. Troubleshoot ships with
  // zero pages today; the designer fills them in incrementally.
  @State private var troubleshootPageIndex: Int = 0
  // Glasses transport only: lens over an app-themed background by default;
  // the raw glasses feed is hidden until the user taps "Show camera". Plain
  // @State so it resets to hidden every session.
  @State private var showCameraFeed = false
  // Portrait is the app default; the real value is overwritten in
  // `.onAppear` from `resolveInterfaceOrientation()` so the session
  // preserves whatever orientation the phone is already in. Mirrors
  // Coaching's orientation flow.
  @State private var currentInterfaceOrientation: UIInterfaceOrientation = .portrait
  // Set true the moment a handoff to coaching is committed (just before
  // `onExit(payload)`). The `onDisappear` cleanup gates `unlock()` on
  // this — when handing off, the learner view manages its own
  // orientation, so we mustn't slam the device back to portrait via
  // `requestGeometryUpdate(.portrait)` in between. Manual-exit paths
  // (X close, pinch-back) leave this false so the existing unlock
  // behavior runs and the parent context returns to portrait.
  @State private var isHandingOff = false
  // Global debug surface — drives the lens boundary outline and the
  // hand-tracking landmark overlay. Set in Server Settings → Debug.
  @AppStorage("debugMode") private var debugMode: Bool = false
  @AppStorage("hudAdditiveBlend") private var hudAdditiveBlend: Bool = false

  init(
    wearables: WearablesInterface,
    wearablesVM: WearablesViewModel,
    progressStore: LocalProgressStore,
    serverBaseURL: String,
    transport: CaptureTransport,
    onExit: @escaping (LearnerSessionStartResponse?) -> Void,
    sessionManager: DeviceSessionManager
  ) {
    self.wearables = wearables
    self.wearablesVM = wearablesVM
    self.progressStore = progressStore
    self.serverBaseURL = serverBaseURL
    self.transport = transport
    self.onExit = onExit
    self._viewModel = StateObject(wrappedValue: DiagnosticSessionViewModel(
      wearables: wearables,
      serverBaseURL: serverBaseURL,
      transport: transport,
      sessionManager: sessionManager
    ))
  }

  var body: some View {
    ZStack {
      // One layout for both transports — only the camera content layer
      // differs. The HUD pages, confirmation overlays, and exit flow are
      // identical regardless of where the pixels behind the lens come
      // from.
      IPhoneCoachingLayout(
        viewModel: viewModel,
        drawerExpanded: $drawerExpanded,
        showDrawer: debugMode && currentInterfaceOrientation.isPortrait,
        cameraContent: {
          switch transport {
          case .iPhone:
            if let previewLayer = viewModel.iPhonePreviewLayer {
              IPhoneCameraPreview(previewLayer: previewLayer)
            } else {
              Color.black
            }
          case .glasses:
            // Hide the raw glasses feed by default — show the lens over an
            // app-themed background. The "Show camera" pill reveals the feed.
            Group {
              if showCameraFeed {
                GlassesCameraPreview(image: viewModel.glassesPreviewFrame)
              } else {
                GlassesThemedBackground()
              }
            }
            .animation(.easeInOut(duration: 0.25), value: showCameraFeed)
          }
        },
        hud: {
          // Lens drives the five-step Troubleshoot flow. Exactly one page
          // is alive at a time; the page is selected from VM state. The
          // confirmation overlay layers on top via the recede+arrive
          // pattern when `pendingConfirmation == true`.
          //
          // Overlay sits *inside* the emulator's page closure (mirrors
          // ExpertNarrationTipPage's ZStack pattern, lines 56-85) so
          // both the page and the overlay are children of the emulator
          // and inherit its `HUDHoverCoordinator` environmentObject.
          // Rendering the overlay as a sibling of the emulator (the
          // older shape) leaves it without the env and crashes on first
          // hover read.
          RayBanHUDEmulator(
            pageCount: 1,
            pageIndex: $troubleshootPageIndex,
            showBoundary: debugMode,
            additiveBlend: hudAdditiveBlend,
            additiveSurfaceVariant: .lowTint,
            // Lens double-tap → focus-engine `.dismiss` → topmost
            // page handler routes to the end-diagnostic overlay.
            // Mirrors Coaching's exit pattern, and gives touch
            // parity with the MediaPipe double-pinch back gesture
            // (which still also fires `viewModel.onBackGesture`
            // legacy callback below).
            enableDismissGesture: true
          ) { _ in
            ZStack {
              troubleshootCurrentPage
                // Canonical recede so the overlay reads as foreground.
                // Numbers live in `RayBanHUDLayoutTokens.recede*`.
                .rayBanHUDRecede(active: viewModel.pendingConfirmation || showDismissConfirmation)

              if viewModel.pendingConfirmation, let product = viewModel.identifiedProduct {
                TroubleshootConfirmOverlay(
                  product: product,
                  onConfirm: { viewModel.confirmIdentification() },
                  onReject: { viewModel.requestReIdentify() },
                  isPushToTalk: routeAudioToMacForDemo,
                  isTalkEngaged: viewModel.isTalkEngaged,
                  onTalkDown: { viewModel.talkPressBegan() },
                  onTalkUp: { viewModel.talkPressEnded() }
                )
                .transition(.scale(scale: 0.88).combined(with: .opacity))
              }

              if showDismissConfirmation {
                CoachingExitConfirmationOverlay(
                  onCancel: {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                      showDismissConfirmation = false
                    }
                  },
                  onConfirm: confirmDiagnosticExit
                )
                .transition(.scale(scale: 0.88).combined(with: .opacity))
                .padding(.horizontal, 32)
              }
            }
            .animation(
              .spring(response: 0.32, dampingFraction: 0.85),
              value: viewModel.pendingConfirmation
            )
            .animation(
              .spring(response: 0.32, dampingFraction: 0.85),
              value: showDismissConfirmation
            )
            .animation(
              .spring(response: 0.32, dampingFraction: 0.85),
              value: troubleshootPageKind
            )
          }
        }
      ) {
        stackedBody
      }

      // Glasses-session phone chrome — "running on glasses" banner + camera
      // feed toggle. Glasses transport only; iPhone keeps its full-bleed
      // camera with no chrome.
      if transport == .glasses {
        GlassesSessionChrome(
          deviceName: glassesDeviceName,
          status: glassesSessionStatus,
          lensUnavailable: viewModel.glassesLensUnavailable,
          showCameraFeed: $showCameraFeed
        )
      }

      // Hand-tracking dev overlay — landmark dots, pinch-drag cross, event
      // log. Sits above everything but allows hit-testing through. Reads
      // from the single shared `HandGestureService` regardless of mode.
      if debugMode {
        HandGestureDebugStack(provider: HandGestureService.shared)
      }

      // Session-health banners: voice-socket errors, camera-branch death,
      // mic stall. Top-anchored, non-blocking (voice keeps running under the
      // camera banner). Mirrors CoachingSessionView's banner stack — this view
      // previously surfaced NO error UI at all for Gemini/camera failures.
      if isGeminiError || viewModel.cameraHealth != .ok || viewModel.micStalled {
        VStack(spacing: Spacing.sm) {
          if isGeminiError {
            reconnectBanner
          }
          if viewModel.cameraHealth != .ok {
            cameraHealthBanner
          }
          if viewModel.micStalled {
            micStalledBanner
          }
          Spacer()
        }
        .padding(.top, Spacing.section)
        .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(.easeInOut(duration: 0.25), value: viewModel.micStalled)
    .animation(.easeInOut(duration: 0.25), value: viewModel.cameraHealth)
    .animation(.easeInOut(duration: 0.25), value: isGeminiError)
    .preferredColorScheme(.dark)
    .onAppear {
      // Double index-finger pinch ("back" gesture) → end-diagnostic
      // confirmation, same destination as the top-bar close button.
      viewModel.onBackGesture = {
        showDismissConfirmation = true
      }
      // Lens-side Start button (Step 8 `TroubleshootLensRenderer`)
      // delegates here so the post-handoff navigation (which owns the
      // `onExit(payload)` cover dismissal) stays on the view layer.
      viewModel.onLensStartHandoff = { procedureId in
        Task { await startHandoff(procedureId: procedureId) }
      }
      // Lens-side "Confirm exit" (on-lens end-diagnostic overlay) runs the
      // same terminal teardown as the phone overlay's confirm path.
      viewModel.onExitConfirmed = {
        confirmDiagnosticExit()
      }
      // Activate the troubleshoot lens renderer. `LensSession.send` forwards to
      // the coordinator, which no-ops safely when no Display-capable device is
      // reachable — so this is safe to call unconditionally.
      //
      // DEFERRED until `isReadyForNativeLens`: the Display capability shares
      // the glasses' BT radio with the HFP mic. Starting it during the HFP
      // warmup makes iOS drop the glasses mic route (falls back to AirPods).
      // We wait until audio + camera are confirmed up; the `.onChange` below
      // activates the lens once the session signals ready. (Parallel to
      // CoachingSessionView; see `GeminiLiveSessionBase.isReadyForNativeLens`.)
      if viewModel.isReadyForNativeLens {
        lensSession.activate(.troubleshoot, vm: viewModel)
      }
      if transport == .iPhone {
        // Match Coaching's orientation flow — broaden the allowed mask so
        // SwiftUI chrome can follow the phone into landscape, seed the
        // preview from the scene's actual interface orientation, and let
        // the observer below forward future rotations into the camera.
        appOrientationController.setAllowed([.portrait, .landscapeLeft, .landscapeRight])
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        let resolved = resolveInterfaceOrientation()
        currentInterfaceOrientation = resolved
        viewModel.setPreviewInterfaceOrientation(resolved)
      }
    }
    // `.task` (not `Task { … }` in `.onAppear`) so SwiftUI cancels the
    // session-start automatically on view disappearance. Prevents an
    // unstructured Task from running teardown into a half-released VM
    // when the user dismisses mid-handshake.
    .task {
      await viewModel.startSession()
    }
    // Bring the native lens up once audio + camera are confirmed ready (see
    // the deferred activate in `.onAppear`). Normal path: at appear time the
    // session is still starting (flag false); it flips true mid-startup.
    .onChange(of: viewModel.isReadyForNativeLens) { _, ready in
      if ready {
        lensSession.activate(.troubleshoot, vm: viewModel)
      }
    }
    .onDisappear {
      // Tear down the troubleshoot lens renderer first so its Combine
      // subscriptions don't fire a final send while the VM is being
      // released. The display capability itself stays attached (app-
      // scoped via `LensDisplayCoordinator`).
      lensSession.deactivate()
      viewModel.onLensStartHandoff = nil
      viewModel.onExitConfirmed = nil
      viewModel.endSession()
      if transport == .iPhone {
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        // Skip `unlock()` on the handoff path — the learner view that's
        // about to mount manages its own orientation. Slamming the
        // device to portrait here (via `requestGeometryUpdate(.portrait)`
        // inside `unlock`) would race the learner's `setAllowed` and
        // leave the OS-level supported set narrowed to portrait, which
        // is what was previously breaking rotation in the post-handoff
        // coaching session.
        if !isHandingOff {
          appOrientationController.unlock()
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
      guard transport == .iPhone else { return }
      let resolved = resolveInterfaceOrientation()
      currentInterfaceOrientation = resolved
      viewModel.setPreviewInterfaceOrientation(resolved)
    }
    .sheet(isPresented: $viewModel.showManualUploadSheet) {
      ManualUploadSheet(
        isPresented: $viewModel.showManualUploadSheet,
        onUpload: { url in
          await viewModel.submitManualUpload(pdfURL: url)
        }
      )
      .presentationDetents([.medium, .large])
    }
    // Recovery layer of the DAT camera permission gate. Mirrors the
    // identical pattern on CoachingSessionView — pre-flight in the
    // transport picker (CaptureTransportPickerSheet) catches the
    // common case; this sheet catches the residual race where
    // permission was revoked between picker tap and session start.
    .sheet(isPresented: $viewModel.pendingGlassesPermissions) {
      PermissionRequiredSheet(
        onGranted: {
          Task { await viewModel.retryAfterPermissionGrant() }
        },
        onCancel: {
          viewModel.pendingGlassesPermissions = false
        }
      )
    }
    // Audio readiness recovery — mirrors CoachingSessionView. Surfaced
    // when BT HFP SCO didn't deliver a buffer within the timeout window.
    .sheet(isPresented: $viewModel.pendingAudioRetry) {
      AudioRecoverySheet(
        onRetry: {
          Task { await viewModel.retryAfterAudioFailure() }
        },
        onCancel: {
          viewModel.pendingAudioRetry = false
        }
      )
    }
    // DAT helper update recovery — mirrors CoachingSessionView. Surfaced
    // when the SDK throws `datAppOnTheGlassesUpdateRequired`. Routes the
    // user through Meta AI's update flow via the SDK's built-in deep link.
    .sheet(isPresented: $viewModel.pendingDATHelperUpdate) {
      DATHelperUpdateRequiredSheet(
        onOpenMetaAI: {
          wearablesVM.openDATGlassesAppUpdate()
        },
        onRetry: {
          Task { await viewModel.retryAfterDATHelperUpdate() }
        },
        onCancel: {
          viewModel.pendingDATHelperUpdate = false
        }
      )
    }
    // Camera-branch death — same surface as CoachingSessionView. Fires once
    // per failure episode; the persistent cameraHealthBanner remains after
    // dismissal as the voice-only indicator.
    .alert("Camera lost", isPresented: $viewModel.showCameraLostAlert) {
      Button("Retry") { viewModel.retryCameraBranch() }
      Button("Continue voice-only", role: .cancel) {}
    } message: {
      Text("I can no longer see the product. Visual diagnosis is off until the camera reconnects.")
    }
  }

  // MARK: - Stacked Body (shared by glasses transport directly and by the
  // iPhone drawer)

  @ViewBuilder
  private var stackedBody: some View {
    VStack(spacing: 0) {
      topBar

      activityFeed
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.md)

      if let resolution = viewModel.resolution {
        DiagnosticResolutionPanel(
          resolution: resolution,
          isHandoffInFlight: viewModel.handoffInFlight,
          handoffError: viewModel.handoffError,
          onStartProcedure: { procedureId in
            Task { await startHandoff(procedureId: procedureId) }
          },
          onRetry: { retryDiagnostic() }
        )
      }

      phaseSection
      controlsBar
    }
  }

  // MARK: - Sections

  private var topBar: some View {
    HStack {
      Button { showDismissConfirmation = true } label: {
        Image(systemName: "xmark")
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(.textPrimary)
          .frame(width: 36, height: 36)
          .glassPanel(cornerRadius: 18)
      }

      Spacer()

      HStack(spacing: Spacing.sm) {
        Circle()
          .fill(phaseDotColor)
          .frame(width: 8, height: 8)
        Text(topBarLabel)
          .font(.retraceFace(.semibold, size: 12))
          .foregroundColor(.textPrimary)
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.sm)
      .glassPanel(cornerRadius: Radius.lg)
    }
    .padding(.horizontal, Spacing.xxl)
    .padding(.top, Spacing.md)
  }

  private var activityFeed: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
          if let product = viewModel.identifiedProduct {
            productChip(product)
          }

          if viewModel.activity.isEmpty {
            activityEmptyState
              .frame(maxWidth: .infinity)
              .padding(.vertical, Spacing.xl)
          } else {
            ForEach(viewModel.activity) { entry in
              DiagnosticActivityRow(entry: entry).id(entry.id)
            }
          }

          Color.clear.frame(height: 1).id("activity-bottom")
        }
        .padding(.vertical, Spacing.md)
      }
      .onChange(of: viewModel.activity.count) { _ in
        withAnimation(.easeOut(duration: 0.15)) {
          proxy.scrollTo("activity-bottom", anchor: .bottom)
        }
      }
    }
    .glassPanel(cornerRadius: Radius.xl)
  }

  private var activityEmptyState: some View {
    VStack(spacing: Spacing.sm) {
      Image(systemName: "stethoscope")
        .font(.system(size: 28))
        .foregroundColor(.textTertiary)
      Text("Tell me what's wrong.")
        .font(.retraceCallout)
        .foregroundColor(.textTertiary)
      Text("Describe the product and the problem. I'll walk you through it from there.")
        .font(.retraceCaption1)
        .foregroundColor(.textTertiary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, Spacing.md)
    }
  }

  private func productChip(_ product: IdentifiedProduct) -> some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundColor(.semanticInfo)
      VStack(alignment: .leading, spacing: 2) {
        Text(product.productName)
          .font(.retraceCallout)
          .foregroundColor(.textPrimary)
        if !product.confidence.isEmpty {
          Text("\(product.confidence) confidence")
            .font(.retraceCaption2)
            .foregroundColor(.textTertiary)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(Spacing.md)
    .glassPanel(cornerRadius: Radius.md)
  }

  /// Non-blocking notice that the mic pipeline isn't delivering audio (BT-HFP
  /// stall / mic route broken). Auto-clears when buffers resume (`micStalled`).
  private var micStalledBanner: some View {
    HStack(spacing: Spacing.md) {
      Image(systemName: "waveform.slash")
        .foregroundColor(.textPrimary)
      Text("Mic not streaming — I can't hear you")
        .font(.retraceCallout)
        .foregroundColor(.textPrimary)
      Spacer(minLength: 0)
    }
    .padding(Spacing.md)
    .glassPanel(cornerRadius: Radius.md)
    .padding(.horizontal, Spacing.xl)
  }

  private var isGeminiError: Bool {
    if case .error = viewModel.geminiConnectionState { return true }
    return false
  }

  /// Voice-socket error banner — mirrors CoachingSessionView's. Reconnect
  /// resumes the Gemini WebSocket (session-resumption handle when available).
  private var reconnectBanner: some View {
    HStack(spacing: Spacing.md) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.textPrimary)
      Text("Voice session disconnected")
        .font(.retraceCallout)
        .foregroundColor(.textPrimary)
      Spacer(minLength: 0)
      Button {
        viewModel.retryGemini()
      } label: {
        Text("Reconnect")
          .font(.retraceFace(.semibold, size: 16))
          .foregroundColor(.textPrimary)
      }
    }
    .padding(Spacing.md)
    .glassPanel(cornerRadius: Radius.md)
    .padding(.horizontal, Spacing.xl)
  }

  /// Persistent camera-health banner — mirrors CoachingSessionView's.
  /// `.reconnecting` while a user-initiated camera rebuild runs; `.failed`
  /// when the camera branch is dead and the session is voice-only. Retry
  /// rebuilds ONLY the camera branch, not the voice socket.
  private var cameraHealthBanner: some View {
    HStack(spacing: Spacing.md) {
      if viewModel.cameraHealth == .reconnecting {
        ProgressView()
          .tint(.textPrimary)
        Text("Reconnecting camera…")
          .font(.retraceCallout)
          .foregroundColor(.textPrimary)
        Spacer(minLength: 0)
      } else {
        Image(systemName: "video.slash.fill")
          .foregroundColor(.textPrimary)
        Text("Camera lost — I can't see the product")
          .font(.retraceCallout)
          .foregroundColor(.textPrimary)
        Spacer(minLength: 0)
        Button {
          viewModel.retryCameraBranch()
        } label: {
          Text("Retry")
            .font(.retraceFace(.semibold, size: 16))
            .foregroundColor(.textPrimary)
        }
      }
    }
    .padding(Spacing.md)
    .glassPanel(cornerRadius: Radius.md)
    .padding(.horizontal, Spacing.xl)
  }

  private var phaseSection: some View {
    DiagnosticPhaseBar(phase: viewModel.phase)
      .padding(.horizontal, Spacing.xl)
      .padding(.vertical, Spacing.md)
  }

  private var controlsBar: some View {
    HStack(spacing: 0) {
      VStack(spacing: Spacing.xs) {
        Image(systemName: viewModel.isMuted ? "mic.slash.fill" : "mic.fill")
          .font(.system(size: 20))
          .foregroundColor(viewModel.isMuted ? .textTertiary : .textPrimary)

        if !viewModel.isMuted {
          RetraceAudioMeter(
            aiPeak: viewModel.aiOutputPeak,
            userPeak: viewModel.userInputPeak,
            tint: .textPrimary,
            intensity: .standard
          )
        } else {
          Text("Muted")
            .font(.system(size: 10))
            .foregroundColor(.textTertiary)
        }
      }
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
      .onTapGesture { viewModel.toggleMute() }
    }
    .padding(.vertical, Spacing.lg)
    .padding(.horizontal, Spacing.xl)
    .glassPanel(cornerRadius: Radius.xl)
    .padding(.horizontal, Spacing.xl)
    .padding(.bottom, Spacing.md)
  }

  // MARK: - Lens page selector

  /// Picks which Troubleshoot lens page to render based on phase + resolution.
  /// Page transitions use the asymmetric inline transition from the design
  /// system, applied at the parent ZStack via `.animation(...)` on the
  /// transition trigger key.
  @ViewBuilder
  private var troubleshootCurrentPage: some View {
    let dismissCallback: () -> Void = { showDismissConfirmation = true }
    Group {
      switch troubleshootPageKind {
      case .identify:
        TroubleshootIdentifyPage(viewModel: viewModel, onDismiss: dismissCallback)
      case .diagnose:
        TroubleshootDiagnosePage(viewModel: viewModel, onDismiss: dismissCallback)
      case .searching:
        TroubleshootSearchingPage(viewModel: viewModel, onDismiss: dismissCallback)
      case .resolved:
        TroubleshootResolvedPage(
          viewModel: viewModel,
          onStart: { procedureId in
            Task { await startHandoff(procedureId: procedureId) }
          },
          onDismiss: dismissCallback
        )
      case .noSolution:
        TroubleshootNoSolutionPage(viewModel: viewModel, onDismiss: dismissCallback)
      }
    }
    .transition(.asymmetric(
      insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top)),
      removal: .opacity
    ))
  }

  private var troubleshootPageKind: TroubleshootPageKind {
    if viewModel.resolution == .noMatch { return .noSolution }
    switch viewModel.resolution {
    case .matchedProcedure, .generatedSOP:
      return .resolved
    case .none, .noMatch:
      break
    }
    // searchNarration is non-nil from the moment search_procedures (or
    // web_search_for_fix) enters pendingToolCallNames — before phase
    // flips to .resolving on result. Route to .searching immediately so
    // the user sees "Searching your library" + ellipsis while the call
    // is in flight, rather than staring at the diagnose page for 5-10s
    // with no signal that a search is happening.
    if viewModel.searchNarration != nil {
      return .searching
    }
    switch viewModel.phase {
    case .discovering: return .identify
    case .diagnosing:  return .diagnose
    case .resolving:   return .searching
    case .resolved:    return .identify // resolution already handled above
    }
  }

  // MARK: - Helpers

  private var topBarLabel: String {
    switch viewModel.phase {
    case .discovering, .diagnosing: return "DIAGNOSING"
    case .resolving:                return "RESOLUTION"
    case .resolved:                 return "LIVE"
    }
  }

  private var phaseDotColor: Color {
    switch viewModel.geminiConnectionState {
    case .connected: return .appPrimary
    case .connecting: return .semanticInfo
    case .error: return .appPrimary
    case .disconnected: return .textTertiary
    }
  }

  // MARK: - Glasses session chrome

  private var glassesDeviceName: String {
    wearablesVM.devices.first.map { wearablesVM.displayName(for: $0) } ?? "Glasses"
  }

  private var glassesSessionStatus: GlassesSessionStatus {
    // When connected, surface the diagnostic phase (DIAGNOSING / RESOLUTION /
    // LIVE); otherwise reflect the connection state like coaching does.
    switch viewModel.geminiConnectionState {
    case .connected:
      return GlassesSessionStatus(label: topBarLabel, dotColor: .green, pulsing: false)
    case .connecting:
      return GlassesSessionStatus(label: "CONNECTING", dotColor: .yellow, pulsing: true)
    case .error:
      return GlassesSessionStatus(label: "RECONNECTING", dotColor: .yellow, pulsing: true)
    case .disconnected:
      return GlassesSessionStatus(label: "STANDBY", dotColor: .gray, pulsing: false)
    }
  }

  private func resolveInterfaceOrientation() -> UIInterfaceOrientation {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first(where: { $0.activationState == .foregroundActive })
      ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    return scene?.interfaceOrientation ?? .portrait
  }

  private func startHandoff(procedureId: String) async {
    // Single Active/Passive setting drives both wire flags (see Profile).
    let activeMonitoring = UserDefaults.standard.object(forKey: "activeMonitoringEnabled") as? Bool ?? true
    if let payload = await viewModel.executeHandoff(
      procedureId: procedureId,
      autoAdvance: activeMonitoring,
      activeMonitoring: activeMonitoring
    ) {
      // Tag this exit as a handoff BEFORE bubbling up — when the parent
      // flips its phase, our `onDisappear` will run, and the gate there
      // depends on this flag to skip `unlock()` so the learner view
      // inherits the broadened orientation mask.
      isHandingOff = true
      // Hand the payload up to the parent (`TroubleshootIntroView`).
      // It dismisses this cover and presents `CoachingSessionView`
      // independently — no stacking, no double-exit when the user
      // finishes coaching. The diagnostic Gemini session was already
      // torn down inside `executeHandoff` (`stopCameraStream` +
      // `stopGeminiLiveSession`).
      onExit(payload)
    }
  }

  private func retryDiagnostic() {
    viewModel.endSession()
    Task { await viewModel.startSession() }
  }

  private func confirmDiagnosticExit() {
    showDismissConfirmation = false
    viewModel.endSession()
    // Manual exit — no handoff payload. Parent clears its
    // `presentedTransport` binding which dismisses this cover.
    onExit(nil)
  }
}

// MARK: - Activity row (diagnostic variant — labels differ from learner)

private struct DiagnosticActivityRow: View {
  let entry: ActivityEntry

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      icon.frame(width: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text(label)
          .font(.retraceOverline)
          .tracking(1)
          .foregroundColor(labelColor)
        Text(entry.text)
          .font(.retraceCallout)
          .foregroundColor(.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
  }

  @ViewBuilder
  private var icon: some View {
    switch entry.kind {
    case .toolCall: Image(systemName: "wand.and.stars").foregroundColor(.textPrimary)
    case .assistant: Image(systemName: "sparkles").foregroundColor(.semanticInfo)
    case .learner: Image(systemName: "person.fill").foregroundColor(.textSecondary)
    }
  }

  private var label: String {
    switch entry.kind {
    case .toolCall(let name): return "TOOL · \(name)".uppercased()
    case .assistant: return "AI"
    case .learner: return "YOU"
    }
  }

  private var labelColor: Color {
    switch entry.kind {
    case .toolCall: return .textPrimary
    case .assistant: return .semanticInfo
    case .learner: return .textSecondary
    }
  }
}

// Make LearnerSessionStartResponse Identifiable so it can drive
// fullScreenCover(item:).
extension LearnerSessionStartResponse: Identifiable {
  public var id: String { sessionId }
}

/// Identifies which Troubleshoot lens page is alive. Owned by
/// `TroubleshootSessionView`; computed from VM state via
/// `troubleshootPageKind`.
enum TroubleshootPageKind: Hashable {
  case identify
  case diagnose
  case searching
  case resolved
  case noSolution
}
