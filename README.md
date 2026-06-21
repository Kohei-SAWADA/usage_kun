# usage-kun

<p align="right">
  <strong>English</strong> |
  <a href="README.ja.md">日本語</a>
</p>

usage-kun is a small, privacy-first macOS menu bar app for keeping Claude and Codex usage visible while you work.

It is built as a personal utility: a compact usage meter rather than a full analytics dashboard. It reads local CLI usage data by default, can optionally reuse local CLI sign-in tokens for official usage numbers, and stores user-supplied API keys only in macOS Keychain.

This project is not affiliated with, endorsed by, or sponsored by OpenAI, Anthropic, or any other provider.

## Screenshots

usage-kun is designed to stay visible without becoming a dashboard. The pinned desktop meter keeps the main limits in the corner of the screen, while the menu bar popover shows the fuller provider breakdown when needed.

<p align="center">
  <img src="assets/screenshots/pinned-desktop-meter.png" alt="Pinned desktop usage meter showing Codex and Claude Code usage in the top-left corner of macOS." width="680">
</p>

<p align="center">
  <em>Pinned desktop meter for at-a-glance Claude and Codex usage.</em>
</p>

<p align="center">
  <img src="assets/screenshots/menu-bar-popover.png" alt="Menu bar popover showing Codex and Claude Code usage cards, reset timing, sync source, and settings tab." width="520">
</p>

<p align="center">
  <em>Menu bar popover with detailed usage cards and quick settings access.</em>
</p>

## Features

- Native macOS menu bar app built with SwiftPM, AppKit, and SwiftUI
- Compact popover from the menu bar
- Optional pinned desktop widget for at-a-glance usage
- Claude and Codex local-log usage estimates
- Optional official usage sync for Claude Code and Codex CLI sign-ins
- Optional OpenAI and Anthropic Admin API cost views
- Credentials stored in macOS Keychain, not in config files
- No telemetry and no bundled analytics

## Requirements

- macOS 14 or newer
- Swift 6 or newer
- Xcode Command Line Tools

## Quick Start

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

## Data Sources

usage-kun uses a staged data model:

1. Local logs: reads known Claude Code and Codex local usage logs for estimates.
2. Official usage sync: opt-in only; reuses local CLI sign-in tokens in read-only mode to fetch provider usage numbers.
3. Admin API costs: opt-in only; reads Admin API keys from macOS Keychain.
4. Browser/OAuth phase: UI and storage placeholders exist, but automatic browser cookie reading is not implemented.

See [docs/providers.md](docs/providers.md) for details.

## Privacy Model

- No telemetry.
- No cloud sync.
- No analytics SDK.
- No conversation content display.
- No automatic browser cookie reading.
- CLI sign-in tokens are not refreshed, copied, stored by this app, or logged.
- API keys and manual cookie headers are stored in macOS Keychain.

See [PRIVACY.md](PRIVACY.md) for the full privacy note.

## Repository Layout

```text
Sources/UsageKun/
  main.swift
  Services/
  Views/

Sources/UsageKunCore/
  Config/
  Providers/
  Security/
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
- Claude local-log quota estimates are best-effort and may not exactly match subscription limits.
- OpenAI Admin API costs are separate from Codex ChatGPT plan limits.
- Anthropic Admin API cost data is intended for organization accounts and may not work for personal accounts.
- The app is unsigned unless you sign it yourself.

## Development

```sh
swift build
swift run UsageKunCoreCheck
```

Package a release-style app bundle:

```sh
./Scripts/package_app.sh
```

## License

MIT. See [LICENSE](LICENSE).
