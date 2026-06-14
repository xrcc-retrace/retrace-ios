import SwiftUI

/// Recovery sheet shown by the coaching / troubleshoot session views
/// when the audio readiness check fails — `AVAudioSession` configured
/// and `AVAudioEngine` started successfully, but the first PCM buffer
/// didn't arrive within the readiness timeout. Symptom is most often
/// a slow BT HFP SCO link setup on cold-boot Display glasses (observed
/// taking 3–8 s instead of the typical sub-second). Surfaced via
/// `.sheet(isPresented: $viewModel.pendingAudioRetry)`.
///
/// **Why distinct from `PermissionRequiredSheet`:** the recovery action
/// is different. Permission failure → deep-link to Meta AI to grant.
/// Audio failure → just retry the session (no Meta AI bounce needed,
/// permissions are verified by the time we reach the audio step).
///
/// Both sheets follow the same shape (icon, title, subtitle, CTA,
/// cancel) for visual consistency. If we ever add a third recovery
/// case, refactor to a single `SessionRecoverySheet(kind:)` enum-driven
/// view.
struct AudioRecoverySheet: View {
  /// Fires when the user taps "Try again". Host wires this to
  /// `viewModel.retryAfterAudioFailure()`. The retry method handles
  /// flipping `pendingAudioRetry = false` and re-running session
  /// start in place.
  var onRetry: () -> Void

  /// Fires when the user taps "Cancel". Host flips
  /// `pendingAudioRetry = false` to dismiss; the user is then back on
  /// the session view with `voiceStatus = "Audio not connecting"` and
  /// can exit via the standard back-out path.
  var onCancel: () -> Void

  var body: some View {
    VStack(spacing: Spacing.lg) {
      VStack(spacing: Spacing.sm) {
        Image(systemName: "waveform.slash")
          .font(.system(size: 32, weight: .semibold))
          .foregroundColor(.textPrimary)
          .padding(.bottom, Spacing.xs)

        Text("Audio not connecting")
          .font(.retraceTitle2)
          .foregroundColor(.textPrimary)
          .multilineTextAlignment(.center)

        Text("Your glasses microphone didn't start streaming in time. This usually clears on a second attempt — make sure the glasses are powered on and worn.")
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
          title: "Try again",
          icon: "arrow.clockwise",
          style: .primary,
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
