# Building GlassifAI

The repository contains all source needed to reproduce the app, including the pinned Codex Rust workspace. It does not commit generated Rust targets, Xcode build output, signing identities, provisioning profiles, or the large generated XCFramework.

## Prerequisites

- macOS on Apple silicon for the verified path
- Xcode 27 beta or a compatible newer Xcode
- an Apple Developer signing team for physical-device installation
- Rust stable and `rustup`
- Git LFS is not required

The app targets iOS 17 or newer.

## 1. Clone

```bash
git clone https://github.com/iannellomarco/GlassifAI.git
cd GlassifAI
```

## 2. Build the embedded Codex framework

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  ./scripts/build-native.sh
```

The script:

1. installs `aarch64-apple-ios`, `aarch64-apple-ios-sim`, and `x86_64-apple-ios` Rust targets;
2. compiles the static bridge for physical devices and both simulator architectures;
3. combines simulator archives with `lipo`; and
4. creates `ios/Frameworks/GlassifAICodex.xcframework`.

Generated bridge output is ignored by Git. Re-run the script after changing `native/`, the pinned Codex crates, Cargo dependencies, or the C header.

## 3. Configure signing

Open `ios/GlassifAI.xcodeproj` and select your signing team. The checked-in project intentionally contains no `DEVELOPMENT_TEAM` value.

The default bundle identifier is:

```text
com.marcoiannello.GlassifAI
```

Use a unique bundle identifier when another signing account requires it. If Meta glasses are used outside Developer Mode, keep the bundle identifier, team ID, Meta app configuration, and `glassifai://` callback aligned with Wearables Developer Center.

## 4. Build the app

Unsigned simulator build:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ios/GlassifAI.xcodeproj \
  -scheme GlassifAI \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

Signed physical-device build after selecting a team:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ios/GlassifAI.xcodeproj \
  -scheme GlassifAI \
  -destination generic/platform=iOS \
  -configuration Debug \
  -allowProvisioningUpdates build
```

For a non-persisted command-line team override, add `DEVELOPMENT_TEAM=<your-team-id>` to the command. Do not commit that value merely to make a local build convenient.

## 5. Install with `devicectl`

Find the built app in Xcode DerivedData, then install and launch it:

```bash
xcrun devicectl device install app \
  --device <device-id> \
  <DerivedData>/Build/Products/Debug-iphoneos/GlassifAI.app

xcrun devicectl device process launch \
  --device <device-id> \
  --terminate-existing \
  com.marcoiannello.GlassifAI
```

Never commit a physical device identifier or the resolved DerivedData path.

## Screenshot maintenance

Debug builds support a non-authenticating onboarding preview:

```bash
xcrun devicectl device process launch \
  --device <device-id> \
  --terminate-existing \
  com.marcoiannello.GlassifAI \
  --preview-onboarding
```

The flag changes display state only in `DEBUG`; it does not delete or replace the Keychain session. Before publishing a screenshot, verify that it contains no account email, device code, transcript, camera content, notification, device name, or other personal data.

## Tests

`GlassifAITests` contains the retained DAT camera-stream integration checks and sample media. These tests require the Meta mock-device tooling supplied by the DAT package and are slower than unit tests.

Run them on a concrete compatible simulator destination rather than the generic placeholder:

```bash
xcodebuild -project ios/GlassifAI.xcodeproj \
  -scheme GlassifAI \
  -destination 'platform=iOS Simulator,id=<simulator-udid>' test
```

## Common failures

### `GlassifAICodex.xcframework` is missing

Run `./scripts/build-native.sh`. The generated framework is intentionally not downloaded from Git or committed.

### Rust cannot find an iOS target

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
```

### The sideband reports missing native root certificates

Confirm the vendored `codex-http-client` iOS WebPKI fallback is present and rebuild the XCFramework. See [The Codex iOS port](CODEX-IOS-PORT.md#tls-on-ios-the-bug-that-looked-like-a-hang).

### Voice connects but a visual question never completes

Check that the sideband event loop is connected and that `RealtimeEvent::HandoffRequested` reaches Swift. Visual delegation requests arrive on the sideband, not reliably on the WebRTC data channel.

### Meta AI opens but does not return

Verify the app URL scheme and Wearables Developer Center callback both use `glassifai://`, then rebuild after changing the bundle or signing team.
