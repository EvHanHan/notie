#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Notie"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
INFO_PLIST_SOURCE="$ROOT_DIR/Resources/Info.plist"
MODULE_CACHE_DIR="${TMPDIR:-/tmp}/notie-clang-module-cache"

if ! command -v clang >/dev/null 2>&1; then
  echo "clang is required. Install Apple Command Line Tools with: xcode-select --install" >&2
  exit 1
fi

mkdir -p "$MACOS_DIR" "$MODULE_CACHE_DIR"
cp "$INFO_PLIST_SOURCE" "$CONTENTS_DIR/Info.plist"

env CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
  clang \
  -fobjc-arc \
  -fmodules \
  -mmacosx-version-min=12.0 \
  -arch arm64 \
  -arch x86_64 \
  -framework Cocoa \
  -framework Carbon \
  "$ROOT_DIR/Sources/main.m" \
  -o "$MACOS_DIR/$APP_NAME"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$APP_BUNDLE" >/dev/null
fi

echo "Built $APP_BUNDLE"
