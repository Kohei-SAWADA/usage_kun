# usage_kun v0.4.3

Windows quota readings no longer turn an expired snapshot or a rounded decimal
into a full allowance. This release contains Windows assets only. macOS remains
on the existing v0.4.2 download; its source, settings, behavior, and published
asset are unchanged and are not rebuilt or replaced for this release.

| Platform | Download |
| --- | --- |
| Windows (Intel / AMD, x64) | [UsageKun-Windows-x64.zip](https://github.com/Kohei-SAWADA/usage_kun/releases/download/v0.4.3/UsageKun-Windows-x64.zip) · [SHA-256](https://github.com/Kohei-SAWADA/usage_kun/releases/download/v0.4.3/UsageKun-Windows-x64.zip.sha256) |
| macOS (Apple Silicon, unchanged v0.4.2) | [UsageKun-macOS.zip](https://github.com/Kohei-SAWADA/usage_kun/releases/download/v0.4.2/UsageKun-macOS.zip) |

## Windows fixes

- Remove the local Codex reset-expiry shortcut that invented 100% remaining
  and a `fresh` label. A synthetic 95% remaining record with a past reset
  reproduces the old result; it now stays unknown until a new reading arrives.
- Keep decimal percentages through the weekly path and display. 99.5% remains
  99.5%. Only an exact 100% reading displays 100% or fills the tray bar completely.
- Treat stale, future-dated, missing-timestamp, expired, and invalid readings as
  unknown. Local quota records expire at 30 minutes; timestamps more than
  5 minutes in the future are rejected. Rereading an old file does not make
  its quota current. Failed authenticated sync leaves quota unknown, including
  when historical local logs belong to an unverified account. Local-only readings
  do not verify account switching or activity on other devices. A failed refresh
  does not retain an old percentage as
  a successful current reading.
- Use field-defined units and reported window durations. Used and remaining
  percentages are converted once, Claude OAuth utilization remains a percentage,
  a weekly primary window stays weekly, and missing windows stay unknown.
  General Codex quota remains separate from model-specific limits.
- Stop presenting Claude token-cap estimates as subscription remaining quota
  or reset times on Windows. Local logged token and API-equivalent cost details
  remain available; usable opt-in official Claude quota is required for a
  percentage. Existing calibration/settings files can remain in place.

Codex quota is Codex quota even when the CLI uses a ChatGPT sign-in. It does not
measure ordinary ChatGPT chat limits or API billing, and this app does not add a
separate ChatGPT chat-quota meter. Existing sync remains opt-in and reads existing
credentials without saving, refreshing, or logging them. No model request is
made to manufacture a new quota reading.

## Updating

On an Intel / AMD Windows PC (x64), quit usage_kun, extract the v0.4.3 ZIP,
and replace the complete app contents at the existing location. Keep
`%APPDATA%\usage_kun` and the existing CLI sign-ins/logs; no migration is required.
Start `UsageKun.exe` and choose **Refresh now**. The package includes the runtime;
the executable is unsigned. Windows ARM remains unsupported.

See the [Windows guide](https://github.com/Kohei-SAWADA/usage_kun/blob/v0.4.3/docs/windows.md) for update steps and unknown-value guidance.
macOS users continue to use the unchanged v0.4.2 package.

## Validation and limits

- Synthetic regression coverage includes 94.9, 95, 95.1, 99, 99.5, and 100,
  used/remaining conversion, Claude OAuth values below 1, missing windows,
  weekly-only and reversed windows, invalid values, expired resets, stale and
  future timestamps, failed reads, and separation of providers/model buckets.
- Windows CI builds the solution, runs core and isolated WPF checks, reruns
  the core checks as a self-contained single-file x64 executable to exercise
  bundled SQLite, and packages the Windows x64 ZIP with its SHA-256 file.
  The existing macOS CI build/core checks do not publish a macOS asset.
- Live authenticated Windows account comparison and physical mouse/tray
  interaction have not been verified. WPF checks use synthetic fixtures and
  invoke handlers rather than physical mouse input. The reproduced defects
  do not establish that the user's live 95% discrepancy had the same cause.
- No macOS UI inspection is repeated for this Windows-only implementation.
  Windows auxiliary Codex statistics from `state_5.sqlite` and toast notifications
  remain unsupported.

The review used similar Windows open-source projects as design references; no
third-party code was copied. See [provider details](https://github.com/Kohei-SAWADA/usage_kun/blob/v0.4.3/docs/providers.md#windows-quota-accuracy-v043)
for source distinctions, references, and limitations.
