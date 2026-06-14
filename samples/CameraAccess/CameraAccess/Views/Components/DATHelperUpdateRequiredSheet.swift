import SwiftUI

/// Recovery sheet shown by the coaching / troubleshoot session views when
/// `manager.acquire(consumerLabel: "gemini-live")` (or its inline
/// `wearables.createSession` fallback) throws
/// `DeviceSessionError.datAppOnTheGlassesUpdateRequired` — the SDK's
/// signal that the DAT helper app on the glasses needs to be updated
/// (or installed for the first time) through Meta AI before any
/// `DeviceSession` can start.
///
/// Surfaced via `.sheet(isPresented: $viewModel.pendingDATHelperUpdate)`.
/// Sibling of `PermissionRequiredSheet` (permissions denied) and
/// `AudioRecoverySheet` (BT HFP SCO setup timeout) — same shape, same
/// interaction model, different recovery action. The "Update glasses app"
/// CTA deep-links into Meta AI via the SDK's built-in
/// `wearables.openDATGlassesAppUpdate()` (mirrors the Server Settings
/// affordance for the lens-display path).
///
/// **Why distinct from the other two recovery sheets:** the user action
/// here happens entirely outside our app (in Meta AI), and the gating
/// signal is a typed `DeviceSessionError` case, not a timeout. Lumping
/// it into `PermissionRequiredSheet` would conflate "user must grant
/// access in Meta AI" (permissions sheet) with "user must update DAT
/// helper in Meta AI" (this sheet) — same destination, fundamentally
/// different remediation.
struct DATHelperUpdateRequiredSheet: View {
  /// Fires when the user taps "Update glasses app". Host wires this to
  /// `wearablesVM.openDATGlassesAppUpdate()` (which calls the SDK's
  /// `wearables.openDATGlassesAppUpdate()` deep link). The user then
  /// completes the update flow inside Meta AI and returns; they tap
  /// "Try again" to re-run session start.
  var onOpenMetaAI: () -> Void

  /// Fires when the user taps "Try again" after completing the update
  /// inside Meta AI. Host wires this to
  /// `viewModel.retryAfterDATHelperUpdate()`. The retry method handles
  /// flipping `pendingDATHelperUpdate = false` and re-running session
  /// start in place.
  var onRetry: () -> Void

  /// Fires when the user taps "Cancel". Host flips
  /// `pendingDATHelperUpdate = false` to dismiss; the user is back on
  /// the session view with `voiceStatus = "Update needed on glasses"`
  /// and can exit via the standard back-out path.
  var onCancel: () -> Void

  var body: some View {
    VStack(spacing: Spacing.lg) {
      VStack(spacing: Spacing.sm) {
        Image(systemName: "arrow.down.app.fill")
          .font(.system(size: 32, weight: .semibold))
          .foregroundColor(.textPrimary)
          .padding(.bottom, Spacing.xs)

        Text("Update needed on glasses")
          .font(.retraceTitle2)
          .foregroundColor(.textPrimary)
          .multilineTextAlignment(.center)

        Text("The DAT helper app on your glasses is out of date. Open Meta AI to update it, then come back and tap Try again.")
          .font(.retraceCallout)
          .foregroundColor(.textSecondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.top, Spacing.xl)
      .padding(.horizontal, Spacing.screenPadding)

      Spacer(minLength: 0)

      VStack(spacing: Spacing.md) {
        CustomButton(
          title: "Update glasses app",
          icon: "arrow.up.right.square",
          style: .primary,
          isDisabled: false,
          action: onOpenMetaAI
        )

        CustomButton(
          title: "Try again",
          icon: "arrow.clockwise",
          style: .secondary,
          isDisabled: false,
          action: onRetry
        )

        CustomButton(
          title: "Cancel",
          style: .ghost,
          isDisabled: false,
          action: onCancel
        )
      }
      .padding(.horizontal, Spacing.screenPadding)
      .padding(.bottom, Spacing.xl)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.backgroundPrimary)
    .presentationDetents([.medium])
    .presentationDragIndicator(.visible)
  }
}
