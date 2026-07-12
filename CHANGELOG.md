# Changelog

All notable changes to this project are documented here. Release numbers follow
[Semantic Versioning](https://semver.org/), and this changelog follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.0.0] - 2026-07-12

### Added

- A systemd oneshot service and timer for a single-peer AirVPN WireGuard tunnel.
- Fail-closed checks for handshake freshness, exact endpoints, policy routing,
  optional ICMP reachability, and qBittorrent TCP/UDP listener ownership.
- Bounded restart, speed-recovery, and credential-free AirVPN endpoint rotation.
- Durable pending-rotation recovery with atomic configuration and status writes.
- A hardened installer with safe staging, ownership checks, and atomic managed-file
  replacement.
- Reproducible release archives, SHA-256 checksums, release automation, and a
  fixed `wg-healthcheck --version` identifier.

### Security

- Root-only configuration and state files, strict data-only configuration parsing,
  fixed command paths, HTTPS-only API access, bounded responses, and systemd
  sandboxing.
- No AirVPN account credential, API key, telemetry, or executable configuration
  hook is accepted.

### Compatibility

- Ubuntu 22.04 and newer, Bash 5.1 and newer, Python 3.10 and newer, systemd 249
  and newer, and a WireGuard configuration containing exactly one peer.
- Existing deployments using retired command hooks or authenticated telemetry must
  follow the migration procedure in the README before enabling the timer.

[Unreleased]: https://github.com/Herbertmt978/airvpn-wg-healthcheck/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Herbertmt978/airvpn-wg-healthcheck/releases/tag/v1.0.0
