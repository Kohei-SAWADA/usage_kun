# Providers

usage-kun separates provider-specific data access from the UI. The UI consumes normalized `UsageSnapshot` values.

## Official Usage Sync

Official usage sync is opt-in per provider. It reuses sign-in tokens that the local CLI already stores on the machine, in read-only mode.

Tokens are not refreshed, copied to app storage, or logged. They are sent only to the matching provider endpoint.

These integrations are best-effort and may break if the provider changes CLI storage or usage endpoints.

### Claude

- Source: macOS Keychain item `Claude Code-credentials`, with `~/.claude/.credentials.json` as a fallback for older installs.
- Endpoint: `https://api.anthropic.com/api/oauth/usage`
- Headers include `Authorization: Bearer`, `anthropic-beta: oauth-2025-04-20`, and a Claude Code style `User-Agent`.
- Goal: match the usage numbers shown by Claude Code `/usage`.

### Codex

- Source: `~/.codex/auth.json`
- Token fields: `tokens.access_token` and optional `tokens.account_id`
- Endpoint: `https://chatgpt.com/backend-api/wham/usage`
- Headers include `Authorization: Bearer` and optional `ChatGPT-Account-Id`.
- Goal: match the usage numbers shown by Codex `/status`.

## Codex Local Logs

Primary local source:

- `~/.codex/logs_2.sqlite`
- Reads `codex.rate_limits` websocket events.
- Treats `rate_limits.primary.window_minutes == 300` as the 5-hour usage window.
- Displays remaining percentage as `100 - used_percent`.
- Displays `rate_limits.secondary` as a 7-day remaining window when available.

Fallback sources:

- `~/.codex/sessions/**/*.jsonl`
- `~/.codex/state_5.sqlite`

The fallback data is only an estimate and may not match official limits.

## Claude Local Logs

Sources:

- `~/.claude/projects/**/*.jsonl`
- `~/.claude.json`

Read fields:

- `message.usage`
- `message.model`
- `timestamp`
- `sessionId`

The app estimates a 5-hour block from local JSONL activity. The estimate may not match Claude Code subscription limits exactly.

## OpenAI Admin API

Source:

- `OPENAI_ADMIN_KEY` stored in macOS Keychain

Notes:

- The key must look like an OpenAI Admin API key.
- Regular project API keys are not enough for organization cost endpoints.
- OpenAI API organization costs are separate from Codex ChatGPT plan limits.

## Anthropic Admin API

Source:

- `ANTHROPIC_ADMIN_KEY` stored in macOS Keychain

Notes:

- Anthropic Admin API cost data is intended for organization accounts.
- It may not work for personal accounts.

## Browser/OAuth Placeholder

Current state:

- opt-in UI is present
- browser source selection is stored
- manual cookie headers can be stored in Keychain
- automatic browser cookie reading is not implemented

Any future implementation must:

- be explicit opt-in
- show which browser is read
- show which data is read
- explain why Keychain access is requested
- never log credentials

