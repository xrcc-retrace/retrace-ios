//
// GlassesSessionStandbyView.swift
//
// The phone "ditto" standby shown for the WHOLE glasses session. The phone is
// the runtime brain but stops being the navigation surface, so it shows one
// constant "Session on glasses" screen — a short description that mirrors the
// current lens screen, and a single "Take back on phone" escape. Nothing else
// is interactable, and the phone never shows the camera feed or recording
// chrome: in full glasses mode the lens is the UI.
//
// During a glasses-first recording the `StreamSessionViewModel` (camera Stream
// + writer + HFP audio) still must live on the phone, so it's hosted
// INVISIBLY behind this view via `GlassesRecordingHost` (renders `Color.clear`)
// whenever `runtimeMode == .expertRecording`. Mounting it runs the existing
// `prepare()` warmup and activates the `.expert` lens renderer; the visible
// phone UI does not change.
//

import Combine
import MWDATCore
import SwiftUI

struct GlassesSessionStandbyView: View {
  @ObservedObject var coordinator: GlassesNavigationCoordinator
  @ObservedObject private var navigatorVM: NavigatorViewModel
  let wearables: WearablesInterface
  @EnvironmentObject private var sessionManager: DeviceSessionManager

  init(coordinator: GlassesNavigationCoordinator, wearables: WearablesInterface) {
    self._coordinator = ObservedObject(wrappedValue: coordinator)
    self._navigatorVM = ObservedObject(wrappedValue: coordinator.navigatorVM)
    self.wearables = wearables
  }

  var body: some View {
    standby
      // Invisible runtime hosts. Present only while their runtime is active;
      // render nothing — they keep the heavy VM alive and drive the lens.
      .background {
        if coordinator.runtimeMode == .expertRecording {
          GlassesRecordingHost(
            coordinator: coordinator,
            wearables: wearables,
            sessionManager: sessionManager,
            uploadService: coordinator.uploadService
          )
        } else if coordinator.runtimeMode == .learnerCoaching,
                  let procedure = coordinator.coachingProcedure {
          GlassesCoachingHost(
            coordinator: coordinator,
            procedure: procedure,
            wearables: wearables,
            sessionManager: sessionManager
          )
        } else if coordinator.runtimeMode == .troubleshootSession {
          GlassesTroubleshootHost(
            coordinator: coordinator,
            wearables: wearables,
            sessionManager: sessionManager
          )
        } else if coordinator.runtimeMode == .askAI {
          GlassesAskAIHost(
            coordinator: coordinator,
            wearables: wearables,
            sessionManager: sessionManager
          )
        }
      }
  }

  // MARK: - The one constant phone view

  private var standby: some View {
    ZStack {
      Color.backgroundPrimary.ignoresSafeArea()

      VStack(spacing: Spacing.section) {
        Spacer()

        // Glasses glyph with a live "connected" pulse — makes it obvious the
        // phone is actively driving the glasses in real time.
        ZStack(alignment: .topTrailing) {
          Image(systemName: "eyeglasses")
            .font(.system(size: 56, weight: .regular))
            .foregroundColor(.textPrimary)
          LivePulseDot()
            .offset(x: 12, y: -4)
        }

        // The HERO: a mode chip over a big activity title — "which step you're
        // on", made large and eye-catching so the live link reads instantly.
        VStack(spacing: Spacing.lg) {
          Text(mirrorStatus.mode)
            .font(.inter(.bold, size: 13))
            .tracking(2)
            .foregroundColor(.appPrimary)
            .padding(.horizontal, Spacing.md + 2)
            .padding(.vertical, Spacing.sm)
            .background(Capsule().fill(Color.appPrimary.opacity(0.16)))

          Text(mirrorStatus.title)
            .font(.retraceFace(.bold, size: 40))
            .foregroundColor(.textPrimary)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.6)
            .lineLimit(2)

          Text("Mirrored live on your glasses")
            .font(.inter(.regular, size: 14))
            .foregroundColor(.textSecondary.opacity(0.7))
        }

        Spacer()

        Button {
          coordinator.exitGlassesMode()
        } label: {
          Text("Take back on phone")
            .font(.inter(.medium, size: 16))
            .foregroundColor(.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.md)
            .background(
              RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.textPrimary.opacity(0.3), lineWidth: 1)
            )
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.bottom, Spacing.section)
      }
      .padding(.horizontal, Spacing.screenPadding)
    }
  }

  /// A two-part echo of what's happening on the lens: a short MODE label (the
  /// chip) and a big activity TITLE (the hero). Recording/coaching/etc. take
  /// precedence over the nav screen since the navigator screen stays on the
  /// Expert hub while the capture runs on the lens.
  private var mirrorStatus: (mode: String, title: String) {
    if coordinator.runtimeMode == .expertRecording {
      return ("EXPERT", "Recording")
    }
    if coordinator.runtimeMode == .learnerCoaching {
      return coordinator.isCoachingFromTroubleshoot
        ? ("TROUBLESHOOT", "Coaching")
        : ("LEARNER", "Coaching")
    }
    if coordinator.runtimeMode == .troubleshootSession {
      return ("TROUBLESHOOT", "Diagnosing")
    }
    if coordinator.runtimeMode == .askAI {
      return ("LEARNER", "Ask AI")
    }
    switch navigatorVM.screen {
    case .home:
      return ("RETRACE", "Choose a mode")
    case .expertHub:
      return ("EXPERT", "Record or Browse")
    case .browseList:
      return ("EXPERT", "Browsing procedures")
    case .procedureDetail:
      return ("EXPERT", "Viewing a procedure")
    case .expertReview:
      return ("EXPERT", "Review your recording")
    case .expertProcessing:
      return ("EXPERT", "Processing")
    case .expertDone:
      return ("EXPERT", "Recording ready")
    case .expertFailed:
      return ("EXPERT", "Recording failed")
    case .learnerHub:
      return ("LEARNER", "Browse or Ask AI")
    case .learnerFilter:
      return ("LEARNER", "Filtering")
    case .learnerProcedureDetail:
      return ("LEARNER", "Viewing a procedure")
    case .troubleshootIntro:
      return ("TROUBLESHOOT", "Ready to diagnose")
    case .retraceGame:
      return ("RETRACE", "Playing")
    case .comingSoon:
      return ("RETRACE", "Continue on glasses")
    }
  }
}

/// A small green "live" dot with a slow expanding-ring pulse — signals that the
/// phone↔glasses link is active. Phone-side UI, so a continuous SwiftUI
/// animation is fine here (the lens frame-rate constraint does not apply).
private struct LivePulseDot: View {
  @State private var animate = false

  var body: some View {
    ZStack {
      Circle()
        .fill(Color.semanticSuccess.opacity(0.55))
        .frame(width: 14, height: 14)
        .scaleEffect(animate ? 2.4 : 1.0)
        .opacity(animate ? 0 : 0.6)
      Circle()
        .fill(Color.semanticSuccess)
        .frame(width: 11, height: 11)
        .overlay(Circle().stroke(Color.backgroundPrimary, lineWidth: 2))
    }
    .onAppear {
      withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
        animate = true
      }
    }
  }
}

// MARK: - Invisible recording host (.expertRecording)

/// Hosts the glasses recording runtime on the phone while the lens drives the
/// entire UX. Renders `Color.clear` — the user never sees it. Mounting runs the
/// existing `prepare()` warmup + audio prewarm; the `.expert` lens renderer is
/// activated on appear (with a lens Start affordance gated on warmup) and torn
/// down by the coordinator on finish/cancel.
private struct GlassesRecordingHost: View {
  @ObservedObject var coordinator: GlassesNavigationCoordinator
  let wearables: WearablesInterface
  @EnvironmentObject private var lensSession: LensSession
  @StateObject private var viewModel: StreamSessionViewModel

  init(
    coordinator: GlassesNavigationCoordinator,
    wearables: WearablesInterface,
    sessionManager: DeviceSessionManager,
    uploadService: UploadService
  ) {
    self._coordinator = ObservedObject(wrappedValue: coordinator)
    self.wearables = wearables
    self._viewModel = StateObject(
      wrappedValue: StreamSessionViewModel(
        wearables: wearables,
        uploadService: uploadService,
        sessionManager: sessionManager,
        externalAudioManager: coordinator.persistentAudio
      )
    )
  }

  var body: some View {
    Color.clear
      .task {
        await viewModel.prepare()
      }
      .onAppear {
        coordinator.activeRuntime = viewModel
        let vm = viewModel
        let context = ExpertLensContext(
          recordingManager: vm.recordingManager,
          hudViewModel: vm.hudViewModel,
          transport: .glasses,
          onStopConfirmed: {
            Task { @MainActor in
              if let result = await vm.stopRecording() {
                coordinator.reviewExpertRecording(url: result.0, duration: result.1)
              } else {
                coordinator.cancelExpertRecording()
              }
            }
          },
          onExitRequested: {
            coordinator.cancelExpertRecording()
          },
          onStart: {
            vm.startRecording(landscape: false)
          },
          readinessPublisher: Publishers.CombineLatest(
            vm.$isReadyToRecord,
            vm.$hasReceivedFirstFrame
          )
          .map { $0 && $1 }
          .eraseToAnyPublisher()
        )
        lensSession.activate(.expert, vm: context)
      }
      .onDisappear {
        Task { await viewModel.teardown() }
      }
  }
}

// MARK: - Invisible coaching host (.learnerCoaching)

/// Hosts the glasses coaching runtime on the phone while the lens drives the
/// entire UX. Renders `Color.clear`. Mounting starts the Gemini Live coaching
/// session; the `.coaching` lens renderer is activated once the VM's
/// `isReadyForNativeLens` gate flips (HFP mic + camera up). Exit confirmed on
/// the lens calls back into the coordinator, which unmounts this host.
private struct GlassesCoachingHost: View {
  @ObservedObject var coordinator: GlassesNavigationCoordinator
  let procedure: ProcedureResponse
  let wearables: WearablesInterface
  @EnvironmentObject private var lensSession: LensSession
  @StateObject private var progressStore = LocalProgressStore()
  @StateObject private var viewModel: CoachingSessionViewModel

  init(
    coordinator: GlassesNavigationCoordinator,
    procedure: ProcedureResponse,
    wearables: WearablesInterface,
    sessionManager: DeviceSessionManager
  ) {
    self._coordinator = ObservedObject(wrappedValue: coordinator)
    self.procedure = procedure
    self.wearables = wearables
    self._viewModel = StateObject(
      wrappedValue: CoachingSessionViewModel(
        procedure: procedure,
        wearables: wearables,
        serverBaseURL: ServerEndpoint.shared.resolvedBaseURL,
        transport: .glasses,
        sessionManager: sessionManager,
        externalAudioManager: coordinator.persistentAudio
      )
    )
  }

  var body: some View {
    Color.clear
      .onAppear {
        coordinator.activeRuntime = viewModel
        viewModel.onExitConfirmed = { [weak coordinator] in
          coordinator?.exitCoaching()
        }
        viewModel.startSession(progressStore: progressStore, startingStep: nil)
        if viewModel.isReadyForNativeLens {
          lensSession.activate(.coaching, vm: viewModel)
        }
      }
      // The readiness gate flips once HFP mic + camera are settled; defer the
      // lens activation until then (same contract as CoachingSessionView).
      .onChange(of: viewModel.isReadyForNativeLens) { _, ready in
        if ready {
          lensSession.activate(.coaching, vm: viewModel)
        }
      }
      .onDisappear {
        viewModel.endSession(progressStore: progressStore)
      }
  }
}

// MARK: - Invisible troubleshoot host (.troubleshootSession)

/// Hosts the glasses diagnostic runtime on the phone while the lens drives the
/// entire UX. Renders `Color.clear`. Mounting starts the Gemini Live diagnostic
/// session; the `.troubleshoot` lens renderer is activated once the VM's
/// `isReadyForNativeLens` gate flips (HFP mic + camera up). Two lens bridges:
/// the exit overlay calls back to `exitTroubleshoot()`, and a found-fix "Start"
/// runs `executeHandoff` then `handoffToCoaching(...)` so the same coaching host
/// takes over. On handoff the diagnostic session is already torn down inside
/// `executeHandoff`, so this host skips its own `endSession()`.
private struct GlassesTroubleshootHost: View {
  @ObservedObject var coordinator: GlassesNavigationCoordinator
  let wearables: WearablesInterface
  @EnvironmentObject private var lensSession: LensSession
  @StateObject private var viewModel: DiagnosticSessionViewModel
  @State private var didHandoff = false

  init(
    coordinator: GlassesNavigationCoordinator,
    wearables: WearablesInterface,
    sessionManager: DeviceSessionManager
  ) {
    self._coordinator = ObservedObject(wrappedValue: coordinator)
    self.wearables = wearables
    self._viewModel = StateObject(
      wrappedValue: DiagnosticSessionViewModel(
        wearables: wearables,
        serverBaseURL: ServerEndpoint.shared.resolvedBaseURL,
        transport: .glasses,
        sessionManager: sessionManager,
        externalAudioManager: coordinator.persistentAudio
      )
    )
  }

  var body: some View {
    Color.clear
      .task {
        await viewModel.startSession()
      }
      .onAppear {
        coordinator.activeRuntime = viewModel
        let vm = viewModel
        vm.onExitConfirmed = { [weak coordinator] in
          coordinator?.exitTroubleshoot()
        }
        vm.onLensStartHandoff = { [weak coordinator] procedureId in
          Task { @MainActor in
            let active = UserDefaults.standard.object(forKey: "activeMonitoringEnabled") as? Bool ?? true
            if let payload = await vm.executeHandoff(
              procedureId: procedureId,
              autoAdvance: active,
              activeMonitoring: active
            ) {
              didHandoff = true
              coordinator?.handoffToCoaching(procedure: payload.procedure)
            }
          }
        }
        if vm.isReadyForNativeLens {
          lensSession.activate(.troubleshoot, vm: vm)
        }
      }
      // The readiness gate flips once HFP mic + camera are settled; defer the
      // lens activation until then (same contract as TroubleshootSessionView).
      .onChange(of: viewModel.isReadyForNativeLens) { _, ready in
        if ready {
          lensSession.activate(.troubleshoot, vm: viewModel)
        }
      }
      .onDisappear {
        viewModel.onExitConfirmed = nil
        viewModel.onLensStartHandoff = nil
        // On the handoff path `executeHandoff` already stopped Gemini + camera;
        // only a manual exit needs the terminal teardown.
        if !didHandoff {
          viewModel.endSession()
        }
      }
  }
}

// MARK: - Invisible Ask-AI host (.askAI)

/// Hosts the audio-only Ask-AI runtime on the phone while the lens drives the
/// UX. Renders `Color.clear`. Unlike coaching/troubleshoot, Ask AI streams no
/// camera, so the `.askAI` lens renderer is activated IMMEDIATELY on appear —
/// the Display capability is already live from the navigator, and there's no
/// camera first-frame to gate on. Picking a result bridges to the coordinator
/// (which hands off into the coaching host); "Go back" exits Ask AI.
private struct GlassesAskAIHost: View {
  @ObservedObject var coordinator: GlassesNavigationCoordinator
  let wearables: WearablesInterface
  @EnvironmentObject private var lensSession: LensSession
  @StateObject private var viewModel: AskAISessionViewModel

  init(
    coordinator: GlassesNavigationCoordinator,
    wearables: WearablesInterface,
    sessionManager: DeviceSessionManager
  ) {
    self._coordinator = ObservedObject(wrappedValue: coordinator)
    self.wearables = wearables
    self._viewModel = StateObject(
      wrappedValue: AskAISessionViewModel(
        wearables: wearables,
        serverBaseURL: ServerEndpoint.shared.resolvedBaseURL,
        sessionManager: sessionManager,
        externalAudioManager: coordinator.persistentAudio
      )
    )
  }

  var body: some View {
    Color.clear
      .task {
        await viewModel.startSession()
      }
      .onAppear {
        coordinator.activeRuntime = viewModel
        viewModel.onSelected = { [weak coordinator] procedureId in
          coordinator?.askAIDidSelect(procedureId: procedureId)
        }
        viewModel.onExitRequested = { [weak coordinator] in
          coordinator?.exitAskAI()
        }
        // Defer the Display until the mic is up. The coordinator detached the
        // navigator Display on launch so HFP audio comes up first; activating
        // the lens here would re-attach the Display DURING the HFP warmup and
        // starve the glasses mic. `isReadyForNativeLens` flips only after HFP
        // has settled (+ the shared session started), so the Display re-attaches
        // last — same contract as the coaching / troubleshoot hosts.
        if viewModel.isReadyForNativeLens {
          lensSession.activate(.askAI, vm: viewModel)
        }
      }
      .onChange(of: viewModel.isReadyForNativeLens) { _, ready in
        if ready {
          lensSession.activate(.askAI, vm: viewModel)
        }
      }
      .onDisappear {
        viewModel.onSelected = nil
        viewModel.onExitRequested = nil
        viewModel.endSession()
      }
  }
}
