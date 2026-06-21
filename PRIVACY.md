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
- API keys or manual headers saved by usage-kun in macOS Keychain

## What The App Sends

When official usage sync is enabled, usage-kun sends the relevant sign-in token only to that provider's usage endpoint.

When Admin API cost sync is enabled, usage-kun sends the relevant Admin API key only to that provider's API endpoint.

## What The App Does Not Do

- It does not include telemetry.
- It does not upload usage logs to a custom server.
- It does not show or export conversation content.
- It does not automatically read browser cookies.
- It does not refresh CLI sign-in tokens.
- It does not store CLI sign-in tokens.
- It does not write API keys to config files.
- It does not log credentials.

## Local Storage

Settings are stored in:

```text
~/Library/Application Support/usage_kun/config.json
```

Credentials are stored in macOS Keychain.

## Endpoint Stability

Some integrations rely on provider endpoints and local CLI file formats that may change. If an integration breaks, usage-kun should fail with a visible message and fall back to local estimates when possible.

