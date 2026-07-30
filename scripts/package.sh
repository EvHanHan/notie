#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Notie"
APP_BUNDLE="$ROOT_DIR/build/$APP_NAME.app"
DIST_DIR="$ROOT_DIR/dist"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
DMG_NAME="$APP_NAME-$VERSION-macos-universal.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"
NOTARY_KEYCHAIN="${NOTARY_KEYCHAIN:-}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notie-package.XXXXXX")"
STAGING_DIR="$WORK_DIR/dmg-root"

cleanup() {
  rm -rf "$WORK_DIR"
}

trap cleanup EXIT

if ! command -v hdiutil >/dev/null 2>&1; then
  echo "hdiutil is required to package a DMG." >&2
  exit 1
fi

"$ROOT_DIR/scripts/build.sh"

mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"

if [[ -n "$SIGNING_IDENTITY" ]]; then
  codesign --verify --deep --strict "$APP_BUNDLE"
  spctl --assess --type execute "$APP_BUNDLE"
fi

mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  "$DMG_PATH" >/dev/null

if [[ -n "$SIGNING_IDENTITY" ]]; then
  codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    --timestamp \
    "$DMG_PATH" >/dev/null
fi

if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "SIGNING_IDENTITY is required when NOTARY_KEYCHAIN_PROFILE is set." >&2
    exit 1
  fi

  notary_args=(
    submit
    "$DMG_PATH"
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE"
    --wait
  )

  if [[ -n "$NOTARY_KEYCHAIN" ]]; then
    notary_args+=(--keychain "$NOTARY_KEYCHAIN")
  fi

  xcrun notarytool "${notary_args[@]}"
  xcrun stapler staple "$DMG_PATH"
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
  codesign --verify --deep --strict "$DMG_PATH"
  spctl --assess --type open "$DMG_PATH"
fi

echo "Packaged $DMG_PATH"
