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

/// Composes the two glasses-session chrome elements — the top status banner
/// and the camera-feed toggle below the lens — over a transparent full-screen
/// layer. Dropped into each session view's outer ZStack **only** when the
/// active transport is `.glasses`. Empty regions are non-interactive so taps
/// fall through to the HUD lens beneath.
struct GlassesSessionChrome: View {
  let deviceName: String
  let status: GlassesSessionStatus
  @Binding var showCameraFeed: Bool

  var body: some View {
    GeometryReader { proxy in
      // The lens is a centered square inset by `viewportInset` on each side
      // (see RayBanHUDLayoutTokens). Anchor the toggle just below its bottom
      // edge so it tracks the lens across device sizes and orientations.
      let lensSide = min(proxy.size.width, proxy.size.height)
        - RayBanHUDLayoutTokens.viewportInset * 2
      let toggleY = proxy.size.height / 2 + lensSide / 2 + Spacing.xl

      ZStack(alignment: .top) {
        CameraFeedToggle(showCameraFeed: $showCameraFeed)
          .position(x: proxy.size.width / 2, y: toggleY)

        GlassesSessionBanner(deviceName: deviceName, status: status)
          .padding(.top, proxy.safeAreaInsets.top + Spacing.xl)
          .frame(maxWidth: .infinity)
      }
      // Fill the reader so `.position` resolves in full-screen coordinates
      // (matching the lens, which is centered in the full bounds).
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .ignoresSafeArea()
  }
}
