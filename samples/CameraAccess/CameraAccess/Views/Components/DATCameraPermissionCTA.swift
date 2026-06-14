import MWDATCore
import SwiftUI

/// Post-registration DAT camera permission prompt — reusable across every
/// surface that triggers glasses registration (onboarding, HomeScreen,
/// Server Settings, and any future entry point).
///
/// **Why this exists.** The DAT 0.7 SDK requires `wearables.requestPermission(.camera)`
/// to be granted via the Meta AI deep-link before any device appears in
/// `wearables.devices`. Without that step the next session attempt throws
/// `noEligibleDevice` no matter how patiently we wait. Registration alone
/// is not enough — `startRegistration` + Meta AI pairing is step 1 of 2;
/// camera permission is step 2.
///
/// **What it does.** When `registrationState == .registered`:
///   1. Queries `sessionManager.cameraPermissionStatus()` (non-prompting,
///      5 s timeout).
///   2. If granted → renders the success state.
///   3. If not granted → renders the "Allow camera access" CTA. Tap fires
///      `sessionManager.ensureCameraPermissionGranted()` which deep-links
///      into Meta AI (60 s timeout safety net for a hung deep-link).
///   4. On grant → success state + optional `onGranted` callback.
///   5. On deny / timeout → re-shows the CTA with "Try again".
///
/// **What it does NOT do.** Renders nothing when `registrationState !=
/// .registered` — the permission step only makes sense once glasses are
/// paired. Hosts can drop this view in unconditionally; it self-hides.
///
/// **Why a shared component.** This logic shipped originally inline in
/// `OnboardingGlassesView`. Replicating it across HomeScreen + Settings
/// = ~240 lines of duplicated state machine that drifts as bugs are
/// found in one place but not the others (the reviewer agent already
/// caught a real timeout bug in the inline version). One copy, three
/// call sites.
struct DATCameraPermissionCTA: View {
  /// Live registration state from the host's `WearablesViewModel`. Drives
  /// the entire state machine — until this is `.registered`, the view
  /// renders nothing.
  let registrationState: RegistrationState

  /// Visual variant. Hosts pick whichever fits their layout:
  /// - `.button` — primary CustomButton (matches "Connect my glasses"
  ///   style; used by onboarding + HomeScreen).
  /// - `.card` — rounded surface row with inline status + tap area
  ///   (matches Settings' connected-device pill style).
  var style: Style = .button

  /// Fires once when permission transitions to `.granted`. Onboarding
  /// uses this to auto-advance the page; Settings / HomeScreen leave nil.
  var onGranted: (() -> Void)? = nil

  @EnvironmentObject private var sessionManager: DeviceSessionManager

  enum Style {
    /// Primary CustomButton — matches the "Connect my glasses" affordance.
    case button
    /// Rounded surface row with inline status — matches Settings' pill.
    case card
  }

  /// Mirrors the state machine that previously lived inline in
  /// `OnboardingGlassesView`. See `OnboardingGlassesView.swift` for the
  /// original docstring rationale on each case.
  enum PermissionPhase {
    case idle           // pre-registration or freshly mounted
    case checking       // post-registration, non-prompting status query in flight
    case needsRequest   // not granted — CTA visible
    case requesting     // CTA tapped, Meta AI deep-link is open
    case granted        // ready
    case denied         // user explicitly denied in Meta AI
  }
  @State private var phase: PermissionPhase = .idle

  /// Time limit for the non-prompting status query. Usually instant
  /// (cached on-device); 5 s tolerates a slow SDK warm-up.
  private static let statusCheckTimeout: TimeInterval = 5.0

  /// Time limit for the prompting request. Generous because the user is
  /// physically away from the app (in Meta AI granting). Safety net for
  /// a hung deep-link, not the expected path.
  private static let requestPromptTimeout: TimeInterval = 60.0

  var body: some View {
    Group {
      if registrationState != .registered {
        // Render nothing — the permission step only applies after
        // glasses are paired. Hosts can drop this view in unconditionally.
        EmptyView()
      } else {
        switch style {
        case .button:
          buttonStyleBody
        case .card:
          cardStyleBody
        }
      }
    }
    .onChange(of: registrationState) { _, newState in
      // `.onChange` fires only on value changes (not initial appearance),
      // so a user who opens this surface with glasses already registered
      // gets caught by `.onAppear` below.
      if newState == .registered {
        Task { await checkAfterRegistration() }
      } else {
        // Re-registering from scratch — reset back to idle so the
        // post-registration check fires fresh once we land on `.registered`.
        phase = .idle
      }
    }
    .onAppear {
      // Catch the case where the view appears with `registrationState`
      // already `.registered` (e.g. user navigated to Settings with
      // glasses already paired from a previous launch). The `.idle`
      // guard prevents re-firing if a check is already in flight from
      // a prior `.onChange`.
      if registrationState == .registered && phase == .idle {
        Task { await checkAfterRegistration() }
      }
    }
  }

  // MARK: - Style: button (onboarding + HomeScreen)

  @ViewBuilder
  private var buttonStyleBody: some View {
    switch phase {
    case .idle, .checking:
      // Brief "checking" interstitial — keeps layout stable instead of
      // popping in the CTA half a second after registration completes.
      CustomButton(
        title: "Checking glasses access…",
        icon: nil,
        style: .secondary,
        isDisabled: true
      ) {}
    case .needsRequest, .requesting, .denied:
      CustomButton(
        title: ctaTitle,
        icon: "eyeglasses",
        style: .primary,
        isDisabled: phase == .requesting
      ) {
        Task { await requestPermission() }
      }
    case .granted:
      // Success row — keeps a visual checkpoint so the user understands
      // both prerequisites are done. Disabled so it doesn't read as
      // tappable.
      CustomButton(
        title: "Glasses access granted",
        icon: "checkmark",
        style: .secondary,
        isDisabled: true
      ) {}
    }
  }

  // MARK: - Style: card (Settings)

  @ViewBuilder
  private var cardStyleBody: some View {
    HStack(spacing: Spacing.md) {
      Image(systemName: cardIconName)
        .font(.system(size: 18, weight: .semibold))
        .foregroundColor(cardIconColor)
        .frame(width: 28)

      VStack(alignment: .leading, spacing: 2) {
        Text(cardTitle)
          .font(.retraceCallout)
          .foregroundColor(.textPrimary)
        Text(cardSubtitle)
          .font(.retraceCaption1)
          .foregroundColor(.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: Spacing.sm)

      if phase == .needsRequest || phase == .denied {
        Button {
          Task { await requestPermission() }
        } label: {
          Text(phase == .denied ? "Try again" : "Allow")
            .font(.retraceCaption1)
            .fontWeight(.semibold)
            .foregroundColor(.backgroundPrimary)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .background(Color.textPrimary)
            .cornerRadius(Radius.full)
        }
        .buttonStyle(ScaleButtonStyle())
      } else if phase == .requesting {
        ProgressView()
          .controlSize(.small)
      }
    }
    .padding(14)
    .background(Color.surfaceRaised)
    .cornerRadius(Radius.md)
  }

  // MARK: - Copy

  private var ctaTitle: String {
    switch phase {
    case .requesting: return "Opening Meta AI…"
    case .denied: return "Try again"
    default: return "Allow glasses access"
    }
  }

  private var cardIconName: String {
    switch phase {
    case .granted: return "checkmark.circle.fill"
    case .denied: return "exclamationmark.triangle.fill"
    default: return "eyeglasses"
    }
  }

  private var cardIconColor: Color {
    switch phase {
    case .granted: return .semanticSuccess
    case .denied: return .yellow
    default: return .textSecondary
    }
  }

  private var cardTitle: String {
    switch phase {
    case .granted: return "Glasses access granted"
    case .denied: return "Glasses access denied"
    case .requesting: return "Opening Meta AI…"
    case .checking, .idle: return "Checking glasses access…"
    case .needsRequest: return "Allow glasses access"
    }
  }

  private var cardSubtitle: String {
    switch phase {
    case .granted: return "Glasses ready for coaching."
    case .denied: return "Without camera access, glasses sessions can't start."
    case .requesting: return "Grant camera access in Meta AI."
    case .checking, .idle: return "Just a moment…"
    case .needsRequest: return "Camera access needed."
    }
  }

  // MARK: - Permission flow

  /// **What "granted" means here.** DAT camera permission is granted.
  /// As of MWDATCore 0.7.0 there is no DAT-side microphone permission —
  /// the `Permission` enum has only `.camera`. iOS-native record
  /// permission gates the mic and is prompted at session start by
  /// `AudioSessionManager.requestMicrophonePermission()`.
  private func checkAfterRegistration() async {
    phase = .checking
    let granted: Bool? = await Self.runWithTimeout(
      seconds: Self.statusCheckTimeout
    ) { [sessionManager] in
      // Inline do/catch so we surface the underlying error before the
      // runWithTimeout race resolves — the original `try?` swallowed it
      // and the outer "timed out" message was misleading (it fired
      // immediately on a thrown error rather than after the actual
      // 5s budget). Logging the real error tells us whether the SDK
      // is returning .denied (action: prompt) vs throwing a
      // PermissionError (action: investigate Dev Mode / DAT helper).
      do {
        let value = try await sessionManager.allGlassesPermissionsGranted()
        print("[Retrace.Diag][CTA] allGlassesPermissionsGranted returned: \(value)")
        return value
      } catch {
        print("[Retrace.Diag][CTA] allGlassesPermissionsGranted threw — type=\(String(describing: type(of: error))) value=\(error)")
        return nil
      }
    }
    if granted == nil {
      // Either a real 5s timeout OR the inner closure logged a throw
      // immediately and we got here via that path. The Retrace.Diag
      // log above is the source of truth.
      print("[DATCameraPermissionCTA] allGlassesPermissionsGranted timed out after \(Self.statusCheckTimeout)s — surfacing CTA")
    }
    if granted == true {
      phase = .granted
      onGranted?()
    } else {
      phase = .needsRequest
    }
  }

  private func requestPermission() async {
    phase = .requesting
    // Budget covers the single Meta AI bounce for camera permission.
    // (Earlier revision sized this for two sequential bounces — camera
    // and DAT-side mic — but MWDATCore 0.7.0's `Permission` enum has
    // only `.camera`; mic gating is iOS-native, handled separately.)
    let granted: Bool? = await Self.runWithTimeout(
      seconds: Self.requestPromptTimeout
    ) { [sessionManager] in
      try? await sessionManager.ensureAllGlassesPermissionsGranted()
    }
    if granted == nil {
      print("[DATCameraPermissionCTA] ensureAllGlassesPermissionsGranted timed out after \(Self.requestPromptTimeout)s — re-surfacing CTA")
      phase = .needsRequest
      return
    }
    if granted == true {
      phase = .granted
      onGranted?()
    } else {
      phase = .denied
    }
  }

  /// Race an async operation against a timeout. Returns the operation's
  /// value if it completes first, `nil` if the timeout wins. Cancels
  /// whichever task lost the race. Hoisted from `OnboardingGlassesView`'s
  /// inline copy; this is now the single call site.
  private static func runWithTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async -> T?
  ) async -> T? {
    await withTaskGroup(of: T?.self) { group in
      group.addTask { await operation() }
      group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return nil
      }
      defer { group.cancelAll() }
      return await group.next() ?? nil
    }
  }
}
