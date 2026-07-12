<div align="center">

# AirVPN WireGuard Healthcheck

<p><strong>A WireGuard interface can stay up while its tunnel, policy routing, or download-client binding is no longer healthy.</strong></p>

[![CI](https://github.com/Herbertmt978/airvpn-wg-healthcheck/actions/workflows/ci.yml/badge.svg)](https://github.com/Herbertmt978/airvpn-wg-healthcheck/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/Herbertmt978/airvpn-wg-healthcheck?sort=semver)](https://github.com/Herbertmt978/airvpn-wg-healthcheck/releases/latest)

</div>

This project runs a systemd health check for a single-peer AirVPN WireGuard tunnel. It verifies the live tunnel state, performs bounded recovery, rotates to a healthy public AirVPN endpoint when enabled, and can prove that qBittorrent still owns both TCP and UDP listeners on the tunnel address.

This is an independent community project and is not affiliated with or endorsed by AirVPN.

If you already operate `wg-quick` through systemd, the scheduling model is familiar. The added boundary is transactional recovery: an endpoint change is not accepted until the tunnel, egress, routing, and configured download-client binding all pass.

> [!IMPORTANT]
> The installer writes managed files under `/usr/local`, `/etc/systemd/system`, and `/etc/wireguard/healthcheck.d`. At runtime, the service runs as root, reads the root-only WireGuard and health-check configurations, writes transaction state under `/etc/wireguard` and `/run/wg-healthcheck`, and can restart WireGuard plus one explicitly configured Docker container. It never reads an AirVPN API key or sends telemetry. Public HTTPS requests go only to the configured AirVPN and speed-test endpoints. This is not a firewall kill switch—configure and test one independently. Disable automation immediately with `sudo systemctl disable --now wg-healthcheck@wg0.timer`; see [complete uninstall](#uninstall) before removing shared files.

[Quick start](#quick-start) · [Releases](#releases-and-versioning) · [Configuration](#configuration-grammar) · [Upgrade](#upgrade) · [Operations](#operations) · [Changelog](CHANGELOG.md) · [Support](#support) · [Security](#security)

## Quick start

Download the pinned release package and checksum file, verify the archive, inspect the code you intend to trust with root, then install without starting the timer:

```bash
set -euo pipefail

repo='Herbertmt978/airvpn-wg-healthcheck'
version='1.0.0'
archive="airvpn-wg-healthcheck-${version}.tar.gz"
base="https://github.com/${repo}/releases/download/v${version}"

workdir="$(mktemp -d)"
cd "$workdir"
curl --fail --location --proto '=https' --proto-redir '=https' \
  --remote-name "${base}/${archive}"
curl --fail --location --proto '=https' --proto-redir '=https' \
  --remote-name "${base}/SHA256SUMS"
awk -v file="$archive" '$2 == file { print }' SHA256SUMS | sha256sum --check -
tar -tzf "$archive" | less
tar -xzf "$archive"
cd "airvpn-wg-healthcheck-${version}"

less README.md install.sh
./bin/wg-healthcheck --version
sudo ./install.sh wg0
```

## See it work

After reviewing `/etc/wireguard/healthcheck.d/wg0.conf`, run one controlled check:

```bash
sudo systemctl start wg-healthcheck@wg0.service
sudo cat /run/wg-healthcheck/wg0.status
```

A successful run produces a private status file like:

```text
outcome=healthy
reason=all_checks_passed
timestamp=1700000000
```

## Releases and versioning

`v1.0.0` is the first stable release. Patch releases in the `1.0.x` line preserve the documented configuration grammar and installer layout unless the release notes identify a security-required migration. The `main` branch is development code; use a tagged release for unattended systems.

Each release attaches two curated source packages and a checksum file:

- `airvpn-wg-healthcheck-<version>.tar.gz` for normal Linux installation.
- `airvpn-wg-healthcheck-<version>.zip` with the same files.
- `SHA256SUMS` covering both attached packages.

The release asset is a source package, not a standalone binary. Run the installer from the extracted package root. It installs the health-check script, AirVPN helper, systemd units, and—only when missing—the disabled configuration template. Existing WireGuard and per-interface health-check configurations are preserved.

Checksums detect a damaged or substituted download relative to the checksum file. They are not a separate publisher signature; obtain the package and `SHA256SUMS` from the same tagged GitHub release over HTTPS, verify the tag and repository identity, and inspect privileged code before installation. See the [changelog](CHANGELOG.md) and [release notes](docs/releases/v1.0.0.md) before upgrading.

## What it checks

Every timer run verifies that the interface exists, WireGuard responds, the runtime peer uses the exact configured endpoint, the handshake is fresh, and any configured route, policy rule, or ping target is present. Recovery additionally verifies the AirVPN exit through the WireGuard interface before it can be reported as successful.

Optional checks can:

- Confirm download speed twice before treating a slow result as a recovery trigger.
- Select a deterministic healthy endpoint from AirVPN's public status API.
- Prove that the same qBittorrent process owns both TCP and UDP listeners on the configured WireGuard address and port, then restart and recheck one configured Docker container when the binding is missing.

Speed checks and AirVPN rotation are disabled by default. qBittorrent checking is disabled until its listen address and port are configured.

Endpoint changes are transactional: the previous configuration is backed up, the new endpoint is written atomically, the tunnel and every configured postcondition are verified, and failed or interrupted rotations are reconciled to the previous endpoint.

## Requirements and security boundary

- Linux with systemd 249 or newer, Bash 5.1 or newer, and Python 3.10 or newer.
- WireGuard tools (`wg` and `wg-quick`), iproute2 (`ip` and `ss`), curl, awk, GNU coreutils, and util-linux (`flock` and `logger`).
- `iputils-ping` when `PING_TARGET` is configured.
- An existing `/etc/wireguard/<iface>.conf` containing exactly one `[Peer]` section and one `Endpoint`. The endpoint host must be a numeric IPv4 or bracketed IPv6 address; DNS names and multi-peer files are rejected.
- The WireGuard configuration and `/etc/wireguard/healthcheck.d/<iface>.conf` must be root-owned regular files with mode `0600`, not symlinks. The health-check directory is mode `0700`.
- Public HTTPS access to AirVPN's status and `whatismyip` APIs. No AirVPN credential or API key is used.
- Docker CLI and daemon access only when `QBITTORRENT_CONTAINER` is configured. Access to the Docker socket is root-equivalent; configure only a trusted, exact container name.

The live compatibility target is Ubuntu 22.04 with systemd 249; CI runs the same source and unit checks on Ubuntu 24.04.

The service runs as root because it controls `wg-quick`, reads the WireGuard configuration, and can optionally use Docker. Its systemd sandbox is deliberately conservative enough for WireGuard routing, resolver hooks, and Docker. This project detects and repairs tunnel failures; it is not an independent firewall kill switch. Configure and test an independent firewall kill switch before relying on the host for unattended downloads.

### Network and privacy

- Endpoint selection reads AirVPN's public status API.
- Recovery verifies the exit through AirVPN's public `whatismyip` API while explicitly bound to the WireGuard interface.
- When enabled, speed checks download from the configured URL; the example default requests 10 MB from Cloudflare.
- When `PING_TARGET` is set, the service sends the configured number of ICMP probes through the WireGuard interface.
- Operational messages are written locally through `logger` and systemd. The project has no account telemetry and does not accept an AirVPN credential.

## Repository layout

- [`bin/wg-healthcheck`](bin/wg-healthcheck) — privileged recovery orchestrator and strict configuration parser.
- [`libexec/airvpn-api`](libexec/airvpn-api) — standard-library Python AirVPN response validator and selector.
- [`config/wg0.conf.example`](config/wg0.conf.example) — safe, disabled-by-default settings template.
- [`systemd/wg-healthcheck@.service`](systemd/wg-healthcheck@.service) and [`.timer`](systemd/wg-healthcheck@.timer) — oneshot service and one-minute timer.
- [`install.sh`](install.sh) — validated, atomic installer with optional `DESTDIR` staging.
- [`tests/`](tests) — Python, recovery, installer, documentation, and CI contract tests.

## Install details

The quick-start installer reloads systemd but does not enable or start the timer. Existing per-interface configuration is preserved; the installer will not replace it with the example.

```text
sudo ./install.sh [--enable] [iface]
```

The interface defaults to `wg0`. `--enable` is intended only for reinstalling an already-reviewed configuration because it starts the timer after installation.

To inspect the filesystem layout without touching the host's systemd state, stage it as an unprivileged user first:

```bash
stage="$(mktemp -d)"
DESTDIR="$stage" ./install.sh wg0
find "$stage" -type f -print
rm -rf -- "$stage"
```

Managed files are replaced atomically one at a time in compatibility order: helper, then main script, then units, followed by a missing new configuration. systemd daemon-reload runs only after all managed files are installed successfully. An interrupted or failed install cleans temporary files but may leave earlier compatible replacements in place; it is not a global rollback transaction. If that happens, keep the timer stopped and rerun the installer after fixing the reported cause.

Review the new data file and enforce its ownership:

```bash
sudoedit /etc/wireguard/healthcheck.d/wg0.conf
sudo chown root:root /etc/wireguard/healthcheck.d/wg0.conf
sudo chmod 0600 /etc/wireguard/healthcheck.d/wg0.conf
```

Run one service invocation during a maintenance window. Even with rotation disabled, recovery can restart an unhealthy tunnel.

```bash
sudo systemctl daemon-reload
sudo systemctl start wg-healthcheck@wg0.service
sudo systemctl --no-pager --full status wg-healthcheck@wg0.service
status="$(sudo cat /run/wg-healthcheck/wg0.status)"
printf '%s\n' "$status"
outcome="$(printf '%s\n' "$status" | awk -F= '$1 == "outcome" { print $2 }')"
case "$outcome" in
  healthy|recovered) ;;
  *) printf 'Health check did not pass; timer remains disabled.\n' >&2; exit 1 ;;
esac
```

Only after the one-shot run and status are correct, enable the timer:

```bash
sudo systemctl enable --now wg-healthcheck@wg0.timer
```

`--enable` is available for reinstalling an already-reviewed configuration:

```bash
sudo ./install.sh --enable wg0
```

Do not use `--enable` for an unreviewed new installation because it enables and starts the timer immediately after installation.

## Configuration grammar

`wg-healthcheck` treats `/etc/wireguard/healthcheck.d/<iface>.conf` as data, not shell code. The service starts it through an `env -i` launcher, and the script validates file ownership and mode before parsing it itself; systemd does not source or import this file.

Each nonblank, non-comment line must be an allowlisted `UPPER_CASE_KEY=value` assignment. A complete value may use matching single or double quotes when it contains spaces. Comments must occupy their own line beginning with `#`.

Unknown keys and duplicate keys are rejected. No `export`, command substitution, variable expansion, or shell commands are accepted. Backslashes, backticks, dollar signs, embedded quotes, control characters, oversized lines, and files larger than 64 KiB are also rejected. There is no expansion or escape processing inside quoted values.

Use `config/wg0.conf.example` as the authoritative key list. Important groups are:

- `MAX_AGE`, restart delays, and timeouts for basic tunnel recovery.
- `REQUIRED_ROUTE` and `REQUIRED_RULE` for policy-routing invariants.
- `QBITTORRENT_LISTEN_IP` and `QBITTORRENT_LISTEN_PORT`, which must be set together. `QBITTORRENT_CONTAINER` enables fixed Docker restart repair; `QBITTORRENT_PROCESS_NAME` defaults to `qbittorrent-nox`.
- `SPEED_CHECK_ENABLED=1` to opt into confirmed speed recovery.
- `AIRVPN_ROTATE_ENABLED=1` to opt into public, credential-free endpoint rotation.

### Policy routing

Inspect the effective route and rule text before copying a unique substring into the configuration:

```bash
ip route show table all
ip rule show
```

The following uses the documentation-only address `192.0.2.2` and policy table `100`:

```ini
REQUIRED_ROUTE="default dev wg0 table 100"
REQUIRED_RULE="from 192.0.2.2 lookup 100"
```

Replace the address with the actual WireGuard address. A nonempty value is a mandatory postcondition: if its exact substring is absent from `ip route show table all` or `ip rule show`, health and recovery verification fail closed.

## Upgrade

Download, verify, inspect, and extract the target release using the quick-start procedure, but do not run its installer yet. Quiesce the installed scheduler and worker and prove there is no incomplete endpoint transaction:

```bash
sudo systemctl disable --now wg-healthcheck@wg0.timer
sudo systemctl stop wg-healthcheck@wg0.service
sudo test ! -e /etc/wireguard/wg0.conf.pending-healthcheck
```

If every command succeeds, run `sudo ./install.sh wg0` from the verified target release directory. The installer preserves existing configuration. Complete one manual service invocation and require a `healthy` or `recovered` status before re-enabling the timer, as shown in the detailed migration procedure below. If the pending-marker check fails, keep both units stopped and reconcile the transaction with the currently installed version; do not switch versions or overwrite its backup.

## Migrating an existing deployment

<details>
<summary><b>Upgrade and legacy migration procedure</b></summary>

Use this sequence for ordinary upgrades as well as legacy configuration migrations.

Quiesce both the scheduler and its worker before replacing or editing anything:

```bash
sudo systemctl disable --now wg-healthcheck@wg0.timer
sudo systemctl stop wg-healthcheck@wg0.service
sudo test ! -e /etc/wireguard/wg0.conf.pending-healthcheck
```

Stopping the service waits for or cancels any active oneshot and returns only after the unit is inactive. If either systemctl command fails, do not continue. The pending-marker check must exit zero before you install or edit. If it fails, do not install or edit anything; reconcile the pending rotation with the current version or troubleshoot it first. Keep the timer disabled while doing so, then repeat the stop and pending-marker check.

After all three preconditions succeed, install and edit the preserved data file:

```bash
sudo ./install.sh wg0
sudoedit /etc/wireguard/healthcheck.d/wg0.conf
```

Remove the retired executable settings `RESTART_CMD_UP`, `RESTART_CMD_DOWN`, and `POST_RESTART_CMD`. Also remove the retired authenticated-telemetry settings `AIRVPN_USERINFO_URL` and `AIRVPN_API_ENV`; unknown legacy keys now make validation fail.

Replace an old `POST_RESTART_CMD` Docker hook with the fixed data settings:

```ini
QBITTORRENT_CONTAINER=qbittorrent
QBITTORRENT_LISTEN_IP=192.0.2.2
QBITTORRENT_LISTEN_PORT=6881
QBITTORRENT_PROCESS_NAME=qbittorrent-nox
```

Use the host's real listen address, port, process name, and container. The container restarts only when the required TCP/UDP binding proof is missing, and the binding must pass after restart.

The old `/etc/wireguard/airvpn-healthcheck.env` is no longer read. The following guard deletes it only when the reference scan returns the specific "no matches" status. References or scan errors leave the file untouched:

```bash
references=''
grep_rc=0
references="$(
  sudo grep -RIl \
    --exclude='airvpn-healthcheck.env' \
    -- 'airvpn-healthcheck.env' \
    /etc/systemd/system \
    /run/systemd/system \
    /usr/lib/systemd/system \
    /lib/systemd/system \
    /etc/wireguard \
    /usr/local
)" || grep_rc=$?

case "$grep_rc" in
  0)
    printf 'Still referenced; do not delete:\n%s\n' "$references"
    ;;
  1)
    sudo rm -f -- /etc/wireguard/airvpn-healthcheck.env
    ;;
  *)
    printf 'Reference scan failed (exit %s); do not delete.\n' "$grep_rc" >&2
    exit "$grep_rc"
    ;;
esac
```

Then validate once before re-enabling:

```bash
sudo chown root:root /etc/wireguard/healthcheck.d/wg0.conf
sudo chmod 0600 /etc/wireguard/healthcheck.d/wg0.conf
sudo systemctl daemon-reload
sudo systemctl start wg-healthcheck@wg0.service
status="$(sudo cat /run/wg-healthcheck/wg0.status)"
printf '%s\n' "$status"
sudo journalctl -u wg-healthcheck@wg0.service -n 100 --no-pager
outcome="$(printf '%s\n' "$status" | awk -F= '$1 == "outcome" { print $2 }')"
case "$outcome" in
  healthy|recovered) ;;
  *) printf 'Migration validation failed; timer remains disabled.\n' >&2; exit 1 ;;
esac
sudo systemctl enable --now wg-healthcheck@wg0.timer
```

</details>

## State and recovery transaction

- `/run/wg-healthcheck/<iface>.status` is an atomic, private machine-readable file containing `outcome`, `reason`, and Unix `timestamp`. Outcomes are `healthy`, `recovered`, `suppressed`, `degraded`, and `failed`.
- `/run/wg-healthcheck/<iface>.last_restart`, `.last_rotate`, and `.last_speedcheck` enforce cooldowns; the interface lock prevents overlapping runs. `/run` state is recreated after reboot.
- `/etc/wireguard/<iface>.conf.bak-healthcheck` is one bounded, atomically replaced copy of the immediately previous full WireGuard configuration. It contains the private key and must remain protected like the original.
- `/etc/wireguard/<iface>.conf.pending-healthcheck` records an incomplete rotation. On the next invocation, reconciliation restores the backup and verifies the old tunnel and qBittorrent binding before normal checks continue.

Never delete the pending marker manually. An interruption or failed marker cleanup intentionally leaves it in place so the next invocation cannot overwrite the known-good backup.

Successful health and verified recovery exit zero. `suppressed` and `degraded` are intentionally nonzero so systemd and monitoring do not mistake cooldown-blocked or incomplete recovery for health; common codes are 75 for suppression and 2 for degraded recovery.

| Outcome | Meaning | Operator action |
| --- | --- | --- |
| `healthy` | All configured checks passed. | None. |
| `recovered` | Recovery and every postcondition passed. | Review the journal for the trigger. |
| `suppressed` | Restart cooldown blocked a requested repair. | Check whether repeated failures need intervention. |
| `degraded` | A protective action ran but full recovery was not proven. | Keep or place the timer in a stopped state and investigate. |
| `failed` | Validation, recovery, or transaction cleanup failed. | Stop the timer; preserve any pending marker and backup. |

## Operations

```bash
/usr/local/sbin/wg-healthcheck --version
systemctl status wg-healthcheck@wg0.timer
systemctl status wg-healthcheck@wg0.service
systemctl list-timers 'wg-healthcheck@*'
journalctl -u wg-healthcheck@wg0.service -n 100 --no-pager
journalctl -t wg-healthcheck -n 100 --no-pager
sudo cat /run/wg-healthcheck/wg0.status
```

If automatic pending-transaction reconciliation fails, keep the timer stopped. Inspect the service journal, status, current configuration, `.bak-healthcheck`, `.pending-healthcheck`, effective route/rule, AirVPN egress, and qBittorrent listeners. Do not delete the marker or overwrite the backup; repair the reported postcondition and rerun the current service so it can complete verified reconciliation.

### Repository rollback

<details>
<summary><b>Compatibility-safe rollback procedure</b></summary>

Rollback crosses an installer compatibility boundary. A legacy installer may unconditionally run `enable --now`. Quiesce both units before checking recovery state:

```bash
sudo systemctl disable --now wg-healthcheck@wg0.timer
sudo systemctl stop wg-healthcheck@wg0.service
sudo test ! -e /etc/wireguard/wg0.conf.pending-healthcheck
```

The pending-marker check must succeed while both units are inactive. If it fails, do not switch revisions or run another installer; reconcile or troubleshoot the transaction with the current version first.

Mask the specific timer instance before changing revisions. The mask prevents a legacy installer's final enable step from starting the timer:

```bash
sudo systemctl mask wg-healthcheck@wg0.timer
release_dir=/path/to/verified/airvpn-wg-healthcheck-1.0.0
test -f "$release_dir/VERSION"
cd "$release_dir"
```

Git users can instead select an exact known-good commit or tag:

```bash
git switch --detach <known-good-commit>
```

Review the target revision's README, configuration template, and required files before running its service. Its accepted keys, file modes, dependencies, or credential requirements may differ from the current revision. Update the preserved configuration only while the service is stopped and the timer instance remains masked.

Run the target installer while capturing, rather than discarding, its result:

```bash
if sudo ./install.sh wg0; then
  installer_rc=0
else
  installer_rc=$?
fi
printf 'installer exit code: %s\n' "$installer_rc"
if timer_state="$(sudo systemctl is-enabled wg-healthcheck@wg0.timer 2>&1)"; then
  timer_state_rc=0
else
  timer_state_rc=$?
fi
printf 'timer state: %s (exit %s)\n' "$timer_state" "$timer_state_rc"
```

Do not ignore a nonzero installer result. Continue only if its output proves the only failure was the final masked-enable attempt. Any earlier copy, configuration, ownership, or daemon-reload failure must be fixed and the installer rerun while the instance remains masked. Whether the installer returned zero or the inspected masked-enable failure, immediately assert the stopped state again:

```bash
sudo systemctl disable --now wg-healthcheck@wg0.timer
```

The timer must remain masked throughout the one-shot validation. Confirm that before starting only the service:

```bash
sudo systemctl is-enabled wg-healthcheck@wg0.timer
sudo systemctl start wg-healthcheck@wg0.service
sudo cat /run/wg-healthcheck/wg0.status
sudo journalctl -u wg-healthcheck@wg0.service -n 100 --no-pager
```

Only after the target revision's requirements are satisfied and the one-shot status is correct should the timer be unmasked and enabled:

```bash
sudo systemctl unmask wg-healthcheck@wg0.timer
sudo systemctl enable --now wg-healthcheck@wg0.timer
```

The current installer preserves `/etc/wireguard/wg0.conf` and the existing health-check data file, but a target legacy installer may have different behavior. A repository rollback is not a substitute for completing or repairing an active endpoint transaction.

</details>

## Uninstall

### Disable one interface

Stop one interface without removing the shared executable, helper, or unit templates:

```bash
sudo systemctl disable --now wg-healthcheck@wg0.timer
sudo systemctl stop wg-healthcheck@wg0.service
if ! sudo test ! -e /etc/wireguard/wg0.conf.pending-healthcheck; then
  printf 'Pending recovery transaction exists; preserve it and troubleshoot before removing anything.\n' >&2
  exit 1
fi
```

This leaves the package available to other interfaces and preserves the `wg0` WireGuard configuration, health-check configuration, backup, and runtime evidence.

### Remove the package

Shared files may be removed only after every health-check instance is stopped and no interface has a pending recovery transaction. Run this complete-package procedure from Bash:

```bash
set -euo pipefail

mapfile -t timers < <(
  {
    systemctl list-unit-files --type=timer --no-legend --plain 'wg-healthcheck@*.timer'
    systemctl list-units --type=timer --all --no-legend --plain 'wg-healthcheck@*.timer'
  } | awk '$1 ~ /^wg-healthcheck@.+[.]timer$/ { print $1 }' | sort -u
)
mapfile -t services < <(
  systemctl list-units --type=service --all --no-legend --plain 'wg-healthcheck@*.service' |
    awk '$1 ~ /^wg-healthcheck@.+[.]service$/ { print $1 }' | sort -u
)

(( ${#timers[@]} == 0 )) || sudo systemctl disable --now "${timers[@]}"
(( ${#services[@]} == 0 )) || sudo systemctl stop "${services[@]}"

active="$(systemctl list-units --all --state=active --no-legend --plain \
  'wg-healthcheck@*.timer' 'wg-healthcheck@*.service')"
if [[ -n "$active" ]]; then
  printf 'Active health-check instances remain; package removal stopped.\n' >&2
  exit 1
fi

pending="$(sudo find /etc/wireguard -maxdepth 1 \
  \( -type f -o -type l \) -name '*.conf.pending-healthcheck' -print -quit)"
if [[ -n "$pending" ]]; then
  printf 'A pending recovery transaction exists; package removal stopped.\n' >&2
  exit 1
fi

sudo rm -f -- \
  /etc/systemd/system/wg-healthcheck@.service \
  /etc/systemd/system/wg-healthcheck@.timer \
  /usr/local/sbin/wg-healthcheck \
  /usr/local/libexec/wg-healthcheck/airvpn-api
if sudo test -d /run/wg-healthcheck && sudo test ! -L /run/wg-healthcheck; then
  sudo find /run/wg-healthcheck -xdev -mindepth 1 -maxdepth 1 -type f -delete
  sudo rmdir -- /run/wg-healthcheck 2>/dev/null || true
fi
sudo rmdir -- /usr/local/libexec/wg-healthcheck 2>/dev/null || true
sudo systemctl daemon-reload
```

Complete package removal deletes shared runtime code, unit templates, and stopped runtime state. It intentionally preserves every `/etc/wireguard/<iface>.conf`, `/etc/wireguard/healthcheck.d/<iface>.conf`, `.bak-healthcheck`, and pending marker because they can contain private keys or operator-specific recovery state. Remove preserved files separately only after inspecting them; never delete a pending marker to force uninstall.

## FAQ

### Is this a firewall kill switch?

No. It detects and repairs configured health failures. Use an independently tested firewall policy to prevent traffic from leaving outside WireGuard.

### Does endpoint rotation require an AirVPN account credential?

No. Selection and egress verification use AirVPN's public HTTPS APIs. The project does not accept an AirVPN username, password, API key, or authenticated telemetry URL.

### Does it support multiple WireGuard peers?

No. The healthcheck rejects configurations that do not contain exactly one peer and one numeric endpoint because recovery must have one unambiguous transaction target.

## Support

Use [GitHub Issues](https://github.com/Herbertmt978/airvpn-wg-healthcheck/issues) for reproducible bugs and narrowly scoped feature requests. Include `wg-healthcheck --version`, platform versions, and a minimal redacted reproduction. Remove credentials, keys, public IP addresses, real endpoints, hostnames, private network layouts, and unredacted journals before posting.

Security vulnerabilities belong in the private process described by [SECURITY.md](SECURITY.md), never in a public issue. Questions about AirVPN accounts, subscriptions, or provider infrastructure belong with AirVPN; this independent project cannot provide account support.

## Security

Read [SECURITY.md](SECURITY.md) before reporting a vulnerability. Never put a WireGuard private key, API token, health-check configuration, journal containing sensitive values, or real endpoint inventory in a public issue.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Changes to recovery, installer, configuration, or systemd behavior must include focused regression coverage and pass the complete development checks below.

## License

No license is currently granted. Public visibility does not grant permission to copy, modify, or redistribute the source; this repository is source-visible rather than open source.

## Development checks

Run from the repository root on Linux:

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
bash tests/test_wg_healthcheck.sh
bash tests/test_install.sh
bash tests/test_release.sh
bash -n bin/wg-healthcheck install.sh scripts/*.sh tests/*.sh
shellcheck -x -S style bin/wg-healthcheck install.sh scripts/*.sh tests/*.sh
systemd-analyze verify systemd/wg-healthcheck@.service systemd/wg-healthcheck@.timer
```
