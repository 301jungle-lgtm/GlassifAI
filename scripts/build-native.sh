#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE="$ROOT/native/GlassifAICodexBridge"
OUTPUT="$ROOT/ios/Frameworks/GlassifAICodex.xcframework"
DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
export SDKROOT="$DEVELOPER_DIR/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"

rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios

cargo build --manifest-path "$BRIDGE/Cargo.toml" --release --target aarch64-apple-ios
cargo build --manifest-path "$BRIDGE/Cargo.toml" --release --target aarch64-apple-ios-sim
cargo build --manifest-path "$BRIDGE/Cargo.toml" --release --target x86_64-apple-ios

mkdir -p "$BRIDGE/build" "$(dirname "$OUTPUT")"
lipo -create \
  "$BRIDGE/target/aarch64-apple-ios-sim/release/libglassifai_codex_bridge.a" \
  "$BRIDGE/target/x86_64-apple-ios/release/libglassifai_codex_bridge.a" \
  -output "$BRIDGE/build/libglassifai_codex_bridge_sim.a"

rm -rf "$OUTPUT"
xcodebuild -create-xcframework \
  -library "$BRIDGE/target/aarch64-apple-ios/release/libglassifai_codex_bridge.a" \
  -headers "$BRIDGE/include" \
  -library "$BRIDGE/build/libglassifai_codex_bridge_sim.a" \
  -headers "$BRIDGE/include" \
  -output "$OUTPUT"


echo "Built $OUTPUT"
