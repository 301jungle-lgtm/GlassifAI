# Changelog

All notable GlassifAI changes are documented here. The project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- New GlassifAI visual identity, app icon, social artwork, and immersive camera-first SwiftUI interface.
- Branded onboarding, privacy consent, Meta glasses connection, conversation controls, and settings.
- `com.marcoiannello.GlassifAI` application identifier.
- Reproducible native bridge build script and curated standalone repository.
- Detailed architecture, authentication, build, security-model, and Codex-to-iOS port documentation.
- Hands-free active-call controls on Meta glasses: Bluetooth HFP audio, temple-tap microphone mute/unmute, and long-press/doff/fold call termination.
- Deterministic tests for DAT session-state gesture interpretation.

### Changed

- Renamed the Xcode project, target, scheme, app entry point, and test target to GlassifAI.
- Reduced the source tree to the iOS app, embedded Codex bridge, pinned upstream source, and required notices.
- Replaced repository screenshots with metadata-minimized captures containing no account or camera data.
- Removed the developer-team identifier from the Xcode project; signing is now selected locally.

## [0.1.0] - 2026-08-22

### Added

- Single Login with ChatGPT device-code flow with Keychain restoration and refresh.
- Native ChatGPT live voice through an embedded Codex Rust XCFramework.
- Authenticated realtime sideband for camera-based visual questions.
- iPhone and Meta glasses capture sources.
- English and Italian visual-question verification on a physical iPhone.
- WebPKI certificate roots for the embedded iOS realtime sideband.

[Unreleased]: https://github.com/iannellomarco/GlassifAI/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/iannellomarco/GlassifAI/releases/tag/v0.1.0
