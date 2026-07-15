# AirVPN WireGuard Healthcheck

[![CI](https://github.com/Herbertmt978/airvpn-wg-healthcheck/actions/workflows/ci.yml/badge.svg)](https://github.com/Herbertmt978/airvpn-wg-healthcheck/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/Herbertmt978/airvpn-wg-healthcheck?sort=semver)](https://github.com/Herbertmt978/airvpn-wg-healthcheck/releases/latest)

`wg-healthcheck` is a root-run systemd health check for a single-peer AirVPN WireGuard tunnel. It verifies the tunnel, selected routing checks, and an optional qBittorrent binding; bounded recovery can restart the tunnel and, when explicitly configured, rotate an endpoint.

This is an independent community project and is not affiliated with or endorsed by AirVPN. It is distributed under the [MIT License](LICENSE).

## Choose a mode

| Static profile mode | API-managed profile mode |
| --- | --- |
| Default; credential-free. You keep the existing WireGuard profile and may opt into public-status endpoint rotation. | Explicit opt-in; API key required. The service manages peer material for one fixed device and selects a healthy server. |
| No account key is read and no authenticated request is made. | It does not create, renew, revoke, or delete an AirVPN device. |

Both modes need Linux with systemd, WireGuard tools, Bash, Python 3.10+, and the networking utilities listed under [Requirements](#requirements). The installer preserves existing per-interface configuration and does not start the timer unless you explicitly request `--enable`.

### Static quick start

```bash
sudo ./install.sh wg0
sudo wg-healthcheck-setup --mode static wg0
```

### API-managed quick start

```bash
sudo ./install.sh wg0
sudo wg-healthcheck-setup --mode api wg0
```

Before starting API mode, activate a key in [AirVPN API settings](https://airvpn.org/apisettings/)
and choose an existing AirVPN device. Copy the key directly from the account page into the
hidden setup prompt; if it is exposed anywhere else, revoke it and create a replacement.

The interactive API path asks for a non-secret device name, country selection, and the key through a hidden terminal prompt. It never accepts a secret value in an argument or environment variable.

After either path, inspect the secret-free status, run one controlled health check, then explicitly decide whether to enable the timer:

```bash
sudo wg-healthcheck status wg0
sudo systemctl start wg-healthcheck@wg0.service
sudo systemctl --no-pager --full status wg-healthcheck@wg0.service
# Enable only after a healthy or recovered manual result:
sudo systemctl enable --now wg-healthcheck@wg0.timer
```

Leave the timer disabled if the manual result is not healthy or recovered. The [operator guide](docs/operations.md) covers safe upgrades, rollback, state repair, key changes, and uninstall.

> [!IMPORTANT]
> This is not a firewall kill switch. Configure and test an independent firewall kill switch before relying on unattended downloads. Docker access is root-equivalent when container recovery is configured.

## What the modes do

Static mode keeps the existing `/etc/wireguard/<iface>.conf` under operator control. `AIRVPN_ROTATE_ENABLED=0` disables endpoint rotation; tunnel restart, configured speed recovery, and configured qBittorrent repair can still run. Enabling rotation permits credential-free endpoint selection from AirVPN's public status data.

API-managed mode is an explicit `AIRVPN_PROFILE_SOURCE=api` choice. It uses one **fixed device** and rejects a generated profile whose interface identity differs from the installed profile. The service may repair peer material and change server selection, but it does not create, renew, revoke, or delete a device.

Version 1.1 calls AirVPN's credential-free `status` service for server selection, the
authenticated `generator` service for one raw profile, and the credential-free
`whatismyip` service for tunnel egress proof. It does not call `userinfo`, `devices`,
`disconnect`, `notification`, or `dns_lists`; account, device, session, notification, and
DNS policy remain operator-owned. AirVPN documents a global limit of 600 API requests per
10 minutes and warns that exceeding it can ban the source IP. This project deliberately
uses a much stricter persistent retry ledger; do not reset that state to force a retry.
The authenticated ledger is per interface, while AirVPN's ceiling is per source IP. If
you operate many interfaces behind one public address, budget their combined traffic and
stagger checks rather than treating each interface's ledger as a separate provider quota.

| AirVPN service | Provider access | v1.1 policy |
| --- | --- | --- |
| `status` | Public | Used for eligible-country and healthy-server selection. |
| `generator` | API key | Used only to generate a raw profile for the configured fixed device. |
| `whatismyip` | Public | Used only through the tunnel to prove AirVPN egress. |
| `devices` | API key | Not used. Its asynchronous list/add/renew/delete/modify lifecycle changes tunnel identity and needs a separate blue/green migration design. |
| `userinfo` | API key | Not used; account and connection details are outside the runtime boundary. |
| `disconnect` | API key | Not used; it is a destructive account-session action. |
| `notification` | API key | Not used; operator notification policy stays external. |
| `dns_lists` | Public | Not used; DNS policy stays external. |

The [AirVPN API Explorer](https://airvpn.org/apisettings/) is the provider authority for
this boundary. A future setup-only device picker could consume a strictly reduced `devices`
list, but unattended checks will not gain device mutation or account-session authority
implicitly.

The generator's authenticated origin is fixed in code. The public status and egress URLs
are root-configuration overrides for controlled testing or a trusted proxy; changing either
one changes the network trust boundary. Keep the AirVPN defaults unless you control and have
reviewed the replacement endpoint.

When authenticated generation fails, diagnostics expose only a local failure phase and,
for response-contract failures, one of eleven fixed reasons such as `media_type`, `size`,
or `protocol`.
They never include the actual status, headers, response body, device, server, or key; see
the [operator guide](docs/operations.md#authenticated-failure-phases).

AirVPN documents exact `result: "ok"` as API success and otherwise places the error message
in `result`; its current authentication boundary can instead return one non-empty top-level
`error` without `result`. Only those two bounded envelopes are permanent generator
rejections. Contradictory or malformed JSON fails closed as a retryable response-contract
error.

As a conservative compatibility-policy exception for AirVPN's raw generator endpoint, the
exact `text/html` label is accepted with no parameter or one exact unquoted,
case-insensitive `charset=utf-8` or `charset=us-ascii` token. No live provider header was
retained or identified to select this exception. The label grants no HTML semantics: the
bounded body must still pass the canonical WireGuard grammar and selected-endpoint check
before any candidate is written. Actual HTML, archives, multipart data, and unknown media
types fail closed.

Generated provider profiles always reject every executable hook. During identity-pinned adoption and rotation, a validated root-owned installed profile may retain repeated `PostUp` and `PostDown` commands in their original order; these remain local code executed as root by `wg-quick`. Review them before setup. `PreUp`, `PreDown`, `SaveConfig`, peer hooks, and unknown directives block API adoption without changing the installed profile.

For API mode, setup shows eligible countries from public status data before asking for the key:

- One country is a strict single-country policy.
- Several countries form a hard allowlist.
- Their order is a soft preference: health and capacity still decide within the allowlist.
- Explicit `ALL` at setup permits every eligible country; a blank setup selection is rejected. Setup stores that choice as the canonical empty runtime allowlist.

The shipped example allowlist is `GB NL BE DE IE`. Treat it as a starting point: setup
shows the currently eligible inventory so operators can choose a narrower or different
policy before any authenticated request.

The configuration example documents `AIRVPN_PROFILE_SOURCE`, `AIRVPN_DEVICE`, and `AIRVPN_COUNTRIES`; use it as the exact accepted-settings reference.

## Requirements

- Linux with systemd 249 or newer, Bash 5.1 or newer, and Python 3.10 or newer. Ubuntu 22.04 and 24.04 are the supported CI targets.
- `wg`, `wg-quick`, `ip`, `ss`, `curl`, `awk`, GNU coreutils, and util-linux tools including `flock` and `logger`.
- `ping` when `PING_TARGET` is configured, and Docker CLI/daemon access only when qBittorrent container recovery is configured.
- Static mode: an existing root-owned mode-`0600` `/etc/wireguard/<iface>.conf` with one `[Peer]` and one numeric endpoint.
- API-managed mode: an existing AirVPN device name. This project manages profiles for that fixed device; it does not manage the device itself.

On Ubuntu, the core packages can be installed with:

```bash
sudo apt-get update
sudo apt-get install --no-install-recommends \
  bash coreutils curl gawk iproute2 iputils-ping python3 systemd util-linux wireguard-tools
```

## What it checks and repairs

Every run verifies that the interface exists, WireGuard responds, the runtime peer matches the configured endpoint, and the latest handshake is fresh. Optional checks cover a route, policy rule, ICMP target, confirmed download speed, and qBittorrent's TCP and UDP listeners on the configured tunnel address.

Recovery is bounded and transactional. It can restart WireGuard, repair one explicitly named qBittorrent container, select a public AirVPN endpoint in static mode, or generate a replacement profile for the fixed AirVPN device in API-managed mode. A changed endpoint or profile is accepted only after tunnel, egress, routing, and configured client checks pass; otherwise the prior state is restored or recovery evidence is retained for an operator.

This verifies health after configuration changes, but it does not redirect traffic and is not a firewall kill switch. Bind qBittorrent to the WireGuard address and test an independent firewall policy that blocks non-VPN egress.

## Configuration and safe defaults

`/etc/wireguard/healthcheck.d/<iface>.conf` is parsed as data, never sourced as shell. Each non-comment line must be an allowlisted `UPPER_CASE_KEY=value` assignment. Unknown or duplicate keys, shell expansion, command substitution, control characters, and oversized input are rejected.

The [configuration example](config/wg0.conf.example) is the authoritative key list. Speed recovery, endpoint rotation, ping, route/rule checks, and qBittorrent repair are disabled until their settings are explicitly configured. Treat nonempty route and rule values as mandatory postconditions: a mismatch makes health verification fail closed.

## Credential boundary

The stored API credential is a root-only regular file at `/etc/wireguard/healthcheck.d/<iface>.api-key` (directory mode `0700`, file mode `0600`). Generated WireGuard profiles and candidates are also secrets. Do not put a key in a command line, shell history, environment variable, URL, log, issue, or chat.

Interactive setup reads a key from the controlling terminal without echo. Automation may provide an absolute path with `--credential-file`; the file must be a root-owned mode-`0600` regular file, and every parent component must be root-owned, non-symlinked, and not writable by other users unless it is a root-owned sticky directory such as `/tmp`. The path is not a secret value. Replace an installed key only through the explicit `--replace-credential` flow after validation. Return to static mode and remove it only through the explicit `--remove-credential` flow; ordinary uninstall preserves credential and API state for recovery.

## Install and verify

Download a tagged release with its `SHA256SUMS`, verify the archive, inspect the extracted files, and run the installer from the package root. The package includes `wg-healthcheck`, `wg-healthcheck-setup`, its fixed Python package, the managed runtime module, provider helper, systemd template and timer, MIT license, operator guide, and safe configuration template.

For v1.1.0:

```bash
set -euo pipefail
repo='Herbertmt978/airvpn-wg-healthcheck'
version='1.1.0'
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
```

Checksums detect corruption relative to the published checksum file; they are not a separate publisher signature. Confirm the repository and tag over HTTPS and inspect privileged code before installation.

```bash
./bin/wg-healthcheck --version
sudo ./install.sh wg0
sudoedit /etc/wireguard/healthcheck.d/wg0.conf
```

The health-check configuration is data, not shell code. It must be root-owned, mode `0600`, and not a symlink. Unknown and duplicate keys are rejected; do not add `export`, command substitutions, variable expansions, or shell commands. The WireGuard profile must also be a root-owned mode-`0600` regular file with exactly one `[Peer]` and numeric endpoint address. API-managed adoption and rotation additionally require its immediate directory (normally `/etc/wireguard`) to be a root-owned, non-symlinked directory with exact mode `0700`.

`sudo ./install.sh --enable wg0` is for an already-reviewed configuration only. It enables and starts the timer after installation; the ordinary installer does not.

## Upgrade safely

For a v1.1 upgrade, use the explicit live convenience after verifying the new package:

```bash
sudo ./install.sh --quiesce wg0
```

`--quiesce` records the timer state, stops the selected timer and worker, waits for inactivity, checks locks and recovery artifacts, installs the new files, and leaves the timer disabled for a manual check. It is incompatible with `--enable` and `DESTDIR`. If it reports an incomplete upgrade, keep the timer disabled and follow the [upgrade recovery procedure](docs/operations.md#upgrade-and-rollback).

For v1.0 upgrades only, quiescence can tighten an empty root-owned legacy lock from mode `0644` to `0600` after proving it is the unlocked selected-interface file beneath the private runtime directory. It never relaxes validation for setup guards, other interfaces, nonempty files, links, or ordinary non-quiesced installs.

## Security and support

Read [SECURITY.md](SECURITY.md) before reporting a vulnerability and [CONTRIBUTING.md](CONTRIBUTING.md) before sharing diagnostics. Never submit private keys, API keys, tokens, passwords, complete configuration files, or unredacted logs.

For operations, troubleshooting, rollback, and removal, see [docs/operations.md](docs/operations.md). For release history, see [CHANGELOG.md](CHANGELOG.md), the current [v1.1.0 release note](docs/releases/v1.1.0.md), and the immutable [v1.0.0 release note](https://github.com/Herbertmt978/airvpn-wg-healthcheck/blob/v1.0.0/docs/releases/v1.0.0.md).

Use [GitHub Issues](https://github.com/Herbertmt978/airvpn-wg-healthcheck/issues) for reproducible bugs and narrowly scoped feature requests. Questions about AirVPN accounts or subscriptions belong with AirVPN; this independent project cannot provide account support.

## Repository layout

- [`bin/wg-healthcheck`](bin/wg-healthcheck) — health, recovery, status, and fixed command dispatch.
- [`bin/wg-healthcheck-setup`](bin/wg-healthcheck-setup) and [`libexec/wg_healthcheck_setup`](libexec/wg_healthcheck_setup) — guided, transactional static/API setup.
- `libexec/wg-healthcheck-managed.d` (full source checkouts only) — bounded canonical sources for managed-profile state and recovery.
- [`libexec/wg-healthcheck-managed`](libexec/wg-healthcheck-managed) — generated, single-file managed runtime and installed trust boundary.
- [`libexec/airvpn-api`](libexec/airvpn-api) — strict standard-library provider response parser and profile generator.
- [`install.sh`](install.sh), [`systemd`](systemd), and [`config`](config) — installer, units, and safe example configuration.

## Development checks

Run the complete deterministic suite on Linux from a full Git checkout. The curated
runtime archives omit development-only sources and tests.

```bash
bash scripts/build-managed-module.sh --check
python3 -m unittest discover -s tests -p 'test_*.py' -v
bash tests/test_wg_healthcheck.sh
bash tests/test_wg_managed_profiles.sh
bash tests/test_install.sh
bash tests/test_release.sh --ref HEAD
bash -n bin/wg-healthcheck libexec/wg-healthcheck-managed \
  libexec/wg-healthcheck-managed.d/*.bash install.sh scripts/*.sh tests/*.sh \
  tests/lib/*.sh tests/install/*.sh tests/wg_healthcheck/*.sh tests/wg_managed/*.sh
shellcheck -s bash -x -S style bin/wg-healthcheck libexec/wg-healthcheck-managed \
  install.sh scripts/*.sh tests/*.sh tests/lib/wg_healthcheck_test_support.sh \
  tests/lib/wg_managed_test_support.sh \
  tests/wg_healthcheck/*.sh tests/wg_managed/*.sh
shellcheck -s bash -x -S style -e SC2034 libexec/wg-healthcheck-managed.d/*.bash
systemd-analyze verify systemd/wg-healthcheck@.service systemd/wg-healthcheck@.timer
```

Edit the fixed source fragments under `libexec/wg-healthcheck-managed.d`, then regenerate
the tracked runtime with `bash scripts/build-managed-module.sh --write`. Release archives
contain only the generated runtime, so production still admits one fixed managed module.
The full generated module keeps cross-fragment unused-variable analysis enabled; the
fragment-only ShellCheck pass suppresses `SC2034` because sibling references are invisible
when each bounded source unit is parsed alone. The installer runner's fixed source hints
let ShellCheck analyze its split units with their shared fixture context.

See [CONTRIBUTING.md](CONTRIBUTING.md) for change and review expectations.
