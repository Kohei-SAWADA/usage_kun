# Windows

usage_kun for Windows is a native .NET 8 / WPF system-tray app with a compact floating usage meter. Supported Windows systems are Windows 10/11 on Intel / AMD PCs (x64) only. Windows ARM, including Windows running on Apple Silicon Macs, is unsupported from v0.4.2 onward. macOS support, including Apple Silicon, is unchanged.

## Download and install

Choose the ZIP from [the latest release](https://github.com/Kohei-SAWADA/usage_kun/releases/latest):

| Computer | Download |
| --- | --- |
| Intel / AMD Windows PC (x64) | `UsageKun-Windows-x64.zip` |

Check **Settings > System > About > System type** for an x64-based processor. Use **Extract All...** on the ZIP, keep the extracted files together, and run `UsageKun.exe`. The runtime is included; no separate .NET installation is required. The Windows executable is unsigned. Quit an existing instance before replacing its executable. Settings are kept separately.

## Update an existing install

Updates are installed manually; there is no automatic updater or installer.

1. Download `UsageKun-Windows-x64.zip` from [the latest release](https://github.com/Kohei-SAWADA/usage_kun/releases/latest) on an Intel / AMD Windows PC (x64).
2. Right-click the running app's tray icon and choose **Quit usage_kun**.
3. Use **Extract All...**, then replace the complete app contents in the existing app folder. Keeping the same folder preserves shortcut and startup paths; no uninstall is needed.
4. Start the new `UsageKun.exe` and choose **Refresh now** from the tray menu.

Keep `%APPDATA%\usage_kun` (settings and calibration), `%USERPROFILE%\.codex`, `%USERPROFILE%\.claude`, and `%USERPROFILE%\.claude.json` (existing CLI sign-in/log and plan data). No settings export or migration is required. If you move the app, update your shortcuts, open the new executable, and save **Settings > Behavior > Start with Windows** with the desired value to update startup registration.

Windows ARM installations have no supported update from v0.4.2 onward. Installing the x64 ZIP on Windows ARM is also unsupported.

## Features

- Tray icon, refresh/settings menu, and a draggable floating meter.
- Refresh and settings controls are separate from the drag handle. Refresh progress and the last update time are visible.
- Codex quota labels follow the reported duration: weekly-only plans show 1W, five-hour limits show 5H, and unknown durations show LIMIT. Both official sync and local logs handle primary-only, secondary-only, and reversed windows.
- Optional official Claude and Codex usage sync using existing Windows CLI sign-ins, without saving, refreshing, or logging credentials.
- Optional Gemini quota from the running Antigravity IDE in the same Windows user session.
- Independent settings window, persistent Save/Cancel controls, and scrolling for small screens.
- Provider visibility, refresh interval, window position, and start-with-Windows settings.

## Reading the meter (v0.4.3)

Percentages show **remaining** quota. A reported 5% used becomes 95% left;
95% used becomes 5% left. Decimal values are kept through parsing and window
selection, then displayed to one decimal place when needed. A 99.5% reading
stays 99.5%; only an exact 100% reading displays 100% or fills the tray bar
completely.

Expired windows do not imply a full allowance. A local Codex record with a past
reset, no usable event timestamp, an age of 30 minutes or more, or a timestamp
more than 5 minutes in the future cannot supply current remaining quota. Missing,
invalid, stale, or unavailable values show unknown (`--%`) with an explanation.
Refreshing the meter rereads its sources; it cannot make an old CLI record current.
If authenticated usage sync fails, current quota stays unknown even if recent
local records exist: a historical log does not prove it belongs to the currently
signed-in account. A failed refresh does not retain an old percentage as a
successful current reading. With local logs alone, a displayed Codex value is a
last recorded limit; account switching and activity on other devices are not
verified against that record.

Local Claude conversation logs supply logged token counts and an API-equivalent
cost estimate, not a reliable subscription quota or reset. Windows now leaves
Claude quota unknown until opt-in official sync returns usable quota fields.
Existing plan/calibration settings do not turn logged tokens into a percentage.

Codex quota belongs to Codex even when its CLI sign-in uses a ChatGPT account.
It does not measure ordinary ChatGPT chat limits or API billing. The app does not
provide a separate ChatGPT chat-quota meter. See [provider details](providers.md#windows-quota-accuracy-v043).

## Sign in and enable sync

Sign in to the relevant CLI or IDE **inside Windows**, then enable its sync option in Settings. Gemini has separate provider-display and quota-sync options. Sync is opt-in. Missing or unavailable usage is displayed with a reason and a next action.

| Source | Windows data |
| --- | --- |
| Codex official | `%USERPROFILE%\.codex\auth.json` |
| Claude official | `%USERPROFILE%\.claude\.credentials.json` |
| Codex local logs | `%USERPROFILE%\.codex\logs_2.sqlite` live rate limits and `%USERPROFILE%\.codex\sessions\**\*.jsonl` rate-limit events; the newest valid record wins |
| Claude local logs | `%USERPROFILE%\.claude\projects\**\*.jsonl` logged tokens and cost estimates; subscription quota remains unknown |
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
```

The package script runs core checks before creating a self-contained ZIP and its SHA-256 file. The UI check uses temporary settings and synthetic fixtures, without touching real credentials or startup registration. Core checks also run on macOS/Linux; WPF execution requires Windows.

## Validation and limits

Core and WPF checks use synthetic fixtures to cover parsing, opt-in gates, error paths, refresh/settings handlers, Save/Cancel, duration labels, and small-screen layout. Quota regression cases include 94.9, 95, 95.1, 99, 99.5, and 100, used/remaining conversion, missing windows, stale records, expired resets, and separation of providers and model buckets. The WPF checks invoke the actual Click handlers, not OS mouse input.

Live account sync has not been verified with authenticated Windows accounts. Physical mouse and tray interaction on an Intel / AMD Windows PC (x64) has not been verified. See the release notes for the build and check results for each version.

Codex live rate limits in `logs_2.sqlite` are read in read-only mode; the SQLite runtime is bundled, so no separate SQLite installation is needed. Auxiliary token/thread statistics from `state_5.sqlite` and Windows toast notifications are not implemented. Antigravity relies on its IDE's local API, which may change.
