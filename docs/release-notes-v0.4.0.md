# usage_kun v0.4.0

This release adds optional Gemini quota display from the running Antigravity IDE and fixes desktop widget controls and Codex window labels.

- The pinned widget's refresh and settings buttons accept clicks reliably. Settings opens in a separate, reusable window.
- Codex labels follow the reported quota duration: weekly-only plans show **1W / 1-WEEK**, and five-hour limits show **5H / 5-HOUR**. Unknown durations show **LIMIT**. Both official sync and local-log fallback preserve the duration.
- A sole secondary limit is displayed as the primary bar. When two limits are present, the shorter window is shown first.
- Gemini (Antigravity) can be enabled in Settings. It reads quota from the running local IDE without saving or logging its ephemeral credentials. Missing quota values remain unknown.
- Provider changes during an active refresh are reflected after the refresh finishes.

## Validation

- `swift build` and `swift run UsageKunCoreCheck` pass, including weekly-only, secondary-only, dual-window, reversed-window, and unknown-duration Codex fixtures.
- The user confirmed the installed macOS build works after the fixes.
- The release archive is checked by extraction and strict code-signature verification.

## Installation

Download `UsageKun-macOS.zip`, unzip it, and move `UsageKun.app` into `/Applications`.

Requires macOS 14 or later. The ZIP contains an Apple Silicon build, ad-hoc signed and not notarized. Intel Mac users can build from source with Swift 6 and Xcode Command Line Tools.
