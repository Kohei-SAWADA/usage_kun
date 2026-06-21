# Repository Guidelines

This repository contains usage-kun, a native macOS menu bar utility for viewing Claude and Codex usage at a glance.

## Product Direction

usage-kun is a usage meter, not a dashboard. Prefer compact, glanceable UI over large analytical screens.

The app should help a user quickly answer:

1. How much usage is left?
2. When does it reset?
3. Is it safe to start a large coding session now?

## Engineering Guidelines

- Keep the app native: SwiftPM, AppKit, and SwiftUI.
- Keep credential handling in `UsageKunCore/Security`.
- Keep provider-specific behavior behind `UsageService` implementations.
- Do not add telemetry or analytics SDKs.
- Do not store tokens or API keys in config files.
- Do not log credentials.
- Keep docs in English.

## Checks

Run these before publishing changes:

```sh
swift build
swift run UsageKunCoreCheck
```

If UI behavior changes, manually inspect both the menu bar popover and the pinned desktop widget.

