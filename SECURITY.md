# Security Policy

## Reporting A Vulnerability

Please open a private security advisory if the repository is hosted on GitHub with that feature enabled. If private advisories are not available, open an issue with a minimal description and avoid posting secrets, tokens, or logs that contain credentials.

Useful reports include:

- credential leakage
- accidental logging of tokens or credentials
- unexpected browser cookie access
- sending provider tokens to the wrong endpoint
- reading files outside the documented local usage paths

## Supported Versions

This project is currently a small personal utility. Security fixes are expected to target the `main` branch.

## Security Principles

- Tokens must not be logged.
- CLI sign-in tokens must be read-only and opt-in.
- Provider data must not be mixed across providers.
- Browser cookie access is not implemented. Any future browser-cookie feature should go through a separate security review before release.
