# Initial Architecture Baseline — 2026-07-12

## Project structure

- `bin/wg-healthcheck` is the privileged Bash orchestration entry point.
- `libexec/airvpn-api` is the standard-library Python boundary for AirVPN JSON.
- `install.sh` atomically installs managed runtime files and preserves operator data.
- `systemd/` owns scheduling and the service sandbox.
- `config/wg0.conf.example` is the authoritative health-check key template.
- `tests/` owns Python, Bash, installer, and release regression coverage.
- `.github/workflows/` owns CI and release automation.
- `scripts/package-release.sh` owns reproducible public source packages.

## Technology stack

- Bash 5.1 or newer for privileged orchestration and installation.
- Python 3.10 or newer, using only the standard library, for API parsing.
- systemd 249 or newer for scheduling and sandboxing.
- WireGuard tools, iproute2, curl, awk, GNU coreutils, util-linux, and optional Docker.
- Shell tests plus Python `unittest`; ShellCheck is a required static check.

## Ownership mapping

| Surface | Canonical owner |
| --- | --- |
| Tunnel health and recovery state machine | `bin/wg-healthcheck` |
| AirVPN response validation and candidate scoring | `libexec/airvpn-api` |
| Runtime settings grammar | `bin/wg-healthcheck` and `config/wg0.conf.example` |
| Filesystem installation contract | `install.sh` |
| Service environment and scheduling | `systemd/` |
| Release contents and reproducibility | `scripts/package-release.sh` |
| Public operator contract | `README.md`, `SECURITY.md`, and release notes |

## Contract inventory

- Runtime invocation: `wg-healthcheck <iface>` and `wg-healthcheck --version`.
- Installer invocation: `install.sh [--enable] [iface]`.
- Health settings: strict, non-executable allowlisted data at
  `/etc/wireguard/healthcheck.d/<iface>.conf`.
- WireGuard profile: root-owned regular file at `/etc/wireguard/<iface>.conf`,
  containing exactly one peer and one numeric endpoint.
- Status: atomic private file at `/run/wg-healthcheck/<iface>.status`.
- Recovery transaction: full backup plus a durable pending marker under
  `/etc/wireguard`.
- Endpoint selector: seven tab-separated display and endpoint fields from the
  Python helper to Bash.
- Public releases: curated `.tar.gz` and `.zip` archives plus `SHA256SUMS`.

## Dependency direction

- systemd invokes the Bash orchestrator through an empty environment.
- Bash invokes fixed local tools and the Python helper.
- The Python helper validates untrusted public AirVPN JSON and returns a bounded
  data contract; it does not control WireGuard or Docker.
- The installer copies reviewed artifacts but does not source runtime settings or
  replace an existing WireGuard profile.
- Tests depend on public contracts; production code does not depend on tests.

## Test system

- `tests/test_airvpn_api.py` tests the Python API boundary.
- `tests/test_wg_healthcheck.sh` uses isolated fixtures and command doubles for
  health, rotation, interruption, rollback, routing, and qBittorrent behavior.
- `tests/test_install.sh` tests ownership, modes, staging, and preservation.
- `tests/test_release.sh` tests curated, reproducible release contents.
- CI runs deterministic checks without account credentials.

## Build and deployment

- Source is installed directly; there is no compilation step.
- `install.sh` installs helper, orchestrator, systemd units, and a missing example
  configuration in compatibility order.
- The timer is not enabled by a fresh install unless explicitly requested.
- Releases are built from tracked Git content and published from annotated tags.

## Known anti-patterns to avoid

- Executable or shell-sourced user configuration.
- Credentials in Git, environment variables, command arguments, URLs, logs, or status.
- Trusting HTTP status without validating provider response content.
- Applying untrusted WireGuard text directly through `wg-quick`.
- Mutating a profile before a durable backup and recoverable marker exist.
- Overwriting operator routing hooks or changing a qBittorrent-bound tunnel address.
- Treating a successful process exit as proof of current health without status evidence.
- Enabling a timer before one controlled successful invocation.

## Last review findings

The 2026-07-12 review found a strong endpoint-only transaction with exact rollback
and postcondition checks. The principal expansion risks are authenticated credential
handling, remote configuration input executing as root, full-profile switch ordering,
qBittorrent exposure during tunnel downtime, and preserving operator-owned routing.

## Compatibility boundaries

- Existing credential-free configurations must remain valid without modification.
- Static endpoint rotation must remain available without opening an API credential.
- The installer must preserve existing WireGuard and health-check files.
- CI and public release tests must never require a live AirVPN account or secret.
- API-managed behavior must be opt-in and must fail before mutation when credentials
  or provider data are invalid.
- The project remains a health/recovery tool, not a substitute for a firewall kill switch.
