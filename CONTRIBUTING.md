# Contributing to GlassifAI

Contributions are welcome, especially for protocol compatibility, accessibility, camera reliability, and careful UI refinement.

## Development

1. Fork and clone the repository.
2. Run `./scripts/build-native.sh` to generate the local Codex XCFramework.
3. Open `ios/GlassifAI.xcodeproj` in Xcode 27 or newer.
4. Use your own signing team and bundle identifier when installing on a device.
5. Keep tokens, provisioning files, local account data, and generated native artifacts out of commits.

## Pull requests

- Keep changes focused and explain the observable behavior they alter.
- Build the signed iOS target and exercise changed camera, authentication, or voice paths on a device when applicable.
- Preserve VoiceOver labels, Dynamic Type, reduced-motion behavior, and 44-point touch targets.
- Do not add analytics, remote credential storage, or a required GlassifAI backend.
- Retain upstream notices when changing vendored or Meta-derived code.

By contributing original work, you agree to license it under the repository’s MIT License. Third-party code remains under its original terms.
