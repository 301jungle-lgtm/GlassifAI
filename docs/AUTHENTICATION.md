# Login with ChatGPT

GlassifAI uses OpenAI’s Codex device-authorization flow. Users authenticate in their browser and the app receives account-backed tokens without collecting a password, embedding a general-purpose login browser, or requiring an API key.

## Endpoints and identifiers

| Purpose | Endpoint |
|---|---|
| Request user code | `POST https://auth.openai.com/api/accounts/deviceauth/usercode` |
| User verification page | `https://auth.openai.com/codex/device` |
| Poll authorization | `POST https://auth.openai.com/api/accounts/deviceauth/token` |
| Exchange/refresh token | `POST https://auth.openai.com/oauth/token` |
| Discover Codex models | `GET https://chatgpt.com/backend-api/codex/models` |

The OAuth client identifier committed in `ChatGPTAuthSession.swift` is the public Codex client identifier from the pinned upstream Codex implementation. OAuth client identifiers identify an application; they are not client secrets.

## First login

1. The user reviews GlassifAI’s privacy disclosure and chooses **Continue**.
2. GlassifAI posts the public Codex client ID to the user-code endpoint.
3. OpenAI returns `device_auth_id`, a short `user_code`, polling interval, and expiry.
4. GlassifAI opens OpenAI’s verification page in the system browser.
5. The user signs in and approves the device code directly with OpenAI.
6. GlassifAI polls at the server-provided interval. HTTP 403, 404, and 429 are treated as pending states.
7. OpenAI returns an authorization code and PKCE verifier.
8. GlassifAI exchanges those values for access, refresh, and ID tokens.
9. The app derives the ChatGPT account ID and public profile fields from token claims, saves the token bundle, and performs model discovery.

The pending code expires after 15 minutes in the current client. Expiry returns the interface to a recoverable error state rather than silently restarting authorization.

## Token storage

Tokens are encoded as one Keychain generic-password item:

```text
service: ai.glassifai.chatgpt.oauth
account: primary
accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
```

`ThisDeviceOnly` prevents migration of the item to another device through a backup restore. The repository contains no account token, refresh token, ID token, account ID, device code, or Keychain export.

## Refresh behavior

`freshTokens()` returns the stored access token when it has at least 60 seconds of remaining validity and includes an account ID. Otherwise it performs a refresh-token exchange.

Concurrent refreshes share one Swift `Task`, preventing multiple network refreshes from racing and replacing each other. A successful refresh atomically updates the existing Keychain item. A failed restore clears the local token bundle and requires a fresh login.

## Account headers

Account-backed Codex requests include:

```http
Authorization: Bearer <short-lived access token>
chatgpt-account-id: <account claim>
originator: codex_cli_rs
```

The realtime bridge implements Codex’s `AuthProvider` trait and adds the same authorization and account headers to call creation and the WebSocket sideband.

## Model discovery

After authentication, GlassifAI requests the account’s available Codex models using the pinned client version. Visual requests prefer `gpt-5.6-sol` when the account exposes it and otherwise select the first available model. The app does not assume that every account receives the same model slugs.

## Logout

Disconnecting:

1. cancels login polling;
2. cancels an in-flight refresh;
3. deletes the Keychain item;
4. clears in-memory model availability; and
5. returns the app to the unauthenticated state.

GlassifAI currently performs local logout. It does not claim to revoke every server-side OpenAI session.

## Why there is no API key

The app is intended for the owner of the iPhone using their own eligible ChatGPT plan. It does not proxy requests through a GlassifAI account and does not pool credentials. This is distinct from OpenAI’s public API billing and public Realtime API authentication.

## Compatibility caveat

This flow follows the pinned Codex client and subscription-backed ChatGPT endpoints. Those endpoints and the realtime transport are not a stable public mobile SDK contract. Keep the client version, request headers, endpoint behavior, and model discovery logic aligned with the pinned Codex revision when upgrading.
