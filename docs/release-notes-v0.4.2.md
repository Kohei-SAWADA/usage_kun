# usage_kun v0.4.2

Windows now supports Intel / AMD PCs (x64) only, and Codex quota no longer misses newer live local readings. macOS behavior, including Apple Silicon support, is unchanged.

| Platform | Download |
| --- | --- |
| macOS (Apple Silicon) | `UsageKun-macOS.zip` |
| Windows (Intel / AMD, x64) | `UsageKun-Windows-x64.zip` |

## Windows

- Remove Windows ARM packaging, CI builds, and ARM-specific Antigravity process discovery. Reject Windows build targets other than x64. Windows ARM, including Windows on Apple Silicon Macs, is no longer supported. Older releases and their assets are retained as history.
- Read Codex live quota from `logs_2.sqlite` in read-only mode, then compare its event timestamp with session JSONL records. Previously a stale session could show 80% remaining while a newer live event reported 25%; this is reproduced in a regression fixture.
- Exclude model-specific rate-limit records from the General Codex quota. Previously a newer model-specific session event could overwrite the General reading.
- Keep remaining-quota conversion, quota-window labels, opt-in official sync precedence, refresh cadence, and settings schema unchanged. Check absolute reset timestamps, timezone offsets, event-relative reset delays, subsecond ordering, and database fallback paths.
- Bundle SQLite with the self-contained executable; users do not need a separate SQLite or .NET installation.

## Updating

Quit usage-kun, extract the appropriate release ZIP, and replace the app at its existing location. Keep `%APPDATA%\usage_kun` on Windows or `~/Library/Application Support/usage_kun` on macOS. CLI sign-ins and logs also remain in place; no settings migration is needed.

If you move the app, update its shortcuts and startup registration. See the detailed [English](../README.md#updating-an-existing-install) or [Japanese](../README.ja.md#既に使っている場合のアップデート) instructions. Windows ARM has no supported update from this version onward.

## Validation and limits

- Local macOS Swift build, core checks, publication preflight, and ZIP extraction/signature verification passed. macOS source and tests are unchanged; only release metadata advances to 0.4.2.
- Windows core fixtures cover the reproduced stale-source and wrong-bucket failures, newest-source selection, corrupt/missing/incompatible database fallback, reset formats, timezone offsets, official sync, and existing Claude/Gemini behavior.
- GitHub CI builds on Windows x64, runs core and isolated WPF checks, runs the core fixtures again as a self-contained single-file x64 executable to verify bundled SQLite, and builds the downloadable x64 ZIP. CI also runs the macOS build and core checks.
- Live authenticated Windows account comparison and physical mouse/tray interaction on an Intel / AMD PC have not been verified. Automated WPF checks use synthetic data; they do not simulate physical mouse input. macOS manual UI inspection was not repeated because its implementation is unchanged.
- Windows auxiliary Codex statistics from `state_5.sqlite` and toast notifications remain unsupported. The macOS app is ad-hoc signed and not notarized; the Windows executable is unsigned.

The confirmed fixes address local-source selection (including fallback after failed official sync). They do not establish that every live-account discrepancy has the same cause. See [provider details](providers.md#windows-codex-quota-v042).
