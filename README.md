<div align="center">

<img src="docs/assets/retrace-banner.svg" alt="Retrace" width="100%" />

# Retrace — iOS

### Record an expert once. Coach every learner forever.

The phone client for **Retrace**, an AI coaching system for hands-on tasks. 🥈 2nd place at the XRCC Berlin 2026 hackathon; work continued through 2026.
SwiftUI app that captures from Ray-Ban Meta glasses or the iPhone camera, holds a **direct WebSocket to Gemini Live** for voice, and renders a HUD on the glasses' lens. The backend lives in [`hshwang34/retrace-server`](https://github.com/hshwang34/retrace-server).

[**🌐 retracelab.com**](https://retracelab.com) · [**▶ Demo**](https://www.youtube.com/watch?v=azK-CLpyRQg) · [**🎬 Full walkthrough**](https://www.youtube.com/watch?v=CqUj5HtP0UE) · [**🛰 Backend**](https://github.com/hshwang34/retrace-server) (private)

</div>

---

## What the phone does

```
 Glasses (DAT SDK 0.8)  ──┐                       ┌──► Gemini Live   (voice + ~1 fps JPEG, direct WebSocket)
                          ├──► this app ──────────┼──► Backend REST  (tokens, procedures, oracle, tool calls)
 iPhone camera + mic    ──┘        │              └──► Lens display  (MWDATDisplay FlexBox tree on the glasses)
                                   └──► mp4 writer (expert recording)
```

The phone is the orchestrator. It never proxies audio through the server, and it never lets Gemini Live decide anything on its own: every judgment (step done, mistake visible, question worth asking) comes from the backend's out-of-band Flash calls and is injected into Live as a text turn.

Everything runs end-to-end on an iPhone alone. Glasses are optional and checked on demand.

---

## 1 · Expert flow — record once

**Record → Review → Upload**, from glasses or iPhone, with an optional AI interviewer riding along.

### Recording pipeline

- `CaptureTransport` is `.glasses` or `.iPhone`, picked per session. The glasses path attaches a DAT `Stream` to the shared `DeviceSession`; the iPhone path wraps `AVCaptureSession` at 720×1280 portrait so the writer settings are identical.
- `ExpertRecordingManager` is an `AVAssetWriter` pipeline with a shared host-clock session start and a `RecordingTimelineOrigin`, so any event can be stamped in video time.
- Upload is multipart to `/api/expert/upload`, returns 202, and the app polls the procedure until `completed | completed_partial | failed`. `ProcedureEditView` / `StepEditView` edit the result.

### The expert interviewer (iPhone transport)

Before recording the expert picks **Ask me / Debrief only / Off**. With it on, a second Gemini Live session (`ExpertInterviewViewModel`, a `GeminiLiveSessionBase` subclass) runs beside the recorder:

| Concern | How it's solved on the phone |
|---|---|
| One `AVAudioSession`, three consumers | A single `AudioSessionManager` in the new `.interview` mode (`.playAndRecord`, `.voiceChat`). The mp4 writer takes the primary mic tap slot, Live takes the secondary slot, and a 16 kHz `PCMRingBuffer` captures the last 5 s for the planner. |
| One camera, two readers | Frames are tee'd from the recording pipeline into the Live session (`usesExternalFrameSource`), 1 fps JPEG. No second capture session. |
| Live answers every pause if it can hear the narration | The mic is sent to Live **only inside an answer window**. Otherwise the send gate is closed and the planner hears the narration instead. |
| When to speak | Every 5 s the phone posts frame + audio chunk + `video_t` to `/observe`. If the server returns an ask, a 250 ms pause gate waits for ≥1.5 s of silence, nothing playing, no stop countdown, then injects `[ASK] …` into Live and opens the answer window. |
| Stop should not kill the mic | The recorder borrows the audio session (`borrowedSession: true`), so Stop can roll into a short debrief on the same socket before teardown. |
| Server restarts between Stop and Upload | The phone owns the `InterviewLog`, saves it as a `<recording>.interview.json` sidecar, and uploads it as the `interview` part. |

Status: builds, server side verified end-to-end; not yet exercised on a device. Design and failure matrix: [`docs/expert-interviewer-design.md` in the backend repo](https://github.com/hshwang34/retrace-server/blob/main/docs/expert-interviewer-design.md).

---

## 2 · Learner flow — hands-free, visually checked coaching

**Discover → Library → Coaching.** The learner picks a procedure, hears the coach, works, and never taps "next".

### Gemini Live client (`Services/GeminiLiveService.swift`)

- **Endpoint** `BidiGenerateContentConstrained` (v1alpha, ephemeral token). It sends JSON control messages as *binary* frames, so the first byte of every binary frame is sniffed before choosing JSON parse vs raw PCM playback.
- **Setup gate.** `{"setup": {}}` is the first frame; `.connected` flips only on `setupComplete`, so no audio can leak before Gemini is ready.
- **Send gate** = `!muted && pendingToolCallIds.isEmpty && isGeminiReady`. A `Set`, not an optional, so multiple function calls in one frame all have to resolve. Logged on transitions only.
- **Barge-in.** `serverContent.interrupted` flushes the playback buffer, or the open-ear speakers keep playing the stale reply.
- **Resumption.** `sessionResumptionUpdate.new_handle` is persisted. On `goAway` or socket death the VM mints a handle-baked token (`GeminiTokenManager`, an `actor` that dedups concurrent refreshes), reconnects, waits for `setupComplete`, and injects the server's `context-summary` so the model resumes on the real current step.

### The oracle loop (`CoachingSessionViewModel`)

```
onEncodedFrame ──► cache latest JPEG
       every ~4 s (Active) ──► POST /verify ──► advanced | error | pending
                                            └─► inject "[ADVANCE] …" / "[CORRECTION] …" into Live
learner says "done" ──► Live calls check_step ──► phone intercepts, POSTs cached frame
                                                 to /verify?mode=on_demand, synthesises toolResponse
```

`check_step` is intercepted on the device because a camera frame cannot ride a tool-call body. `get_reference_clip` and `go_to_step` are forwarded to `/tool-call`. A single **Active / Passive** toggle arms the poll loop. On a verified advance, the next-step injection is deferred until Live finishes voicing the confirmation.

### On the glasses

- **`DeviceSessionManager`** is the sole caller of `wearables.createSession`. Camera (`"gemini-live"`, `"expert"`) and lens (`"lens"`) consumers refcount one `DeviceSession` per device, because a second `createSession` throws `sessionAlreadyExists`. Start races `stateStream()` against `errorStream()` so `datAppOnTheGlassesUpdateRequired` surfaces immediately.
- **Lens HUD.** Each flow has a `*LensRenderer` that builds a pure `FlexBox`/`VideoPlayer` tree; `LensDisplayCoordinator` pushes it to `MWDATDisplay`. An on-phone emulator (`RayBanHUDEmulator`, square 600×600 over the live camera) renders the same tree 1:1. Design system: [`Views/RayBanHUD/DESIGN.md`](samples/CameraAccess/CameraAccess/Views/RayBanHUD/DESIGN.md).
- **Hands as the controller.** `HandTracking/` (Apple Vision + MediaPipe pose → pinch / micro-gesture recognizers) drives hover-then-select on the HUD. Confirm registrations are token-stamped because SwiftUI fires the new page's `onAppear` before the old page's `onDisappear`.
- **Glasses-first navigation.** `GlassesNavigationCoordinator` owns a standby "session on glasses" mode and swaps heavy runtime VMs (coaching, troubleshoot, Ask AI, recording) in and out under a uniform `GlassesRuntime` teardown contract.

### Audio modes (`AudioSessionManager`)

| Mode | Duplex | Route | Used by |
|---|---|---|---|
| `.coaching` | full, AEC | BT HFP glasses, speaker fallback | glasses coaching / troubleshoot |
| `.coachingPhoneOnly` | full, AEC | built-in mic + loudspeaker | iPhone coaching |
| `.recording` | capture only | HFP or iPhone mic | glasses expert recording |
| `.recordingPhoneOnly` | capture only | built-in mic | iPhone recording, interviewer off |
| `.interview` | full, AEC | built-in mic + loudspeaker | iPhone recording with the interviewer on |

---

## 3 · Troubleshooter flow — diagnose, then coach

`Views/Troubleshoot/` + `DiagnosticSessionViewModel` drive a Live session against `/api/troubleshoot/*` with no procedure chosen up front.

```
describe the problem on camera
  → identify_product → confirm_identification  (TroubleshootConfirmOverlay)
  → search_procedures                           (library match → candidates on the lens)
  → web_search_for_fix                          (no match: cited procedure synthesised live)
  → handoff_to_learner                          (server returns a full SessionStartResponse;
                                                 the phone swaps WebSockets atomically into coaching)
```

`DiagnosticPhaseBar` mirrors the server's phase machine; `DiagnosticResolutionPanel` shows the chosen fix and its sources. **Ask AI** (`AskAISessionViewModel`) is the audio-only sibling: describe what you want to do, the lens lists matches, tap one to hand off.

---

## Build & run

- Xcode 15+, iOS 17+, real device recommended.
- Backend on the same Wi-Fi (Bonjour `_retrace._tcp` auto-discovers it) or a manual URL in **Server Settings** (gear icon). `ServerEndpoint` resolves `.auto / .local / .cloud / .custom`.
- Glasses need a Meta developer account with Developer Mode and the Meta AI app. Without them, DEBUG builds pair a `MockDeviceKit` Ray-Ban from the shake-gesture debug menu.

```bash
open samples/CameraAccess/CameraAccess.xcodeproj   # set your team, Cmd+R
```

**New Swift files must be registered in `project.pbxproj`** (the target uses a classic `PBXGroup`). Run the `pbxproj` registration snippet in [`CLAUDE.md`](CLAUDE.md) after adding a file, or the build silently skips it.

### Distribution

`.github/workflows/testflight.yml` builds and uploads to TestFlight on a `v*` tag push via Fastlane `match` and an App Store Connect API key. A Run Script phase patches the malformed `Info.plist` inside `MediaPipeTasksVision.framework`; App Store validation rejects the build without it.

---

## Layout

```
samples/CameraAccess/CameraAccess/
  Models/          CaptureTransport · ProcedureModels · DiagnosticModels · InterviewModels
  Services/
    GeminiLiveService · GeminiTokenManager        direct Live socket, token actor
    DeviceSessionManager                           sole owner of DAT DeviceSessions
    ServerEndpoint · BonjourDiscovery              backend resolution
    ProcedureAPIService · InterviewAPIService      REST clients
    InterviewLogStore · LocalProgressStore         sidecar log · saved procedures
    Lens/                                          LensSession · LensFlow · renderer protocol
  Utils/
    AudioSessionManager                            five modes, one AVAudioSession
    ExpertRecordingManager · IPhoneCameraCapture   AVAssetWriter · AVCaptureSession
    PCMRingBuffer · UploadService
  ViewModels/
    GeminiLiveSessionBase                          token lifecycle, reconnect, frame throttle, owner-fed hooks
    CoachingSessionViewModel                       learner flow + oracle loop
    DiagnosticSessionViewModel · AskAISessionViewModel
    ExpertInterviewViewModel · IPhoneExpertRecordingViewModel
    GlassesNavigationCoordinator · LensDisplayCoordinator
  Views/
    Expert/ · Learner/ · Troubleshoot/ · Onboarding/
    RayBanHUD/                                     emulator + Native/ renderers + DESIGN.md
  HandTracking/                                    pose → gesture recognizers
```

---

## Attribution

Forked from Meta's [`meta-wearables-dat-ios`](https://github.com/facebook/meta-wearables-dat-ios) `CameraAccess` sample; the DAT SDK 0.8.0 is consumed via Swift Package Manager. Hand tracking uses MediaPipe Tasks Vision.

<div align="center">

Built at XRCC Berlin 2026 by Hyunseok Hwang and Arthur Lee · Backend: [hshwang34/retrace-server](https://github.com/hshwang34/retrace-server)

</div>
