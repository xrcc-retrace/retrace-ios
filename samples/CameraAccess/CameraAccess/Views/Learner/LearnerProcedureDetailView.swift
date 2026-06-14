import AVFAudio
import MWDATCore
import SwiftUI
import UIKit

struct LearnerProcedureDetailView: View {
  let procedureId: String
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  @ObservedObject var progressStore: LocalProgressStore
  @EnvironmentObject private var deviceSessionManager: DeviceSessionManager

  @StateObject private var viewModel = ProcedureDetailViewModel()
  @State private var presentedCoaching: CaptureTransport?
  @State private var showRegistrationSheet = false
  @State private var showGlassesInactiveSheet = false
  @State private var isStartCoachingExpanded = false
  @State private var coachingStartingStep: Int?
  @State private var resumeTransport: CaptureTransport = .iPhone
  /// Surfaced when the user has previously denied mic access — coaching
  /// can't proceed without it, so the alert deep-links to Settings
  /// instead of pushing the coaching view into a stranded state. See
  /// Step 6b.5 in the native-lens-port plan.
  @State private var showMicPermissionDeniedAlert = false

  var body: some View {
    RetraceScreen {
      ZStack {
        content

        if showsStartCoachingDismissOverlay {
          Color.black.opacity(0.001)
            .contentShape(Rectangle())
            .onTapGesture {
              collapseStartCoachingCTA()
            }
            .transition(.opacity)
        }
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .navigationTitle("Workflow")
    .retraceNavBar()
    .task {
      await viewModel.fetchProcedure(id: procedureId)
    }
    .fullScreenCover(item: $presentedCoaching) { transport in
      if let procedure = viewModel.procedure {
        CoachingSessionView(
          procedure: procedure,
          wearables: wearables,
          wearablesVM: wearablesVM,
          progressStore: progressStore,
          serverBaseURL: viewModel.serverBaseURL,
          transport: transport,
          startingStep: coachingStartingStep,
          sessionManager: deviceSessionManager
        )
      }
    }
    .onChange(of: presentedCoaching) { _, new in
      if new == nil { coachingStartingStep = nil }
    }
    .sheet(isPresented: $showRegistrationSheet) {
      RegistrationPromptSheet(viewModel: wearablesVM) {
        presentedCoaching = .glasses
      }
    }
    .sheet(isPresented: $showGlassesInactiveSheet) {
      GlassesInactiveSheet(iPhoneAlternativeTitle: "Coach with iPhone instead") {
        presentedCoaching = .iPhone
      }
    }
    .alert(
      "Microphone access needed",
      isPresented: $showMicPermissionDeniedAlert
    ) {
      Button("Open Settings") {
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Coaching needs the microphone for two-way voice. Enable it in Settings → Retrace → Microphone.")
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let procedure = viewModel.procedure {
        learnerCTAInset(for: procedure)
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    if viewModel.isLoading && viewModel.procedure == nil {
      ProgressView()
        .scaleEffect(1.5)
        .tint(.textPrimary)
    } else if let procedure = viewModel.procedure {
      ProcedureChapterDetailContent(
        procedure: procedure,
        serverBaseURL: viewModel.serverBaseURL,
        metrics: learnerMetrics(for: procedure),
        readMoreContent: learnerReadMoreContent(for: procedure),
        headerActionContent: saveButton(for: procedure),
        expandedStepFooter: { _ in EmptyView() }
      )
    } else if let error = viewModel.errorMessage {
      VStack(spacing: Spacing.lg) {
        Image(systemName: "exclamationmark.triangle")
          .font(.system(size: 36))
          .foregroundColor(.textPrimary)
        Text(error)
          .font(.retraceCallout)
          .foregroundColor(.textSecondary)
          .multilineTextAlignment(.center)
      }
      .padding(Spacing.screenPadding)
    }
  }

  private func learnerMetrics(for procedure: ProcedureResponse) -> [ProcedureMetricItem] {
    let full = ProcedureMetricItem.workflowSummary(
      duration: procedure.totalDuration,
      stepCount: procedure.steps.count,
      completionCount: progressStore.completedCount(for: procedure.id)
    )
    // For manual/web procedures, the totalDuration is a 30s-per-step
    // placeholder Gemini emits for API compatibility. Drop the duration
    // metric so we don't show a misleading "X minutes". Step count +
    // completion count remain meaningful and stay in the strip.
    let st = (procedure.sourceType ?? "video").lowercased()
    guard st == "video" else {
      return full.filter { $0.icon != "clock" }
    }
    return full
  }

  @ViewBuilder
  private func learnerReadMoreContent(for procedure: ProcedureResponse) -> some View {
    if let resumable = progressStore.inProgressSession(for: procedure.id) {
      VStack(alignment: .leading, spacing: Spacing.md) {
        Divider()
          .background(Color.borderSubtle)

        resumeProgressSection(resumable)
      }
    } else {
      EmptyView()
    }
  }

  private func saveButton(for procedure: ProcedureResponse) -> some View {
    Button {
      progressStore.toggleSaved(procedure.id)
    } label: {
      HStack(spacing: Spacing.md) {
        Image(systemName: progressStore.isSaved(procedure.id) ? "bookmark.fill" : "bookmark")
          .foregroundColor(.textPrimary)
        Text(progressStore.isSaved(procedure.id) ? "Saved to Library" : "Save to Library")
          .font(.retraceFace(.medium, size: 17))
          .foregroundColor(.textPrimary)
      }
      .frame(maxWidth: .infinity)
      .frame(height: 48)
      .background(Color.surfaceBase)
      .cornerRadius(Radius.full)
    }
    .buttonStyle(ScaleButtonStyle())
  }

  @ViewBuilder
  private func learnerCTAInset(for procedure: ProcedureResponse) -> some View {
    let resumable = progressStore.inProgressSession(for: procedure.id)

    VStack(spacing: 0) {
      LinearGradient(
        colors: [Color.backgroundPrimary.opacity(0), Color.backgroundPrimary],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: 20)

      Group {
        if let resumable {
          resumeCTAs(resumable)
        } else {
          freshCTAs
        }
      }
      .padding(.horizontal, Spacing.screenPadding)
      .padding(.bottom, Spacing.xl)
      .background(Color.backgroundPrimary)
    }
  }

  @ViewBuilder
  private func resumeProgressSection(_ resumable: SessionRecord) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack {
        Text("IN PROGRESS")
          .font(.retraceOverline)
          .tracking(0.5)
          .foregroundColor(.appPrimary)

        Spacer()

        Text(relativeTime(from: resumable.startedAt))
          .font(.retraceCaption1)
          .foregroundColor(.textSecondary)
      }

      StepProgressBar(
        currentStep: resumable.stepsCompleted,
        totalSteps: resumable.totalSteps
      )

      Text("Step \(resumable.stepsCompleted + 1) of \(resumable.totalSteps)")
        .font(.retraceCallout)
        .foregroundColor(.textPrimary)
    }
    .padding(Spacing.xl)
    .background(Color.surfaceBase)
    .cornerRadius(Radius.lg)
  }

  @ViewBuilder
  private var freshCTAs: some View {
    VStack(spacing: Spacing.md) {
      if isStartCoachingExpanded {
        // Pre-flight DAT camera permission CTA. Self-hides until
        // registered; surfaces when registered-but-not-granted; shows
        // "granted ✓" once user grants in Meta AI. Disables only the
        // glasses button below; iPhone transport doesn't require it.
        DATCameraPermissionCTA(
          registrationState: wearablesVM.registrationState,
          style: .card
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))

        CustomButton(
          title: "Coach with Glasses",
          icon: "eyeglasses",
          style: .primary,
          isDisabled: glassesBlockedByMissingPermission
        ) {
          launchCoaching(transport: .glasses, startingStep: nil)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))

        CustomButton(
          title: "Coach with iPhone",
          icon: "iphone",
          style: .secondary,
          isDisabled: false
        ) {
          launchCoaching(transport: .iPhone, startingStep: nil)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
      } else {
        CustomButton(
          title: "Start coaching",
          icon: "play.fill",
          style: .primary,
          isDisabled: false
        ) {
          withAnimation(.easeInOut(duration: 0.2)) {
            isStartCoachingExpanded = true
          }
        }
        .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: isStartCoachingExpanded)
  }

  @ViewBuilder
  private func resumeCTAs(_ resumable: SessionRecord) -> some View {
    let continueStep = resumable.stepsCompleted + 1
    let resumeBlockedByPermission = resumeTransport == .glasses && glassesBlockedByMissingPermission

    VStack(spacing: Spacing.md) {
      HStack(spacing: 0) {
        transportPillOption(
          label: "Glasses",
          icon: "eyeglasses",
          value: .glasses
        )
        transportPillOption(
          label: "iPhone",
          icon: "iphone",
          value: .iPhone
        )
      }
      .padding(4)
      .background(Color.surfaceBase)
      .clipShape(Capsule())

      // Pre-flight DAT camera permission CTA — only relevant when the
      // glasses pill is selected. The component self-hides when not
      // registered; when registered-but-not-granted it surfaces here so
      // the user can grant before tapping Continue / Start Over.
      if resumeTransport == .glasses {
        DATCameraPermissionCTA(
          registrationState: wearablesVM.registrationState,
          style: .card
        )
      }

      CustomButton(
        title: "Continue from Step \(continueStep)",
        icon: "arrow.right.circle.fill",
        style: .primary,
        isDisabled: resumeBlockedByPermission
      ) {
        launchCoaching(transport: resumeTransport, startingStep: continueStep)
      }

      CustomButton(
        title: "Start Over",
        icon: "arrow.counterclockwise",
        style: .secondary,
        isDisabled: resumeBlockedByPermission
      ) {
        progressStore.updateSession(
          id: resumable.id,
          stepsCompleted: resumable.stepsCompleted,
          status: .abandoned
        )
        launchCoaching(transport: resumeTransport, startingStep: nil)
      }
    }
  }

  /// True when the user is paired but DAT camera permission isn't
  /// `.granted` — in this state the glasses transport will fail at the
  /// pre-session gate, so we disable any button that would launch a
  /// glasses-transport session. iPhone-transport buttons stay enabled.
  /// Reactive — re-renders when DSM's `cameraPermission` flips.
  private var glassesBlockedByMissingPermission: Bool {
    wearablesVM.registrationState == .registered &&
      deviceSessionManager.cameraPermission != .granted
  }

  @ViewBuilder
  private func transportPillOption(
    label: String,
    icon: String,
    value: CaptureTransport
  ) -> some View {
    let isSelected = resumeTransport == value

    Button {
      resumeTransport = value
    } label: {
      HStack(spacing: 6) {
        Image(systemName: icon)
        Text(label)
      }
      .font(.retraceCallout)
      .fontWeight(isSelected ? .semibold : .regular)
      .foregroundColor(isSelected ? .backgroundPrimary : .textSecondary)
      .frame(maxWidth: .infinity)
      .frame(height: 36)
      .background(isSelected ? Color.textPrimary : Color.clear)
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
  }

  private var showsStartCoachingDismissOverlay: Bool {
    guard isStartCoachingExpanded, let procedure = viewModel.procedure else { return false }
    return progressStore.inProgressSession(for: procedure.id) == nil
  }

  private func collapseStartCoachingCTA() {
    withAnimation(.easeInOut(duration: 0.2)) {
      isStartCoachingExpanded = false
    }
  }

  private func launchCoaching(transport: CaptureTransport, startingStep: Int?) {
    collapseStartCoachingCTA()
    // Mic permission is checked BEFORE navigation so a denial doesn't
    // strand the user in a coaching view that can't actually capture
    // voice. DAT camera + registration are gated below (and via the
    // separate DAT-permissions sheet on session start) — those don't
    // apply to the iPhone transport so we only check them in the
    // glasses branch.
    Task { @MainActor in
      let micOK = await ensureMicrophonePermission()
      guard micOK else {
        // Alert was surfaced inside the helper; nothing more to do.
        return
      }
      coachingStartingStep = startingStep
      let pairedSnapshot = wearables.devices.map { id -> String in
        if let d = wearables.deviceForIdentifier(id) {
          return "\(d.nameOrId())(type=\(d.deviceType().rawValue),supportsDisplay=\(d.supportsDisplay()))"
        } else {
          return "\(id)(unresolved)"
        }
      }.joined(separator: ", ")
      let permDescription = deviceSessionManager.cameraPermission.map { String(describing: $0) } ?? "unavailable"
      print("[Retrace.Diag][launchGate] transport=\(transport) hasActiveDevice=\(wearablesVM.hasActiveDevice) devicesCount=\(wearables.devices.count) [\(pairedSnapshot)] registrationState=\(wearablesVM.registrationState) cameraPermission=\(permDescription)")
      switch transport {
      case .glasses:
        // Pre-HOTFIX behavior restored 2026-05-21 — route on real glasses
        // connectivity now that lens + DeviceSessionManager are wired.
        if wearablesVM.registrationState != .registered {
          print("[Retrace.Diag][launchGate] → routing to RegistrationPromptSheet (not .registered)")
          showRegistrationSheet = true
        } else if !wearablesVM.hasActiveDevice {
          print("[Retrace.Diag][launchGate] → routing to GlassesInactiveSheet (registered but no active device)")
          showGlassesInactiveSheet = true
        } else {
          print("[Retrace.Diag][launchGate] → presentedCoaching = .glasses")
          presentedCoaching = .glasses
        }
      case .iPhone:
        presentedCoaching = .iPhone
      }
    }
  }

  /// Mic preflight: granted → true; undetermined → prompt inline; denied
  /// → surface the Settings deep-link alert and return false. iOS-native
  /// path per `mwdat-ios:permissions-registration` (DAT 0.7 has no
  /// `Permission.microphone`).
  private func ensureMicrophonePermission() async -> Bool {
    switch AVAudioApplication.shared.recordPermission {
    case .granted:
      return true
    case .denied:
      showMicPermissionDeniedAlert = true
      return false
    case .undetermined:
      let granted = await AVAudioApplication.requestRecordPermission()
      if !granted {
        showMicPermissionDeniedAlert = true
      }
      return granted
    @unknown default:
      // Be permissive on future enum cases — let the in-session retry
      // path surface the failure rather than blocking here.
      return true
    }
  }

  private func relativeTime(from date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return "Started " + formatter.localizedString(for: date, relativeTo: Date())
  }
}
