# ObjectSizeLock v0.8 (diagnostic regression patch)

## What's changed

- Advance VNTrackObjectRequest.inputObservation on every valid Vision output, **including** rejected/low-confidence results; previously only accepted frames updated the request.
- Evaluate abrupt frame movement against previous Vision output, not an old last-accepted box.
- Add low-confidence UNCERTAIN grace period (18 analyzed frames); don't mark LOST after a few weak frames.
- Require consecutive strong observations before marking TRACKING.
- Disable automatic zoom at runtime while tracking is under diagnosis.
- Do **not** claim reliable occlusion recovery: unsafe template reacquisition remains disabled.

## How to install

In Ubuntu (assuming zip downloaded to /home/mark/mark_gitlab):

```bash
cd /home/mark/mark_gitlab/ObjectSizeLock_iOS
unzip -o ../ObjectSizeLock_v08_diagnostic_patch.zip
git diff --check
git add Sources/CameraTracker.swift Sources/ContentView.swift README_V08.md
git commit -m 'fix: maintain vision tracking state through uncertain frames'
git push origin main
git push github main
```

Build with GitHub Actions, download latest IPA and install via iloader.

## Validation limitations

- Linux Swift parser (`swiftc -frontend -parse`) passed on both changed Swift files. This does **not** prove type-checking or an iOS build.
- A deterministic synthetic state-sequence regression passed. This is **not** inference on the user's uploaded videos and does not establish actual tracking accuracy.
- Original user video metadata was checked, but Vision is an Apple iOS framework and cannot be run here on Linux.
- Must validate with GitHub Actions / Xcode, then user's iPhone. Fixed 1× and Auto Zoom disabled intentionally.
