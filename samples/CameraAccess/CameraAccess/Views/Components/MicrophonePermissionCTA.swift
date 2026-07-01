import AVFoundation
import SwiftUI
import UIKit

/// iOS microphone permission prompt — the audio-side sibling of
/// `DATCameraPermissionCTA`, mounted right underneath it on every surface that
/// grants glasses prerequisites (Settings, HomeScreen, Onboarding).
///
/// **Why this exists.** Voice coaching needs the iOS record permission. It used
/// to be requested lazily, buried inside the audio arm
/// (`GlassesNavigationCoordinator.armPersistentAudio` /
/// `GeminiLiveSessionBase`), so a user could reach a live glasses session with
/// the mic never granted — the engine starts on a dead route, buffers never
/// flow, and the whole session is silent while otherwise looking healthy. We
/// pull that grant UP FRONT into the same deliberate permission surfaces as the
/// camera, so it's done once in Settings/Onboarding rather than impromptu
/// mid-flow.
///
/// **Camera vs microphone.** The camera permission is a DAT-SDK permission and
/// routes through the Meta AI deep-link (`DATCameraPermissionCTA`). The
/// microphone is iOS-native — `MWDATCore.Permission` has only `.camera` as of
/// 0.7.0 — so this fires the standard iOS prompt (`AVAudioApplication`) and,
/// once denied, deep-links to iOS Settings. Same placement and look, different
/// backend.
///
/// **What it does.**
///   - `.undetermined` → "Allow" fires the one-time iOS mic prompt.
///   - `.denied` → "Open Settings" deep-links to Settings › Retrace › Microphone
///     (the iOS prompt no-ops after a denial, so Settings is the only path back).
///   - `.granted` → success state.
/// Re-reads the live status whenever the app returns to the foreground so a
/// grant made in Settings reflects immediately.
struct MicrophonePermissionCTA: View {
  /// Visual variant — mirrors `DATCameraPermissionCTA.Style` so the two sit
  /// together cleanly on any surface.
  var style: Style = .button

  /// Fires once when permission transitions to `.granted` (onboarding uses this
  /// to auto-advance; Settings / HomeScreen leave it nil).
  var onGranted: (() -> Void)? = nil

  enum Style {
    case button  // primary CustomButton — onboarding + HomeScreen
    case card    // rounded surface row — Settings
  }

  @State private var status: AVAudioApplication.recordPermission =
    AVAudioApplication.shared.recordPermission
  @State private var requesting = false
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openURL) private var openURL

  var body: some View {
    Group {
      switch style {
      case .button: buttonStyleBody
      case .card:   cardStyleBody
      }
    }
    .onAppear { refresh() }
    .onChange(of: scenePhase) { _, phase in
      // The user may grant from iOS Settings via the denied CTA — re-read on
      // foreground so the card settles to the success state without a relaunch.
      if phase == .active { refresh() }
    }
  }

  // MARK: - Style: button (onboarding + HomeScreen)

  @ViewBuilder
  private var buttonStyleBody: some View {
    switch status {
    case .granted:
      CustomButton(title: "Microphone access granted", icon: "checkmark",
                   style: .secondary, isDisabled: true) {}
    case .denied:
      CustomButton(title: "Enable microphone in Settings", icon: "mic.slash.fill",
                   style: .primary, isDisabled: false) { openAppSettings() }
    default:  // .undetermined
      CustomButton(title: requesting ? "Requesting…" : "Allow microphone access",
                   icon: "mic.fill", style: .primary, isDisabled: requesting) {
        requestMicrophone()
      }
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

      if status == .granted {
        EmptyView()
      } else if requesting {
        ProgressView().controlSize(.small)
      } else {
        Button {
          status == .denied ? openAppSettings() : requestMicrophone()
        } label: {
          Text(status == .denied ? "Settings" : "Allow")
            .font(.retraceCaption1)
            .fontWeight(.semibold)
            .foregroundColor(.backgroundPrimary)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .background(Color.textPrimary)
            .cornerRadius(Radius.full)
        }
        .buttonStyle(ScaleButtonStyle())
      }
    }
    .padding(14)
    .background(Color.surfaceRaised)
    .cornerRadius(Radius.md)
  }

  // MARK: - Copy

  private var cardIconName: String {
    switch status {
    case .granted: return "checkmark.circle.fill"
    case .denied:  return "exclamationmark.triangle.fill"
    default:       return "mic.fill"
    }
  }

  private var cardIconColor: Color {
    switch status {
    case .granted: return .semanticSuccess
    case .denied:  return .yellow
    default:       return .textSecondary
    }
  }

  private var cardTitle: String {
    switch status {
    case .granted: return "Microphone access granted"
    case .denied:  return "Microphone access denied"
    default:       return "Allow microphone access"
    }
  }

  private var cardSubtitle: String {
    switch status {
    case .granted: return "The AI can hear you during coaching."
    case .denied:  return "Without the mic, coaching sessions are silent. Enable it in Settings."
    default:       return "Coaching needs the mic so the AI can hear you."
    }
  }

  // MARK: - Actions

  private func refresh() { status = AVAudioApplication.shared.recordPermission }

  /// Fire the one-time iOS mic prompt (only shows an alert when `.undetermined`;
  /// after a denial it returns immediately, which is why denied → Settings).
  private func requestMicrophone() {
    requesting = true
    AVAudioApplication.requestRecordPermission { granted in
      DispatchQueue.main.async {
        self.requesting = false
        self.status = granted ? .granted : .denied
        if granted { self.onGranted?() }
      }
    }
  }

  private func openAppSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
  }
}
