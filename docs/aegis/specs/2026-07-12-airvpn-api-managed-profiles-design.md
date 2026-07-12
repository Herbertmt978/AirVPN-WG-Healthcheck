# Design: Dual-Mode AirVPN WireGuard Profile Management

Status: approved for implementation by the repository owner
Target release: `v1.1.0`
Date: 2026-07-12

## TaskIntentDraft

- **Outcome:** retain the existing credential-free workflow and add an opt-in,
  API-managed workflow that can securely provision and rotate AirVPN WireGuard
  profiles for unattended hosts.
- **Primary deployment:** migrate the download VM to API-managed mode while
  keeping qBittorrent traffic bound to and verified through AirVPN.
- **Success evidence:** deterministic tests, malicious-input tests, crash-boundary
  rollback tests, full secret scans, reproducible release validation, an authenticated
  dry run, a controlled VM rotation, post-rotation AirVPN egress, and live public-peer
  qBittorrent source verification.
- **Stop condition:** `v1.1.0` is merged, tagged, released with both paths documented,
  and the VM is healthy in API-managed mode with a verified rollback path.
- **Non-goals:** automatic AirVPN API-key creation, automatic device renewal/deletion,
  automatic port-forward allocation, arbitrary provider support, or claiming to be a
  firewall kill switch.
- **Risks:** account credential exposure, remote root-code execution through a generated
  profile, request storms, changed tunnel identity invalidating qBittorrent/policy rules,
  and incomplete rollback while the download client is running.

## BaselineReadSetHint

- `README.md`, `SECURITY.md`, `CONTRIBUTING.md`, and `CHANGELOG.md`
- `bin/wg-healthcheck`, especially configuration, selection, restart, transaction,
  reconciliation, qBittorrent, and main-flow functions
- `libexec/airvpn-api`
- `install.sh`, systemd units, package script, and all current tests
- AirVPN API settings/explorer, public status endpoint, configuration generator,
  technical specifications, and official device-lifecycle statements

## ImpactStatementDraft

- **Affected layers:** Python provider boundary, Bash recovery transaction, strict
  settings grammar, new guided setup surface, installer/package contents, systemd
  persistent state, tests, security docs, README, release notes, and VM deployment.
- **Canonical owners:** Python owns authenticated HTTP and provider-profile parsing;
  Bash owns local state transitions and rollback; the setup helper owns interactive
  credential capture and operator choices.
- **Invariants:** the API key never crosses the documented secret boundary; remote text
  is never executable; the old verified profile remains recoverable; live managed
  rotation cannot change interface identity; qBittorrent does not run across an
  unverified managed-profile switch.
- **Compatibility:** static mode and existing configuration stay valid. API-managed
  mode is an explicit opt-in. The installer continues to preserve existing operator data.

## First-principles decision review

- **Non-negotiable goal:** automate profile creation and server recovery without giving
  a remote response or account credential authority over local routing policy.
- **Non-negotiable constraints:** fail closed before mutation, preserve a verified
  rollback target, keep secrets out of observable surfaces, and preserve existing users.
- **Historical assumption removed:** full automation does not require automatic device
  renewal. Ordinary tunnel trouble is a server/profile problem, not a device-key problem.
- **Smallest sufficient path:** a fixed existing AirVPN device, authenticated profile
  generation, strict normalization, transactional local switching, and explicit
  provisioning.
- **Escalation trigger:** changing the AirVPN device, tunnel address, forwarded-port
  ownership, or consumer configuration requires a separate blue/green device-lifecycle
  design and approval.

## Product modes

### Static profile mode

- Default and fully credential-free.
- Operator supplies `/etc/wireguard/<iface>.conf` as today.
- `AIRVPN_ROTATE_ENABLED=0` performs restart-only recovery.
- `AIRVPN_ROTATE_ENABLED=1` retains public status-based endpoint-only rotation.
- No API-key file is opened and no authenticated request is made.

### API-managed profile mode

- Explicit opt-in with `AIRVPN_PROFILE_SOURCE=api`.
- Uses one existing AirVPN device, configured by an explicit non-secret device name.
- Supports explicit first provisioning and full peer-material refresh during rotation.
- Selects a different healthy server from the public status API, then asks the
  authenticated generator for that exact server and fixed device.
- Rejects a runtime candidate whose interface private key or addresses differ from the
  current profile.
- Does not create, renew, revoke, or delete an AirVPN device.

## Operator experience

### Installation

The non-interactive installer remains:

```text
sudo ./install.sh wg0
```

It installs reviewed runtime files, creates secure empty directories as required, and
preserves every existing operator configuration and credential.

A new guided command is installed as:

```text
sudo wg-healthcheck-setup wg0
```

The guide presents exactly two choices:

1. Existing/static WireGuard profile
2. AirVPN API-managed profile

After API mode is selected, setup queries the credential-free public status API and shows
only countries with at least one currently healthy IPv4/WireGuard-capable server. The user
must explicitly select one or more countries by displayed number or two-letter code before
the credential prompt. Selecting one country is a strict single-country policy. Selecting
several creates a hard allowlist; list order is a soft preference while server health,
load, users, and capacity continue to choose the candidate within that allowlist. An
explicit `ALL` choice permits every eligible country.

The setup helper is a standard-library Python program so secret input does not pass through
a shell variable. It never accepts an API key value in an argument or environment variable.
API mode reads it with a hidden controlling-terminal prompt, passes it only through a
private descriptor to the provider helper, and validates a redacted dry run before it may
persist the credential. The guide shows a non-secret summary, asks before mutation, runs
one controlled health check, and offers to enable the timer only after success.

When adopting an existing profile, the guide first proves that the generated device
private key and address set match the installed profile. It then creates a durable
root-only pre-managed snapshot and updates only the two new non-secret health settings
through the same strict parser and an atomic preserve-unrelated-keys rewrite. A mismatch
does not persist the proposed credential, leaves static mode selected, makes no network
change, and gives a redacted corrective message.

For automation, the guide accepts a caller-supplied root-owned credential file by path;
it never accepts the secret value itself. A non-interactive invocation must state the
mode, device, countries, and whether to enable the timer explicitly.

The public setup surface is:

```text
wg-healthcheck-setup [OPTIONS] <iface>
  --mode static|api
  --dry-run | --apply
  --enable-timer | --leave-timer-disabled
  --device NAME
  --countries "GB NL ..."
  --credential-file ABSOLUTE_PATH
  --non-interactive
  --restore-pre-managed
  --replace-credential
  --remove-credential
  --reset-api-state
```

Interactive setup may suggest the provider's conventional `default` device name, but it
must confirm it through generated-profile identity. Non-interactive API setup requires an
explicit device and `--countries` containing one or more two-letter codes or the single
token `ALL`. Presence of a credential file never selects API mode by itself.

`--reset-api-state` is a maintenance action, requires `--dry-run` or `--apply`, and cannot
enable the timer. It may be combined with `--mode static --remove-credential --apply` for
an explicit API-data purge after all inactivity checks; it never removes the pre-managed
recovery snapshot.

### Runtime commands

- `wg-healthcheck <iface>` keeps its existing timer behavior.
- `wg-healthcheck provision <iface> --dry-run|--apply` handles a missing profile. `--apply`
  refuses to overwrite an existing path.
- `wg-healthcheck adopt <iface> --dry-run|--apply` validates and explicitly adopts an
  existing matching static profile. It refuses a changed device identity.
- `wg-healthcheck rotate <iface> --dry-run|--apply` selects and validates an alternate;
  only `--apply` may run the managed transaction.
- `wg-healthcheck status <iface> [--json]` prints a secret-free summary of mode, timer,
  tunnel, last check/rotation, credential presence, pending state, and qBittorrent proof.
- `wg-healthcheck reset-api-state <iface> --dry-run|--apply` is the single owner for
  clearing corrupt/backoff/exclusion state after worker, lock, and pending checks.
- `wg-healthcheck --version` remains stable.

Mutating administrative commands require exactly one of `--dry-run` or `--apply` so an
omitted safety flag cannot cause a network change. The systemd invocation remains the
only argument-free recovery path.

## Configuration contract

New non-secret settings:

- `AIRVPN_PROFILE_SOURCE=static|api`, default `static`.
- `AIRVPN_DEVICE=`, required in API mode and validated as bounded single-line data.

Device names are 1–64 printable ASCII characters beginning with an alphanumeric character
and otherwise limited to alphanumerics, spaces, dot, underscore, and hyphen. Selected
server public names are 1–64 ASCII alphanumerics or hyphens. Values outside those grammars
fail before a request.

Existing country, port, timeout, cooldown, speed, routing, and qBittorrent settings remain
authoritative. `AIRVPN_ROTATE_ENABLED` continues to control whether recovery may move to
another server; its implementation depends on the selected profile source.

`AIRVPN_COUNTRIES` is normalized to unique uppercase two-letter codes in the selected
order, with at most 32 entries. It is a hard candidate allowlist. An empty value means the
operator explicitly chose `ALL`; setup never silently converts an omitted API-mode choice
to all countries. The first code receives the existing soft preference, but a healthier
later country may win. Setup displays this distinction before confirmation.

The generator URL and authenticated origin are fixed in code. They are deliberately not
configurable because the credential must never be sent to an operator-supplied host.

## Provisioning and adoption semantics

- **No WireGuard profile:** only explicit `provision --apply` may install the canonical
  generated IPv4 profile. The ordinary timer path still fails closed on a missing profile.
- **Existing matching static profile:** `adopt --dry-run` compares the generated interface
  private key and IPv4 address without mutation. `adopt --apply` creates
  `/etc/wireguard/<iface>.conf.pre-managed`, mode `0600`, enables API source in the health
  settings, and leaves the live tunnel unchanged until an explicit or health-triggered
  managed rotation.
- **Existing mismatched profile:** adoption fails before configuration, credential, Docker,
  or network mutation. Static operation remains selected.
- **Missing or corrupt local identity:** managed mode cannot infer that a changed private
  key or address is safe. The operator must preserve or move the invalid file explicitly,
  correct every route/qBittorrent/firewall consumer, and run a fresh provision command.
- **Renamed, missing, or inaccessible AirVPN device:** authenticated operations enter the
  persistent device-error backoff and leave the current profile and client untouched.
- **Return to static:** `wg-healthcheck-setup --mode static --restore-pre-managed --apply`
  restores the exact pre-managed snapshot through verified transaction handling. Without
  `--restore-pre-managed`, only the mode changes and the current valid profile is retained.

Identity pinning is deliberate: v1.1 automation repairs server/profile peer material but
does not repair or rotate the AirVPN device identity.

## Credential boundary

- Fixed path: `/etc/wireguard/healthcheck.d/<iface>.api-key`.
- Parent directory: root-owned mode `0700`; file: root-owned regular non-symlink mode
  `0600`, one bounded ASCII line in the provider-documented format.
- The setup helper writes through a same-directory temporary file with `umask 077`, then
  atomically renames and syncs it.
- Runtime opens the file on a private descriptor. The Python helper reads that descriptor;
  secret content is never placed in Bash variables, arguments, the environment, URLs,
  logs, status, state, exceptions, or tests.
- Before every installed-key use, runtime requires the fixed path to be a root-owned
  regular non-symlink file with exact mode `0600`, a secure root-owned mode-`0700` parent,
  bounded size, and exactly one newline-terminated ASCII record. Validation and open occur
  before provider, Docker, profile, or network actions; the helper independently validates
  the bytes after receiving the descriptor.
- Authenticated requests use the `API-KEY` header, a fixed AirVPN HTTPS origin, no
  redirects, bounded time and response size, and a neutral user agent.
- Core dumps are disabled for the service.
- Generated profiles and temporary candidates are secrets because they contain private
  and preshared keys. They remain root-only, are never logged, and are durably removed
  when no longer required.

Credential replacement is a separate transaction. The setup helper validates the proposed
key and fixed device through a dry run before touching the installed key, stages it mode
`0600`, retains at most one root-only previous key during the atomic swap, revalidates the
installed key, then removes and syncs the previous copy. Failure restores the old key and
leaves the selected mode unchanged. Switching to static never opens the stored key and
offers explicit removal. Uninstall preserves credentials unless the operator explicitly
uses `--remove-credential`; removal unlinks the file and syncs its directory but makes no
unreliable secure-erasure claim for journaling or copy-on-write filesystems.

The credential supplied for acceptance testing is not a production credential. It is
removed after the live test. The VM remains in API mode only after the owner supplies a
new API key that was not pasted into chat; otherwise it is returned to verified static mode.

## Provider response boundary

The Python helper must parse and canonically render authenticated generator output. It
must never copy provider text verbatim into an active profile.

Before credential input, `airvpn-api list-countries` reads the existing public status
endpoint and prints sorted, tab-separated `CODE`, sanitized country name, and healthy
eligible server count fields. A country is eligible only when its code is exactly two
ASCII letters and at least one server has `health=ok` plus a valid `ip_v4_in1`. Duplicate
codes, conflicting names, malformed fields, control characters, and oversized responses
fail the setup step before any secret is read. The interactive chooser does not use a
cached or hard-coded country inventory.

Authenticated generation uses one `GET` request to the fixed URL
`https://airvpn.org/api/generator/` with the `API-KEY` header and percent-encoded query
parameters:

- `system=linux`
- `protocols=wireguard_1_udp_<port>`
- `servers=<exact public_name selected from the status response>`
- `device=<explicit configured device>`
- `resolve=on`
- `iplayer_entry=ipv4`
- `iplayer_exit=ipv4`
- `wireguard_mtu=1320`
- `wireguard_persistent_keepalive=15`

API mode accepts only AirVPN's documented WireGuard ports `1637`, `47107`, and `51820`.
The public status record must be healthy, its `public_name` must satisfy the bounded device/
server text grammar, and the generated numeric IPv4 endpoint must equal that record's
`ip_v4_in1` plus the configured port. Static mode retains its existing broader endpoint
validation.

The request has a 20-second default timeout capped at 60 seconds, rejects every redirect,
and accepts at most 64 KiB. HTTP 200 may contain a JSON error and therefore is not treated
as success. The helper accepts only the expected WireGuard text content or a bounded JSON
error object; it rejects HTML, archives, multipart data, unsupported content encodings,
and any unexpected content type. Redacted response-shape fixtures captured during the live
dry run become deterministic contract tests without retaining credentials or key material.

Required structure:

- exactly one `[Interface]` and one `[Peer]`;
- unique required fields with bounded values;
- valid WireGuard private, public, and preshared keys;
- exactly one canonical IPv4 `/32` interface address;
- numeric endpoint matching the selected server and configured WireGuard port;
- MTU `1320`, keepalive `15`, and exactly `0.0.0.0/0` for `AllowedIPs`.

Rejected content includes unknown sections, duplicate security fields, additional peers,
`SaveConfig`, `PreUp`, `PostUp`, `PreDown`, `PostDown`, shell syntax, control characters,
hostnames, unexpected routes, and oversized responses.

Managed mode uses a canonical allowlist rather than preserving arbitrary local text. The
rendered `[Interface]` contains `Address`, `PrivateKey`, `MTU`, optional `DNS`, and optional
`Table`. `Table` may be `auto`, `off`, or a numeric table ID. The rendered `[Peer]` contains
only `PublicKey`, `PresharedKey`, `Endpoint`, `AllowedIPs`, and `PersistentKeepalive`.
Comments are replaced by a fixed generated header; the exact pre-managed file retains the
operator's original formatting and comments for rollback.

Existing managed adoption rejects every hook, `SaveConfig`, unknown directive, additional
address, or additional peer. Runtime rotation requires the generated interface private key
and IPv4 address to equal the current values before any qBittorrent or tunnel mutation.
Candidate rendering uses those unchanged interface values, the validated optional local
`Table`, and the newly generated AirVPN peer fields.

For first provisioning without an existing profile, only the canonical allowlisted
generated profile is installed. The installer itself never provisions implicitly.

Secret profile bytes never travel through stdout, stderr, shell variables, command
substitution, or arguments. The orchestrator pre-opens a root-only candidate descriptor;
the Python helper receives credential descriptor 3 and output descriptor 4, closes both
immediately after use, and writes only a redacted manifest to the separate status channel.
No child process inherits either descriptor. `LimitCORE=0` protects systemd runs and manual
setup/provision paths set the equivalent process core limit before reading any secret.

## Managed rotation transaction

The endpoint-only transaction remains unchanged for static mode. Managed mode uses a
versioned full-profile transaction:

- Active: `/etc/wireguard/<iface>.conf`, root-owned mode `0600`.
- Backup: `/etc/wireguard/<iface>.conf.bak-healthcheck`, root-owned mode `0600`.
- Candidate: `/etc/wireguard/.<iface>.conf.managed-candidate`, root-owned mode `0600`.
- Pending journal: `/etc/wireguard/<iface>.conf.pending-healthcheck`, root-owned mode
  `0600`.
- Pre-managed snapshot: `/etc/wireguard/<iface>.conf.pre-managed`, root-owned mode `0600`.

The v2 pending journal is strict line-oriented data with unique fields:

```text
version=2
transaction=managed-profile
phase=prepared|client-stopped|tunnel-down|candidate-installed|candidate-up|verified
backup_sha256=<64 lowercase hex>
candidate_sha256=<64 lowercase hex>
old_endpoint=<canonical numeric endpoint>
candidate_endpoint=<canonical numeric endpoint>
qb_was_running=0|1
```

Every journal update is written to a non-symlink same-directory temporary file, mode
`0600`, then atomically renamed and followed by file and parent-directory durability
barriers. The backup and candidate are fully written, synced, hashed, and re-read before
the first journal is committed. Each phase transition verifies the expected active,
backup, and candidate digests before continuing.

The v1.1 reader remains compatible with the v1.0 one-line canonical-endpoint marker. It
classifies that shape as an endpoint transaction, verifies the backup endpoint, and runs
the existing restore path. Upgrade instructions still require no pending marker before
install, but an interrupted v1.0 transaction is not rendered unrecoverable by the new code.

Pending classification occurs after fixed-path and lock validation but before profile-mode
dispatch. A normal static run with no v2 marker never loads managed code. Static mode with
a v2 marker securely loads the managed module solely to reconcile before any normal check;
API mode with a v1 marker uses the built-in endpoint reconciler first. Every mode change,
static restore, credential removal, and state purge refuses while either marker type remains
unresolved.

1. Acquire the existing per-interface lock and a global authenticated-API lock.
2. Respect persistent request backoff, daily limits, and candidate-failure exclusions.
3. Select a healthy alternate server and generate a candidate for the fixed device.
4. Strictly validate and stage the normalized candidate as root mode `0600` on the
   `/etc/wireguard` filesystem.
5. Confirm interface identity and all local compatibility invariants before mutation.
6. Durably back up the complete current profile.
7. Write and sync the `prepared` journal with verified backup/candidate SHA-256 digests,
   endpoints, and the recorded qBittorrent running state. It contains no profile or
   credential content.
8. If the configured qBittorrent container is running, stop it. Failure aborts before
   tunnel downtime.
9. Update the journal to `client-stopped`, bring the interface down while the old profile
   is still installed, then record `tunnel-down`.
10. Reverify the candidate digest, atomically install and sync it, record
    `candidate-installed`, bring the interface up, then record `candidate-up`.
11. Verify live interface address, peer public key, exact endpoint, fresh handshake,
    required route/rule, AirVPN egress, and optional post-rotation speed.
12. Restart qBittorrent only after network verification, then require matching TCP and UDP
    ownership on the WireGuard address. A previously stopped container remains stopped.
13. Record `verified`, write status and cooldown state, then remove and sync the pending
    marker last. Candidate cleanup occurs only after the active digest is reverified.

On failure or interruption, reconciliation brings down any candidate, restores the full
backup, starts and verifies the previous tunnel, restores the recorded qBittorrent running
state, and proves its binding. The marker remains whenever rollback is incomplete.

Reconciliation first classifies the active file by digest and phase. It verifies the
backup digest before restore and never guesses when the active, backup, candidate, or
journal state does not match the recorded transaction. Any digest mismatch leaves the
marker in place, keeps qBittorrent stopped, writes a redacted failed status, and requires
operator repair. Successful rollback restores the exact bytes, owner, and mode of the
backup before removing the candidate or marker.

## Failure, retry, and state model

- HTTP 200 is not success by itself; provider result or normalized profile structure must
  prove success.
- Authentication and device errors are persistent failures and do not retry each minute.
- Rate limits, timeouts, and server errors use capped exponential backoff with jitter and
  honor `Retry-After` when valid.
- Transient backoff starts at five minutes, doubles to a six-hour ceiling, and applies
  bounded jitter. A valid `Retry-After` may extend it to at most 24 hours.
- Authentication or unknown-device failures block timer-driven authenticated requests
  for 24 hours and are reset early only when the credential file or configured device
  changes, or by an explicit operator dry run.
- A maximum of six authenticated generation attempts is allowed per rolling 24 hours per
  interface. At most 16 failed servers are retained, each for six hours.
- API backoff, attempt history, and failed-server exclusions live under
  `/var/lib/wg-healthcheck` so reboot cannot reset them.
- API failure before mutation leaves the current profile byte-for-byte unchanged.
- Managed mode does not silently downgrade to endpoint-only mutation. Static mode remains
  a separately selected operating mode, not an error fallback.
- A failed managed candidate is excluded until its bounded expiry so deterministic
  selection cannot immediately choose it again.
- The public selector accepts at most 16 validated repeated server-name exclusions and
  filters them before scoring. Every failed managed candidate is recorded before rollback;
  pruning expiry makes it eligible again. Static selection supplies no exclusion list.

An explicit root administrative `provision|adopt|rotate --dry-run` may bypass only the
authentication/unknown-device suppression so a replacement key can be validated. It still
acquires the global lock, records an attempt, obeys the rolling daily cap and rate-limit/
transient backoff, and mutates no profile, Docker, or tunnel state. Success clears the
authentication/device suppression; failure records the new classified result. Timer runs
never receive this bypass.

Persistent state is root-owned non-symlink data at
`/var/lib/wg-healthcheck/<iface>.api-state`, directory mode `0700` and file mode `0600`.
Its strict v1 schema records schema version, rolling-window start, attempt count,
backoff-until epoch, failure class, credential-file device/inode/mtime/size tuple, configured
device name, and up to 16 server-name/expiry pairs. It never stores a credential digest,
profile field, address, or endpoint. Writes are bounded, atomic, synced, and reject duplicate
or unknown fields.

The interface lock is acquired first, followed by the global
`/run/wg-healthcheck/airvpn-api.lock`; the global lock is released immediately after the
authenticated response and persistent attempt state are durably recorded, before Docker
or tunnel work. No code path acquires them in reverse order. Invalid persistent state,
backward clock movement, or an implausible future timestamp blocks timer-driven API calls
without changing the tunnel. An explicit setup dry run may display the redacted problem
and `--reset-api-state --apply` clears it only after the timer and worker are inactive, no
interface/global lock is held, and no pending journal exists.

The global lock contract is process-tested with two interface workers and a blocking
provider double: maximum authenticated generator concurrency is exactly one, while the
lock must be released before either worker begins Docker or tunnel work.

The installer creates the persistent directory with the required ownership for live and
staged installs. Normal uninstall preserves API state and credentials for recovery;
explicit setup purge flags remove them after the timer, worker, locks, and pending journal
are proven inactive.

## qBittorrent and leak boundary

- When a qBittorrent container is configured, managed rotation must stop it before
  bringing down the verified tunnel and start it only after route and AirVPN egress pass.
- A successful transaction still requires the same process and container PID to own both
  TCP and UDP listeners on the configured WireGuard address and port.
- If rollback cannot restore a verified tunnel, qBittorrent stays stopped.
- Hosts without a configured qBittorrent container remain responsible for an independent
  firewall kill switch. The software does not claim to protect arbitrary clients.

## Install and upgrade safety

- Fresh installation remains non-interactive and never starts or provisions a tunnel.
- A live v1.1 installer refuses to replace runtime files while an instance timer or worker
  is active, an interface lock is held, or a pending journal exists.
- `install.sh --quiesce <iface>` is the explicit upgrade convenience: it records whether
  the timer was enabled, stops timer and worker, waits for inactivity, checks the lock and
  journal, installs in helper/main/setup/unit/template order, validates preserved files,
  and leaves the timer disabled for a manual check.
- Neither the installer nor setup automatically re-enables a previously enabled timer.
  Setup offers re-enablement only after the installed version completes a healthy or
  recovered manual invocation.
- Both v1.0 one-line and v1.1 versioned markers are recognized by v1.1 reconciliation.
  Downgrade to v1.0 is refused while a v2 marker exists; the current v1.1 code must finish
  or roll back that transaction first.
- Installation, upgrade, rollback, and uninstall are tested with live-layout fixtures and
  `DESTDIR` staging, including preservation of existing credentials and pre-managed files.

## Security and privacy tests

Automated tests must prove:

- static mode never opens the key file or makes an authenticated request;
- missing, symlinked, oversized, multiline, wrong-owner, and wrong-mode keys fail before
  any mutation;
- a sentinel key is absent from arguments, environment, URLs, output, errors, logs, status,
  state, release archives, and process listings;
- authenticated requests reject redirects and never echo headers or response bodies;
- malicious profiles with hooks, duplicates, extra peers, malformed keys, hostnames,
  changed identity, or unexpected routes are rejected before tunnel-down;
- 401, 403, 429, 5xx, timeout, and malformed responses preserve the working profile;
- crash injection at every transaction boundary either restores the old verified state or
  retains actionable pending state;
- candidate health, identity, route, egress, speed, qBittorrent stop/start, and binding
  failures perform verified rollback;
- rollback failure retains the marker and leaves qBittorrent stopped;
- concurrent interfaces cannot exceed one authenticated generator request at a time;
- persistent backoff survives reboot simulation and prevents request storms;
- dry-run produces only a redacted manifest and does not mutate files or networking.
- country discovery is credential-free, shows only eligible healthy countries, rejects
  malformed/conflicting provider data, preserves explicit user order after normalization,
  and never treats an omitted API-mode selection as `ALL`.

## Public documentation and install guide

The README starts with a two-path chooser and keeps each quick start self-contained:

- **Use an existing WireGuard profile — no API key**
- **Let the service provision and manage an AirVPN profile — API key required**

Each path includes prerequisites, four or fewer primary setup commands after package
verification, verification, rollback/disable, upgrade, uninstall, and troubleshooting.
The guide explicitly explains what the key can control, where it is stored, how to rotate
it, and that generated profiles are secrets. Examples use documentation-only addresses
and placeholders.

The first 100 lines contain the mode chooser and both two-command setup paths:

```text
sudo ./install.sh wg0
sudo wg-healthcheck-setup --mode static wg0
```

```text
sudo ./install.sh wg0
sudo wg-healthcheck-setup --mode api wg0
```

Long-form upgrade, rollback, uninstall, state-repair, and credential-replacement procedures
move to `docs/operations.md`; the README retains concise safe commands and direct links.
Both paths end with `wg-healthcheck status`, one manual health run, and an explicit decision
to enable or leave the timer disabled.

`SECURITY.md`, `CONTRIBUTING.md`, configuration comments, changelog, and `v1.1.0` release
notes must match the new trust boundary. CI remains credential-free.

## Distribution license decision

The current repository intentionally contains no license, so default copyright remains
in effect even though the source is public. GitHub documents that an explicit open-source
license is required to grant general permission to use, modify, and distribute a project:
<https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository>.

The repository owner approved the MIT License on 2026-07-12. The implementation adds the
standard license text at the repository root, includes it in release packages, and updates
public documentation and release metadata consistently.

## Release and deployment acceptance

- Version is `1.1.0`; release notes and changelog describe both modes and migration.
- The curated archives include the setup helper and no credentials, generated profiles,
  runtime state, VM identifiers, endpoints, or private configuration.
- Complete Python/Bash/installer/release tests, syntax checks, ShellCheck, and secret scans
  pass on the exact tagged tree and packaged archives.
- Git history and release artifacts are scanned for the supplied sentinel/test key pattern
  and general secrets before publication.
- A live authenticated dry run uses the supplied temporary key without exposing it.
- Release-candidate order is fixed: complete deterministic source/package/secret checks;
  install the branch candidate on the quiesced VM; run authenticated dry-run, adoption,
  successful rotation, and rollback drill; restore a healthy VM; then merge.
- After merge, push only `main`, require green CI on that exact commit, create and push only
  the annotated `v1.1.0` tag, require tag/release checks, and then verify the published
  release and freshly downloaded assets.
- The download VM timer is quiesced; current configs and service state are backed up and
  hashed; API mode is adopted only if the generated device identity matches.
- One controlled managed rotation must pass tunnel identity, handshake, route/rule,
  AirVPN egress, qBittorrent TCP/UDP binding, and public-peer source checks. Public-peer
  evidence waits up to 60 seconds for at least one public peer; if none is available, the
  deterministic substitute is qBittorrent TCP/UDP ownership plus a process-bound WireGuard
  route/egress probe, and the absence of peers is reported rather than treated as failure.
- The previous configuration and a tested static-mode rollback procedure remain available.
- After acceptance, the supplied test key is removed. Completion of the VM migration
  requires atomic installation and validation of a newly generated production API key
  that has not been shared in chat. Without it, the VM is restored to verified static mode
  and the API-migration portion of the goal remains open.
- Immediate post-deployment observation covers at least five timer cycles. A redacted
  24-hour follow-up is operational monitoring, not permission to weaken the release gate.
- The branch is reviewed, merged to `main`, pushed, tagged with annotated `v1.1.0`, and
  published as a GitHub release only after CI and VM acceptance succeed.

## Compatibility and retirement

- Static and API modes are both first-class public workflows.
- The current `AIRVPN_ROTATE_ENABLED` key and endpoint-only behavior remain supported.
- Existing installers and configurations are not rewritten automatically.
- No legacy behavior is retired in `v1.1.0`.
- Device lifecycle automation is deferred until a separate design covers blue/green
  devices, tunnel-address consumers, forwarded-port ownership, and revocation recovery.

## ADR signal

This change introduces a durable authenticated-provider boundary, a new profile-source
contract, and a versioned transaction type. After implementation proves the design, an ADR
should record canonical ownership between the Python provider boundary, Bash transaction,
and guided setup helper, plus the deliberate exclusion of automatic device lifecycle.

## Decision recorded

The repository owner approved this specification and the MIT License on 2026-07-12.
Approval authorizes both public modes, the guided setup helper, API-managed migration of
the download VM, and a `v1.1.0` release. It does not authorize automatic AirVPN device or
port lifecycle.
