# Windows

usage_kun for Windows is a native .NET 8 / WPF system-tray app with a compact floating usage meter. Supported Windows systems are Windows 10/11 on Intel / AMD PCs (x64) only. Windows ARM, including Windows running on Apple Silicon Macs, is unsupported from v0.4.2 onward. macOS support, including Apple Silicon, is unchanged.

## Download and install

The current Windows release is [v0.4.7](https://github.com/Kohei-SAWADA/usage_kun/releases/tag/v0.4.7) (2026-10-11). Choose [UsageKun-Windows-x64.zip](https://github.com/Kohei-SAWADA/usage_kun/releases/download/v0.4.7/UsageKun-Windows-x64.zip). macOS remains v0.4.4:

| Computer | Download |
| --- | --- |
| Intel / AMD Windows PC (x64) | `UsageKun-Windows-x64.zip` |

Check **Settings > System > About > System type** for an x64-based processor. Use **Extract All...** on the ZIP, keep the extracted files together, and run `UsageKun.exe`. The runtime is included; no separate .NET installation is required. The Windows executable is unsigned. Quit an existing instance before replacing its executable. Settings are kept separately.

## Update an existing install

Updates are installed manually; there is no automatic updater or installer.

1. Download `UsageKun-Windows-x64.zip` from [the v0.4.7 release](https://github.com/Kohei-SAWADA/usage_kun/releases/tag/v0.4.7) on an Intel / AMD Windows PC (x64).
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
- Provider visibility, refresh interval, window position, optional always-on-top, and start-with-Windows settings.

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
Claude quota unknown until official sync returns usable quota fields.
Existing plan/calibration settings do not turn logged tokens into a percentage.

Codex quota belongs to Codex even when its CLI sign-in uses a ChatGPT account.
It does not measure ordinary ChatGPT chat limits or API billing. The app does not
provide a separate ChatGPT chat-quota meter. See [provider details](providers.md#windows-quota-accuracy-v043).

## Sign in and sync

Sign in to the relevant CLI or IDE **inside Windows**. In Windows 0.4.7, review the sources you want to use in Settings, then choose **Start sync** to save explicit approval. **Save** alone does not approve sync. Public v0.4.4 retains its previous opt-in Save behavior. Existing explicit off choices remain off when upgrading. Gemini has a separate provider-display option, which remains off by default. Missing or unavailable usage is displayed with a reason and a next action.

| Source | Windows data |
| --- | --- |
| Codex official | `%USERPROFILE%\.codex\auth.json` |
| Claude official | `%USERPROFILE%\.claude\.credentials.json` |
| Codex local logs | `%USERPROFILE%\.codex\logs_2.sqlite` live rate limits and `%USERPROFILE%\.codex\sessions\**\*.jsonl` rate-limit events; the newest valid record wins |
| Claude local logs | `%USERPROFILE%\.claude\projects\**\*.jsonl` logged tokens and cost estimates; subscription quota remains unknown |
| Gemini | The current user's running Antigravity language-server process and loopback quota service |

Official requests go only to the vendor endpoints. Antigravity's ephemeral credential is sent only to its discovered loopback service. Redirects are not followed. Mac sign-in files are not automatically copied or reused.

## Current Windows release

Windows **0.4.7** includes the latest source changes described here. App and core assemblies are both 0.4.7. The [v0.4.7 release](https://github.com/Kohei-SAWADA/usage_kun/releases/tag/v0.4.7) includes the exact Windows build-source snapshot, input hashes, package checksums, and build manifest. [Windows build provenance](windows-build-v0.4.7.json) records the source and packaged executable identity. macOS remains v0.4.4.

All four **Sync sources** checkboxes start checked for a new configuration: local CLI logs, Claude usage sync, Codex usage sync, and Gemini quota from Antigravity. Those selections are separate from permission to begin reading sources. Review them in Settings, uncheck unwanted sources, then choose **Start sync** to explicitly approve and save the selected sources. **Save** alone only saves preferences. Existing explicit off choices remain off. Existing configurations without an explicit sync approval and unreadable/corrupt configurations require approval; a failed save does not authorize sync.

Before approval, startup, timer ticks, tray refresh, and settings changes do not read usage sources or credentials and do not contact provider or Antigravity services. The service layer also refuses direct refresh calls. After approval, only visible providers and enabled sources are fetched. A settings save failure pauses sync in the running session. If the app is restarted before that failure is resolved, the last successfully saved approval and source selections can be reloaded; an unsaved opt-out is not a durable settings change. Isolated WPF checks have passed on Windows. A separate read-only diagnostic using the matching 0.4.7 Core successfully fetched Codex official usage; the running GUI refresh result and physical meter/tray interaction were not captured.

## Settings and startup

Configuration lives at `%APPDATA%\usage_kun\config.json`. Shared settings use the same camelCase keys as macOS. Windows adds `widgetPositionX` and `widgetPositionY` for the meter position, and `alwaysOnTop` for window stacking.

**Settings > Behavior > Always on top** defaults to off, including when updating from an older version. Other applications can cover the meter and settings window normally. Enable the checkbox and click **Save** to keep usage_kun above other applications. Saving applies the change to the existing meter immediately and preserves it across restarts; **Cancel** discards changes.

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

Windows 0.4.7 validation on 2026-10-11: the Windows Release solution build passed with zero warnings/errors; `UsageKun.Core.Check`, the self-contained win-x64 core-check executable, and `UsageKun.UI.Check` passed using isolated synthetic fixtures. Cases verify no source, credential, discovery or request calls before approval, normal Save versus explicit Start sync, persisted opt-outs, malformed/missing/duplicate approval, startup persistence, and failed saves. The self-contained x64 ZIP was rebuilt from the recorded source snapshot. Its extracted executable matches the publish output byte-for-byte; source, ZIP, and executable SHA-256 hashes are recorded in the dated build manifest. A separate read-only diagnostic using the matching 0.4.7 Core successfully fetched Codex official usage. The installed packaged app showed version 0.4.7 in Settings and passed restart/single-instance checks. Physical meter/tray visuals and logout/login startup were not verified.

Core and WPF checks use synthetic fixtures to cover parsing, opt-in gates, error paths, refresh/settings handlers, Save/Cancel, duration labels, and small-screen layout. Quota regression cases include 94.9, 95, 95.1, 99, 99.5, and 100, used/remaining conversion, missing windows, stale records, expired resets, and separation of providers and model buckets. The WPF checks invoke the actual Click handlers, not OS mouse input.

Live Codex official usage was verified through a separate read-only diagnostic using the matching Core, not by capturing the running GUI refresh. Live Claude and Antigravity sync, physical meter/tray visuals, and logout/login startup were not verified. See the release notes for the build and check results for each version.

Codex live rate limits in `logs_2.sqlite` are read in read-only mode; the SQLite runtime is bundled, so no separate SQLite installation is needed. Auxiliary token/thread statistics from `state_5.sqlite` and Windows toast notifications are not implemented. Antigravity relies on its IDE's local API, which may change.
