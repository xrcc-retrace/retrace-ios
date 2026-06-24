/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// WearablesViewModel.swift
//
// Primary view model for the CameraAccess app that manages DAT SDK integration.
// Demonstrates how to listen to device availability changes using the DAT SDK's
// device stream functionality and handle permission requests.
//

import Combine
import MWDATCore
import SwiftUI

#if DEBUG
import MWDATMockDevice
#endif

@MainActor
class WearablesViewModel: ObservableObject {
  @Published var devices: [DeviceIdentifier]
  @Published var hasMockDevice: Bool
  @Published var registrationState: RegistrationState
  /// True when there's an actively reachable device (powered on, awake, in
  /// range) — not merely a paired one. Use this for "is the device connected
  /// right now" UI; glasses sitting in their case yield `false`.
  ///
  /// Phase 3: when `sessionManager` is injected this is republished from
  /// `manager.$hasAnyActiveDevice` via Combine `.assign`, so the manager
  /// becomes the single source of truth for device availability. The local
  /// `AutoDeviceSelector.activeDeviceStream()` path is kept as a fallback
  /// for instances constructed without a manager.
  @Published var hasActiveDevice: Bool = false
  @Published var showGettingStartedSheet: Bool = false
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""

  /// True when any paired device has `Compatibility == .deviceUpdateRequired`.
  /// Drives the Settings "Update firmware" CTA. Mirrors the DAT 0.7 sample
  /// (`samples/CameraAccess/.../WearablesViewModel.swift`'s
  /// `requiresFirmwareUpdate` pattern, lines 488-514).
  @Published private(set) var requiresFirmwareUpdate: Bool = false

  private var registrationTask: Task<Void, Never>?
  private var deviceStreamTask: Task<Void, Never>?
  private var setupDeviceStreamTask: Task<Void, Never>?
  private var activeDeviceTask: Task<Void, Never>?
  private let wearables: WearablesInterface
  private var compatibilityListenerTokens: [DeviceIdentifier: AnyListenerToken] = [:]
  /// Per-device compatibility cache, refreshed on each `monitorDeviceCompatibility`
  /// run and on each `addCompatibilityListener` callback. Derives `requiresFirmwareUpdate`.
  private var deviceCompatibility: [DeviceIdentifier: Compatibility] = [:]

  /// Combine binding to the manager's `hasAnyActiveDevice` when the manager
  /// is available. Stored so it lives as long as this VM.
  private var hasActiveDeviceCancellable: AnyCancellable?

  init(wearables: WearablesInterface, sessionManager: DeviceSessionManager? = nil) {
    self.wearables = wearables
    self.devices = wearables.devices
    self.hasMockDevice = false
    self.registrationState = wearables.registrationState

    // Set up device stream immediately to handle MockDevice events
    setupDeviceStreamTask = Task {
      await setupDeviceStream()
    }

    registrationTask = Task {
      for await registrationState in wearables.registrationStateStream() {
        let previousState = self.registrationState
        self.registrationState = registrationState
        if self.showGettingStartedSheet == false && registrationState == .registered && previousState == .registering {
          self.showGettingStartedSheet = true
        }
      }
    }

    // Phase 3: prefer the manager's published `hasAnyActiveDevice`. When the
    // manager isn't injected (legacy callers / tests), fall back to a local
    // filterless `AutoDeviceSelector.activeDeviceStream()` — preserved so
    // behavior doesn't regress for any caller that hasn't been updated.
    if let manager = sessionManager {
      hasActiveDeviceCancellable = manager.$hasAnyActiveDevice
        .receive(on: DispatchQueue.main)
        .assign(to: \.hasActiveDevice, on: self)
    } else {
      let activeSelector = AutoDeviceSelector(wearables: wearables)
      activeDeviceTask = Task { [weak self] in
        for await device in activeSelector.activeDeviceStream() {
          guard let self else { return }
          await MainActor.run {
            self.hasActiveDevice = device != nil
          }
        }
      }
    }
  }

  deinit {
    registrationTask?.cancel()
    deviceStreamTask?.cancel()
    setupDeviceStreamTask?.cancel()
    activeDeviceTask?.cancel()
    hasActiveDeviceCancellable?.cancel()
  }

  private func setupDeviceStream() async {
    if let task = deviceStreamTask, !task.isCancelled {
      task.cancel()
    }

    deviceStreamTask = Task {
      for await devices in wearables.devicesStream() {
        self.devices = devices
        #if DEBUG
        self.hasMockDevice = !MockDeviceKit.shared.pairedDevices.isEmpty
        #endif
        // Monitor compatibility for each device
        monitorDeviceCompatibility(devices: devices)
      }
    }
  }

  private func monitorDeviceCompatibility(devices: [DeviceIdentifier]) {
    // Remove listeners for devices that are no longer present, and forget
    // their cached compatibility so a removed device can't keep the
    // `requiresFirmwareUpdate` flag stuck on.
    let deviceSet = Set(devices)
    compatibilityListenerTokens = compatibilityListenerTokens.filter { deviceSet.contains($0.key) }
    deviceCompatibility = deviceCompatibility.filter { deviceSet.contains($0.key) }
    updateFirmwareUpdateRequired()

    // Add listeners for new devices. Each listener fires when the SDK
    // re-evaluates compatibility (e.g. after a firmware update lands).
    for deviceId in devices {
      // Refresh the cached compatibility for every present device — initial
      // pass to seed `requiresFirmwareUpdate` even for devices we already
      // had a listener on.
      if let device = wearables.deviceForIdentifier(deviceId) {
        deviceCompatibility[deviceId] = device.compatibility()
      }

      guard compatibilityListenerTokens[deviceId] == nil else { continue }
      guard let device = wearables.deviceForIdentifier(deviceId) else { continue }

      // Capture device name before the closure to avoid Sendable issues
      let deviceName = device.nameOrId()
      let token = device.addCompatibilityListener { [weak self] compatibility in
        guard let self else { return }
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.deviceCompatibility[deviceId] = compatibility
          self.updateFirmwareUpdateRequired()
          if compatibility == .deviceUpdateRequired {
            self.showError("Device '\(deviceName)' requires an update to work with this app")
          }
        }
      }
      compatibilityListenerTokens[deviceId] = token
    }

    updateFirmwareUpdateRequired()
  }

  /// Recompute `requiresFirmwareUpdate` from the per-device compatibility
  /// cache. Idempotent — call after any mutation of `deviceCompatibility`.
  private func updateFirmwareUpdateRequired() {
    requiresFirmwareUpdate = deviceCompatibility.values.contains(.deviceUpdateRequired)
  }

  /// Human-readable name for a paired device (falls back to the raw identifier
  /// string if the SDK can't resolve it, e.g. the device is paired but out of
  /// range).
  func displayName(for deviceId: DeviceIdentifier) -> String {
    wearables.deviceForIdentifier(deviceId)?.nameOrId() ?? String(describing: deviceId)
  }

  func connectGlasses() {
    guard registrationState != .registering else { return }
    Task { @MainActor in
      do {
        try await wearables.startRegistration()
      } catch let error as RegistrationError {
        showError(error.description)
      } catch {
        showError(error.localizedDescription)
      }
    }
  }

  func disconnectGlasses() {
    Task { @MainActor in
      do {
        try await wearables.startUnregistration()
      } catch let error as UnregistrationError {
        showError(error.description)
      } catch {
        showError(error.localizedDescription)
      }
    }
  }

  /// Disconnect then immediately re-register. Convenience for the settings
  /// screen — useful when the Meta AI handshake has gone stale.
  func reRegisterGlasses() {
    Task { @MainActor in
      do {
        try await wearables.startUnregistration()
      } catch {
        // Non-fatal — we may have already been unregistered.
        print("[WearablesVM] reRegister: unregistration failed: \(error)")
      }
      do {
        try await wearables.startRegistration()
      } catch let error as RegistrationError {
        showError(error.description)
      } catch {
        showError(error.localizedDescription)
      }
    }
  }

  /// Deep-link into the Meta AI iOS app's "Update / install DAT helper on
  /// glasses" flow. Used when a DeviceSession fails with
  /// `DeviceSessionError.datAppOnTheGlassesUpdateRequired` (or its first
  /// install — same path).
  func openDATGlassesAppUpdate() {
    Task { @MainActor in
      do {
        try await wearables.openDATGlassesAppUpdate()
      } catch {
        showError(error.localizedDescription)
      }
    }
  }

  /// Deep-link into the Meta AI iOS app's firmware-update flow. Used when
  /// `Device.compatibility() == .deviceUpdateRequired`.
  func openFirmwareUpdate() {
    Task { @MainActor in
      do {
        try await wearables.openFirmwareUpdate()
      } catch {
        showError(error.localizedDescription)
      }
    }
  }

  func showError(_ error: String) {
    errorMessage = error
    showError = true
  }

  func dismissError() {
    showError = false
  }
}
