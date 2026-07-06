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
chmod 755 "$EXECUTABLE"

test -x "$EXECUTABLE"
test -f "$PLIST"

echo "Built $APP_DIR"
