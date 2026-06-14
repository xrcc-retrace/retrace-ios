---
description: Swift patterns, async/await, naming conventions, key types for DAT SDK iOS development (0.7)
---

# DAT SDK Conventions (iOS, 0.7)

## Architecture

The SDK is organized into four modules:
- **MWDATCore**: Device discovery, registration, permissions, device selectors
- **MWDATCamera**: `Stream` capability, `VideoFrame`, photo capture
- **MWDATDisplay**: On-glasses display capability — `FlexBox` view trees, `VideoPlayer`, lens rendering
- **MWDATMockDevice**: `MockDeviceKit` for testing without hardware

## DeviceSession lifecycle — single source of truth

**Never call `wearables.createSession(...)` directly.** All DAT `DeviceSession` lifecycle goes through the shared singleton at `Services/DeviceSessionManager.swift`.

```swift
// In a new consumer (camera, display, or any future capability)
let session = try await sessionManager.acquire(consumerLabel: "my-consumer")
// Attach capability:
guard let stream = try session.addStream(config: streamConfig) else { ... }
// ... use stream ...
await stream.stop()
await sessionManager.release(consumerLabel: "my-consumer")
```

Why: (1) per GitHub issue #180, two `createSession` calls against the same physical device fail with `noEligibleDevice`; the manager guarantees one shared session for camera + display coexistence. (2) The manager races `stateStream()` vs `errorStream()` during start so `datAppOnTheGlassesUpdateRequired` etc. surface immediately instead of timing out. (3) Refcounted leases serialize rapid view dismiss/remount automatically.

## Swift Patterns

- Use `async/await` for all SDK operations — the SDK is fully async
- Use `AsyncStream` (via `session.stateStream()` / `session.errorStream()`) for state observation **inside the manager**; consumers should subscribe to `manager.sessionErrors` instead.
- Use `.listen {}` publisher callbacks for high-frequency streams: `videoFramePublisher`, `photoDataPublisher`, `capability.statePublisher`
- Annotate UI-updating code with `@MainActor`
- Never block the main thread with frame processing
- Handle errors with do/catch — the SDK throws typed errors (`DeviceSessionError`, `StreamError`, `DisplayError`)
- Forward-compat: add `@unknown default` to every switch over an SDK enum so future case bumps don't break compile

## Naming Conventions

| Type | Convention | Example |
|------|-----------|---------|
| Entry point | `Wearables.shared` | `Wearables.shared.startRegistration()` |
| Sessions | `DeviceSession` | `manager.acquire(consumerLabel:)` |
| Capabilities | `Stream`, `Display` (was `StreamSession` in 0.6) | `session.addStream(...)`, `session.addDisplay()` |
| Selectors | `*DeviceSelector` | `AutoDeviceSelector`, `SpecificDeviceSelector` |
| Config | `*Configuration` (was `*Config` in 0.6) | `StreamConfiguration` |
| Publishers | `*Publisher` | `statePublisher`, `videoFramePublisher` |
| Streams | `*Stream()` methods | `session.stateStream()`, `session.errorStream()` |

**0.6 → 0.7 rename sweep applied**: `StreamSession` → `Stream`, `StreamSessionConfig` → `StreamConfiguration`, `StreamSessionState` → `StreamState`, `StreamSessionError` → `StreamError`. Qualify as `MWDATCamera.Stream` in files that also `import Foundation` (via Combine etc.) to avoid collision with `Foundation.Stream`.

## Imports

```swift
import MWDATCore     // Registration, devices, permissions, DeviceSession
import MWDATCamera   // Stream, VideoFrame, photo capture
import MWDATDisplay  // Display capability, FlexBox, VideoPlayer (lens rendering)
```

For testing:
```swift
import MWDATMockDevice  // MockDeviceKit, MockRaybanMeta, MockCameraKit
```

## Key Types

- `Wearables` — SDK entry point. Call `Wearables.configure()` at launch, then use `Wearables.shared`
- `DeviceSession` — One per physical device; created via the shared `DeviceSessionManager` (NOT directly). Both `Stream` (camera) and `Display` (lens) attach as capabilities to the same session.
- `Stream` (MWDATCamera) — Camera streaming capability. `session.addStream(config:)` → `await stream.start()`.
- `VideoFrame` — Individual video frame with `.makeUIImage()` convenience
- `Display` (MWDATDisplay) — On-glasses lens rendering capability. `session.addDisplay()` → `await display.start()` → `try await display.send(view)`.
- `FlexBox` (MWDATDisplay) — Root `DisplayableView` for lens UI. Children: `Text`, `Icon`, `Image`, `Button`, nested `FlexBox`.
- `VideoPlayer` (MWDATDisplay) — Full-screen video on lens. NOT a `ViewComponent`; sent on its own, not embedded.
- `AutoDeviceSelector` — Automatically selects the best available device. Optional `filter: { $0.supportsDisplay() }` for display-capable devices only.
- `SpecificDeviceSelector` — Selects a specific device by identifier
- `StreamConfiguration` — Configure video codec, resolution, frame rate
- `MockDeviceKit` — Factory for creating simulated devices in tests

## Error Handling

```swift
do {
    try Wearables.configure()
} catch {
    // Handle configuration error
}

do {
    let session = try await sessionManager.acquire(consumerLabel: "my-consumer")
} catch DeviceSessionManager.AcquireError.sessionStartFailed(.datAppOnTheGlassesUpdateRequired) {
    // Show "Update app on glasses" CTA
} catch {
    // Generic error
}
```

## Links

- [iOS API Reference (0.7)](https://wearables.developer.meta.com/docs/reference/ios_swift/dat/0.7)
- [Developer Documentation](https://wearables.developer.meta.com/docs/develop/)
- [GitHub Repository](https://github.com/facebook/meta-wearables-dat-ios)
- Canonical sample: `samples/CameraAccess/CameraAccess/ViewModels/DeviceSessionManager.swift` in that repo — the pattern we ported from.
