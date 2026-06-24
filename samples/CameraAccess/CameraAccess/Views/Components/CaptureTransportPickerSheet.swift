import MWDATCore
import SwiftUI

struct CaptureTransportPickerSheet: View {
  let title: String
  let subtitle: String?
  let glassesActionLabel: String
  let iPhoneActionLabel: String
  /// Live registration state from the host. When `.registered` AND
  /// DAT camera permission is missing, the embedded permission CTA
  /// surfaces and the glasses button is disabled. Used by Troubleshoot
  /// and Expert recording — both need DAT camera permission for the
  /// glasses transport.
  let registrationState: RegistrationState
  let onSelect: (CaptureTransport) -> Void

  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var sessionManager: DeviceSessionManager

  init(
    title: String,
    subtitle: String? = nil,
    glassesActionLabel: String,
    iPhoneActionLabel: String,
    registrationState: RegistrationState,
    onSelect: @escaping (CaptureTransport) -> Void
  ) {
    self.title = title
    self.subtitle = subtitle
    self.glassesActionLabel = glassesActionLabel
    self.iPhoneActionLabel = iPhoneActionLabel
    self.registrationState = registrationState
    self.onSelect = onSelect
  }

  /// True when paired but DAT camera permission isn't `.granted`. The
  /// glasses transport would later fail at the pre-session gate, so we
  /// disable that option here. iPhone transport stays available.
  private var glassesBlockedByMissingPermission: Bool {
    registrationState == .registered &&
      sessionManager.cameraPermission != .granted
  }

  /// Detent grows when we need to surface the permission CTA card
  /// alongside the two transport buttons.
  private var detentHeight: CGFloat {
    let base: CGFloat = subtitle == nil ? 260 : 300
    return glassesBlockedByMissingPermission ? base + 120 : base
  }

  var body: some View {
    VStack(spacing: Spacing.xl) {
      VStack(spacing: Spacing.xs) {
        Text(title)
          .font(.retraceTitle3)
          .foregroundColor(.textPrimary)
          .multilineTextAlignment(.center)
        if let subtitle {
          Text(subtitle)
            .font(.retraceCallout)
            .foregroundColor(.textSecondary)
            .multilineTextAlignment(.center)
        }
      }
      .padding(.top, Spacing.xl)
      .padding(.horizontal, Spacing.screenPadding)

      VStack(spacing: Spacing.md) {
        // Pre-flight DAT camera permission card. Self-hides when not
        // registered; surfaces the "Allow" CTA when registered-but-not-
        // granted; shows "granted ✓" once user completes the Meta AI
        // round-trip. Same component used in onboarding / HomeScreen /
        // Settings — single state machine, three call sites.
        DATCameraPermissionCTA(
          registrationState: registrationState,
          style: .card
        )

        CustomButton(
          title: glassesActionLabel,
          icon: "eyeglasses",
          style: .primary,
          isDisabled: glassesBlockedByMissingPermission
        ) {
          select(.glasses)
        }

        CustomButton(
          title: iPhoneActionLabel,
          icon: "iphone",
          style: .secondary,
          isDisabled: false
        ) {
          select(.iPhone)
        }
      }
      .padding(.horizontal, Spacing.screenPadding)

      Spacer(minLength: 0)
    }
    .padding(.bottom, Spacing.xxl)
    .frame(maxWidth: .infinity, alignment: .top)
    .background(Color.backgroundPrimary)
    .presentationDetents([.height(detentHeight)])
    .presentationDragIndicator(.visible)
    .presentationBackground(Color.backgroundPrimary)
  }

  private func select(_ transport: CaptureTransport) {
    onSelect(transport)
    dismiss()
  }
}
