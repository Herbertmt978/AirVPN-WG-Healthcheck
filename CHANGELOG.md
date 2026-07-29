# Changelog

All notable changes to this project are documented here. Release numbers follow
[Semantic Versioning](https://semver.org/), and this changelog follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.1.0] - 2026-07-29

### Added

- Two explicit profile choices: the credential-free static default and opt-in
  API-managed profiles for one existing, fixed AirVPN device.
- Guided `wg-healthcheck-setup` flows for country selection, authenticated dry runs,
  transactional application, timer decisions, credential replacement, static restore,
  and API-state maintenance.
- Strict generated-profile parsing and canonical rendering, interface identity pinning,
  persistent bounded retry state, failed-server exclusions, and digest-bound recovery
  journals for managed full-profile rotation.
- qBittorrent containment during managed switches, a preserved pre-managed profile,
  quiesced live upgrades, an MIT license, and a complete operator guide.
- Secret-free authenticated failure phases that distinguish transport, response-contract,
  generated-profile, and contained internal failures. Response failures add one fixed
  local reason (`status`, `encoding`, `media_missing`, `media_multiple`, `media_invalid`,
  `media_type`, `media_parameter`, `read`, `size`, `json`, or `protocol`) without exposing
  provider material.
- Compatibility-safe retention of ordered, repeated `PostUp` and `PostDown` commands from
  the validated root-owned installed profile; provider profiles remain hook-free.

### Changed

- Static endpoint-only rotation remains supported and is never an implicit fallback from
  API mode. One country is strict, multiple countries are a hard allowlist, order is a
  soft preference, and explicit `ALL` permits every currently eligible country. The
  shipped example starts with `GB NL BE DE IE` and remains operator-configurable.
- Setup and upgrades preserve operator files, require explicit apply and timer decisions,
  leave quiesced timers disabled for manual verification, and install every managed/setup
  runtime owner through inert upgrade guards. Quiesced v1.0 upgrades narrowly migrate an
  unlocked, empty, root-owned selected-interface legacy lock from `0644` to `0600`.
- Release archives and CI now cover the complete v1.1 runtime on Ubuntu 22.04 and 24.04,
  with reproducible tar/ZIP assets and exact installed-layout checks.
- Managed recovery now has bounded canonical source fragments and split regression suites,
  while production still installs and validates one deterministically generated runtime
  module; CI rejects source drift and architecture-boundary growth.
- Authenticated setup failures retain bounded retry/exclusion behaviour while returning
  only an exact local phase and optional response-reason enum for safe troubleshooting.
- Updated the SHA-pinned GitHub artifact actions used by future release workflows
  to their Node 24 versions.
- Authenticated generation uses a fixed `GET` with `system=other` and omits the
  undocumented `format=text` parameter. It prefers `application/x-wireguard-profile`, then
  `text/plain`, requests identity content encoding, and uses a low-priority wildcard only
  for negotiation. Responses require HTTP 200, exactly one syntactically valid content
  type, no non-identity encoding, and a 64-KiB bound. HTML, multipart, and known ZIP, gzip,
  tar, 7z, bzip2, and xz types are rejected; other syntactically valid parameterless labels
  are advisory and never bypass JSON handling, strict profile parsing, endpoint checks, or
  identity pinning. AirVPN is not asserted to document a success MIME type.
- Identity-pinned adoption and rotation preserve the installed numeric DNS policy,
  including an absent `DNS` directive, so generated peer refreshes cannot silently add a
  host resolver dependency. Fresh provisioning still retains validated provider DNS when
  present; a working `resolvconf`-compatible backend is therefore required when the
  generated profile contains `DNS`.

### Security

- API credentials are accepted only from a hidden terminal or a root-owned mode-`0600`
  file and cross process boundaries only through private descriptors, never arguments,
  environment variables, logs, or status output.
- HTTPS-only public requests, non-redirecting fixed-origin authenticated requests,
  bounded response/profile grammars, full fixed-path ancestor validation for privileged
  code, root-only state, identity-pinned adoption, qBittorrent stop/start barriers, and
  fail-closed rollback prevent untrusted provider data or ambiguous recovery state from
  being accepted.
- Static mode opens no credential, makes no authenticated request, and remains isolated
  from AirVPN device lifecycle; this project does not create, renew, revoke, or delete a
  device.
- Provider failure diagnostics cross the secret boundary only as one fixed allowlisted
  phase and, for response failures, one fixed local reason; malformed, additional, or
  provider-controlled output is discarded.
- Local hook provenance stays separate from the provider profile model and renderer;
  `PreUp`, `PreDown`, `SaveConfig`, peer hooks, and unknown directives remain rejected.

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

[Unreleased]: https://github.com/Herbertmt978/airvpn-wg-healthcheck/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/Herbertmt978/airvpn-wg-healthcheck/releases/tag/v1.1.0
[1.0.0]: https://github.com/Herbertmt978/airvpn-wg-healthcheck/releases/tag/v1.0.0
