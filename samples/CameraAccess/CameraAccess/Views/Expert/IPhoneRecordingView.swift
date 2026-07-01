import AVFoundation
import MWDATCore
import SwiftUI

/// Expert recording screen — transport-agnostic.
///
/// Both transports render the same `ExpertRecordingLayout` with the same
/// HUD (`ExpertNarrationTipPage`) and the same chrome (close button, mic
/// badge, Start CTA, recording review sheet). Only the camera content
/// layer differs:
///   • `.iPhone` → `IPhoneCameraPreview(previewLayer:)` over an
///     `AVCaptureVideoPreviewLayer`
///   • `.glasses` → `GlassesCameraPreview(image:)` over the DAT SDK's
///     glasses video stream
///
/// The two paths can't share a single `@StateObject` since the underlying
/// VMs differ, so the body delegates to one of two private engine
/// sub-views below. Both engines pull the HUD + chrome bodies from the
/// shared `expertRecordingHUD` / `expertRecordingChrome` helpers, so the
/// visual structure is guaranteed identical and any change to either
/// shows up on both transports.
struct IPhoneRecordingView: View {
  let transport: CaptureTransport
  let wearables: WearablesInterface
  /// Resolved name of the connected glasses, shown in the glasses-session
  /// banner. Ignored on the iPhone transport.
  let glassesDeviceName: String
  let uploadService: UploadService
  let onAcknowledgeProcedure: () -> Void
  let onRecordingComplete: (URL, TimeInterval) -> Void

  /// Shared `DeviceSessionManager`. Glasses transport forwards it to
  /// `StreamSessionViewModel`; iPhone transport ignores it (no DAT SDK
  /// session involved).
  let sessionManager: DeviceSessionManager

  init(
    transport: CaptureTransport,
    wearables: WearablesInterface,
    glassesDeviceName: String = "Glasses",
    uploadService: UploadService,
    onAcknowledgeProcedure: @escaping () -> Void,
    onRecordingComplete: @escaping (URL, TimeInterval) -> Void,
    sessionManager: DeviceSessionManager
  ) {
    self.transport = transport
    self.wearables = wearables
    self.glassesDeviceName = glassesDeviceName
    self.uploadService = uploadService
    self.onAcknowledgeProcedure = onAcknowledgeProcedure
    self.onRecordingComplete = onRecordingComplete
    self.sessionManager = sessionManager
  }

  var body: some View {
    switch transport {
    case .iPhone:
      IPhoneRecordingEngine(
        uploadService: uploadService,
        onAcknowledgeProcedure: onAcknowledgeProcedure,
        onRecordingComplete: onRecordingComplete
      )
    case .glasses:
      GlassesRecordingEngine(
        wearables: wearables,
        glassesDeviceName: glassesDeviceName,
        uploadService: uploadService,
        onAcknowledgeProcedure: onAcknowledgeProcedure,
        onRecordingComplete: onRecordingComplete,
        sessionManager: sessionManager
      )
    }
  }
}

// MARK: - iPhone engine

/// Drives the iPhone-camera recording flow. The `@StateObject` VM is
/// instantiated lazily by SwiftUI, so creating two engine views (only one
/// of which is ever rendered at a time, per the parent's transport
/// switch) costs nothing for the inactive transport.
private struct IPhoneRecordingEngine: View {
  let onAcknowledgeProcedure: () -> Void
  let onRecordingComplete: (URL, TimeInterval) -> Void

  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var appOrientationController: AppOrientationController
  @EnvironmentObject private var lensSession: LensSession
  @StateObject private var viewModel: IPhoneExpertRecordingViewModel

  @AppStorage("debugMode") private var debugMode: Bool = false
  @AppStorage("hudAdditiveBlend") private var hudAdditiveBlend: Bool = false
  @State private var currentInterfaceOrientation: UIInterfaceOrientation = .portrait
  @State private var expertPageIndex: Int = 0

  init(
    uploadService: UploadService,
    onAcknowledgeProcedure: @escaping () -> Void,
    onRecordingComplete: @escaping (URL, TimeInterval) -> Void
  ) {
    self._viewModel = StateObject(
      wrappedValue: IPhoneExpertRecordingViewModel(uploadService: uploadService)
    )
    self.onAcknowledgeProcedure = onAcknowledgeProcedure
    self.onRecordingComplete = onRecordingComplete
  }

  var body: some View {
    ExpertRecordingLayout {
      IPhoneCameraPreview(previewLayer: viewModel.previewLayer)
    } hud: {
      expertRecordingHUD(
        recordingManager: viewModel.recordingManager,
        hudViewModel: viewModel.hudViewModel,
        debugMode: debugMode,
        hudAdditiveBlend: hudAdditiveBlend,
        pageIndex: $expertPageIndex,
        onStop: {
          // Stop = capture mode is over. Finalize the mp4, then hand the
          // URL up so the parent can dismiss this view (camera + audio
          // teardown fires on `onDisappear`) and present the review as
          // a sibling full-screen cover. No camera running underneath
          // the review — that was the old sheet-on-top-of-recording-view
          // pattern, which kept the AVCaptureSession alive for the full
          // upload + procedure-review flow.
          Task {
            if let result = await viewModel.stopRecording() {
              onRecordingComplete(result.0, result.1)
            }
          }
        }
      )
    } chrome: {
      expertRecordingChrome(
        recordingManager: viewModel.recordingManager,
        hudViewModel: viewModel.hudViewModel,
        isPreviewLive: viewModel.isPreviewLive,
        debugMode: debugMode,
        onClose: { dismiss() },
        onStart: {
          // Always portrait/natural orientation. The pinned-landscape mode
          // was deprecated — rotating the phone gives the same result via
          // the orientation observer below.
          viewModel.startRecording(landscape: false)
        }
      )
    }
    .animation(.easeInOut(duration: 0.18), value: viewModel.recordingManager.isHUDActive)
    .task {
      await viewModel.prepare()
    }
    .onAppear {
      // Broaden the allowed orientation mask so SwiftUI chrome can follow
      // the phone into landscape, same as the learner coaching flow.
      appOrientationController.setAllowed([.portrait, .landscapeLeft, .landscapeRight])
      UIDevice.current.beginGeneratingDeviceOrientationNotifications()
      let resolved = resolveInterfaceOrientation()
      currentInterfaceOrientation = resolved
      // Seed the preview from the scene's actual interface orientation so
      // the layout matches the current phone orientation.
      viewModel.camera.setPreviewInterfaceOrientation(resolved)
      // Step 9: wire the expert lens renderer. Stop confirms here fire
      // the same flow the phone Stop button uses — finalize the .mp4,
      // bubble up via `onRecordingComplete`. Lens output is forwarded through
      // `LensSession.send`, which no-ops safely without a Display device.
      let context = ExpertLensContext(
        recordingManager: viewModel.recordingManager,
        hudViewModel: viewModel.hudViewModel,
        transport: .iPhone,
        onStopConfirmed: {
          Task {
            if let result = await viewModel.stopRecording() {
              onRecordingComplete(result.0, result.1)
            }
          }
        },
        onExitRequested: { dismiss() }
      )
      lensSession.activate(.expert, vm: context)
    }
    .onDisappear {
      lensSession.deactivate()
      Task { await viewModel.teardown() }
      UIDevice.current.endGeneratingDeviceOrientationNotifications()
      appOrientationController.unlock()
    }
    .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
      let resolved = resolveInterfaceOrientation()
      currentInterfaceOrientation = resolved
      viewModel.camera.setPreviewInterfaceOrientation(resolved)
    }
    .alert("Error", isPresented: $viewModel.showError) {
      Button("OK") { viewModel.dismissError() }
    } message: {
      Text(viewModel.errorMessage)
    }
  }
}

// MARK: - Glasses engine

/// Drives the glasses-camera recording flow. Body shape mirrors the iPhone
/// engine 1-for-1 — the only difference is the camera preview view and the
/// fact that there's no AVCaptureSession orientation to forward.
private struct GlassesRecordingEngine: View {
  let glassesDeviceName: String
  let onAcknowledgeProcedure: () -> Void
  let onRecordingComplete: (URL, TimeInterval) -> Void

  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var lensSession: LensSession
  @StateObject private var viewModel: StreamSessionViewModel

  @AppStorage("debugMode") private var debugMode: Bool = false
  @AppStorage("hudAdditiveBlend") private var hudAdditiveBlend: Bool = false
  @State private var expertPageIndex: Int = 0
  // Lens over an app-themed background by default; the raw glasses feed is
  // hidden until the user taps "Show camera" (handy for framing a shot).
  // Plain @State so it resets to hidden every session.
  @State private var showCameraFeed = false

  init(
    wearables: WearablesInterface,
    glassesDeviceName: String,
    uploadService: UploadService,
    onAcknowledgeProcedure: @escaping () -> Void,
    onRecordingComplete: @escaping (URL, TimeInterval) -> Void,
    sessionManager: DeviceSessionManager
  ) {
    self.glassesDeviceName = glassesDeviceName
    self.onAcknowledgeProcedure = onAcknowledgeProcedure
    self.onRecordingComplete = onRecordingComplete
    self._viewModel = StateObject(
      wrappedValue: StreamSessionViewModel(wearables: wearables, uploadService: uploadService, sessionManager: sessionManager)
    )
  }

  private var expertGlassesStatus: GlassesSessionStatus {
    viewModel.recordingManager.isRecording
      ? GlassesSessionStatus(
          label: "REC",
          dotColor: Color(red: 0.96, green: 0.26, blue: 0.21),
          pulsing: true
        )
      : GlassesSessionStatus(label: "READY", dotColor: .textTertiary, pulsing: false)
  }

  var body: some View {
    ExpertRecordingLayout {
      Group {
        if showCameraFeed {
          GlassesCameraPreview(image: viewModel.currentVideoFrame)
        } else {
          GlassesThemedBackground()
        }
      }
      .animation(.easeInOut(duration: 0.25), value: showCameraFeed)
    } hud: {
      expertRecordingHUD(
        recordingManager: viewModel.recordingManager,
        hudViewModel: viewModel.hudViewModel,
        debugMode: debugMode,
        hudAdditiveBlend: hudAdditiveBlend,
        pageIndex: $expertPageIndex,
        onStop: {
          // See IPhoneRecordingEngine — same hand-off pattern: stop
          // finalizes the mp4, then we hand the URL up so the parent
          // can dismiss this view (teardown stops the glasses stream
          // and hand-tracking) and present the review as a sibling
          // full-screen cover with no glasses pipeline running.
          Task {
            if let result = await viewModel.stopRecording() {
              onRecordingComplete(result.0, result.1)
            }
          }
        }
      )
    } chrome: {
      ZStack {
        // Glasses-session phone chrome — banner (top) + camera feed toggle
        // (below lens). Rendered beneath the recording controls so the
        // close button and Start CTA always stay on top and tappable.
        GlassesSessionChrome(
          deviceName: glassesDeviceName,
          status: expertGlassesStatus,
          showCameraFeed: $showCameraFeed
        )

        // Glasses-only: gate the Start CTA on `isReadyToRecord` (set
        // true after the silent warmup cycle in `prepare()`) AND
        // `isPreviewLive`. The chrome param is named `isPreviewLive`
        // for shape-parity with the iPhone engine, but we feed both
        // signals into it so the disabled state covers warmup too.
        expertRecordingChrome(
          recordingManager: viewModel.recordingManager,
          hudViewModel: viewModel.hudViewModel,
          isPreviewLive: viewModel.isPreviewLive && viewModel.isReadyToRecord,
          debugMode: debugMode,
          onClose: { dismiss() },
          onStart: { viewModel.startRecording(landscape: false) }
        )
      }
    }
    .animation(.easeInOut(duration: 0.18), value: viewModel.recordingManager.isHUDActive)
    .task {
      await viewModel.prepare()
    }
    .onAppear {
      // Step 9: wire the expert lens renderer for the glasses path.
      // Hand-tracking status reads "Neural Band" on this transport
      // (glasses use the band for input, not MediaPipe — per Step 6b.2).
      let context = ExpertLensContext(
        recordingManager: viewModel.recordingManager,
        hudViewModel: viewModel.hudViewModel,
        transport: .glasses,
        onStopConfirmed: {
          Task {
            if let result = await viewModel.stopRecording() {
              onRecordingComplete(result.0, result.1)
            }
          }
        },
        onExitRequested: { dismiss() }
      )
      lensSession.activate(.expert, vm: context)
    }
    .onDisappear {
      lensSession.deactivate()
      Task { await viewModel.teardown() }
    }
    .alert("Error", isPresented: $viewModel.showError) {
      if viewModel.cameraConnectionLost {
        // The glasses camera transport died (frame starvation). Offer a
        // rebuild — `reconnect()` re-runs prepare() against a fresh session.
        Button("Reconnect") { Task { await viewModel.reconnect() } }
        Button("Cancel", role: .cancel) { viewModel.dismissError() }
      } else {
        Button("OK") { viewModel.dismissError() }
      }
    } message: {
      Text(viewModel.errorMessage)
    }
  }
}

// MARK: - Shared HUD body

/// Lens content shared by both engines. Hidden until `isHUDActive` flips so
/// pre-recording the user sees just the camera preview + Start CTA — no
/// narration card, no stop pill. Same fade-in semantics on both transports.
///
/// `@MainActor` because it reads `@MainActor`-isolated state on
/// `recordingManager` / `hudViewModel`. SwiftUI view bodies are
/// MainActor-isolated, so callers satisfy this for free.
@MainActor
@ViewBuilder
private func expertRecordingHUD(
  recordingManager: ExpertRecordingManager,
  hudViewModel: ExpertRecordingHUDViewModel,
  debugMode: Bool,
  hudAdditiveBlend: Bool,
  pageIndex: Binding<Int>,
  onStop: @escaping () -> Void
) -> some View {
  if recordingManager.isHUDActive {
    RayBanHUDEmulator(
      pageCount: 1,
      pageIndex: pageIndex,
      showBoundary: debugMode,
      additiveBlend: hudAdditiveBlend,
      additiveSurfaceVariant: .lowTint,
      enableDismissGesture: true
    ) { _ in
      ExpertNarrationTipPage(
        recordingManager: recordingManager,
        hud: hudViewModel,
        onStop: onStop
      )
    }
    .transition(.opacity)
  }
}

// MARK: - Shared chrome body

/// Non-HUD overlays shared by both engines. Two phases:
///   • Pre-recording — close button (top-left), mic-source badge (top-right),
///     Start CTA (bottom).
///   • Recording — chrome stays empty above the lens. Recording status,
///     audio meter, mic-source, and stop pill all live *inside* the lens
///     alongside the narration card. See `ExpertNarrationTipPage`.
///
/// `@MainActor` for the same reason as `expertRecordingHUD` — reads
/// MainActor-isolated state on `recordingManager` / `hudViewModel`.
@MainActor
@ViewBuilder
private func expertRecordingChrome(
  recordingManager: ExpertRecordingManager,
  hudViewModel: ExpertRecordingHUDViewModel,
  isPreviewLive: Bool,
  debugMode: Bool,
  onClose: @escaping () -> Void,
  onStart: @escaping () -> Void
) -> some View {
  if !isPreviewLive {
    ProgressView()
      .scaleEffect(1.5)
      .tint(.textPrimary)
  }

  // Top row: pre-recording shows close (top-left) + mic-source badge
  // (top-right). When recording starts, the mic badge moves *into* the
  // lens so chrome stops rendering it to avoid double-up.
  VStack {
    HStack(alignment: .top) {
      if !recordingManager.isHUDActive {
        Button(action: onClose) {
          Image(systemName: "xmark")
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(.textPrimary)
            .frame(width: 36, height: 36)
            .glassPanel(cornerRadius: Radius.full)
        }
        .padding(.leading, 20)

        Spacer()

        ExpertHUDMicSourceBadge(micSource: hudViewModel.micSource)
          .padding(.trailing, 20)
      } else {
        Spacer()
      }
    }
    .padding(.top, 20)

    Spacer()
  }

  // Pre-recording bottom: Start CTA only.
  if !recordingManager.isHUDActive {
    VStack(spacing: 12) {
      Spacer()
      ExpertStartRecordingButton(
        isStarting: recordingManager.isStarting,
        isEnabled: isPreviewLive,
        onStart: onStart
      )
    }
    .padding(.all, 24)
  }

  // Hand-tracking dev overlay — landmark dots, pinch-drag cross, event
  // log. Sits above the rest of chrome but allows hit-testing through.
  if debugMode {
    HandGestureDebugStack(provider: HandGestureService.shared)
  }
}

// MARK: - Start button (pre-recording only)

private struct ExpertStartRecordingButton: View {
  let isStarting: Bool
  let isEnabled: Bool
  let onStart: () -> Void

  var body: some View {
    CustomButton(
      title: isStarting ? "Starting…" : "Start recording",
      style: .primary,
      isDisabled: !isEnabled || isStarting,
      action: onStart
    )
  }
}

// MARK: - Shared helpers

private func resolveInterfaceOrientation() -> UIInterfaceOrientation {
  let scene = UIApplication.shared.connectedScenes
    .compactMap { $0 as? UIWindowScene }
    .first(where: { $0.activationState == .foregroundActive })
    ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
  return scene?.interfaceOrientation ?? .portrait
}
