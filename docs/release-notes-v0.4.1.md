# usage_kun v0.4.1

Windows downloads are now available alongside the macOS app.

| Platform | Download |
| --- | --- |
| macOS (Apple Silicon) | `UsageKun-macOS.zip` |
| Windows (Intel / AMD) | `UsageKun-Windows-x64.zip` |
| Windows ARM64 / Parallels on Apple Silicon | `UsageKun-Windows-arm64.zip` |

## Windows

- Native tray app and floating usage meter with working refresh/settings handlers and an independent settings window.
- Codex 1W / 5H labels reflect the actual limit duration, including weekly-only plans.
- Opt-in official Claude/Codex usage sync and Gemini (Antigravity) local quota support.
- Clear unavailable-data messages, small-screen scrolling, and persistent settings.
- Self-contained executables include the .NET runtime. Extract the ZIP and run UsageKun.exe. Sign in to the CLI or Antigravity inside Windows before enabling sync.

## Validation

Windows ARM64 installation/startup, core checks, and 27 isolated WPF checks passed in Parallels. GitHub CI builds the Windows solution, runs core and WPF checks, and packages both Windows architectures. SHA-256 checksums are included.

Live account sync and physical mouse/tray interaction have not been verified in the Parallels session. Windows SQLite log reading and toast notifications remain unsupported; see [the Windows guide](https://github.com/Kohei-SAWADA/usage_kun/blob/main/docs/windows.md).

## macOS

The app behavior is unchanged from v0.4.0; the version number is aligned with this release. The macOS app is ad-hoc signed and not notarized. Windows executables are unsigned.
