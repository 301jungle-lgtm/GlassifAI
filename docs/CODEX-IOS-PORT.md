# Porting the useful part of Codex to iOS

GlassifAI’s most unusual component is not the camera UI. It is a small, statically linked slice of OpenAI Codex running inside an ordinary iOS app.

The goal was not to put the Codex CLI on an iPhone. That would be the wrong abstraction: the CLI assumes a desktop filesystem, subprocesses, shell commands, terminal state, and app-server transports. GlassifAI needed only the part that already knew how to authenticate an account-backed realtime call and speak the exact private protocol expected by ChatGPT.

This document explains what was extracted, why a hand-written Swift reproduction was insufficient, how Rust was cross-compiled, and how the realtime sideband became the bridge between voice and vision.

## The problem

The starting product requirements were:

- sign in with the user’s own ChatGPT account;
- use subscription-backed live voice without an API key;
- run entirely on the iPhone;
- preserve native microphone, speaker, interruption, and camera behavior; and
- let the voice model request a current visual frame.

Codex device OAuth worked for account-backed model discovery and Responses. The same token did not work when a generic iOS client tried public Realtime or reconstructed private call requests. Direct attempts reached OpenAI but were rejected at the voice transport boundary.

That distinction matters:

```text
OAuth token is valid
        ≠
Every OpenAI transport accepts that token
```

The public Realtime API and ChatGPT’s subscription-backed realtime service are different products with different request contracts and entitlements.

## Why not embed the whole Codex CLI?

A normal iOS app cannot reasonably host the full CLI runtime. The complete Codex workspace includes desktop-oriented capabilities such as:

- subprocess and shell execution;
- arbitrary workspace reads and writes;
- Unix sockets and stdio transports;
- terminal UI state;
- sandbox/process policy integrations;
- desktop app-server lifecycle; and
- many crates unrelated to realtime call setup.

Even if those crates could be made to compile, shipping them would increase attack surface, binary size, review complexity, and maintenance cost without helping the product.

The better question was:

> What is the smallest upstream-compatible slice that can create and control a realtime call?

The answer was three Codex crates and a tiny bridge:

- `codex-api`
- `codex-http-client`
- `codex-protocol`
- `glassifai-codex-bridge` as an iOS `staticlib`

Swift remains the application runtime. Rust is a protocol adapter.

## Why use upstream code instead of copying the HTTP request?

We first reproduced the visible request shape in Swift: account bearer token, ChatGPT account header, alpha feature header, session identifiers, client metadata, SDP multipart body, and the known realtime session payload.

That was useful for diagnosis, but it was not robust. Private transports can depend on behavior beyond the obvious JSON:

- provider selection and base URL normalization;
- exact header merging and omission rules;
- WebSocket query construction;
- event-parser selection;
- session-mode defaults;
- sideband call-ID joining;
- transcript/handoff wire adapters; and
- version-specific compatibility behavior.

The exact pinned Codex implementation already encoded those decisions. Calling it directly removed a growing list of “almost the same” Swift behavior.

This is the key architectural lesson from the port:

> For a private, versioned protocol, reuse the implementation that defines the behavior instead of continually reverse-engineering its output.

## The native bridge

The bridge exports a deliberately small C ABI from `native/GlassifAICodexBridge`:

```c
char *glassifai_codex_realtime_start(
    const char *access_token,
    const char *account_id,
    const char *sdp);

bool glassifai_codex_delegation_complete(
    const char *handoff_id,
    const char *text);

char *glassifai_codex_next_sideband_event(void);
char *glassifai_codex_sideband_status(void);
void glassifai_codex_realtime_close(void);
void glassifai_codex_string_free(char *value);
```

The ABI uses JSON strings for the two structured boundaries:

- call start returns `{ ok, sdp, call_id, error }`;
- sideband events are returned one at a time as JSON.

This keeps the generated module stable and avoids exposing Rust layouts, Tokio types, or Codex enums to Swift.

Every Rust-owned output string has one matching free function. Swift wraps each call with `defer` so ownership is explicit.

## Creating the realtime call

`OAuthAuth` implements Codex’s `AuthProvider` trait. It injects:

```http
Authorization: Bearer <access token>
chatgpt-account-id: <account id>
```

The bridge constructs a ChatGPT Codex `Provider`, a direct Codex HTTP transport, and a `RealtimeSessionConfig` with:

- frameless bidirectional event parsing;
- conversational session mode;
- audio output;
- the pinned realtime model and voice;
- concise smart-glasses instructions; and
- client visual delegation enabled.

`RealtimeCallClient::create_with_session_and_headers` accepts Swift’s SDP offer and returns the answer plus call ID. Swift applies the answer through `LiveKitWebRTC`.

The call-creation Tokio runtime is current-thread and short-lived. It exists only long enough to complete the authenticated HTTP exchange.

## Why WebRTC stayed in Swift

Codex knows how to create the call, but the iPhone already has mature native media primitives:

- `AVAudioSession` controls routes, Bluetooth HFP, interruptions, and voice processing;
- LiveKitWebRTC provides the peer connection and data channel;
- Swift owns application lifecycle and UI state; and
- camera capture is native on both AVFoundation and Meta DAT paths.

Moving audio capture into Rust would duplicate platform work and make route/interruption behavior harder to reason about. The split is therefore intentional:

```text
Swift: media plane + product lifecycle
Rust: authenticated protocol control plane
```

## The sideband discovery

Voice connected before vision worked. The assistant would say a filler phrase such as “checking now” and then wait forever.

The initial assumption was that client delegation requests and results should travel over the WebRTC data channel. The Codex source showed a more specific architecture: when WebRTC carries media, an authenticated WebSocket joins the existing call by `call_id` and acts as a server-owned sideband control channel.

The delegation request arrived there as:

```rust
RealtimeEvent::HandoffRequested(...)
```

It did not reliably arrive on the app’s WebRTC data channel.

The bridge now starts a second Rust thread after call creation. That thread owns a current-thread Tokio runtime and:

1. joins the call through `connect_webrtc_sideband`;
2. continuously consumes parsed realtime events;
3. converts `HandoffRequested` into a small client-delegation JSON object;
4. appends it to a process-local queue; and
5. accepts completed visual context through an unbounded command channel.

Swift polls the queue every 100 ms while the call is active. A visual result is returned using Codex’s frameless delegation wire adapter through `send_conversation_function_call_output` with the `Speakable` context channel.

That last choice is important: the result is not a new user utterance. It is the completion of a client handoff that the realtime model is already waiting for.

## TLS on iOS: the bug that looked like a hang

After the sideband was implemented, visual requests still stalled. Instrumenting only coarse sideband states exposed the actual error:

```text
failed to connect realtime websocket:
no native root CA certificates found
```

`rustls-native-certs` returned an empty root set inside the iOS static-library environment. The normal desktop Codex path assumed a native certificate store would be available.

The fix is a small, explicit patch in vendored `codex-http-client`:

1. on iOS, build a Rustls client configuration even when no custom CA bundle is configured;
2. attempt native certificate loading first;
3. if the resulting root store is empty, extend it with `webpki_roots::TLS_SERVER_ROOTS`; and
4. keep normal certificate verification and optional custom-CA addition.

This is a trust-store fallback, not a TLS bypass. Hostname and certificate-chain validation remain enabled.

Once the WebPKI fallback was compiled into the XCFramework, the sideband connected and the same visual handoff completed end to end.

## The visual handoff

When Swift receives a delegation event:

1. it extracts the handoff ID and visual question;
2. selects the latest JPEG only if it is at most ten seconds old;
3. rejects frames larger than 1.5 MB before storage in session state;
4. obtains a fresh account token;
5. selects `gpt-5.6-sol` when available, otherwise the account’s first exposed model;
6. posts text plus a data-URL image to the account-backed Codex Responses endpoint with `store: false`;
7. parses the streamed or JSON text result;
8. bounds the returned description to 2,000 characters; and
9. completes the matching handoff over the Rust sideband.

The realtime model then turns that grounded description into a short spoken answer in the language and context of the ongoing conversation.

## Cross-compiling Rust for iOS

The bridge is compiled for three targets:

```text
aarch64-apple-ios
 aarch64-apple-ios-sim
x86_64-apple-ios
```

The two simulator archives are combined with `lipo`, then Xcode packages device and simulator libraries plus headers into `GlassifAICodex.xcframework`.

The complete process is captured in `scripts/build-native.sh`.

Important build choices:

- minimum deployment target is iOS 17;
- the crate type is `staticlib`;
- only required Codex crates are direct dependencies;
- Codex-compatible Tungstenite revisions are pinned in Cargo patches;
- no CLI, TUI, shell, filesystem, or app-server executable is linked intentionally; and
- generated `target/`, `build/`, and XCFramework output are ignored.

The generated archive is large because a Rust static library carries object code for its dependency graph. It is intentionally generated from source instead of committed through Git LFS or hidden in an opaque release binary.

## Runtime ownership and shutdown

The bridge currently supports one active realtime sideband per process, matching the app’s one-call UI.

Starting a new call replaces the global sideband sender and asks the previous sideband to close. Ending a call:

- sends `Close` to the Rust runtime;
- cancels Swift vision and polling tasks;
- closes the WebRTC data channel;
- disables the audio track;
- closes the peer connection; and
- deactivates `AVAudioSession`.

The sideband queue is cleared when a new call starts so a handoff from an old call cannot be applied to a new conversation.

## What the port deliberately does not include

The iOS bridge is not a general Codex runtime. It does not expose:

- shell commands;
- subprocess creation;
- arbitrary filesystem access;
- MCP servers;
- workspace editing;
- app-server JSON-RPC;
- terminal state;
- approval flows for tools; or
- download-and-execute behavior.

That exclusion is as important as the code that was ported. The bridge should remain a narrow protocol component.

## Security notes

- The public OAuth client ID and protocol metadata are compatibility identifiers, not user credentials.
- User access/account values enter Rust only at call start and are never returned through status/event APIs.
- Sideband diagnostics are coarse state strings and must remain free of request bodies and tokens.
- Camera bytes never cross the Rust ABI; Rust receives only the final textual handoff result.
- No trust-all TLS mode exists.
- The transport is private and unsupported. Pinning makes behavior auditable, not officially supported.

See [Security and privacy model](SECURITY-MODEL.md) for the complete data inventory.

## Upgrade checklist

When moving to a newer Codex revision:

1. inspect realtime call, WebSocket, wire-adapter, auth-provider, and header changes;
2. update the vendored revision and client version together;
3. reapply or retire the iOS WebPKI fallback based on upstream behavior;
4. update any pinned Tungstenite patches;
5. compile all three iOS targets from a clean Rust target directory;
6. recreate the XCFramework;
7. build both simulator and signed device targets;
8. verify device OAuth restoration and refresh;
9. verify ordinary voice and interruption;
10. ask visual questions in at least English and Italian;
11. confirm a visual handoff is received through the sideband and completed once; and
12. inspect logs to ensure tokens, account IDs, transcripts, SDP, and images are absent.

## What made the solution work

The final result came from three decisions:

1. **Embed the exact protocol implementation, not the desktop product.**
2. **Keep media native and use Rust only for the private control plane.**
3. **Treat sideband and TLS behavior as first-class, observable components.**

That produced an iPhone app with Codex-compatible ChatGPT login, native low-latency voice, and on-demand camera grounding—without a Mac gateway or GlassifAI server in the runtime path.
