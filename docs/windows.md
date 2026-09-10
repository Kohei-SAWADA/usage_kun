# Windows

usage_kun for Windows is a native .NET 8 / WPF system-tray app with a compact floating usage meter.

## Download and install

Choose the ZIP from [the latest release](https://github.com/Kohei-SAWADA/usage_kun/releases/latest):

| Computer | Download |
| --- | --- |
| Intel / AMD Windows PC | `UsageKun-Windows-x64.zip` |
| Windows ARM64, including Parallels on Apple Silicon | `UsageKun-Windows-arm64.zip` |

Extract the ZIP and run `UsageKun.exe`. The runtime is included; no separate .NET installation is required. The Windows executable is unsigned. Quit an existing instance before replacing its executable. Settings are kept separately.

## Features

- Tray icon, refresh/settings menu, and a draggable floating meter.
- Refresh and settings controls are separate from the drag handle. Refresh progress and the last update time are visible.
- Codex quota labels follow the reported duration: weekly-only plans show 1W, five-hour limits show 5H, and unknown durations show LIMIT. Both official sync and local logs handle primary-only, secondary-only, and reversed windows.
- Optional official Claude and Codex usage sync using existing Windows CLI sign-ins, without saving, refreshing, or logging credentials.
- Optional Gemini quota from the running Antigravity IDE in the same Windows user session.
- Independent settings window, persistent Save/Cancel controls, and scrolling for small screens.
- Provider visibility, refresh interval, window position, and start-with-Windows settings.

## Sign in and enable sync

Sign in to the relevant CLI or IDE **inside Windows**, then enable its sync option in Settings. Gemini has separate provider-display and quota-sync options. Sync is opt-in. Missing or unavailable usage is displayed with a reason and a next action.

| Source | Windows data |
| --- | --- |
| Codex official | `%USERPROFILE%\.codex\auth.json` |
| Claude official | `%USERPROFILE%\.claude\.credentials.json` |
| Codex local logs | `%USERPROFILE%\.codex\sessions\**\*.jsonl` rate-limit events |
| Claude local logs | `%USERPROFILE%\.claude\projects\**\*.jsonl` usage and `.claude.json` plan data |
| Gemini | The current user's running Antigravity language-server process and loopback quota service |

Official requests go only to the vendor endpoints. Antigravity's ephemeral credential is sent only to its discovered loopback service. Redirects are not followed. Mac sign-in files are not automatically copied or reused.

## Settings and startup

Configuration lives at `%APPDATA%\usage_kun\config.json`. Shared settings use the same camelCase keys as macOS. Windows adds `widgetPositionX` and `widgetPositionY` for the meter position.

Start-with-Windows uses the current user's `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` key and does not require administrator rights.

## Build and check

Use the .NET 8 SDK:

```powershell
dotnet build Windows/UsageKun.Windows.sln -c Release
dotnet run --project Windows/tests/UsageKun.Core.Check -c Release
dotnet run --project Windows/tests/UsageKun.UI.Check -c Release
pwsh ./Scripts/package_windows.ps1 -Runtime win-x64
pwsh ./Scripts/package_windows.ps1 -Runtime win-arm64
```

The package script runs core checks before creating a self-contained ZIP and its SHA-256 file. The UI check uses temporary settings and synthetic fixtures, without touching real credentials or startup registration. Core checks also run on macOS/Linux; WPF execution requires Windows.

## Validation and limits

The Windows ARM64 build was installed and launched on Windows 11 in Parallels. Core checks and 27 isolated WPF checks passed, covering refresh/settings handlers, Save/Cancel, duration labels, and small-screen layout. Archive contents and installed executable hashes were checked.

Live account sync has not been verified with authenticated Windows accounts; parsers, opt-in gates, and error paths are covered by fixtures. Physical mouse and tray clicks were not verified in the Parallels session. The WPF checks invoke the actual Click handlers, not OS mouse input.

Codex SQLite live logs and auxiliary statistics, and Windows toast notifications, are not implemented. Use official sync or session JSONL for Codex. Antigravity relies on its IDE's local API, which may change.
