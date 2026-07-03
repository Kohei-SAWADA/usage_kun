# Architecture

usage-kun is currently implemented as a native macOS app with SwiftPM, AppKit, and SwiftUI.

The original product idea left room for a future Tauri implementation, but the current repository focuses on a small native macOS utility that can be built with the Swift toolchain alone.

## Structure

```text
Sources/UsageKun/
  main.swift
  Services/
    LaunchAtLoginService.swift
  Views/
    AppTheme.swift
    DesktopWidgetView.swift
    ProviderLogo.swift
    SettingsView.swift
    StatusIconRenderer.swift
    StatusPill.swift
    UsageCardView.swift
    UsageDashboardView.swift

Sources/UsageKunCore/
  Config/
    AppConfig.swift
    ClaudeCalibrationStore.swift
  Providers/
    AdminAPIUsageService.swift
    BrowserOAuthUsageService.swift
    CLIOAuthUsageService.swift
    LocalLogUsageService.swift
  Security/
    KeychainCredentialStore.swift
  UsageSnapshot.swift
  UsageService.swift

Tests/UsageKunCoreCheck/
  main.swift
```

## Boundaries

- `UsageKun`: AppKit and SwiftUI user interface.
- `UsageKunCore`: usage models, providers, credential storage, and aggregation.
- `UsageService`: provider abstraction consumed by UI state.
- `CompositeUsageService`: combines local logs, official usage sync, Admin API costs, and opt-in browser/OAuth status.
- `LocalLogUsageService`: reads known local Claude and Codex usage files.
- `ClaudeCalibrationStore`: stores Claude 5-hour cap calibration learned from official usage sync.
- `CLIOAuthUsageService`: opt-in official usage sync using existing local CLI sign-ins.
- `AdminAPIUsageService`: optional organization cost sync through provider Admin APIs.
- `BrowserOAuthUsageService`: opt-in state and messaging for future browser/OAuth integrations.
- `KeychainCredentialStore`: stores user-supplied secrets in macOS Keychain.

UI code should consume normalized `UsageSnapshot` values rather than reading provider files directly.

## Data Flow

```text
Local files / Keychain / Provider APIs
        |
        v
UsageService implementations
        |
        v
CompositeUsageService
        |
        v
UsageStore
        |
        v
SwiftUI views
```

## Verification

This repository uses a small executable check target:

```sh
swift run UsageKunCoreCheck
```

This keeps the core checks usable in Command Line Tools only environments where `XCTest` or Swift Testing may not be available.

## Future Portability

If the app is ever ported to Tauri or another desktop stack, keep these boundaries:

- provider quirks stay in backend/provider adapters
- UI receives normalized `UsageSnapshot` values
- credentials do not flow into UI views
- macOS and cross-platform credential storage stay isolated
