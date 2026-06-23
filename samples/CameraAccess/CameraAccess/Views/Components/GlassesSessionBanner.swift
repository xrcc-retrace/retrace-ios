import SwiftUI

/// Mode-agnostic status payload for `GlassesSessionBanner`. Each session view
/// computes this from its own state (Gemini connection state, troubleshoot
/// phase, recording state) so the banner itself stays dumb.
struct GlassesSessionStatus: Equatable {
  /// Short uppercase label, e.g. "LIVE", "REC", "DIAGNOSING".
  let label: String
  /// Dot color — green when healthy/live, red while recording, yellow while
  /// connecting, gray when idle.
  let dotColor: Color
  /// Whether the dot should pulse (used for transient/active states like
  /// CONNECTING or REC). Suppressed automatically under Reduce Motion.
  let pulsing: Bool
}

/// Top-of-screen status pill shown only during **glasses** sessions. Signals
/// "this session is running on your glasses, not the phone" by surfacing the
/// connected device name plus a mode-appropriate live status.
///
/// This is phone-app chrome — it deliberately uses the app's `.glassPanel`
/// surface + Retrace type tokens, NOT the Ray-Ban lens design language (see
/// `Views/RayBanHUD/DESIGN.md`). It must read as part of the mobile UI around
/// the lens, never as part of the lens.
struct GlassesSessionBanner: View {
  let deviceName: String
  let status: GlassesSessionStatus

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pulse = false

  var body: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "eyeglasses")
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.textSecondary)

      Text(deviceName)
        .font(.retraceFace(.semibold, size: 12))
        .foregroundColor(.textPrimary)
        .lineLimit(1)
        .truncationMode(.middle)

      Text("|")
        .font(.retraceCaption1)
        .foregroundColor(.textTertiary)

      HStack(spacing: Spacing.xs) {
        Circle()
          .fill(status.dotColor)
          .frame(width: 7, height: 7)
          .opacity(shouldPulse ? (pulse ? 1.0 : 0.4) : 1.0)

        Text(status.label)
          .font(.retraceOverline)
          .tracking(1)
          .foregroundColor(.textSecondary)
      }
    }
    .padding(.horizontal, Spacing.xl)
    .padding(.vertical, Spacing.md)
    .glassPanel(cornerRadius: Radius.full)
    .fixedSize()
    .onAppear { startPulseIfNeeded() }
    .onChange(of: shouldPulse) { _, _ in startPulseIfNeeded() }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Running on \(deviceName), \(status.label)")
  }

  private var shouldPulse: Bool { status.pulsing && !reduceMotion }

  private func startPulseIfNeeded() {
    if shouldPulse {
      withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
        pulse = true
      }
    } else {
      pulse = false
    }
  }
}
