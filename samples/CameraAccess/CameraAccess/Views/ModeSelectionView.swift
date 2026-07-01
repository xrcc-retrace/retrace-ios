import MWDATCore
import SwiftUI

enum AppMode {
  case expert
  case learner
  case troubleshoot
}

struct ModeSelectionView: View {
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  @EnvironmentObject private var glassesNav: GlassesNavigationCoordinator
  @EnvironmentObject private var sessionManager: DeviceSessionManager
  @State private var selectedMode: AppMode?

  private let workflows: [LandingWorkflow] = [
    .init(
      title: "Expert Mode",
      subtitle: "Record a workflow for others",
      icon: "video.fill",
      mode: .expert
    ),
    .init(
      title: "Learner Mode",
      subtitle: "Learn workflows with AI",
      icon: "person.wave.2.fill",
      mode: .learner
    ),
    .init(
      title: "Troubleshoot",
      subtitle: "Diagnose a problem and fix",
      icon: "stethoscope",
      mode: .troubleshoot
    ),
  ]

  var body: some View {
    ZStack {
      // Persistent backdrop so no edge reveals system white during transitions.
      Color.backgroundPrimary.ignoresSafeArea()

      // Base layer: the mode selector is always rendered. It stays visible
      // behind the tab view as the tab view slides in/out from the right.
      modeSelectorScreen

      // Overlay layer: the selected mode's tab view slides in from the
      // trailing edge, covering the mode selector. On exit it slides back
      // out, revealing the mode selector already in place (no blink).
      if let mode = selectedMode {
        selectedModeView(for: mode)
          .transition(.move(edge: .trailing))
          .zIndex(1)
      }
    }
    .animation(.easeInOut(duration: 0.35), value: selectedMode)
    .tint(.textPrimary)
    // Glasses-first navigation. The cover appears the moment "Launch on
    // Display" is tapped: first the readiness gate (register + connect +
    // verify a Display-capable device), then — once ready — the lens activates
    // and the cover switches to the "Session on glasses" standby.
    .fullScreenCover(isPresented: Binding(
      get: { glassesNav.phase != .idle },
      set: { if !$0 { glassesNav.exitGlassesMode() } }
    )) {
      switch glassesNav.phase {
      case .preparing:
        GlassesReadinessGateView(wearablesVM: wearablesVM)
      case .active:
        GlassesSessionStandbyView(coordinator: glassesNav, wearables: wearables)
      case .idle:
        EmptyView()
      }
    }
  }

  @ViewBuilder
  private func selectedModeView(for mode: AppMode) -> some View {
    let dismiss = { selectedMode = nil }
    switch mode {
    case .expert:
      ExpertTabView(wearables: wearables, wearablesVM: wearablesVM, onExit: dismiss)
    case .learner:
      LearnerTabView(wearables: wearables, wearablesVM: wearablesVM, onExit: dismiss)
    case .troubleshoot:
      // The intro picker chooses transport (glasses vs iPhone) before the
      // diagnostic session opens — same pattern as the coaching flow.
      TroubleshootIntroView(
        wearables: wearables,
        wearablesVM: wearablesVM,
        serverBaseURL: ServerEndpoint.shared.resolvedBaseURL,
        onExit: dismiss
      )
    }
  }

  private var modeSelectorScreen: some View {
    NavigationStack {
      RetraceScreen {
        ZStack {
          EntryBackdropView()

          ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Spacing.section) {
              heroBlock
                .padding(.top, Spacing.section + 80)

              // Hero, button, and the three mode cards form one compact block
              // near the top — no flexible gap. The footer follows directly.
              launchOnDisplayButton
                .padding(.top, Spacing.lg)

              workflowCards

              versionFooter
            }
            .padding(.horizontal, Spacing.screenPadding)
            .padding(.bottom, Spacing.jumbo)
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerRelativeFrame(.vertical, alignment: .top)
          }
          .scrollBounceBehavior(.always, axes: .vertical)
        }
      }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Image("RetraceWordmark")
            .resizable()
            .scaledToFit()
            .frame(width: 168, height: 28)
            .accessibilityLabel("Retrace")
        }
        ToolbarItem(placement: .topBarTrailing) {
          NavigationLink {
            ServerSettingsView(wearablesVM: wearablesVM)
          } label: {
            Image(systemName: "gearshape")
              .foregroundColor(.textPrimary)
          }
          .accessibilityLabel("Settings")
        }
      }
      .toolbarBackground(.hidden, for: .navigationBar)
    }
  }
}

extension AppMode: Hashable {}

private extension ModeSelectionView {
  var heroBlock: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      Text(greeting)
        .font(.inter(.regular, size: 24))
        .foregroundColor(.textSecondary.opacity(0.7))

      Text("What are we working on today?")
        .font(.retraceFace(.semibold, size: 28))
        .foregroundColor(.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  var launchOnDisplayButton: some View {
    LaunchOnDisplayButton(isReady: sessionManager.hasDisplayCapableDevice) {
      glassesNav.beginLaunch()
    }
  }

  var workflowCards: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      ForEach(workflows) { workflow in
        ModeCard(
          icon: workflow.icon,
          title: workflow.title,
          subtitle: workflow.subtitle,
          isEnabled: true
        ) {
          selectedMode = workflow.mode
        }
      }
    }
  }

  var versionFooter: some View {
    Text("Retrace v1.0")
      .font(.system(size: 11, weight: .regular))
      .foregroundColor(.textSecondary.opacity(0.45))
      .tracking(0.4)
      .frame(maxWidth: .infinity, alignment: .center)
  }

  var greeting: String {
    let hour = Calendar.current.component(.hour, from: Date())
    switch hour {
    case 5..<12:
      return "Good morning!"
    case 12..<18:
      return "Good afternoon!"
    default:
      return "Good evening!"
    }
  }
}

private struct LandingWorkflow: Identifiable {
  let title: String
  let subtitle: String
  let icon: String
  let mode: AppMode

  var id: AppMode { mode }
}

/// The flagship "Launch on Display" CTA. A luminous brand-gold treatment that
/// signals this is the headline new feature: a slowly rotating angular gold
/// gradient, a bright sheen band that sweeps across like the lens catching
/// light, a breathing accent glow, and a press spring. Continuous motion is
/// driven by `TimelineView(.animation)` (same cadence as the entry backdrop).
private struct LaunchOnDisplayButton: View {
  /// True only when a connected, Display-capable device is observed
  /// (`DeviceSessionManager.hasDisplayCapableDevice`). Drives both the active
  /// look AND pressability — the inactive variant is not a `Button` at all, so
  /// it cannot be tapped.
  let isReady: Bool
  let action: () -> Void
  @State private var start = Date()

  var body: some View {
    Group {
      if isReady {
        // Active: the luminous animated CTA, pressable.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
          let t = context.date.timeIntervalSince(start)
          Button(action: action) {
            label(t: t)
          }
          .buttonStyle(LaunchPressStyle())
        }
        .transition(.opacity)
      } else {
        // Inactive: static, dimmed, NON-pressable (no Button), with a hint.
        inactiveLabel
          .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: 0.3), value: isReady)
    .accessibilityLabel("Launch on Display glasses")
    .accessibilityHint(isReady ? "" : "Connect your Ray-Ban Display glasses to enable")
  }

  /// Disabled treatment — muted surface, lock glyph, and a caption telling the
  /// user what's missing. Deliberately NOT a `Button` so it's unpressable.
  private var inactiveLabel: some View {
    VStack(spacing: Spacing.sm) {
      HStack(spacing: Spacing.md) {
        Image(systemName: "eyeglasses")
          .font(.system(size: 19, weight: .semibold))
        Text("Launch on Display")
          .font(.retraceFace(.semibold, size: 17))
        Spacer(minLength: 0)
        Image(systemName: "lock.fill")
          .font(.system(size: 13, weight: .semibold))
          .opacity(0.7)
      }
      .foregroundColor(.textSecondary)
      .padding(.horizontal, Spacing.xl)
      .padding(.vertical, Spacing.lg)
      .frame(maxWidth: .infinity)
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(Color.surfaceRaised)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(Color.borderSubtle, lineWidth: 1)
      )

      Text("Connect your Ray-Ban Display glasses to launch")
        .font(.inter(.regular, size: 13))
        .foregroundColor(.textTertiary)
        .frame(maxWidth: .infinity, alignment: .center)
    }
  }

  @ViewBuilder
  private func label(t: TimeInterval) -> some View {
    // No sliding sheen. The whole button gently breathes: a soft scale pulse +
    // a glow that swells and fades in sync. Clean, premium, not tacky.
    let cornerRadius: CGFloat = 16
    let phase = 0.5 + 0.5 * sin(t * 1.5)               // 0 … 1, ~4.2s period
    let glowOpacity = 0.28 + 0.32 * phase              // 0.28 … 0.60
    let glowRadius = CGFloat(13 + 11 * phase)          // 13 … 24
    let pulse = CGFloat(1.0 + 0.016 * phase)           // 1.000 … 1.016

    HStack(spacing: Spacing.md) {
      Image(systemName: "eyeglasses")
        .font(.system(size: 19, weight: .semibold))
      Text("Launch on Display")
        .font(.retraceFace(.semibold, size: 17))
      Spacer(minLength: 0)
      Image(systemName: "sparkles")
        .font(.system(size: 14, weight: .semibold))
        .opacity(0.9)
    }
    .foregroundColor(.backgroundPrimary)
    .padding(.horizontal, Spacing.xl)
    .padding(.vertical, Spacing.lg)
    .frame(maxWidth: .infinity)
    // Clean, static brand-gold fill.
    .background(
      LinearGradient(
        colors: [Color.appBadgeAccent, Color.appPrimary],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
    )
    // The pulse + breathing glow.
    .scaleEffect(pulse)
    .shadow(color: Color.appPrimary.opacity(glowOpacity), radius: glowRadius, x: 0, y: 6)
  }
}

private struct LaunchPressStyle: SwiftUI.ButtonStyle {
  func makeBody(configuration: SwiftUI.ButtonStyleConfiguration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
      .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
  }
}

private struct EntryBackdropView: View {
  // Tune these to reshape the diamond motion. Separation fractions are
  // expressed as a fraction of motifSize: 0 = fully overlapping diamonds,
  // 1 = fully apart.
  private let baseSeparationFraction: CGFloat = 0.0
  private let maxSeparationFraction: CGFloat = 0.75
  private let animationSpeed: Float = 0.8
  private let verticalOffset: CGFloat = 120

  // Shader visual constants — kept here so the shader argument list reads
  // declaratively rather than as a stack of bare floats.
  private let opacity: Float = 0.96
  private let pixelScale: Float = 1.0

  // Anchor for relative time. Using timeIntervalSinceReferenceDate would
  // overflow Float precision (~7.7e8) and freeze the animation. @State so
  // the anchor survives parent re-renders (tab push/pop) — otherwise
  // elapsed snaps back to 0 each time and the shader jitters.
  @State private var startDate = Date()

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
      GeometryReader { proxy in
        let size = proxy.size
        let motifSize = max(min(size.width * 0.84, size.height * 0.44), 280)
        let center = CGPoint(x: size.width * 0.42, y: size.height * 0.22 + verticalOffset)
        let elapsed = Float(context.date.timeIntervalSince(startDate))

        Rectangle()
          .fill(Color.backgroundPrimary)
          .colorEffect(
            Shader(
              function: .init(library: .default, name: "diamondLogoDither"),
              arguments: [
                .float2(Float(size.width), Float(size.height)),
                .float2(Float(center.x), Float(center.y)),
                .float(Float(motifSize)),
                .float(Float(motifSize * baseSeparationFraction)),
                .float(Float(motifSize * maxSeparationFraction)),
                .float(elapsed),
                .float(animationSpeed),
                .float(opacity),
                .float(pixelScale),
              ]
            )
          )
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    .ignoresSafeArea()
  }
}
