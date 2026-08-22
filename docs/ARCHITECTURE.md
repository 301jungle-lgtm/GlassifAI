# GlassifAI architecture

GlassifAI is an iPhone-first voice and vision assistant. It combines a native SwiftUI application, Meta’s Wearables Device Access Toolkit (DAT), LiveKit’s WebRTC framework, and a small Rust bridge built from pinned OpenAI Codex sources.

The central design constraint is simple: normal operation must not require a Mac companion, GlassifAI backend, shared credential service, or OpenAI API key.

## System boundaries

```text
┌──────────────────────────────── iPhone ────────────────────────────────┐
│                                                                        │
│  SwiftUI                                                               │
│  ├─ onboarding and account state                                      │
│  ├─ camera-source selection                                           │
│  ├─ conversation state and captions                                   │
│  └─ settings and disconnect                                           │
│                                                                        │
│  Capture                                                               │
│  ├─ AVFoundation iPhone camera                                        │
│  └─ Meta Wearables DAT glasses stream                                 │
│                                                                        │
│  GlassifAIRealtimeSession                                             │
│  ├─ LiveKitWebRTC microphone, speaker, SDP, and data channel           │
│  ├─ account-backed image Responses                                    │
│  └─ Swift ↔ C ABI polling bridge                                      │
│                          │                                             │
│  GlassifAICodexBridge    │                                             │
│  ├─ Codex realtime call creation                                      │
│  ├─ authenticated WebSocket sideband                                  │
│  └─ visual delegation event queue                                     │
│                                                                        │
│  Keychain                                                              │
│  └─ device OAuth access, refresh, ID, account, and expiry data         │
└──────────────────────────┬─────────────────────────────────────────────┘
                           │
              ┌────────────┴────────────┐
              │                         │
        auth.openai.com           chatgpt.com
        device OAuth              voice + Codex Responses
```

## Components

| Component | Responsibility | Important files |
|---|---|---|
| App root | Restores login, selects onboarding or the main experience, initializes DAT | `ios/GlassifAI/GlassifAIApp.swift` |
| Authentication | Device-code login, polling, token exchange, refresh, model discovery, logout | `Runtime/ChatGPTAuthSession.swift` |
| Token storage | This-device-only Keychain persistence | `Runtime/ChatGPTKeychain.swift` |
| Voice session | Audio session, peer connection, data channel, captions, interruption, teardown | `Runtime/GlassifAIRealtimeSession.swift` |
| Glasses gestures | Capability-free DAT state session that maps fixed temple transitions to microphone mute and call end | `Runtime/GlassesGestureSession.swift` |
| Native bridge | Codex request construction, realtime call creation, sideband lifecycle, event queue | `native/GlassifAICodexBridge/src/lib.rs` |
| iPhone camera | Camera authorization, capture session, throttled JPEG production | `Runtime/GlassifAICamera.swift` |
| Glasses camera | DAT registration, camera permission, stream decoding, throttled JPEG production | `ViewModels/StreamSessionViewModel.swift` |
| Interface | Camera preview, conversation controls, captions, source selection | `Runtime/GlassifAIExperienceView.swift` |

## Voice call lifecycle

1. Swift configures `AVAudioSession` for `.playAndRecord` with `.voiceChat` mode.
   When the glasses source is selected, GlassifAI prefers the available Bluetooth HFP input; output follows the full-duplex voice route. If HFP is unavailable, it falls back to iPhone audio.
2. `LiveKitWebRTC` creates a peer connection, microphone track, send-only video transceiver, and negotiated data channel.
3. Swift creates an SDP offer and waits briefly for ICE gathering.
4. `ChatGPTAuthSession` returns a fresh account-backed access token.
5. `EmbeddedCodexBridge.startRealtime` passes the token, ChatGPT account ID, and SDP to Rust through the C ABI.
6. Rust uses Codex `RealtimeCallClient` to create the private ChatGPT realtime call and returns SDP answer plus call ID.
7. Swift applies the remote SDP and waits for the data channel to open.
8. Rust joins the call’s authenticated WebSocket sideband on a dedicated Tokio runtime thread.
9. Audio is carried by WebRTC. Control/delegation events are carried by the sideband and exposed to Swift through a bounded process-local queue.
10. Teardown closes the sideband, data channel, audio track, peer connection, and audio session.


## Hands-free active-call controls

GlassifAI starts a capability-free `DeviceStateSession` alongside an active glasses call and subscribes to `WearablesInterface.addDeviceSessionStateListener`.

Meta DAT exposes resulting session states, not raw gesture events:

```text
running → paused   temple tap   → toggle microphone mute
paused → running   temple tap   → toggle microphone mute
active → stopped   long press, doff, fold, or link loss → end call
```

The state interpreter ignores an initial `stopped` value and suppresses the `stopped` transition produced by GlassifAI's own teardown, preventing a false hang-up or recursive stop. It also emits at most one end action for a stopped session.

The microphone mute is implemented by disabling the local WebRTC audio track. The realtime call and output audio remain active, so a second temple tap can restore the microphone without renegotiating the call.

This is hands-free control after call start, not a cold-start wake word. The user starts the call once from the iPhone; while the call is active, HFP audio and DAT state transitions allow the phone to stay in a pocket. Because DAT does not provide a stop reason, GlassifAI cannot distinguish long-press from doff, fold, or Bluetooth/session loss.

## Visual-question lifecycle

```text
User asks visual question
        │
        v
ChatGPT realtime model requests client delegation
        │
        v
Rust sideband parses RealtimeEvent::HandoffRequested
        │
        v
C ABI queue → Swift polling loop
        │
        v
Most recent JPEG (≤10 seconds old, ≤1.5 MB)
        │
        v
Account-backed Codex Responses request with input_image
        │
        v
Short visual description
        │
        v
Rust sideband send_conversation_function_call_output
        │
        v
Realtime model speaks a natural answer
```

The voice model does not receive a continuous camera stream. It asks for visual context only when needed. Swift then sends one recent frame through the Responses endpoint and returns only a short textual result to the live conversation.

## Concurrency model

- UI and observable session state are `@MainActor` isolated.
- Camera session work runs on a dedicated serial dispatch queue.
- Camera frame conversion runs on a separate output queue and is throttled before JPEG encoding.
- Native call creation uses a short-lived current-thread Tokio runtime.
- The long-lived sideband owns a separate Rust thread and current-thread Tokio runtime.
- C ABI queues are protected by standard mutexes. Tokens are copied into Rust only for call creation and sideband authentication.
- Swift polls sideband events every 100 ms while a voice session is active; polling ends during teardown.

## Persistence

Persisted by GlassifAI:

- ChatGPT OAuth tokens, account ID, and expiry in Keychain
- selected camera source in UserDefaults

Not persisted by GlassifAI:

- camera frames
- transcripts
- audio
- sideband messages
- SDP
- call IDs
- visual model results

## Failure behavior

| Failure | User-visible result | Recovery |
|---|---|---|
| Device code expires | Login error | Start login again |
| Refresh token fails | Local session is cleared | Reauthenticate |
| Voice call creation fails | Conversation error | Tap to reconnect |
| Sideband TLS/connect fails | Visual channel error | End and restart call |
| No fresh frame | Spoken request to point/hold camera | Retry visual question |
| Image Responses fails | Spoken bounded failure response | Retry visual question |
| Glasses unavailable | Placeholder explaining the state | Wake glasses or switch to iPhone |

## Dependency and compatibility policy

- Meta Wearables DAT is pinned by Swift Package Manager.
- LiveKit WebRTC is pinned by Swift Package Manager.
- Codex source is vendored and pinned because private realtime protocol behavior changes independently of public API guarantees.
- The generated Codex XCFramework is intentionally not committed. `scripts/build-native.sh` reproduces it from source.
- The private ChatGPT realtime transport is unsupported. A server-side protocol or entitlement change may require a new pinned Codex revision and bridge update.
