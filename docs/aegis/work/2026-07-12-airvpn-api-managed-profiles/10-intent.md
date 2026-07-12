# Intent: AirVPN API-Managed WireGuard Profiles

## Requested outcome

Ship a polished `v1.1.0` with two first-class choices: the existing static,
credential-free workflow and an opt-in API-managed workflow. Provide guided country and
device selection, release both paths publicly under MIT, and migrate the download VM to
verified API-managed operation.

## Goal and stop condition

- **Goal:** secure profile provisioning and rotation without exposing credentials,
  executing remote profile content, weakening static behavior, or losing rollback.
- **Success evidence:** deterministic RED/GREEN tests, full regression and secret checks,
  reproducible packages, controlled VM success and rollback, AirVPN egress, policy routing,
  qBittorrent TCP/UDP ownership, and published-asset verification.
- **Done:** `v1.1.0` is merged, green, tagged, published, freshly verified, and the VM is
  healthy in API mode with a fresh production key that was not shared in chat.
- **Blocked:** a required provider contract, production credential, VM invariant, CI gate,
  or publication permission cannot be satisfied safely.
- **Needs verification:** implementation exists but exact source/package/live evidence is
  incomplete.
- **Scope exceeded:** continuing would require automatic AirVPN device/key/port lifecycle
  or another unapproved account mutation.

## Scope

- Fixed-device authenticated profile generation and strict canonical parsing.
- Explicit provision, adopt, rotate, restore, state-reset, and status commands.
- Guided interactive/non-interactive setup with country allowlist selection.
- Persistent backoff and failed-server exclusions.
- Digest-bound v2 transaction recovery and v1 marker compatibility.
- qBittorrent stop/start protection during managed switches.
- Installer, systemd, documentation, MIT, packaging, CI, release, and VM migration.

## Non-goals

- AirVPN API-key creation.
- AirVPN device creation, renewal, deletion, or revocation.
- Port-forward allocation or reassignment.
- Generic VPN-provider support.
- Claiming to replace a firewall kill switch.

## BaselineReadSetHint

- `docs/aegis/baseline/2026-07-12-initial-baseline.md`
- `docs/aegis/specs/2026-07-12-airvpn-api-managed-profiles-design.md`
- `docs/aegis/plans/2026-07-12-airvpn-api-managed-profiles.md`
- `README.md`, `SECURITY.md`, `CONTRIBUTING.md`, `CHANGELOG.md`
- Runtime, provider, installer, systemd, package, workflow, and complete test owners.

## ImpactStatementDraft

The provider helper gains a credentialed boundary; the runtime gains a securely loaded
managed module and administrative commands; setup becomes a new operator owner. The
configuration grammar, transaction journal, qBittorrent lifecycle, persistent filesystem,
installer, release assets, CI, public docs, and VM deployment all change. Static mode,
legacy invocation, endpoint rotation, v1 reconciliation, deterministic public CI, and
operator-file preservation remain hard compatibility boundaries.

## Risk hints

- Credential or generated-key leakage through process, log, error, fixture, or package.
- Remote profile directives executing as root.
- Wrong-device identity changing qBittorrent/policy consumers.
- Crash/digest mismatch leaving an ambiguous profile.
- Timer request storms or repeated failed-server selection.
- qBittorrent running during unverified tunnel downtime.
- Release publication from a tree different from VM-tested source.
