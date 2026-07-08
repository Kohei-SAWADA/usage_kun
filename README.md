# usage-kun

<p align="center">
  <img src="assets/usage-kun-thumbnail.png" alt="usage-kun thumbnail showing an AI usage meter for Claude and Codex">
</p>

<p align="right">
  <strong>English</strong> |
  <a href="README.ja.md">日本語</a>
</p>

usage-kun is a small, privacy-first macOS menu bar app for keeping Claude and Codex usage visible while you work.

It is built as a personal utility: a compact usage meter rather than a full analytics dashboard. It reads local CLI usage data by default and can optionally reuse Claude Code / Codex CLI sign-in tokens in read-only mode for official 5-hour and 1-week quota numbers. It does not store, refresh, or log those tokens.

This project is not affiliated with, endorsed by, or sponsored by OpenAI, Anthropic, or any other provider.

## Screenshots

usage-kun is designed to stay visible without becoming a dashboard. The pinned desktop meter keeps both the 5-hour primary window and 1-week secondary window in the corner of the screen, while the menu bar popover shows the fuller provider breakdown when needed.

<p align="center">
  <img src="assets/screenshots/pinned-desktop-meter.png" alt="Pinned desktop usage meter showing Codex and Claude Code 5-hour and 1-week usage bars in the top-left corner of macOS." width="420">
</p>

<p align="center">
  <em>Pinned desktop meter with compact 5-hour and 1-week quota bars.</em>
</p>

<p align="center">
  <img src="assets/screenshots/menu-bar-popover.png" alt="Menu bar popover showing Codex and Claude Code usage cards with 5-hour and 1-week limits, reset timing, sync source, and settings tab." width="520">
</p>

<p align="center">
  <em>Menu bar popover with detailed provider cards, reset timing, and quick settings access.</em>
</p>

## Features

- Native macOS menu bar app built with SwiftPM, AppKit, and SwiftUI
- Compact menu bar popover with provider cards
- Optional pinned desktop widget for at-a-glance usage
- 5-hour primary and 1-week secondary quota bars for Claude Code and Codex
- Per-provider checkboxes to show only Claude, only Codex, or both
- Local-log usage estimates when official sync is unavailable
- Optional official usage sync for Claude Code and Codex CLI sign-ins
- Low-usage and reset notifications for the packaged app
- Read-only token reuse with no token persistence, refresh, or credential logging
- No telemetry and no bundled analytics

## Requirements

- macOS 14 or newer
- Swift 6 or newer
- Xcode Command Line Tools

## Quick Start

### Install From The Release ZIP

1. Download the latest `UsageKun-macOS.zip` from [Releases](https://github.com/Kohei-SAWADA/usage_kun/releases/latest).
2. Unzip it and move `UsageKun.app` to `/Applications` (or anywhere you like).
3. Open `UsageKun.app`.

### First Launch: "Apple could not verify UsageKun is free of malware"

On first launch, macOS blocks the app with a dialog like:

> Apple could not verify "UsageKun" is free of malware that may harm your Mac or compromise your privacy.

**This is expected and does not mean the download is broken.** The app is signed but not notarized by Apple (notarization requires a paid Apple Developer account), so macOS cannot vouch for it automatically. You only need to approve it once:

1. In the warning dialog, click **Done** (do NOT click "Move to Trash").
2. Open **System Settings** > **Privacy & Security**.
3. Scroll down to the **Security** section. You will see a message saying "UsageKun" was blocked.
4. Click **Open Anyway** next to that message.
5. In the confirmation dialog, click **Open Anyway** again and authenticate with Touch ID or your password.

The app opens normally from then on; the warning does not come back until you download a new version.

Alternatively, you can clear the quarantine flag from Terminal instead (same effect, no dialogs):

```sh
xattr -d com.apple.quarantine /Applications/UsageKun.app
```

If you prefer not to trust a downloaded binary at all, build it yourself from source below — the result is identical and needs no Gatekeeper approval.

### Run From Source

Run from source:

```sh
swift run
```

Build the app bundle:

```sh
./Scripts/package_app.sh
open UsageKun.app
```

Run the lightweight core check:

```sh
swift build
swift run UsageKunCoreCheck
```

This repository includes `UsageKunCoreCheck` because some Command Line Tools only environments do not provide a working `XCTest` or Swift Testing setup.

To inspect the local Claude 5-hour estimate and calibration details:

```sh
swift run UsageKunCoreCheck --claude-estimate
```

## Updating An Existing Install

Your settings and calibration data are stored outside the app bundle, so updating the app should not remove your preferences. You do not need to delete `~/.codex`, `~/.claude`, or `~/Library/Application Support/usage_kun`.

### If You Installed From Git

From the repository directory you already cloned:

```sh
cd usage_kun
git pull
./Scripts/package_app.sh
open UsageKun.app
```

`package_app.sh` rebuilds the release executable, stops a running `UsageKun` process if one is active, and replaces the local `UsageKun.app` bundle.

### If You Used GitHub Download ZIP

Download the latest source ZIP from GitHub, unzip it, open Terminal in the unzipped `usage_kun` folder, and run:

```sh
./Scripts/package_app.sh
open UsageKun.app
```

### If You Used The Release ZIP

1. Download the latest `UsageKun-macOS.zip` from [Releases](https://github.com/Kohei-SAWADA/usage_kun/releases/latest).
2. Quit the old usage-kun app from the menu bar.
3. Unzip `UsageKun-macOS.zip`.
4. Replace your old `UsageKun.app` with the new one.
5. Open the new `UsageKun.app`.

On first launch of the new version, macOS may show the "could not verify" warning again; approve it the same way as in [First Launch](#first-launch-apple-could-not-verify-usagekun-is-free-of-malware). If official Claude sync is enabled, macOS may ask for Claude Code Keychain access again after the update.

## Data Sources

usage-kun uses a staged data model:

1. Local logs: reads known Claude Code and Codex local usage logs for estimates.
2. Official usage sync: opt-in only; reuses local CLI sign-in tokens in read-only mode to fetch provider 5-hour and 1-week usage numbers.
3. Claude calibration: when official Claude sync succeeds, usage-kun can calibrate the local Claude 5-hour cap estimate for later fallback use.

See [docs/providers.md](docs/providers.md) for details.

## Privacy Model

- No telemetry.
- No cloud sync.
- No analytics SDK.
- No conversation content display.
- No automatic browser cookie reading.
- CLI sign-in tokens are not refreshed, copied, stored by this app, or logged.
- No Admin API keys or manual cookie headers are collected in this release.

See [PRIVACY.md](PRIVACY.md) for the full privacy note.

## Repository Layout

```text
Sources/UsageKun/
  main.swift
  Services/
    LaunchAtLoginService.swift
    UsageNotifier.swift
  Views/

Sources/UsageKunCore/
  Config/
    AppConfig.swift
    ClaudeCalibrationStore.swift
  OnboardingDetector.swift
  Providers/
    CLIOAuthUsageService.swift
    LocalLogUsageService.swift
  UsageNotificationPlanner.swift
  UsageSnapshot.swift
  UsageService.swift

Tests/UsageKunCoreCheck/
  main.swift

assets/screenshots/
  pinned-desktop-meter.png
  menu-bar-popover.png

Packaging/
  Info.plist

Scripts/
  package_app.sh
  package_release_zip.sh
  preflight_publication.sh
```

## Why Another Usage Meter?

There are already several AI usage monitors and menu bar utilities. usage-kun exists as a small, auditable implementation tuned for one workflow: keep Claude and Codex limits visible without opening a dashboard, while keeping authentication handling explicit and local.

The emphasis is on:

- local-first behavior
- clear provider boundaries
- small native macOS UI
- readable Swift code
- privacy-first credential handling

## Limitations

- Official usage endpoints can change without notice.
- Claude local-log quota estimates are best-effort. They deduplicate repeated JSONL rows by `requestId` and `message.id`, and can self-calibrate after opt-in official Claude usage sync succeeds.
- Official sync requires existing Claude Code / Codex CLI sign-in state on the same Mac.
- Notifications are intended for the packaged `UsageKun.app` build.
- The app is ad-hoc signed but not notarized, so first launch of a downloaded copy needs a one-time Gatekeeper approval.

## Release History

### v0.3.0

Per-provider visibility.

- Added Settings > Providers with Claude and Codex checkboxes. Only checked providers are shown in the menu bar, popover, and desktop meter; unchecked providers are not fetched at all. Both are checked by default.

Details: [docs/release-notes-v0.3.0.md](docs/release-notes-v0.3.0.md)

### v0.2.2

Plan-detection fixes for the local estimates.

- Fixed Max 20x plans being treated as Max 5x in the local Claude estimate (usage was overstated ~4x). Detection now reads the rate-limit tier fields in `~/.claude.json`, where the 5x/20x distinction actually lives.
- Added a "Claude plan" setting (Auto / Pro / Max 5x / Max 20x) for when auto-detection is wrong. Local estimate only; official sync is always exact.
- The Codex live rate-limit reader no longer requires the primary window to be exactly 300 minutes.

Details: [docs/release-notes-v0.2.2.md](docs/release-notes-v0.2.2.md)

### v0.2.1

Packaging and hardening fixes; no feature changes.

- Fixed the release zip shipping an app whose incomplete signature made Gatekeeper reject downloaded copies as "damaged". The bundle is now fully ad-hoc signed with sealed resources and verified during packaging.
- Stopped archiving extended attributes as AppleDouble `._*` files in the release zip.
- Codex local databases are now opened with `sqlite3 -readonly -batch`.
- Restricted the CI workflow token to read-only access.
- Documented release-zip installation and the one-time Gatekeeper approval.

Details: [docs/release-notes-v0.2.1.md](docs/release-notes-v0.2.1.md)

### v0.2.0

This update turns usage-kun into a clearer quota monitor for both short and weekly windows.

- Added first-class 5-hour and 1-week usage windows for Claude Code and Codex.
- Redesigned the pinned desktop meter and menu bar popover with primary and secondary quota bars.
- Kept the menu bar compact as `usage` plus a remaining-usage meter.
- Added one-click onboarding for official CLI usage sync.
- Added optional low-usage and reset notifications for the packaged app.
- Removed retired Admin API and Cookie/OAuth code paths.
- Added publication preflight checks for local-only files, build output, app bundles, and release artifacts.

Full notes: [docs/release-notes-v0.2.0.md](docs/release-notes-v0.2.0.md)

### v0.1.1

This update focused on making Claude Code 5-hour estimates more reliable while preserving the existing Codex behavior.

- Improved Claude local-log accuracy by deduplicating repeated JSONL usage rows with the `(requestId, message.id)` pair.
- Recalibrated initial Claude 5-hour caps for deduplicated weighted tokens.
- Added automatic Claude cap calibration after opt-in official Claude usage sync succeeds.
- Added `swift run UsageKunCoreCheck --claude-estimate` for checking the local Claude estimate.
- Fixed Claude cost estimation for Opus, Fable, Mythos, and cache-write token handling.

Full notes: [docs/release-notes-v0.1.1.md](docs/release-notes-v0.1.1.md)

### v0.1.0

Initial public release.

- Native macOS menu bar usage meter for Claude and Codex.
- Optional pinned desktop widget.
- Local-first usage display.
- Privacy-first credential handling and no telemetry.

## Development

```sh
swift build
swift run UsageKunCoreCheck
```

Package a release-style app bundle:

```sh
./Scripts/package_app.sh
```

Run the publication preflight:

```sh
./Scripts/preflight_publication.sh
```

Build a local release zip:

```sh
./Scripts/package_release_zip.sh
```

## License

MIT. See [LICENSE](LICENSE).
