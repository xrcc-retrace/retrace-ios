import MWDATCamera
import MWDATCore
import SwiftUI

struct CoachingSessionView: View {
  let procedure: ProcedureResponse
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  @ObservedObject var progressStore: LocalProgressStore
  let serverBaseURL: String
  let transport: CaptureTransport
  let startingStep: Int?

  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var appOrientationController: AppOrientationController
  @EnvironmentObject private var lensSession: LensSession
  @StateObject private var viewModel: CoachingSessionViewModel

  @State private var showDismissConfirmation = false
  // Drawer state for the camera-first layout. Both transports use the
  // same drawer — the camera feed (iPhone preview layer or glasses video
  // stream) sits behind the HUD; pull up the drawer for the activity
  // feed and controls.
  @State private var drawerExpanded = false
  // Portrait is the app's default; the real value is overwritten in
  // `.onAppear` from `resolveInterfaceOrientation()` so the session
  // preserves whatever orientation the phone is already in.
  @State private var currentInterfaceOrientation: UIInterfaceOrientation = .portrait
  // Global debug surface — drives the lens boundary outline, hand-tracking
  // overlay, etc. Set in Server Settings → Debug. No per-session toggle.
  @AppStorage("debugMode") private var debugMode: Bool = false
  // Additive (plus-lighter) blending for the lens — emulates the real
  // Ray-Ban Display's optical surface. Set in Server Settings → Debug.
  @AppStorage("hudAdditiveBlend") private var hudAdditiveBlend: Bool = false
  // Active lens page inside the Ray-Ban emulator. Mutated by the emulator's
  // gesture pipeline (finger swipe today, MediaPipe pinch-drag tomorrow).
  @State private var coachingPageIndex: Int = 0
  // Glasses transport only: the phone shows the lens over an app-themed
  // background by default; the raw glasses camera feed is hidden until the
  // user taps the "Show camera" pill. Plain @State so it resets to hidden
  // every session (no persistence).
  @State private var showCameraFeed = false

  init(
    procedure: ProcedureResponse,
    wearables: WearablesInterface,
    wearablesVM: WearablesViewModel,
    progressStore: LocalProgressStore,
    serverBaseURL: String,
    transport: CaptureTransport = .glasses,
    startingStep: Int? = nil,
    sessionManager: DeviceSessionManager
  ) {
    self.procedure = procedure
    self.wearables = wearables
    self.wearablesVM = wearablesVM
    self.progressStore = progressStore
    self.serverBaseURL = serverBaseURL
    self.transport = transport
    self.startingStep = startingStep
    self._viewModel = StateObject(wrappedValue: CoachingSessionViewModel(
      procedure: procedure,
      wearables: wearables,
      serverBaseURL: serverBaseURL,
      transport: transport,
      sessionManager: sessionManager
    ))
  }

  var body: some View {
    ZStack {
      // One layout for both transports — only the camera content layer
      // differs. The HUD, drawer, gesture surface, and overlays are
      // identical. The reference clip lives inside `CoachingStepPage`
      // for both transports, so no separate floating PiP is needed.
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
          let pages = coachingPages
          // Overlay sits *inside* the emulator's page closure (mirrors
          // ExpertNarrationTipPage's ZStack pattern) so both the page
          // and the overlay are children of the emulator and inherit
          // its `HUDHoverCoordinator` environmentObject. Rendering the
          // overlay as a sibling of the emulator left it without the
          // env and crashed on first hover read.
          RayBanHUDEmulator(
            pageCount: pages.count,
            pageIndex: $coachingPageIndex,
            showBoundary: debugMode,
            additiveBlend: hudAdditiveBlend,
            enableDismissGesture: true
          ) { idx in
            ZStack {
              coachingPageContent(for: pages[min(idx, pages.count - 1)])
                // Canonical recede so the overlay reads as foreground.
                // Numbers live in `RayBanHUDLayoutTokens.recede*`.
                .rayBanHUDRecede(active: showDismissConfirmation)

              if showDismissConfirmation {
                CoachingExitConfirmationOverlay(
                  onCancel: {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                      showDismissConfirmation = false
                    }
                  },
                  onConfirm: {
                    viewModel.endSession(progressStore: progressStore)
                    dismiss()
                  }
                )
                .transition(.scale(scale: 0.88).combined(with: .opacity))
                .padding(.horizontal, 32)
              }
            }
            .animation(
              .spring(response: 0.32, dampingFraction: 0.85),
              value: showDismissConfirmation
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
    }
    .preferredColorScheme(.dark)
    // Exit is now driven by `RayBanHUDEmulator.onLensBackGesture` →
    // `CoachingExitConfirmationOverlay` rendered inside the lens.
    // The previous `.alert("End Session?", …)` system dialog has been
    // retired so the exit flow stays inside the Ray-Ban aesthetic.
    .onAppear {
      // Double index-finger pinch ("back" gesture). Precedence: while a
      // reference clip is playing full-screen on the lens, "back" interrupts
      // the clip and returns to the step (→ dismissReferenceClip, which
      // resumes Gemini and repaints). Otherwise it opens the exit
      // confirmation — same destination as the dev finger-double-tap on the
      // lens background.
      // Weak-capture viewModel so the closure stored on it can't retain it
      // (mirrors onExitConfirmed below).
      viewModel.onBackGesture = { [weak viewModel] in
        guard let viewModel else { return }
        if viewModel.isClipPlaying {
          viewModel.onClipDismissRequested?()
          return
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
          showDismissConfirmation = true
        }
      }
      // Native lens exit overlay confirms ON the glasses (not the phone), so
      // its "Confirm exit" needs the same terminal action the phone overlay
      // runs — endSession + dismiss — both of which live here in the view.
      // Weak-capture viewModel so the closure stored on it can't retain it.
      viewModel.onExitConfirmed = { [weak viewModel] in
        guard let viewModel else { return }
        viewModel.endSession(progressStore: progressStore)
        dismiss()
      }
      // Native lens path (Step 6) — mirrors this session's state onto the
      // glasses display. Silent no-op when the "Send to glasses lens"
      // toggle is off or no Display capability is available.
      //
      // DEFERRED until `isReadyForNativeLens`: the Display capability shares
      // the glasses' BT radio with the HFP mic. Starting it during the HFP
      // warmup makes iOS drop the glasses mic route (falls back to AirPods),
      // so we wait until audio + camera are confirmed up. See the matching
      // `.onChange` below and `GeminiLiveSessionBase.isReadyForNativeLens`.
      if viewModel.isReadyForNativeLens {
        lensSession.activate(.coaching, vm: viewModel)
      }
      viewModel.startSession(progressStore: progressStore, startingStep: startingStep)
      if transport == .iPhone {
        // Broaden the allowed orientation mask so the user can naturally
        // rotate between portrait and landscape, but don't force rotate.
        // Whatever orientation the phone is already in is what the session
        // opens in.
        appOrientationController.setAllowed([.portrait, .landscapeLeft, .landscapeRight])
        // `orientationDidChangeNotification` only fires while device
        // orientation notifications are actively being generated.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        // Seed from the scene's actual interface orientation so the layout
        // and preview match the current phone orientation. If the camera
        // hasn't finished starting, `GeminiLiveSessionBase` caches this
        // and replays it onto the preview layer the moment it comes up.
        let resolved = resolveInterfaceOrientation()
        currentInterfaceOrientation = resolved
        viewModel.setPreviewInterfaceOrientation(resolved)
      }
    }
    // Bring the native lens up the moment audio + camera are confirmed
    // ready (see the deferred activate in `.onAppear`). This is the normal
    // path — at appear time the session is still starting, so the flag is
    // false; it flips true mid-startup and we activate here.
    .onChange(of: viewModel.isReadyForNativeLens) { _, ready in
      if ready {
        lensSession.activate(.coaching, vm: viewModel)
      }
    }
    .onDisappear {
      // Tear down the native lens renderer first so it stops projecting
      // VM state to the glasses. Display capability stays attached
      // (it's app-scoped); the next `.activate(.coaching|.troubleshoot|...)`
      // will mount a fresh renderer without re-handshaking the SDK.
      lensSession.deactivate()
      viewModel.endSession(progressStore: progressStore)
      if transport == .iPhone {
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        appOrientationController.unlock()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
      guard transport == .iPhone else { return }
      let resolved = resolveInterfaceOrientation()
      currentInterfaceOrientation = resolved
      viewModel.setPreviewInterfaceOrientation(resolved)
    }
    // Reset to the step page on every step transition so the user doesn't
    // get stranded on a stale insights/clip page from the previous step.
    .onChange(of: viewModel.currentStepIndex) { _, _ in
      coachingPageIndex = 0
    }
    // Completion collapses the page list to a single page; clamp to 0.
    .onChange(of: viewModel.isCompleted) { _, _ in
      coachingPageIndex = 0
    }
    // Recovery layer of the DAT camera permission gate. The pre-flight
    // on LearnerProcedureDetailView catches the 99% case; this sheet
    // catches the residual race where permission was revoked between
    // tapping "Coach with Glasses" and the session VM running its gate
    // (e.g. user backgrounded into Meta AI between the two). On grant,
    // the embedded CTA calls `retryAfterPermissionGrant()` which re-runs
    // `startGeminiLiveSession()` cleanly (no state was initialized
    // before the gate fired).
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
    // Audio readiness recovery — fires when BT HFP SCO didn't deliver
    // its first PCM buffer within the timeout. Permission has already
    // been verified by the time we get here; the recovery action is a
    // straight retry of session start (no Meta AI bounce needed).
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
    // DAT helper update recovery — fires when the SDK throws
    // `datAppOnTheGlassesUpdateRequired` from `manager.acquire` (or the
    // inline `createSession` fallback). The user must update the DAT
    // helper app via Meta AI before any DeviceSession can start.
    // Mirrors `LensDisplayCoordinator.requiresDATAppUpdate` — same SDK
    // signal, parallel UI surface for the camera-streaming consumer.
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
  }

  private func resolveInterfaceOrientation() -> UIInterfaceOrientation {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first(where: { $0.activationState == .foregroundActive })
      ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    return scene?.interfaceOrientation ?? .portrait
  }

  // MARK: - Stacked Body (shared by glasses transport directly and by the
  // iPhone drawer)

  @ViewBuilder
  private var stackedBody: some View {
    VStack(spacing: 0) {
      topBar

      if viewModel.isCompleted {
        Spacer()
        completionPanel
        Spacer()
      } else {
        activityFeed
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(.horizontal, Spacing.xl)
          .padding(.top, Spacing.md)

        if isGeminiError {
          reconnectBanner
        }

        if viewModel.micStalled {
          micStalledBanner
        }

        stepInstructionPanel
        stepProgressSection
        controlsBar
      }
    }
  }

  private var isGeminiError: Bool {
    if case .error = viewModel.geminiConnectionState { return true }
    return false
  }

  private var reconnectBanner: some View {
    HStack(spacing: Spacing.md) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.textPrimary)
      Text("Voice coaching disconnected")
        .font(.retraceCallout)
        .foregroundColor(.textPrimary)
      Spacer()
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
    .padding(.bottom, Spacing.sm)
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
      Spacer()
    }
    .padding(Spacing.md)
    .glassPanel(cornerRadius: Radius.md)
    .padding(.horizontal, Spacing.xl)
    .padding(.bottom, Spacing.sm)
  }

  // MARK: - Activity Feed (tool calls + live transcript)

  private var activityFeed: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
          if viewModel.activity.isEmpty {
            activityEmptyState
              .frame(maxWidth: .infinity)
              .padding(.vertical, Spacing.xl)
          } else {
            ForEach(viewModel.activity) { entry in
              ActivityRow(entry: entry)
                .id(entry.id)
            }
          }
          // Anchor so we can autoscroll to the bottom.
          Color.clear
            .frame(height: 1)
            .id("activity-bottom")
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
      Image(systemName: "waveform")
        .font(.system(size: 28))
        .foregroundColor(.textTertiary)
      Text("Waiting for the coach…")
        .font(.retraceCallout)
        .foregroundColor(.textTertiary)
      Text("Talk to the AI — what it hears and does will show up here.")
        .font(.retraceCaption1)
        .foregroundColor(.textTertiary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, Spacing.md)
    }
  }

  // MARK: - Top Bar

  private var topBar: some View {
    HStack {
      // Drawer-side exit affordance — mirrors the Troubleshoot pattern.
      // Routes to the same in-lens exit-confirmation overlay as the
      // double-pinch / lens double-tap, so all three exit triggers
      // converge on the same UX.
      Button {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
          showDismissConfirmation = true
        }
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(.textPrimary)
          .frame(width: 36, height: 36)
          .glassPanel(cornerRadius: 18)
      }

      Spacer()

      HStack(spacing: Spacing.sm) {
        Circle()
          .fill(geminiStatusColor)
          .frame(width: 8, height: 8)

        Text("Step \(viewModel.currentStepIndex + 1) of \(procedure.steps.count)")
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

  // MARK: - Step Instruction Panel

  private var stepInstructionPanel: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if let step = viewModel.currentStep {
        Text("STEP \(viewModel.currentStepIndex + 1) OF \(procedure.steps.count)")
          .font(.retraceOverline)
          .tracking(1)
          .foregroundColor(.textSecondary)

        Text(step.title)
          .font(.retraceTitle3)
          .foregroundColor(.textPrimary)

        Text(step.description)
          .font(.retraceCallout)
          .foregroundColor(.textSecondary)

        if !step.tips.isEmpty {
          HStack(spacing: Spacing.sm) {
            ForEach(step.tips.prefix(2), id: \.self) { tip in
              Text(tip)
                .font(.retraceCaption2)
                .foregroundColor(.semanticInfo)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xxs)
                .background(Color.semanticInfo.opacity(0.15))
                .cornerRadius(Radius.xs)
            }
          }
        }

        if !step.warnings.isEmpty {
          HStack(spacing: Spacing.sm) {
            ForEach(step.warnings.prefix(2), id: \.self) { warning in
              Text(warning)
                .font(.retraceCaption2)
                .foregroundColor(.appPrimary)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xxs)
                .background(Color.appPrimary.opacity(0.15))
                .cornerRadius(Radius.xs)
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.xl)
    .glassPanel(cornerRadius: Radius.xl)
    .padding(.horizontal, Spacing.xl)
  }

  // MARK: - Step Progress

  private var stepProgressSection: some View {
    StepProgressBar(
      currentStep: viewModel.currentStepIndex + 1,
      totalSteps: procedure.steps.count
    )
    .padding(.horizontal, Spacing.xl)
    .padding(.vertical, Spacing.md)
  }

  // MARK: - Controls Bar (mic + PiP only — step progression is AI-driven)

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
      .onTapGesture {
        viewModel.toggleMute()
      }

      VStack(spacing: Spacing.xs) {
        Image(systemName: viewModel.showPiP ? "pip.fill" : "pip")
          .font(.system(size: 20))
          .foregroundColor(viewModel.showPiP ? .semanticInfo : .textPrimary)
        Text("Reference")
          .font(.system(size: 10))
          .foregroundColor(.textSecondary)
      }
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
      .onTapGesture {
        viewModel.showPiP.toggle()
      }

    }
    .padding(.vertical, Spacing.lg)
    .padding(.horizontal, Spacing.xl)
    .glassPanel(cornerRadius: Radius.xl)
    .padding(.horizontal, Spacing.xl)
    .padding(.bottom, Spacing.md)
  }

  // MARK: - Completion Panel

  private var completionPanel: some View {
    VStack(spacing: Spacing.xl) {
      Image(systemName: "checkmark.seal.fill")
        .font(.system(size: 48))
        .foregroundColor(.semanticSuccess)

      Text("Procedure Complete")
        .font(.retraceTitle2)
        .foregroundColor(.textPrimary)

      HStack(spacing: Spacing.xl) {
        InfoItem(label: "Steps", value: "\(procedure.steps.count)")
        InfoItem(label: "Time", value: viewModel.formattedSessionDuration)
      }

      CustomButton(
        title: "Done",
        style: .primary,
        isDisabled: false
      ) {
        dismiss()
      }
    }
    .padding(Spacing.screenPadding)
    .frame(maxWidth: .infinity)
    .glassPanel(cornerRadius: Radius.xl)
    .padding(.horizontal, Spacing.xl)
    .padding(.bottom, Spacing.xl)
  }

  // MARK: - Helpers

  private var geminiStatusColor: Color {
    switch viewModel.geminiConnectionState {
    case .connected:
      return .green
    case .connecting:
      return .yellow
    case .error:
      return .red
    case .disconnected:
      return .gray
    }
  }

  // MARK: - Glasses session chrome

  private var glassesDeviceName: String {
    wearablesVM.devices.first.map { wearablesVM.displayName(for: $0) } ?? "Glasses"
  }

  private var glassesSessionStatus: GlassesSessionStatus {
    switch viewModel.geminiConnectionState {
    case .connected:
      return GlassesSessionStatus(label: "LIVE", dotColor: .green, pulsing: false)
    case .connecting:
      return GlassesSessionStatus(label: "CONNECTING", dotColor: .yellow, pulsing: true)
    case .error:
      return GlassesSessionStatus(label: "RECONNECTING", dotColor: .yellow, pulsing: true)
    case .disconnected:
      return GlassesSessionStatus(label: "STANDBY", dotColor: .gray, pulsing: false)
    }
  }

  /// Resolve the current step's reference media (video clip vs. manual page
  /// image vs. none) from its REAL clip_url + the procedure's source_type.
  /// Without this, a manual procedure's page PNG would be handed to AVPlayer
  /// as a "clip" and silently fail to play.
  private var currentStepMedia: StepReferenceMedia {
    guard let step = viewModel.currentStep else { return .none }
    return step.referenceMedia(sourceType: procedure.sourceType, baseURL: serverBaseURL)
  }

  private var currentStepClipURL: URL? {
    if case .video(let url) = currentStepMedia { return url }
    return nil
  }

  /// Image shown in the reference panel. A per-step manual page image takes
  /// precedence; otherwise fall back to the procedure-level expert reference
  /// image (`reference_image_url`). nil when neither exists.
  private var currentStepReferenceImageURL: URL? {
    if case .image(let url) = currentStepMedia { return url }
    guard let path = procedure.referenceImageUrl else { return nil }
    return URL(string: "\(serverBaseURL)\(path)")
  }

  // MARK: - Ray-Ban emulator pages

  /// Ordered list of pages the lens emulator paginates through. Today
  /// always one page: the step page during an active procedure, the
  /// completion page when the procedure ends. Reference clip + insights
  /// are no longer separate pages — they live inside `CoachingStepPage`
  /// as in-page expandable panels driven by the top-row toggle buttons.
  private var coachingPages: [CoachingPageKind] {
    viewModel.isCompleted ? [.completion] : [.step]
  }

  @ViewBuilder
  private func coachingPageContent(for kind: CoachingPageKind) -> some View {
    switch kind {
    case .step:
      CoachingStepPage(
        viewModel: viewModel,
        stepCount: procedure.steps.count,
        clipURL: currentStepClipURL,
        referenceImageURL: currentStepReferenceImageURL,
        // Pass through the exit-overlay flag so the step card's
        // auto-scrolling description suspends while the recede recipe
        // is up — the user's scroll position is preserved across the
        // confirm/cancel cycle. See DESIGN.md → Animation System.
        isOverlayActive: showDismissConfirmation,
        onShowExitConfirmation: {
          withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            showDismissConfirmation = true
          }
        }
      )
    case .completion:
      CoachingCompletionPage(onExit: handleExit)
    }
  }

  private func handleExit() {
    viewModel.endSession(progressStore: progressStore)
    dismiss()
  }
}

/// Page identity for the Coaching lens. Kept here (not in the page files
/// themselves) so the parent view fully owns the page list and the
/// per-mode inclusion logic.
enum CoachingPageKind: Hashable {
  case step
  case completion
}

// MARK: - Activity Row

private struct ActivityRow: View {
  let entry: ActivityEntry

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      icon
        .frame(width: 22)
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
    case .toolCall:
      Image(systemName: "wand.and.stars")
        .foregroundColor(.textPrimary)
    case .assistant:
      Image(systemName: "sparkles")
        .foregroundColor(.semanticInfo)
    case .learner:
      Image(systemName: "person.fill")
        .foregroundColor(.textSecondary)
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
