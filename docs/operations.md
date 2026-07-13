# Operations guide

This guide assumes a reviewed release package, a root shell only where required, and a maintenance window. `wg-healthcheck` can restart WireGuard and an explicitly configured container; it is not a firewall kill switch.

## Verify a setup before automation

Both setup paths leave the timer disabled unless the operator makes an explicit successful timer decision. Confirm the selected mode and run one manual health check:

```bash
sudo wg-healthcheck status wg0
sudo systemctl start wg-healthcheck@wg0.service
sudo systemctl --no-pager --full status wg-healthcheck@wg0.service
sudo cat /run/wg-healthcheck/wg0.status
```

Enable automation only when the run reports `healthy` or `recovered` and the configured firewall policy is independently verified:

```bash
sudo systemctl enable --now wg-healthcheck@wg0.timer
```

Otherwise, leave the timer disabled and resolve the reported condition before another run.

## Country selection in API-managed mode

Interactive setup lists countries that currently have eligible WireGuard servers. One country is a strict policy: only that country is eligible. Multiple countries are a hard allowlist. List order is a soft preference, not a guarantee; health, capacity, and load choose the final server inside the allowlist. `ALL` is an explicit choice that permits every eligible country and must be the only country token in non-interactive use. Setup rejects blank selection, then stores an accepted `ALL` choice as the canonical empty `AIRVPN_COUNTRIES` runtime allowlist.

API mode uses a fixed device name. It can refresh profile peer material, but does not create, renew, revoke, or delete a device. A generated profile must match the installed interface identity before setup can adopt it.

## Credential lifecycle

The credential location is `/etc/wireguard/healthcheck.d/<iface>.api-key`. It is root-owned mode `0600` beneath a root-owned mode-`0700` directory. Never provide a key in an argument, command line, or environment variable. Interactive setup uses a hidden terminal prompt; automation accepts only `--credential-file` pointing at a root-owned file.

To change an API credential, use API mode with `--replace-credential`; setup validates the proposed key and fixed device before replacing the installed file:

```bash
sudo wg-healthcheck-setup --mode api --replace-credential wg0
```

For unattended first-time setup, create the input file outside the repository with root ownership and mode `0600`, then pass only its path. Device names and country codes are not secrets:

```bash
sudo wg-healthcheck-setup --non-interactive \
  --mode api --device 'existing-device-name' --countries 'GB NL' \
  --credential-file /path/to/root-owned-key \
  --apply --leave-timer-disabled wg0
```

Remove the temporary input file through its owning secret-management process after setup succeeds. To return to static mode and remove the installed credential, use static mode with `--remove-credential --apply`; add `--restore-pre-managed` only when you intend to restore the saved pre-managed profile:

```bash
sudo wg-healthcheck-setup --non-interactive --mode static \
  --remove-credential --apply --leave-timer-disabled wg0
```

Normal package removal intentionally preserves the credential and persistent API state so that recovery remains possible.

Generated profiles and transient candidates contain private material. Keep them root-only and never copy them into shell history, diagnostics, tickets, or chat.

## Upgrade and rollback

For a normal v1.1 upgrade, verify and extract the target release, then run:

```bash
sudo ./install.sh --quiesce wg0
```

The installer stops the selected timer and worker, checks for active shared instances, locks, pending transactions, and safety records, and leaves the timer disabled. It never implicitly re-enables a previously enabled timer. Do not combine `--quiesce` with `--enable`, and do not use it with `DESTDIR` staging.

If an upgrade refuses because a recovery artifact exists, keep the timer disabled. Reconcile the pending transaction with the currently installed version first; do not delete a pending or safety marker to force an upgrade. Then rerun the quiesced installer, check `wg-healthcheck status wg0`, run the manual service check, and make a fresh timer decision.

For rollback, first disable the timer and stop the worker. Validate that no recovery artifact remains, then install only a reviewed compatible revision. Older installers can enable a timer automatically, so keep the timer runtime-masked until the manual health check succeeds. A runtime mask lives under `/run` and does not replace the installer-managed unit file under `/etc`. Review any nonzero installer result; a masked timer is not permission to ignore an earlier copy or validation failure.

```bash
sudo systemctl disable --now wg-healthcheck@wg0.timer
sudo systemctl stop wg-healthcheck@wg0.service
sudo systemctl mask --runtime wg-healthcheck@wg0.timer
# From the extracted, reviewed compatible revision:
if ! sudo ./install.sh wg0; then
  printf 'Rollback installer failed; timer remains runtime-masked.\n' >&2
  exit 1
fi
sudo systemctl start wg-healthcheck@wg0.service
sudo cat /run/wg-healthcheck/wg0.status
# Continue only when the manual result is healthy or recovered.
sudo systemctl unmask --runtime wg-healthcheck@wg0.timer
sudo systemctl enable --now wg-healthcheck@wg0.timer
```

Never continue past a nonzero installer result. Do not unmask or enable the timer until the replacement version and configuration have been reviewed and its manual result is healthy or recovered.

## State repair and return to static mode

Use `--reset-api-state` only as a maintenance action with `--dry-run` or `--apply`; it cannot enable the timer. It requires the timer, worker, interface/global locks, and recovery artifacts to be inactive. In API mode, supply the existing fixed device and country policy. Read the dry-run output before repeating the command with `--apply`:

```bash
sudo wg-healthcheck-setup --non-interactive \
  --mode api --device 'existing-device-name' --countries 'GB NL' \
  --reset-api-state --dry-run --leave-timer-disabled wg0
sudo wg-healthcheck-setup --non-interactive \
  --mode api --device 'existing-device-name' --countries 'GB NL' \
  --reset-api-state --apply --leave-timer-disabled wg0
```

To restore a pre-managed WireGuard profile, use static mode with `--restore-pre-managed --apply`. Without that flag, selecting static keeps the current valid profile and changes only the selected source. Removing a credential is separate and explicit through `--remove-credential`.

## Disable and uninstall

To disable one interface while preserving its configuration and recovery evidence:

```bash
sudo systemctl disable --now wg-healthcheck@wg0.timer
sudo systemctl stop wg-healthcheck@wg0.service
```

Before removing shared package files, stop every `wg-healthcheck@*.timer` and `wg-healthcheck@*.service` instance and prove that no pending or safety transaction remains. Back up the operator configuration first. Do not remove a pending marker to force uninstall; reconcile the transaction with the installed version instead.

Run the complete package-removal sequence from Bash. It deliberately stops all installed instances before touching shared executables:

```bash
set -euo pipefail

mapfile -t timers < <(
  {
    systemctl list-unit-files --type=timer --no-legend --plain 'wg-healthcheck@*.timer'
    systemctl list-units --type=timer --all --no-legend --plain 'wg-healthcheck@*.timer'
  } | awk '$1 ~ /^wg-healthcheck@.+[.]timer$/ { print $1 }' | sort -u
)
mapfile -t services < <(
  systemctl list-units --type=service --all --no-legend --plain \
    'wg-healthcheck@*.service' |
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
  \( -type f -o -type l \) \
  \( -name '*.conf.pending-healthcheck' -o -name '*.conf.safety-healthcheck' \) \
  -print -quit)"
setup_pending="$(sudo find /etc/wireguard/healthcheck.d -maxdepth 1 \
  \( -type f -o -type l \) -name '*.setup-transaction' -print -quit)"
if [[ -n "$pending" || -n "$setup_pending" ]]; then
  printf 'A pending recovery transaction exists; package removal stopped.\n' >&2
  exit 1
fi

sudo rm -f -- \
  /etc/systemd/system/wg-healthcheck@.service \
  /etc/systemd/system/wg-healthcheck@.timer \
  /usr/local/sbin/wg-healthcheck \
  /usr/local/sbin/wg-healthcheck-setup \
  /usr/local/libexec/wg-healthcheck/airvpn-api \
  /usr/local/libexec/wg-healthcheck/wg-healthcheck-managed
sudo rm -rf -- /usr/local/libexec/wg-healthcheck/wg_healthcheck_setup
sudo rmdir -- /usr/local/libexec/wg-healthcheck 2>/dev/null || true
sudo systemctl daemon-reload
```

Review every fixed path before running the block on a modified installation. If a transaction is present, never delete a pending marker to force uninstall; recover it with the installed version.

Package removal does not remove the WireGuard profile, health-check configuration, credential, pre-managed snapshot, or persistent API state. Use setup's explicit static/credential maintenance flow when you intend to retire API-managed data.

## Useful status commands

```bash
sudo wg-healthcheck status wg0
sudo systemctl --no-pager --full status wg-healthcheck@wg0.service
sudo systemctl --no-pager --full status wg-healthcheck@wg0.timer
sudo journalctl -u wg-healthcheck@wg0.service -n 100 --no-pager
```

Status output is secret-free. Treat configuration files, credentials, generated profiles, and unredacted logs as sensitive material.
