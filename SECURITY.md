# Security policy

## Reporting a vulnerability

Please use GitHub’s private vulnerability reporting for this repository rather than opening a public issue. Include the affected commit, reproduction steps, impact, and any suggested mitigation.

Do not include access tokens, refresh tokens, device codes, account identifiers, camera frames, or other private user data in a report.

## Scope

High-priority reports include credential disclosure, insecure Keychain handling, unintended camera persistence, authentication bypass, sideband session confusion, or network traffic sent anywhere other than the documented providers.

The private ChatGPT realtime transport is an upstream compatibility risk, not by itself a GlassifAI vulnerability. Reports showing that GlassifAI exposes credentials or weakens transport security remain in scope.
