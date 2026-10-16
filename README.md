# Object Size Lock (iPhone proof of concept)

Native iOS prototype using SwiftUI, AVFoundation and Vision.

## What is implemented
- Portrait rear-camera preview
- Tap to select an approximate square region; drag to select an exact bounding rectangle around **any visible object**
- Vision single-object bounding-box tracking (`VNTrackObjectRequest`)
- Proportional smooth camera zoom to maintain initial bounding-box area
- Start/stop movie recording and save .mov to Photos
- Clear tracking and pause automatic zoom

## Important limits
This is a **prototype, not a tested production app**. It has not been compiled with Xcode or run on a physical iPhone in this environment. iOS/macOS build and actual camera test are required. It may need small fixes after the first GitHub Actions run. Video stabilization / frame-orientation and performance must be checked on your model. A tiny, occluded, blurry, or fast target may be lost. A stationary phone cannot turn toward a subject leaving the frame. Zoom cannot exceed the device camera's limit.

## Build without owning a Mac
1. Create a GitHub repo. Upload this entire folder, including the hidden `.github/workflows/ios-ipa.yml` path.
2. In GitHub > Actions choose **Build unsigned iPhone IPA** > **Run workflow** (or push to `main`).
3. Download the artifact named `ObjectSizeLock-unsigned-IPA`.
4. On Windows install Sideloadly from https://sideloadly.io/ and its prerequisite Apple drivers. Connect iPhone via USB.
5. Load `ObjectSizeLock-unsigned.ipa`, sign with your own free Apple Account, and install. On iOS approve the app / enable Developer Mode if prompted.
6. A free account typically needs to refresh the installed signature every seven days.

Unsigned IPA does **not** install directly via AirDrop, Files, or Safari. Do not upload your Apple Account password to GitHub, a workflow, or unknown signing services.

## Development
The repository uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) `project.yml` to create the Xcode project on a macOS runner. Sources are under `Sources/`.

## Planned validation
- Confirm GitHub Actions successfully builds the target, adjust any iOS API differences.
- Confirm portrait preview and Vision tracking bounding box align with camera preview on the target iPhone.
- Test ramp control and low-confidence target loss; tune zoom deadband and rate.
- Confirm simultaneous recording/tracking and video saving; test app background interruptions and permissions.

## License
MIT; use at your own risk.
