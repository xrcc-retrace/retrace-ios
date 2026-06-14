---
description: Project-specific DAT SDK invariants for retrace-ios. For canonical Meta guidance, use the `mwdat-ios:*` plugin skills.
---

# DAT SDK — Retrace project invariants

For everything about how the Meta DAT iOS SDK itself works — modules, types, naming, Swift patterns, lifecycle, capabilities, permissions, MockDeviceKit, debugging, error handling — **invoke the `mwdat-ios:*` plugin skills**:

| Skill | When to use |
|---|---|
| `mwdat-ios:getting-started` | First-time setup, SPM, Info.plist, `Wearables.configure()` |
| `mwdat-ios:dat-conventions` | Swift patterns, async/await, naming, key types, imports |
| `mwdat-ios:session-lifecycle` | DeviceSession states, pause/resume, `stateStream()` vs `.listen{}` |
| `mwdat-ios:camera-streaming` | `Stream`, frames, photo capture, resolution/framerate |
| `mwdat-ios:display-access` | `Display` capability, `FlexBox`, on-glasses UI |
| `mwdat-ios:permissions-registration` | Registration, `Permission.camera`, Meta AI deep links |
| `mwdat-ios:mockdevice-testing` | `MockDeviceKit` for hardware-free dev |
| `mwdat-ios:debugging` | Common failure modes, Developer Mode, version matrix |
| `mwdat-ios:sample-app-guide` | End-to-end example structure |

These are pinned at 0.7.0 and are the authoritative reference. Do not re-derive Meta's patterns inline in our docs — point at the skill and let it own the canonical version.

---

## Project-specific invariants (these are NOT in the plugin)

These rules apply on top of Meta's canonical guidance and are load-bearing for Retrace specifically.

### 1. `Services/DeviceSessionManager.swift` owns every DeviceSession

**Never call `wearables.createSession(...)` directly from a new consumer.** All DAT `DeviceSession` lifecycle goes through the shared singleton.

```swift
let session = try await sessionManager.acquire(consumerLabel: "my-consumer")
// attach capability (Stream and/or Display) on this exact session ...
await sessionManager.release(consumerLabel: "my-consumer")
```

Why this invariant exists (the parts not covered by the plugin):
- The SDK's capability-composition model: `Stream` (camera) and `Display` (lens) both attach as capabilities to one `DeviceSession` via `session.addStream(config:)` and `session.addDisplay()`. Calling `wearables.createSession(...)` twice against the same physical device throws `DeviceSessionError.sessionAlreadyExists` — the manager guarantees a single shared session so the two consumers can coexist.
- The manager races `stateStream()` vs `errorStream()` in a `ThrowingTaskGroup` during start so `datAppOnTheGlassesUpdateRequired` surfaces immediately rather than after a 5 s timeout.
- Refcounted leases serialize rapid view dismiss/remount automatically (subsumes the old `teardownInFlight` static gate).
- Handles `.paused` / `.starting` / `.stopping` per `mwdat-ios:session-lifecycle`'s "don't restart during `.paused`" rule before falling through to a fresh `createSession`.

### 2. Permission gate uses `allGlassesPermissionsGranted()`, not raw SDK calls

DSM exposes the camera-permission API as `cameraPermissionStatus()`, `ensureCameraPermissionGranted()`, `allGlassesPermissionsGranted()`. The `all*` variants are camera-only aliases — `MWDATCore.Permission` has no `.microphone` case. iOS-native `AVAudioApplication.requestRecordPermission()` is the mic gate and is prompted at session start by `AudioSessionManager`.

### 3. Typed catch on `datAppOnTheGlassesUpdateRequired`

Both consumers of the shared session surface this as a dedicated recovery affordance:
- Camera-streaming consumer (`GeminiLiveSessionBase`) → `pendingDATHelperUpdate` flag → `DATHelperUpdateRequiredSheet`
- Display consumer (`LensDisplayCoordinator`) → `requiresDATAppUpdate` flag → inline error in Server Settings

Both deep-link to `wearables.openDATGlassesAppUpdate()`. Mirror this pattern for any new consumer.

### 4. Add new Swift files to the Xcode project

The main `CameraAccess` target uses traditional `PBXGroup` — new `.swift` files are not compiled until registered in `project.pbxproj`. Use the registration script in `retrace-ios/CLAUDE.md` after every file creation.
