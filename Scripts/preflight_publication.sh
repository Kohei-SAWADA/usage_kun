#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  printf 'preflight failed: %s\n' "$1" >&2
  exit 1
}

info() {
  printf '==> %s\n' "$1"
}

for path in \
  ".build" \
  ".DS_Store" \
  "12000_document" \
  ".claude" \
  ".vscode" \
  "UsageKun.app" \
  "UsageKun 2.app" \
  "UsageKun-macOS.zip" \
  "260703_idea.md" \
  "fable_sekkei.md" \
  "sekkeisho.md" \
  "解説.md"; do
  if [ -e "$path" ]; then
    if ! grep -qxF "$path/" .gitignore 2>/dev/null && ! grep -qxF "$path" .gitignore 2>/dev/null; then
      fail "$path exists but is not ignored"
    fi
    printf 'local-only path ignored: %s\n' "$path"
  fi
done

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  tracked_forbidden="$(
    git ls-files \
      12000_document .claude .vscode 'UsageKun 2.app' \
      260703_idea.md fable_sekkei.md sekkeisho.md 解説.md \
      UsageKun.app UsageKun-macOS.zip .build 2>/dev/null || true
  )"
  if [ -n "$tracked_forbidden" ]; then
    printf '%s\n' "$tracked_forbidden" >&2
    fail "local-only files are tracked by git"
  fi
else
  info "not a git checkout; tracked-file leak check skipped"
fi

info "swift build"
swift build

info "core checks"
swift run UsageKunCoreCheck

info "package app"
"$ROOT_DIR/Scripts/package_app.sh"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Packaging/Info.plist)"
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' UsageKun.app/Contents/Info.plist)"
app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' UsageKun.app/Contents/Info.plist)"

[ "$version" = "$app_version" ] || fail "packaged app version does not match Packaging/Info.plist"
[ "$build" = "$app_build" ] || fail "packaged app build does not match Packaging/Info.plist"

printf 'preflight passed: usage_kun %s (%s)\n' "$version" "$build"
