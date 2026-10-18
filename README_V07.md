# ObjectSizeLock v0.7 — tracking coordinate diagnostic patch

This diagnostic build overlays three distinct rectangles:

- Yellow dashed: the user's initial selection, held fixed in preview metadata coordinates.
- Pink dashed: the raw bounding box returned by Apple Vision, whether accepted or not.
- Green solid: the latest accepted tracking box.

Changes from v0.6:
- Delay LOST after brief confidence/jump anomalies; show UNCERTAIN and hold zoom.
- Prevent frame-to-frame appearance similarity from directly forcing LOST.
- Disable the unsafe template-based reacquisition by default; it was falsely matching backgrounds. LOST requires manual reselection until proper Re-ID is integrated.
- Retain conservative zoom gating; default Auto Zoom remains disabled.

## Replace
Extract this archive in the root of ObjectSizeLock_iOS (overwriting Sources/CameraTracker.swift and Sources/ContentView.swift). Then git add/commit/push to GitHub and inspect the build log.

## Caveats
Not compiled with Xcode in this environment. No real iPhone test. This patch is intended to localize bounding-box coordinate/tracker problems, **not** to promise successful occlusion recovery. In particular, the three coordinate-space overlays are all projected through the PreviewLayer mapping, so apparent agreement does not independently prove that the camera frame orientation is correct. The best next diagnostic is saving a true CVPixelBuffer ROI next to the on-screen selection.
