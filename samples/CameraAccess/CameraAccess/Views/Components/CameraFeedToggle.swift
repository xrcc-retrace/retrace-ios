import SwiftUI

/// App-themed backdrop shown behind the Ray-Ban lens during glasses sessions
/// when the raw camera feed is hidden (the default). A subtle branded gradient
/// so the lens reads as the headline and the screen still feels like "the app",
/// not a black void or a video mirror.
struct GlassesThemedBackground: View {
  var body: some View {
    LinearGradient(
      colors: [Color.backgroundPrimary, Color.surfaceBase.opacity(0.5)],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
    .ignoresSafeArea()
  }
}

/// Pill that reveals / hides the live glasses camera feed behind the lens.
/// Phone-app chrome (Retrace `.glassPanel` + type tokens), intentionally
/// distinct from the Ray-Ban lens design language.
struct CameraFeedToggle: View {
  @Binding var showCameraFeed: Bool

  var body: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.25)) {
        showCameraFeed.toggle()
      }
    } label: {
      HStack(spacing: Spacing.sm) {
        Image(systemName: showCameraFeed ? "eye.fill" : "eye.slash")
          .font(.system(size: 12, weight: .medium))
        Text(showCameraFeed ? "Hide camera" : "Show camera")
          .font(.retraceFace(.medium, size: 13))
      }
      .foregroundColor(showCameraFeed ? .textPrimary : .textSecondary)
      .padding(.horizontal, Spacing.xl)
      .padding(.vertical, Spacing.md)
      .frame(minHeight: 44)
      .glassPanel(cornerRadius: Radius.full)
      .overlay(
        // Subtle "on" tint — stays within the app's non-HUD palette.
        Capsule()
          .fill(Color.textPrimary.opacity(showCameraFeed ? 0.08 : 0.0))
      )
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(showCameraFeed ? "Hide glasses camera feed" : "Show glasses camera feed")
  }
}

/// Non-blocking notice shown during a glasses session when the lens output was
/// requested but the connected glasses have no display — so the session runs
/// camera-only with the phone UI. This is the visible difference between
/// "Phone + non-display Ray-Bans" and "Phone + display Ray-Bans"; without it the
/// non-display case silently no-op'd the lens. Same `.glassPanel` chrome as the
/// session banner, warning-toned icon.
struct GlassesLensUnavailableNotice: View {
  var body: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "eyeglasses")
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.semanticInfo)
      Text("No lens display · camera only")
        .font(.retraceFace(.medium, size: 12))
        .foregroundColor(.textSecondary)
        .lineLimit(1)
    }
    .padding(.horizontal, Spacing.xl)
    .padding(.vertical, Spacing.md)
    .glassPanel(cornerRadius: Radius.full)
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("These glasses have no lens display; running camera-only")
  }
}

/// Composes the two glasses-session chrome elements — the top status banner
/// and the camera-feed toggle below the lens — over a transparent full-screen
/// layer. Dropped into each session view's outer ZStack **only** when the
/// active transport is `.glasses`. Empty regions are non-interactive so taps
/// fall through to the HUD lens beneath.
struct GlassesSessionChrome: View {
  let deviceName: String
  let status: GlassesSessionStatus
  /// True when the lens was requested but the connected glasses can't display
  /// it → show the camera-only notice above the device banner.
  var lensUnavailable: Bool = false
  @Binding var showCameraFeed: Bool

  var body: some View {
    GeometryReader { proxy in
      // The lens is a centered square inset by `viewportInset` on each side
      // (see RayBanHUDLayoutTokens). Anchor the banner just above the lens's
      // top edge and the toggle just below its bottom edge — symmetric gaps
      // of `Spacing.xl` so both hug the lens across device sizes/orientations.
      let lensSide = min(proxy.size.width, proxy.size.height)
        - RayBanHUDLayoutTokens.viewportInset * 2
      let centerY = proxy.size.height / 2
      let bannerY = centerY - lensSide / 2 - Spacing.xl
      let toggleY = centerY + lensSide / 2 + Spacing.xl

      ZStack {
        VStack(spacing: Spacing.sm) {
          if lensUnavailable {
            GlassesLensUnavailableNotice()
              .transition(.move(edge: .top).combined(with: .opacity))
          }
          GlassesSessionBanner(deviceName: deviceName, status: status)
        }
        .animation(.easeInOut(duration: 0.25), value: lensUnavailable)
        .position(x: proxy.size.width / 2, y: bannerY)

        CameraFeedToggle(showCameraFeed: $showCameraFeed)
          .position(x: proxy.size.width / 2, y: toggleY)
      }
      // Fill the reader so `.position` resolves in full-screen coordinates
      // (matching the lens, which is centered in the full bounds).
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .ignoresSafeArea()
  }
}
