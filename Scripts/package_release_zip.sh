#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

"$ROOT_DIR/Scripts/package_app.sh"

ZIP_PATH="$ROOT_DIR/UsageKun-macOS.zip"
rm -f "$ZIP_PATH"
# --norsrc/--noextattr keep filesystem extended attributes (e.g. from cloud
# storage folders) from being archived as AppleDouble ._* files, which would
# break the sealed code signature after extraction.
ditto -c -k --keepParent --norsrc --noextattr --noqtn UsageKun.app "$ZIP_PATH"

# The archive must round-trip to a bundle that still passes Gatekeeper's
# strict signature check.
VERIFY_DIR="$(mktemp -d)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
ditto -x -k "$ZIP_PATH" "$VERIFY_DIR"
codesign --verify --strict --deep "$VERIFY_DIR/UsageKun.app"

echo "Built $ZIP_PATH"
