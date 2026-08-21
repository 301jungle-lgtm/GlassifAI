# Security and privacy model

This document describes what GlassifAI stores, what it sends, and the repository controls intended to prevent developer-machine or user data from being published accidentally.

It is an engineering threat model, not a claim that the private ChatGPT transport is an official or stable mobile SDK.

## Security goals

1. A GlassifAI-controlled server must not receive account credentials, audio, camera frames, or transcripts.
2. ChatGPT account tokens must remain protected by the iPhone Keychain at rest.
3. Camera images must remain ephemeral and be transmitted only for an explicit visual question.
4. One user’s account or call state must never be shared with another user.
5. The public repository must not contain developer signing data, device IDs, local paths, account data, tokens, generated app bundles, or screenshots with personal content.

## Trust boundaries

### Trusted local boundary

The installed GlassifAI process owns:

- OAuth orchestration
- Keychain access
- microphone and camera permissions
- WebRTC peer connection
- the embedded Rust bridge
- in-memory sideband and delegation queues

The Swift and Rust components are in the same process. The C ABI is a language boundary, not a security sandbox.

### External providers

GlassifAI intentionally communicates with:

- `auth.openai.com` for device authorization and token refresh;
- `chatgpt.com` for account-backed Codex model discovery, Responses, realtime call creation, and realtime sideband traffic; and
- Meta’s documented DAT/Meta AI flows when glasses are paired or streamed.

LiveKitWebRTC is a client framework in the app; GlassifAI does not require LiveKit Cloud.

### Unsupported boundary

The subscription-backed ChatGPT realtime transport is private and unsupported. It can change or be withdrawn. Protocol instability is a compatibility risk. It becomes a security issue if a change causes tokens or content to be sent to an unintended destination; endpoint changes must therefore be reviewed, not followed through an arbitrary redirect or fallback.

## Data inventory

| Data | Storage | Lifetime | Destination |
|---|---|---|---|
| Access token | Keychain and process memory | Until expiry/logout | OpenAI authentication headers |
| Refresh token | Keychain and refresh request memory | Until logout/replacement | `auth.openai.com` |
| ID token | Keychain and transient claim parsing | Until logout/replacement | Not intentionally transmitted by GlassifAI |
| ChatGPT account ID | Keychain and process memory | Until logout | ChatGPT Codex request header |
| Microphone audio | WebRTC buffers | Live call | ChatGPT realtime transport |
| Output audio | WebRTC buffers | Live call | Device speaker/Bluetooth route |
| Camera frame | Process memory | Latest frame only | Codex Responses after visual delegation |
| Transcript/caption | Observable process memory | Current app/session lifetime | Realtime UI and transport protocol |
| SDP/call ID | Process memory | Live call | ChatGPT realtime call/sideband |
| Camera-source preference | UserDefaults | Until changed | Nowhere |

## Token storage

`ChatGPTKeychain` uses a generic-password item with:

```text
kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
```

This blocks migration to another device via backup restore. The app does not export Keychain data, write token values to `UserDefaults`, or intentionally log token bodies.

The access and account values necessarily cross the Swift/Rust ABI when a realtime call starts. Rust copies them into owned strings for authenticated request construction. They are not returned through the event/status FFI.

## Camera handling

- The iPhone and glasses paths throttle visual JPEG generation.
- `submitVisionJPEG` rejects frames over 1.5 MB.
- A visual request uses only a frame no older than ten seconds.
- Responses requests set `store: false`.
- GlassifAI does not write images to its sandbox, Photos, logs, or repository.
- The live voice model receives a short textual visual description, not the JPEG itself.

These controls bound GlassifAI behavior; external provider retention remains governed by the provider’s service and account terms.

## Network behavior

- No TLS bypass is present.
- The Rust WebSocket sideband uses rustls certificate verification.
- iOS falls back to Mozilla WebPKI roots only when native root loading returns an empty store.
- Custom CA support remains additive and retains verification; it is not trust-all behavior.
- No HTTP endpoint is used for production account or content traffic.

## Logging rules

Never log:

- OAuth token bodies
- authorization headers
- account IDs
- device or user codes
- SDP
- sideband event bodies
- image payloads
- transcript contents

Current diagnostics expose coarse states such as `connected`, `delegation received`, or `send failed`. Error strings should be reviewed when upstream libraries change because an upstream error may begin including request data.

## Repository hygiene

The repository ignores:

- generated XCFramework output
- Rust `target` and local bridge build directories
- Xcode DerivedData/build products
- provisioning profiles, app bundles, and dSYMs through normal build-location exclusion
- Xcode user state
- `.env` files

Before publishing, audit tracked files and history for:

```text
absolute home-directory paths
Apple development team and device identifiers
email addresses and account labels
access/refresh/device tokens
private keys and provisioning material
camera screenshots and transcripts
```

The vendored Codex workspace includes clearly named public test fixtures, including test certificates and test-only key material. Those fixtures are upstream source, not credentials from a GlassifAI developer machine. New matches must still be inspected rather than automatically dismissed.

## Screenshot policy

Repository screenshots must:

- use a forced `DEBUG` preview state or a deliberately blank camera view;
- show no email, account name, user/device code, transcript, notification, or real-world camera detail;
- be reviewed at full resolution before staging;
- be re-encoded to remove unnecessary metadata; and
- avoid filenames containing device IDs or user names.

The checked-in screenshots are product-state illustrations, not evidence containing live account data.

## Signing and local identifiers

The project intentionally does not commit `DEVELOPMENT_TEAM`, provisioning profile UUIDs, signing certificate names, physical device IDs, DerivedData paths, or local usernames. Developers select a team in Xcode or pass a temporary command-line override.

The bundle identifier `com.marcoiannello.GlassifAI` and public GitHub account are product identifiers intentionally published by the project owner, not secrets.

## Incident response

If a credential or private screenshot is committed:

1. stop publishing new artifacts;
2. revoke or rotate the exposed credential with its provider;
3. remove it from the working tree;
4. rewrite every affected Git object, not only the latest commit;
5. force-push the sanitized history;
6. invalidate caches/releases containing the object; and
7. document the impact through GitHub’s private vulnerability reporting process.

Deleting a value in a later commit does not remove it from Git history.
