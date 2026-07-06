# Retrace — iOS app target

This directory is the Xcode project for the Retrace phone app (`CameraAccess.xcodeproj` — the name is inherited from Meta's DAT SDK sample this app was forked from).

📄 **The canonical README lives at the repo root: [`../../README.md`](../../README.md)** — features, architecture, build & run, project layout, and design decisions are all documented there. This stub keeps only the notes you need when working from inside this directory.

## Build & run

```bash
open CameraAccess.xcodeproj
```

Select your team and a run destination, then **Cmd+R**. Real device recommended; the whole app runs end-to-end on iPhone without paired glasses (DEBUG builds include `MockDeviceKit` for hardware-free glasses simulation — shake-gesture debug menu to pair a mock).

## Adding new Swift files

The `CameraAccess` target uses a traditional `PBXGroup` — new `.swift` files on disk are **not** compiled until registered in `project.pbxproj`. After creating any new `.swift` file, run the registration script documented in the root README ("Adding new Swift files") from this directory. Don't skip this — builds silently miss unregistered files.

## Lens UI

Before touching anything that renders inside the Ray-Ban lens (coaching pages, recording chrome, overlays), read the design system doc: [`CameraAccess/Views/RayBanHUD/DESIGN.md`](CameraAccess/Views/RayBanHUD/DESIGN.md).

## Attribution

Forked from Meta's [`meta-wearables-dat-ios`](https://github.com/facebook/meta-wearables-dat-ios) `CameraAccess` sample (see that repo for the inherited sample-code license); the Meta DAT SDK (0.8.0) is consumed via Swift Package Manager.
