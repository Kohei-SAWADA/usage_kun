# usage_kun v0.2.0

## Highlights

- Adds first-class 5 hour and 1 week usage windows for Claude Code and Codex.
- Redesigns the desktop meter and popover cards with a clearer primary/secondary quota hierarchy.
- Keeps the menu bar compact as `usage` plus a remaining-usage meter.
- Adds one-click onboarding for official CLI usage sync.
- Adds optional notifications for low remaining usage and reset events.

## Safety and cleanup

- Removes retired Admin API and Cookie/OAuth code paths.
- Keeps official sync read-only: tokens are never stored, refreshed, or logged.
- Adds publication preflight checks to prevent local documents, build output, and app artifacts from entering the public repo.

## Validation

- `swift build`
- `swift run UsageKunCoreCheck`
- `./Scripts/preflight_publication.sh`
