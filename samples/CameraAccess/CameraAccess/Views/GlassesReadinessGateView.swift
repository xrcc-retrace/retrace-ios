//
// GlassesReadinessGateView.swift
//
// Shown on "Launch on Display" BEFORE the "Session on glasses" standby. Runs
// the full DAT readiness chain (per the mwdat-ios permissions-registration +
// display-access skills) and only lets the coordinator activate the lens once
// the glasses are genuinely ready:
//
//   1. Registered with Meta AI            (WearablesViewModel.registrationState)
//   2. A connected, DISPLAY-capable device(DeviceSessionManager.hasDisplayCapableDevice)
//      — distinguishes "no glasses awake" from "connected but not Display
//        (e.g. Oakley Vanguard)".
//   3. Firmware compatible                (WearablesViewModel.requiresFirmwareUpdate)
//   4. On-glasses DAT helper app current  (LensDisplayCoordinator.requiresDATAppUpdate)
//
// When every check passes the gate auto-advances (after a short "ready" beat)
// by calling `coordinator.enterGlassesMode()`, which activates the lens and
// flips the cover to `GlassesSessionStandbyView`.
//

import MWDATCore
import SwiftUI

struct GlassesReadinessGateView: View {
  @EnvironmentObject private var coordinator: GlassesNavigationCoordinator
  @EnvironmentObject private var sessionManager: DeviceSessionManager
  @EnvironmentObject private var lensDisplayCoordinator: LensDisplayCoordinator
  @ObservedObject var wearablesVM: WearablesViewModel

  /// The single resolved readiness state, derived from the live DAT signals.
  enum Step: Equatable {
    case needsRegistration   // not registered → deep-link to Meta AI
    case registering         // registration handshake in progress
    case firmwareUpdate      // a paired device needs a firmware update
    case datAppUpdate        // on-glasses DAT helper app needs an update
    case noGlasses           // registered, but nothing reachable/awake
    case noDisplayDevice     // reachable glasses, but not Display-capable
    case cameraPermission    // Display device present, but DAT camera permission not granted
    case ready               // registered + connected Display device + camera granted
  }

  private var step: Step {
    if wearablesVM.requiresFirmwareUpdate { return .firmwareUpdate }
    if lensDisplayCoordinator.requiresDATAppUpdate { return .datAppUpdate }
    switch wearablesVM.registrationState {
    case .registering:
      return .registering
    case .registered:
      // A Display-capable device is connected — but the lens Display capability
      // also needs DAT camera permission. `DeviceSessionManager.acquire("lens")`
      // hard-blocks on `cameraPermission != .granted`, so gate `.ready` on it
      // here or the downstream acquire throws `cameraPermissionDenied` and the
      // lens silently never activates.
      if sessionManager.hasDisplayCapableDevice {
        return sessionManager.cameraPermission == .granted ? .ready : .cameraPermission
      }
      if sessionManager.hasAnyActiveDevice { return .noDisplayDevice }
      return .noGlasses
    default:                       // .available / .unavailable
      return .needsRegistration
    }
  }

  private var isReady: Bool { step == .ready }

  var body: some View {
    ZStack {
      Color.backgroundPrimary.ignoresSafeArea()

      VStack(spacing: Spacing.section) {
        Spacer()

        Image(systemName: iconName)
          .font(.system(size: 52, weight: .regular))
          .foregroundColor(.textPrimary)

        VStack(spacing: Spacing.sm) {
          Text(title)
            .font(.retraceFace(.semibold, size: 24))
            .foregroundColor(.textPrimary)
            .multilineTextAlignment(.center)
          Text(subtitle)
            .font(.inter(.regular, size: 16))
            .foregroundColor(.textSecondary.opacity(0.8))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }

        if showsSpinner {
          ProgressView()
            .tint(.textPrimary)
            .padding(.top, Spacing.xs)
        }

        Spacer()

        VStack(spacing: Spacing.md) {
          // Camera-permission step hosts the shared, timeout-hardened CTA
          // (probe → request via Meta AI → granted/denied/retry). It writes the
          // result into `DeviceSessionManager.cameraPermission`; when that flips
          // to `.granted`, `step` recomputes to `.ready` and `.task(id: isReady)`
          // auto-advances. The component IS the CTA here, so `cta` is nil for
          // this step (see `cta` below) — no double button.
          if step == .cameraPermission {
            DATCameraPermissionCTA(registrationState: .registered, style: .button)
          }

          if let cta {
            Button(action: cta.action) {
              Text(cta.title)
                .font(.retraceFace(.semibold, size: 16))
                .foregroundColor(.backgroundPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.lg)
                .background(
                  RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.appPrimary)
                )
            }
          }

          Button {
            coordinator.exitGlassesMode()
          } label: {
            Text("Cancel")
              .font(.inter(.medium, size: 16))
              .foregroundColor(.textSecondary)
              .frame(maxWidth: .infinity)
              .padding(.vertical, Spacing.md)
          }
        }
        .padding(.bottom, Spacing.section)
      }
      .padding(.horizontal, Spacing.screenPadding)
    }
    // Auto-advance once ready: a short "Glasses ready" beat (deliberate pacing),
    // then hand off to the coordinator to activate the lens. Re-runs whenever
    // readiness flips so a mid-gate connection still launches.
    .task(id: isReady) {
      guard isReady else { return }
      try? await Task.sleep(nanoseconds: 800_000_000)
      guard !Task.isCancelled, step == .ready else { return }
      coordinator.enterGlassesMode()
    }
  }

  // MARK: - Per-step presentation

  private struct CTA {
    let title: String
    let action: () -> Void
  }

  private var iconName: String {
    switch step {
    case .needsRegistration, .noGlasses, .noDisplayDevice: return "eyeglasses"
    case .registering:                                     return "arrow.triangle.2.circlepath"
    case .firmwareUpdate, .datAppUpdate:                   return "exclamationmark.triangle.fill"
    case .cameraPermission:                                return "camera.fill"
    case .ready:                                           return "checkmark.circle.fill"
    }
  }

  private var title: String {
    switch step {
    case .needsRegistration: return "Connect your glasses"
    case .registering:       return "Opening Meta AI…"
    case .firmwareUpdate:    return "Update needed"
    case .datAppUpdate:      return "Update glasses app"
    case .noGlasses:         return "Waking your glasses…"
    case .noDisplayDevice:   return "Display glasses needed"
    case .cameraPermission:  return "Allow camera access"
    case .ready:             return "Glasses ready"
    }
  }

  private var subtitle: String {
    switch step {
    case .needsRegistration:
      return "Link your Ray-Ban Display in the Meta AI app to launch on the lens."
    case .registering:
      return "Approve Retrace in Meta AI, then come back here."
    case .firmwareUpdate:
      return "Your glasses need a firmware update before the Display can be used."
    case .datAppUpdate:
      return "The on-glasses helper app needs an update to render the Display."
    case .noGlasses:
      return "Put on your Ray-Ban Display glasses and make sure they're powered on."
    case .noDisplayDevice:
      return "The connected glasses don't have a lens display. Switch to your Ray-Ban Display glasses."
    case .cameraPermission:
      return "Your glasses need camera access to show the lens display. Grant it in Meta AI."
    case .ready:
      return "Launching on Display…"
    }
  }

  private var showsSpinner: Bool {
    switch step {
    case .registering, .noGlasses, .noDisplayDevice, .ready: return true
    // .cameraPermission: the hosted DATCameraPermissionCTA renders its own
    // "Checking…" / "Opening Meta AI…" affordance — no gate-owned spinner.
    case .needsRegistration, .firmwareUpdate, .datAppUpdate, .cameraPermission: return false
    }
  }

  private var cta: CTA? {
    switch step {
    case .needsRegistration:
      return CTA(title: "Connect glasses") { wearablesVM.connectGlasses() }
    case .firmwareUpdate:
      return CTA(title: "Update firmware") { wearablesVM.openFirmwareUpdate() }
    case .datAppUpdate:
      return CTA(title: "Update glasses app") { wearablesVM.openDATGlassesAppUpdate() }
    // .cameraPermission renders the hosted DATCameraPermissionCTA instead of a
    // gate-owned button (see body) — so no CTA here.
    case .registering, .noGlasses, .noDisplayDevice, .cameraPermission, .ready:
      return nil
    }
  }
}
