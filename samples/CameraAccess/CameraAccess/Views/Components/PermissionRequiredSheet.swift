import MWDATCore
import SwiftUI

/// Recovery sheet shown by the coaching / troubleshoot session views when
/// the pre-session DAT camera permission gate fails on a `.glasses`
/// transport session. Surfaced via
/// `.sheet(isPresented: $viewModel.pendingGlassesCameraPermission)`.
///
/// Wraps the shared `DATCameraPermissionCTA` component with a title +
/// subtitle + cancel button. The CTA's `onGranted` callback flows up
/// to the caller via `onGranted` so the session VM can re-run its
/// start sequence (`retryAfterPermissionGrant()`).
///
/// On cancel the sheet just dismisses; the user is back on the session
/// view with `voiceStatus = "Glasses camera permission required"` and
/// can exit via the existing back-out path. We don't auto-dismiss the
/// session here because tearing down the fullScreenCover requires
/// reaching back into the parent view's `presentedCoaching` /
/// `presentedTransport` binding, which we deliberately don't plumb.
struct PermissionRequiredSheet: View {
  /// Fires when the user grants permission inside the embedded CTA.
  /// Host wires this to `viewModel.retryAfterPermissionGrant()` + a
  /// flip of `pendingGlassesCameraPermission = false` so the sheet
  /// dismisses cleanly.
  var onGranted: () -> Void

  /// Fires when the user explicitly cancels. Host flips
  /// `pendingGlassesCameraPermission = false` to dismiss.
  var onCancel: () -> Void

  var body: some View {
    VStack(spacing: Spacing.lg) {
      VStack(spacing: Spacing.sm) {
        Image(systemName: "camera.fill")
          .font(.system(size: 32, weight: .semibold))
          .foregroundColor(.textPrimary)
          .padding(.bottom, Spacing.xs)

        Text("Camera access needed")
          .font(.retraceTitle2)
          .foregroundColor(.textPrimary)
          .multilineTextAlignment(.center)

        Text("Your glasses need camera access to run this session. Grant it in the Meta AI app to continue.")
          .font(.retraceCallout)
          .foregroundColor(.textSecondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.top, Spacing.xl)
      .padding(.horizontal, Spacing.screenPadding)

      // We only reach this sheet from a session view, which is only
      // mounted post-registration — hardcoding `.registered` is safe
      // and avoids plumbing `wearablesVM` through to the sheet.
      DATCameraPermissionCTA(
        registrationState: .registered,
        style: .card,
        onGranted: onGranted
      )
      .padding(.horizontal, Spacing.screenPadding)

      Spacer(minLength: 0)

      CustomButton(
        title: "Cancel",
        style: .ghost,
        isDisabled: false,
        action: onCancel
      )
      .padding(.horizontal, Spacing.screenPadding)
      .padding(.bottom, Spacing.xl)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.backgroundPrimary)
    .presentationDetents([.medium])
    .presentationDragIndicator(.visible)
  }
}
