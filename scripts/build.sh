#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Notie"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
INFO_PLIST_SOURCE="$ROOT_DIR/Resources/Info.plist"
ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.icns"
MENU_BAR_ICON_SOURCE="$ROOT_DIR/Resources/MenuBarDuckTemplate.png"
MODULE_CACHE_DIR="${TMPDIR:-/tmp}/notie-clang-module-cache"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"

if ! command -v clang >/dev/null 2>&1; then
  echo "clang is required. Install Apple Command Line Tools with: xcode-select --install" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$HELPERS_DIR" "$MODULE_CACHE_DIR"
cp "$INFO_PLIST_SOURCE" "$CONTENTS_DIR/Info.plist"
cp "$ICON_SOURCE" "$RESOURCES_DIR/AppIcon.icns"
cp "$MENU_BAR_ICON_SOURCE" "$RESOURCES_DIR/MenuBarDuckTemplate.png"

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo is required to build the local transcription helper. Install Rust with https://rustup.rs" >&2
  exit 1
fi
if ! command -v cmake >/dev/null 2>&1; then
  echo "cmake is required to build transcribe-cpp. Install it with: brew install cmake" >&2
  exit 1
fi
RUSTUP_BIN="$(command -v rustup || true)"
if [[ -z "$RUSTUP_BIN" && -n "${CARGO_BIN_PATH:-}" && -x "$CARGO_BIN_PATH/rustup" ]]; then
  RUSTUP_BIN="$CARGO_BIN_PATH/rustup"
fi
if [[ -z "$RUSTUP_BIN" && -n "$(command -v cargo || true)" ]]; then
  CARGO_BIN_PATH="$(dirname "$(command -v cargo)")"
  if [[ -x "$CARGO_BIN_PATH/rustup" ]]; then
    RUSTUP_BIN="$CARGO_BIN_PATH/rustup"
  fi
fi
if [[ -z "$RUSTUP_BIN" ]]; then
  echo "rustup is required to install the cross-compilation targets. Install Rust with https://rustup.rs" >&2
  exit 1
fi
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  if ! "$RUSTUP_BIN" target list --installed | grep -Fxq "$target"; then
    echo "Rust target ${target} is missing. Install it with: $RUSTUP_BIN target add ${target}" >&2
    exit 1
  fi
done

TRANSCRIBER_DIR="$ROOT_DIR/Transcriber"
ARM_TARGET="aarch64-apple-darwin"
X86_TARGET="x86_64-apple-darwin"
TRANSCRIBE_CMAKE_ARGS="-DGGML_NATIVE=OFF" \
  cargo build --manifest-path "$TRANSCRIBER_DIR/Cargo.toml" --release --target "$ARM_TARGET"
TRANSCRIBE_CMAKE_ARGS="-DGGML_NATIVE=OFF" \
  cargo build --manifest-path "$TRANSCRIBER_DIR/Cargo.toml" --release --target "$X86_TARGET"
lipo -create \
  "$TRANSCRIBER_DIR/target/$ARM_TARGET/release/notie-transcriber" \
  "$TRANSCRIBER_DIR/target/$X86_TARGET/release/notie-transcriber" \
  -output "$HELPERS_DIR/notie-transcriber"
chmod 755 "$HELPERS_DIR/notie-transcriber"

env CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
  clang \
  -fobjc-arc \
  -fmodules \
  -mmacosx-version-min=14.2 \
  -arch arm64 \
  -arch x86_64 \
  -framework Cocoa \
  -framework Carbon \
  -framework EventKit \
  -framework AVFoundation \
  -framework CoreAudio \
  -framework ScreenCaptureKit \
  "$ROOT_DIR/Sources/main.m" \
  -o "$MACOS_DIR/$APP_NAME"

if ! command -v codesign >/dev/null 2>&1; then
  echo "codesign is required to sign the app bundle." >&2
  exit 1
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
  codesign \
    --force \
    --deep \
    --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp \
    "$APP_BUNDLE" >/dev/null
else
  # Local builds still need a stable bundle signature so macOS can persist permissions.
  codesign \
    --force \
    --deep \
    --sign - \
    "$APP_BUNDLE" >/dev/null
fi

echo "Built $APP_BUNDLE"
