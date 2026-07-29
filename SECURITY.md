# Security Policy

## Supported versions

| Release line | Supported |
| --- | --- |
| `1.1.x` | Yes |
| `1.0.x` | No |
| `< 1.0` | No |
| `main` | Development only |

Security fixes are released on the current supported line. Locally modified deployments and untagged development snapshots are not supported release lines.

## Reporting a vulnerability

Use GitHub's private vulnerability-reporting flow when the repository offers a **Report a vulnerability** button. If that flow is unavailable, open a minimal issue asking the maintainer to establish a private contact channel; do not include exploit details or sensitive data in the issue.

Never submit WireGuard private keys, AirVPN API keys, tokens, passwords, complete configuration files, generated profiles, credentialed URLs, or unredacted logs. Redact every secret before sharing a reproduction, and describe only the affected version, security boundary, impact, and minimum steps needed to reproduce it.

## Security boundary

`wg-healthcheck` is privileged software. It runs as root, invokes `wg-quick`, reads root-only WireGuard configuration and optional AirVPN credentials, makes configured HTTPS requests, and can access the root-equivalent Docker socket when container repair is enabled. It is not a firewall kill switch and must be deployed behind an independently tested network policy.

API mode is intentionally limited to a fixed AirVPN device name supplied by the account owner. The project does not create, renew, or delete an AirVPN device. Generated profiles and API state stay in root-only files; public issue reports must never include their contents.
