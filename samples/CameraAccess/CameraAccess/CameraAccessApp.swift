/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// CameraAccessApp.swift
//
// Main entry point for the CameraAccess sample app demonstrating the Meta Wearables DAT SDK.
// This app shows how to connect to wearable devices (like Ray-Ban Meta smart glasses),
// stream live video from their cameras, and capture photos. It provides a complete example
// of DAT SDK integration including device registration, permissions, and media streaming.
//

import Foundation
import MWDATCore
import SwiftUI

#if DEBUG
import MWDATMockDevice
#endif

@main
struct CameraAccessApp: App {
  @UIApplicationDelegateAdaptor(RetraceAppDelegate.self) private var appDelegate
  @StateObject private var appOrientationController = AppOrientationController.shared
  @Environment(\.scenePhase) private var scenePhase

  private let wearables: WearablesInterface
  @StateObject private var wearablesViewModel: WearablesViewModel
  @StateObject private var deviceSessionManager: DeviceSessionManager
  @StateObject private var lensDisplayCoordinator: LensDisplayCoordinator
  @StateObject private var lensSession: LensSession
  @StateObject private var glassesNavCoordinator: GlassesNavigationCoordinator
  @ObservedObject private var localNetworkPermission = LocalNetworkPermission.shared

  init() {
    RetraceNavBarAppearance.install()

    URLCache.shared = URLCache(
      memoryCapacity:  16 * 1024 * 1024,
      diskCapacity:   256 * 1024 * 1024,
      diskPath:       "RetraceURLCache"
    )

    // One-time eviction of any stale procedures-list responses sitting on
    // disk from before the server started sending Cache-Control: no-store.
    // The disk cache survives app rebuilds, so without this users see a
    // snapshot of the procedures list from whenever they last had the app
    // open and a freshly-uploaded procedure won't appear. The cost is
    // a single tab-switch network round-trip on launch — negligible.
    // Stamped against a UserDefaults key so we only do it once per install.
    let cacheNukeKey = "retrace.urlcache.nukedForNoStore.v1"
    if !UserDefaults.standard.bool(forKey: cacheNukeKey) {
      URLCache.shared.removeAllCachedResponses()
      UserDefaults.standard.set(true, forKey: cacheNukeKey)
    }

    let arguments = ProcessInfo.processInfo.arguments
    if arguments.contains("--ui-testing-reset-onboarding") {
      UserDefaults.standard.removeObject(forKey: OnboardingContainerView.completionKey)
    } else if arguments.contains("--ui-testing-complete-onboarding") {
      UserDefaults.standard.set(true, forKey: OnboardingContainerView.completionKey)
    }

    do {
      try Wearables.configure()
    } catch {
      #if DEBUG
      NSLog("[CameraAccess] Failed to configure Wearables SDK: \(error)")
      #endif
    }

    #if DEBUG
    // Auto-configure MockDeviceKit when launched by XCUITests
    if arguments.contains("--ui-testing") {
      // 0.8: pairGlasses(model:) replaces pairRaybanMeta(); only throws
      // .notEnabled, which would be a test-harness misconfiguration.
      let device = try! MockDeviceKit.shared.pairGlasses(model: .rayBanMeta)

      let cameraKit = device.services.camera
      Task {
        guard let videoURL = Bundle.main.url(forResource: "plant", withExtension: "mp4"),
          let imageURL = Bundle.main.url(forResource: "plant", withExtension: "png")
        else {
          fatalError("Test resources not found - are you running a Release build?")
        }
        cameraKit.setCameraFeed(fileURL: videoURL)
        cameraKit.setCapturedImage(fileURL: imageURL)

        device.powerOn()
        device.don()
      }
    }
    #endif

    // Start Bonjour discovery for the Retrace server
    BonjourDiscovery.shared.startBrowsing()

    let wearables = Wearables.shared
    self.wearables = wearables
    let manager = DeviceSessionManager(wearables: wearables)
    self._deviceSessionManager = StateObject(wrappedValue: manager)
    self._wearablesViewModel = StateObject(wrappedValue: WearablesViewModel(wearables: wearables, sessionManager: manager))
    let coordinator = LensDisplayCoordinator(wearables: wearables, sessionManager: manager)
    self._lensDisplayCoordinator = StateObject(wrappedValue: coordinator)
    let lens = LensSession(coordinator: coordinator)
    self._lensSession = StateObject(wrappedValue: lens)
    self._glassesNavCoordinator = StateObject(
      wrappedValue: GlassesNavigationCoordinator(
        lensSession: lens,
        api: ProcedureAPIService(),
        wearables: wearables,
        sessionManager: manager
      )
    )
  }

  var body: some Scene {
    WindowGroup {
      MainAppView(wearables: Wearables.shared, viewModel: wearablesViewModel)
        .environmentObject(appOrientationController)
        .environmentObject(lensSession)
        .environmentObject(lensDisplayCoordinator)
        .environmentObject(deviceSessionManager)
        .environmentObject(glassesNavCoordinator)
        .preferredColorScheme(.dark)
        .alert("Error", isPresented: $wearablesViewModel.showError) {
          Button("OK") {
            wearablesViewModel.dismissError()
          }
        } message: {
          Text(wearablesViewModel.errorMessage)
        }
        // Trigger the iOS Local Network prompt on fresh installs and log the
        // definitive grant state every launch. Denied = DAT 0.8 WiFi glasses
        // video AND _retrace._tcp server discovery silently fall back/fail.
        .task { await LocalNetworkPermission.shared.check(context: "app-launch") }
        .alert("Local Network Access Needed", isPresented: $localNetworkPermission.showDeniedAlert) {
          Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) {
              UIApplication.shared.open(url)
            }
          }
          Button("Not Now", role: .cancel) {}
        } message: {
          Text("Local Network access is off, so Retrace can't stream glasses video over Wi-Fi or find your server. Enable it in Settings → Privacy & Security → Local Network → Retrace.")
        }
        .overlay {
          RegistrationView(viewModel: wearablesViewModel)
        }
        // Pair Bonjour discovery with scene phase. `startBrowsing` is
        // already called once at launch in `init()`; the guard inside it
        // makes re-entry idempotent. Stopping on background releases the
        // NWBrowser so a Wi-Fi switch or DHCP rotation re-resolves cleanly
        // on the next foreground.
        .onChange(of: scenePhase) { _, newPhase in
          switch newPhase {
          case .active:
            BonjourDiscovery.shared.startBrowsing()
          case .background:
            BonjourDiscovery.shared.stopBrowsing()
          default:
            break
          }
        }
    }
  }
}
