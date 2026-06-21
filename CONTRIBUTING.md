# Contributing

Thanks for taking a look at usage-kun.

## Development Setup

Requirements:

- macOS 14 or newer
- Swift 6 or newer
- Xcode Command Line Tools

Build and check:

```sh
swift build
swift run UsageKunCoreCheck
```

Package an app bundle:

```sh
./Scripts/package_app.sh
```

## Guidelines

- Keep the app local-first.
- Do not add telemetry.
- Do not log credentials.
- Store credentials in macOS Keychain.
- Keep provider-specific logic behind `UsageService` implementations.
- Keep UI copy compact; this is a menu bar meter, not a dashboard.
- Document provider assumptions in `docs/providers.md`.
- Document structural changes in `docs/architecture.md`.

## Pull Requests

Please include:

- what changed
- how it was tested
- any privacy or credential-handling impact

