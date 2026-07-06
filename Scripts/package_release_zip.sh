#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

"$ROOT_DIR/Scripts/package_app.sh"

ZIP_PATH="$ROOT_DIR/UsageKun-macOS.zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent UsageKun.app "$ZIP_PATH"

echo "Built $ZIP_PATH"
