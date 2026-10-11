# v0.4.7 — Windows sync approval and verified package

This Windows Intel / AMD x64 release packages the latest verified Windows source. Both app and core versions are 0.4.7. macOS source and release assets are unchanged; download macOS from [v0.4.4](https://github.com/Kohei-SAWADA/usage_kun/releases/tag/v0.4.4).

## Changes

- Require successfully saved **Start sync** approval before reading usage sources, credentials, or making provider requests. **Save** alone saves preferences and does not approve sync.
- Keep existing explicit off choices. New configurations initially select all four sync sources, but selections alone do not authorize access. Missing, corrupt, or duplicate approval and failed saves do not authorize reads.
- Fetch only visible providers and enabled sources after approval. Suspend sync in the current session after a settings-save failure. A restart can reload the last successfully saved approval and choices; unsaved changes are not durable.
- Include the current Windows meter/settings changes: always-on-top defaults off, Save applies it immediately, Cancel preserves active choices, and small-screen layouts keep controls reachable.
- Align English and Japanese installation/update instructions with the Windows v0.4.7 package.

## Source and package identity

The Windows executable is the same verified 0.4.7 binary that was built before publication. Its product version embeds the SHA-256 digest of `SOURCE_INPUTS.sha256`. The release's exact Windows source archive preserves all 30 recorded build/check inputs, including line endings. Documentation and sanitized publication metadata were updated afterward.

The release includes the self-contained application ZIP, a Windows-only source ZIP, source-input hash manifests, `BUILD_MANIFEST.json`, and checksums. See [Windows build provenance](windows-build-v0.4.7.json). No personal configuration, credentials, live quota values, or machine-specific validation logs are included in these assets.

## Validation

- Windows Release solution build: passed with zero warnings/errors.
- `UsageKun.Core.Check`: passed with isolated synthetic fixtures.
- Self-contained win-x64 core-check executable: passed, including bundled SQLite use.
- `UsageKun.UI.Check`: passed 92 checks using actual WPF controls/Click handlers and temporary settings.
- Packaged app: Settings displayed 0.4.7; its executable matched the distribution ZIP. Restart and single-instance checks passed.
- Codex official usage: a separate read-only diagnostic using the matching 0.4.7 Core returned usable official usage. It did not capture the running GUI refresh result.

The floating meter and native tray were unavailable to visual capture; their physical interaction and displayed live values remain unverified. Live Claude/Antigravity sync and Windows logout/login startup were not exercised. The executable is unsigned.
