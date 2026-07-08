#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

swift build -c release --product UsageKun

APP_DIR="$ROOT_DIR/UsageKun.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE="$MACOS_DIR/UsageKun"
PLIST="$CONTENTS_DIR/Info.plist"

if pgrep -x UsageKun >/dev/null 2>&1; then
  echo "Stopping running UsageKun before rebuilding the app bundle"
  pkill -TERM -x UsageKun || true
  sleep 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp ".build/release/UsageKun" "$EXECUTABLE"
cp "Packaging/Info.plist" "$PLIST"
cp "Packaging/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
chmod 755 "$EXECUTABLE"

test -x "$EXECUTABLE"
test -f "$PLIST"
test -f "$RESOURCES_DIR/AppIcon.icns"

# Sign the whole bundle. Without this the executable only carries the linker's
# bare ad-hoc signature (no sealed resources, Info.plist not bound), and
# Gatekeeper rejects downloaded copies as "damaged".
# CODESIGN_IDENTITY defaults to ad-hoc ("-"); set it to a Developer ID
# identity to produce a notarizable build.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
xattr -cr "$APP_DIR"
codesign --force --options runtime \
  --identifier "$BUNDLE_ID" \
  --sign "$CODESIGN_IDENTITY" \
  "$APP_DIR"
codesign --verify --strict --deep "$APP_DIR"

echo "Built and signed $APP_DIR"
