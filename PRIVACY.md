# Privacy

usage-kun is designed as a local-first utility.

## What The App Reads

Depending on your settings, usage-kun may read:

- `~/.codex/logs_2.sqlite`
- `~/.codex/sessions/**/*.jsonl`
- `~/.codex/state_5.sqlite`
- `~/.codex/auth.json` for opt-in official Codex usage sync
- `~/.claude/projects/**/*.jsonl`
- `~/.claude.json`
- the macOS Keychain item used by Claude Code for opt-in official Claude usage sync

## What The App Sends

When official usage sync is enabled, usage-kun sends the relevant sign-in token only to that provider's usage endpoint.

## What The App Does Not Do

- It does not include telemetry.
- It does not upload usage logs to a custom server.
- It does not show or export conversation content.
- It does not automatically read browser cookies.
- It does not refresh CLI sign-in tokens.
- It does not store CLI sign-in tokens.
- It does not collect Admin API keys or manual cookie headers in this release.
- It does not log credentials.

## Local Storage

Settings are stored in:

```text
~/Library/Application Support/usage_kun/config.json
```

Claude Code credentials remain in the Keychain item created by Claude Code itself. usage-kun reads that item only when official Claude sync is enabled.

## Endpoint Stability

Some integrations rely on provider endpoints and local CLI file formats that may change. If an integration breaks, usage-kun should fail with a visible message and fall back to local estimates when possible.

## Optional Gemini (Antigravity) quota

When enabled in Settings, usage_kun discovers the current user's running Antigravity language server and reads quota over a loopback connection. Its ephemeral CSRF credential stays in memory and is never saved or logged. This integration does not send the credential to a remote endpoint. It requires Antigravity to be running and signed in.

## Windows

The Windows app reads local CLI logs from the Windows user profile. Official Claude/Codex sync and Antigravity quota sync require explicit settings opt-in. Windows CLI sign-in files remain in their existing locations; usage_kun does not persist or refresh their credentials. Configuration is stored under `%APPDATA%\usage_kun`. The Mac account's sign-in files are not copied into Windows.
