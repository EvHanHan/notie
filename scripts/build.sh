#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Notie"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
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
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$MODULE_CACHE_DIR"
cp "$INFO_PLIST_SOURCE" "$CONTENTS_DIR/Info.plist"
cp "$ICON_SOURCE" "$RESOURCES_DIR/AppIcon.icns"
cp "$MENU_BAR_ICON_SOURCE" "$RESOURCES_DIR/MenuBarDuckTemplate.png"

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
