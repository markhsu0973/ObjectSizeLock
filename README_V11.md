# ObjectSizeLock v1.1 – Core ML inference benchmark

- Existing `CameraTracker.swift` unchanged. Existing Vision tracking and video recording remain unchanged.
- New SwiftUI sheet benchmarks OSTrack Core ML using neutral synthetic arrays, not actual tracking.
- Core ML model downloaded in GitHub Actions from `v1.1-model` release; never commit model to Git.
- Requires `ostrack_vitb384.mlpackage.zip` containing a top-level `ostrack_vitb384.mlpackage/` directory.
- `MLModel` uses computeUnits=.all; time measures `prediction` only, after one warmup.
- Does not benchmark preprocessing, postprocessing, video or zoom; does not establish correctness of Core ML numerics.
- Due to large model size and platform dependencies, CI compile and physical-device runtime remain unverified.

On Ubuntu from /home/mark/mark_gitlab/tracking_app:

    zip -q -r -0 ostrack_vitb384.mlpackage.zip ostrack_vitb384.mlpackage

Upload the asset to a GitHub release tag named `v1.1-model` in the same repository.
Using `gh` after `gh auth login` (if not already installed, install GitHub CLI):

    gh release create v1.1-model ostrack_vitb384.mlpackage.zip --repo markhsu0973/ObjectSizeLock --title 'OSTrack Core ML model' --notes 'v1.1 Core ML model asset'

Then apply ZIP contents to ObjectSizeLock_iOS root, commit, and push. The first CI job must successfully download the release asset.
