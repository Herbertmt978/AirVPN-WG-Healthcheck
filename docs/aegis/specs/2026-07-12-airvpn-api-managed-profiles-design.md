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
- `wg-healthcheck provision <iface> --dry-run [--credential-fd N] [--settings-fd N]`
  validates a missing-profile plan; `provision <iface> --apply [--credential-fd N]`
  installs the profile and refuses to overwrite an existing path.
- `wg-healthcheck adopt <iface> --dry-run [--credential-fd N] [--settings-fd N]`
  validates a matching static profile; `adopt <iface> --apply [--credential-fd N]`
  explicitly adopts it and refuses a changed device identity.
- An existing API-mode profile may use `adopt --dry-run` only with both a supplied
  credential descriptor and a validated proposed-settings descriptor. This is the narrow
  setup replacement-key validation seam; it remains identity-pinned and `adopt --apply`
  remains forbidden in API mode.
- The setup-only `--settings-fd` is rejected on apply and every other command. It validates
  proposed device/country settings before any persistent config change.
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

Setup adds a fixed administrative lease at
`/run/wg-healthcheck/<iface>.setup-guard`, a root-owned mode-0600 regular file. Ordinary
non-status runtime invocations acquire it shared before loading configuration and hold it
through cleanup. Setup stops the timer/worker and holds it exclusive across validation,
config/key persistence, runtime apply, rollback, fresh health verification, and the timer
decision. Only explicit setup-capable commands may accept an inherited lease descriptor;
runtime verifies that descriptor is the exact fixed file and part of the exclusive locked
open-file description. The lock order is administrative lease, interface lock, then global
API lock. Status stays observational and never creates a lease file.

The setup-only settings descriptor is a root-owned mode-0600 regular file with both a
different descriptor number and a different `(st_dev,st_ino)` identity from the credential
descriptor. It contains exactly three newline-terminated ASCII records:

```text
version=1
device=<validated device name>
countries=ALL|<CODE>[ <CODE>...]
```

The record is capped at 256 bytes. Codes are unique uppercase two-letter values, `ALL`
must be the sole token, and no unknown, repeated, NUL/control-bearing, unterminated, or
non-canonical field is accepted. Runtime reads bounded bytes from the already-open FD,
requires exact size and stable pre/post metadata, and closes both private descriptors on
every invalid-settings path before any child, log helper, config/state/lock/provider work.
It overlays only the in-memory dry-run device/country policy and treats that validated
country record as the explicit policy instead of requiring an installed
`AIRVPN_COUNTRIES` occurrence. Without an override, the exact installed occurrence rule
remains. The installed config remains authoritative for apply.

Dry-run validates the complete prospective API configuration after the in-memory overlay,
including every API-only cross-field rule while the persisted source remains `static`.
Apply repeats that side-effect-free prospective validation from installed settings before
provider, profile, Docker, tunnel, or source-flip effects.

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
  If the durable install succeeds but API-source activation fails or the process crashes,
  the root-only profile is intentionally retained as an inert static recovery profile;
  setup never deletes an installed secret profile automatically. The timer remains
  disabled, status reports static mode, and a retry follows the matching-profile adoption
  path, making that exact profile the pre-managed recovery snapshot. This is the only
  intentional exception to restoring profile absence.
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

Only an already-active API configuration may reuse its installed credential without a
prompt. Entering API mode from static always requires a proposed descriptor, even when a
retained key file exists. An exact retained key may be revalidated without rewriting it;
a different value requires `--replace-credential`. Credential selection during interrupted
setup is based on the durable pre-transaction configuration snapshot rather than current
key-file presence. If recovery can still commit or roll back either source, setup requests
a proposal and accepts it after recovery only when it exactly matches the restored active
API credential or an explicit replacement was requested.

The credential supplied for acceptance testing is not a production credential. It is
removed after the live test. The VM remains in API mode only after the owner supplies a
new API key that was not pasted into chat; otherwise it is returned to verified static mode.

The AirVPN API Explorer classifies `status`, `dns_lists`, and `whatismyip` as public and
`userinfo`, `notification`, `devices`, `generator`, and `disconnect` as account-scoped.
The `devices` service exposes asynchronous list/add/renew/delete/modify lifecycle actions.
Version 1.1 intentionally admits only public `status`, account-scoped `generator`, and
tunnel-bound public `whatismyip`. A setup-only reduced device picker is future work;
unattended device mutation, account inspection, notification, disconnect, and DNS-list
policy remain outside this trust and product boundary.

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

- `system=other` (AirVPN's raw single-profile output, not an OS archive)
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
as success. The helper explicitly requests AirVPN's `system=other` raw profile form and
accepts only the expected WireGuard text content or a bounded JSON error object; it rejects
HTML, OS archives, multipart data, unsupported content encodings, and any unexpected
content type. Synthetic redacted response-shape fixtures provide deterministic contract
tests without retaining credentials or generated key material.

AirVPN documents exact top-level `result: "ok"` as API success and otherwise uses `result`
for the error message. Its current authentication boundary can instead emit a top-level
non-empty `error` string with no `result`. The helper recognizes only those two shapes as
permanent generator rejection envelopes. It treats missing, empty, non-string,
success-shaped, contradictory, duplicate-keyed, non-object, malformed, or over-deep JSON
as a transient `phase=response`, `reason=json` contract failure and never exposes any
remote field.

An authenticated transient failure emits one exact local phase. Only `phase=response` may
also emit one exact local reason: `status`, `encoding`, `media`, `read`, `size`, `json`, or
`protocol`. These values identify the helper branch only. They must not contain, encode,
or cause retention of an actual status, header name or value, URL, body, device, server,
credential-derived value, or provider message. The runtime admits only newline-exact
allowlisted manifests. Adding this diagnostic does not broaden the accepted media types,
content encodings, status codes, JSON envelope, profile grammar, or request contract.

Required structure:

- exactly one `[Interface]` and one `[Peer]`;
- unique required fields with bounded values;
- valid WireGuard private, public, and preshared keys;
- exactly one canonical IPv4 `/32` interface address;
- numeric endpoint matching the selected server and configured WireGuard port;
- MTU `1320`, keepalive `15`, and exactly `0.0.0.0/0` for `AllowedIPs`.

Rejected provider content includes unknown sections, duplicate security fields, additional
peers, `SaveConfig`, `PreUp`, `PostUp`, `PreDown`, `PostDown`, shell syntax, control
characters, hostnames, unexpected routes, and oversized responses.

Managed mode uses a canonical allowlist rather than preserving arbitrary local text. The
rendered `[Interface]` contains `Address`, `PrivateKey`, `MTU`, optional `DNS`, and optional
`Table`. `Table` may be `auto`, `off`, or a numeric table ID. The rendered `[Peer]` contains
only `PublicKey`, `PresharedKey`, `Endpoint`, `AllowedIPs`, and `PersistentKeepalive`.
Comments are replaced by a fixed generated header; the exact pre-managed file retains the
operator's original formatting and comments for rollback.

The provider model and public renderer remain unable to carry hooks. The fixed fd5 pinning
path parses the already validated root-owned installed profile into a private wrapper and
may retain only ordered, repeated Interface `PostUp` and `PostDown` commands, including
their exact original directive text and significant whitespace. `PreUp`,
`PreDown`, `SaveConfig`, peer hooks, unknown directives, an additional address, or an
additional peer still block adoption before HTTP or mutation. Runtime rotation requires the
generated interface private key and IPv4 address to equal the current values before any
qBittorrent or tunnel mutation. Candidate rendering uses those unchanged interface values,
the validated optional local `Table`, retained local post hooks, and newly generated AirVPN
peer fields. Generated/provider hooks can never cross into that private wrapper.

For first provisioning without an existing profile, only the canonical allowlisted
generated profile is installed. The installer itself never provisions implicitly.

Secret profile bytes never travel through stdout, stderr, shell variables, command
substitution, or arguments. The orchestrator pre-opens a root-only candidate descriptor;
the Python helper receives credential descriptor 3 and output descriptor 4, closes both
immediately after use, and writes only a redacted manifest to the separate status channel.
No child process inherits either descriptor. `LimitCORE=0` protects systemd runs and manual
setup/provision paths set the equivalent process core limit before reading any secret.

For first setup validation, the guide passes both the proposed credential and the strict
non-secret settings record through distinct private descriptors. After a successful dry
run, setup atomically persists device/country settings while source remains `static`,
installs and revalidates the credential, and then calls runtime apply without a settings
override. Runtime's existing final source flip is the activation point. Any failure
restores the exact prior config and credential; every crash before apply therefore remains
in inert static mode.

Authenticated validation retains runtime-owned attempt, outcome, backoff, and credential
identity accounting even if setup later rolls back; removing that security history would
enable retry storms and is not part of setup rollback. Stopping the timer is also a
persistent safety action, not rolled back implicitly. After runtime apply, setup performs a
controlled health run under its lease and accepts only a newly replaced, stable,
root-owned mode-0600 status with a current `healthy` or `recovered` outcome. That fresh
health proof is the ordinary setup commit point. The explicit exception is a successful
`restore-static --apply`: runtime has already completed its verified profile/qBittorrent
transaction and source change, so that success commits the restored static profile. A
later setup-status proof failure retains that exact static result with the timer disabled
rather than combining the restored profile with a rolled-back API source. If the optional
timer enable then fails, setup disables/stops the timer, retains the verified committed
mode/config/credential/profile, and reports that only timer activation remains incomplete;
it does not attempt to undo a possibly successful managed recovery.

Setup recovery uses a strict root-only journal beside the health configuration. Legacy v1
and v2 records retain their exact field order and historical phases; neither may claim the
v3-only `verifying` or `rolled-back` phases. Current v3 records contain exact ordered
`version`, `operation`, `phase`, prior-key, prior-snapshot, key-change, proof-start, and
prior-status identity fields with canonical LF separators. Operation/phase combinations
are explicit. Static operations must record `key_changed=0`; an API operation cannot claim
both that no prior key existed and that the key was unchanged. `verifying` and `verified`
require a persisted proof start; every other phase, including `rolled-back`, requires zero
proof fields. Before invoking a recoverable health check, setup records `verifying` with
the prior status identity and start time. Rollback restores repeatable snapshots, records
`rolled-back` with cleared proof, then removes the snapshots and journal last.

Atomic journal, health-config, and credential rewrites each use a fixed same-directory
root-only staging name opened with exclusive creation. They never overwrite an abandoned
staging entry. An apply recovery holds the exclusive setup lease while durably discarding
these unpublished fixed entries before it reads the authoritative journal; a dry run with
one present fails closed without mutating it. This bounds every possible staged secret and
makes a power-loss remnant discoverable and recoverable without directory-pattern guesses.

Each setup snapshot is copied to a fixed same-directory root-only staging path, synced,
validated, published without overwriting an existing snapshot, and followed by a directory
barrier. Recovery removes an unpublished staging copy only while the journal is still
`prepared`; a later phase without its authoritative snapshot fails closed. A published
snapshot and its interrupted same-inode staging link are reconciled durably before restore.
A lone runtime-owned managed candidate is removed only by the managed runtime under the
inherited exclusive setup lease and interface lock, with no pending journal or safety
record, strict metadata/size checks, unlink, parent sync, and an absence proof.

## Managed rotation transaction

The endpoint-only transaction remains unchanged for static mode. Managed mode uses a
versioned full-profile transaction:

- Active: `/etc/wireguard/<iface>.conf`, root-owned mode `0600`.
- Backup: `/etc/wireguard/<iface>.conf.bak-healthcheck`, root-owned mode `0600`.
- Candidate: `/etc/wireguard/.<iface>.conf.managed-candidate`, root-owned mode `0600`.
- Pending journal: `/etc/wireguard/<iface>.conf.pending-healthcheck`, root-owned mode
  `0600`.
- Safety record: `/etc/wireguard/<iface>.conf.safety-healthcheck`, root-owned mode `0600`.
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

The companion safety record is the authoritative crash owner for the period in which
deleting the phase journal and finalizing a successful transaction cannot be one atomic
filesystem operation. It is strict ASCII line-oriented data with this exact schema:

```text
version=1
record=managed-profile-safety
state=pending|committed|finalizing
backup_sha256=<64 lowercase hex>
candidate_sha256=<64 lowercase hex>
old_endpoint=<canonical numeric IPv4 endpoint>
candidate_endpoint=<canonical numeric IPv4 endpoint>
qb_intent=unmanaged|running|stopped
qb_container=-|<validated container name>
qb_container_id=-|<64 lowercase Docker container ID>
qb_process=-|<validated process name>
qb_listen_ipv4=-|<canonical IPv4>
qb_listen_port=0|<1..65535>
```

The safety-record parent is the same root-owned mode-`0700` WireGuard directory. The file
is a root-owned, non-symlink regular file with exact mode `0600`, at most 4 KiB, exactly
the listed unique fields, LF separators, and a final LF. Each create or state transition
uses a same-directory private temporary file, file sync, atomic rename, final-file sync,
and parent-directory sync.

The two profile digests must differ. Both endpoints must be canonical, but they may be
equal when an exact static restore changes peer material without changing the server
address. Equal endpoints do not bypass any qBittorrent containment, tunnel restart,
identity, digest, network, or crash-recovery proof. `qb_intent=unmanaged` requires every
qBittorrent tuple field to use its `-`/`0` sentinel. A `running` or `stopped` intent
requires a complete tuple whose listen address equals the single digest-bound interface
IPv4 `/32`; its immutable Docker container ID and current configured container/process/
listen tuple must all match. The safety record and v2 journal duplicate digests,
endpoints, and running intent consistently: `running` maps to `qb_was_running=1`, while
`stopped` and `unmanaged` map to `0`. A container name alone is insufficient because
Docker may recreate a different container under that name.

Before any pre-exclusion, qBittorrent, backup, journal, profile, or network effect, a
status-only comparator opens the active and candidate files directly and requires exact
Interface `PrivateKey`, canonical dotted IPv4 `/32`, and optional `Table` presence/value
identity. `Table` is only `auto`, `off`, or a canonical integer from 1 through
4294967295. It rejects duplicates, invalid addresses, and changed identity without ever
placing the private key in shell variables, arguments, stdout, stderr, logs, or a
pipeline. The same comparison is repeated between the durable backup and candidate after
backup creation and before the safety record is written.

Every journal update is written to a non-symlink same-directory temporary file, mode
`0600`, then atomically renamed and followed by file and parent-directory durability
barriers. The backup and candidate are fully written, synced, hashed, and re-read before
the first journal is committed. Each phase transition verifies the expected active,
backup, and candidate digests before continuing.

The v1.1 reader remains compatible with the v1.0 one-line canonical-endpoint marker. It
classifies that shape as an endpoint transaction, verifies the backup endpoint, and runs
the existing restore path. Upgrade instructions still require no pending marker or safety
record before install, but an interrupted v1.0 transaction is not rendered unrecoverable
by the new code.

Pending classification occurs after fixed-path and lock validation but before profile-mode
dispatch. The safety record is classified before the journal because it owns every
ambiguous post-mutation state. A normal static run with neither file never loads managed
code; any safety record or v2 journal securely loads it solely for reconciliation before
normal dispatch. API mode with a v1 marker uses the built-in endpoint reconciler first.
Every mode change, static restore, credential removal, state purge, installation, upgrade,
and uninstall refuses while a safety record or either marker type remains unresolved.

The recovery classifier is exact:

| Safety record | Pending journal | Action |
| --- | --- | --- |
| absent | absent | normal dispatch |
| absent | canonical v1 | existing endpoint reconciliation |
| absent | v2 | contain qBittorrent, retain evidence, and fail as an orphan |
| absent | invalid or unknown | contain the configured client where safely identifiable, retain evidence, and fail |
| `pending` | matching v2 | roll back from the safety record and phase evidence |
| `pending` | absent | roll back from the safety record alone |
| `pending` | invalid or mismatched | contain recorded and configured clients, retain evidence, and fail |
| `committed` or `finalizing` | absent | finish candidate verification and cleanup idempotently |
| `committed` or `finalizing` | any marker | contain clients, retain evidence, and fail as impossible state |
| invalid | any | contain the configured client, retain evidence, and fail |

The forward transaction is:

1. Acquire the per-interface lock, then use the global authenticated-API lock only for
   bounded provider/state work. Respect backoff, daily limits, and exclusions.
2. Select, generate, strictly validate, and durably stage the normalized candidate on the
   `/etc/wireguard` filesystem. Verify candidate digest/endpoint and compare active to
   candidate identity before any local mutation.
3. Snapshot the configured qBittorrent tuple, immutable container ID, and running intent;
   malformed or unprovable Docker state fails before mutation. Durably back up the entire
   active profile, then repeat the identity comparison from backup to candidate.
4. Persist any pre-switch candidate state, write and sync the `pending` safety record,
   then write the matching `prepared` journal. Neither file contains profile or credential
   content.
5. If qBittorrent was running, stop the recorded container ID and prove it stopped. Record
   `client-stopped`. A stopped or unmanaged client remains stopped/unmanaged.
6. Run containment checkpoints after the stop, immediately before and after tunnel down,
   before and after candidate installation, before and after candidate up, and before and
   after network verification. Any unexpected running state, malformed state, or inspect
   failure triggers a best-effort stop-and-prove operation and fails the transaction.
7. Bring the interface down while the old profile remains installed and record
   `tunnel-down`. Reverify the candidate, atomically install and sync it, record
   `candidate-installed`, bring it up, and record `candidate-up`.
8. Verify live interface address, peer public key, exact endpoint, fresh handshake,
   required route/rule, AirVPN egress, and optional post-rotation speed.
9. Restore qBittorrent only after network verification. A recorded-running client must
   still be stopped; the transaction owns exactly one start of the recorded immutable ID,
   then re-inspects it and proves the same configured tuple plus TCP and UDP ownership. An
   already-running or replaced container is contained and fails. A recorded-stopped or
   unmanaged client must remain so.
10. Record `verified` and re-prove candidate digest, network health, immutable container
    identity, configured tuple, and final qBittorrent intent before cleanup.
11. Remove and sync the candidate, reverify the active digest, then unlink and sync the v2
    journal. A journal unlink or sync failure is never repaired by recreating the journal;
    the still-`pending` safety record owns rollback.
12. Repeat active/network/qBittorrent proof after cleanup, then atomically transition the
    safety record from `pending` to `committed` and sync it. This is the candidate commit
    point: a crash observes either a pending rollback owner or a committed candidate owner,
    never an unowned intermediate state. If the transition reports a durability failure,
    a strict re-read controls the next action: visible `pending` rolls back; visible
    `committed|finalizing` finalizes without rollback; missing or invalid state is contained
    without guessing.
13. Write success status and rotation cooldown as post-commit best effort. Their failure
    never rolls back a committed candidate and therefore cannot leave a success stamp for
    a profile that was restored.
14. Transition to `finalizing`, repeat active/network/qBittorrent proof, and unlink and sync
    the safety record last. If the final unlink reappears after a crash, finalization is
    harmlessly repeated.

Pending rollback first stops and proves stopped both the recorded immutable container and
any different currently configured target. It validates the safety record, journal when
present, digests, endpoints, backup, and active classification without guessing; runs the
same containment checkpoints around down, restore, up, and verification; restores and
syncs the exact backup bytes/mode/owner; and verifies the old tunnel. It then removes and
syncs candidate and journal artifacts. Only when the current configuration still matches
the recorded tuple may it restore the recorded qBittorrent intent and prove the immutable
ID, TCP/UDP binding, and final state. Configuration drift keeps both targets stopped and
the safety record present. The safety record is removed and synced only after the complete
rollback postcondition passes. Any mismatch or incomplete rollback retains it, keeps
qBittorrent stopped, writes only redacted status, and requires operator repair.
Rollback status reporting is best-effort bookkeeping, not commit authority; required
failed-candidate exclusion durability retains its existing fail-closed contract. Managed
rollback never creates or removes a rotation-success stamp.

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
interface/global lock is held, and no pending journal or safety record exists.

The global lock contract is process-tested with two interface workers and a blocking
provider double: maximum authenticated generator concurrency is exactly one, while the
lock must be released before either worker begins Docker or tunnel work.

The installer creates the persistent directory with the required ownership for live and
staged installs. Normal uninstall preserves API state and credentials for recovery;
explicit setup purge flags remove them after the timer, worker, locks, and pending journal
and safety record are proven inactive.

## qBittorrent and leak boundary

- When a qBittorrent container is configured, managed rotation must stop it before
  bringing down the verified tunnel and start it only after route and AirVPN egress pass.
- A successful transaction still requires the recorded immutable container ID and same
  process to own both TCP and UDP listeners on the configured WireGuard address and port.
- An external restart, replacement container, configuration drift, malformed inspect
  result, or unexpected running state during forward or rollback work is contained and
  fails closed; the transaction never treats it as its own successful restore.
- If rollback cannot restore a verified tunnel, qBittorrent stays stopped.
- Hosts without a configured qBittorrent container remain responsible for an independent
  firewall kill switch. The software does not claim to protect arbitrary clients.

## Install and upgrade safety

- Fresh installation remains non-interactive and never starts or provisions a tunnel.
- A live v1.1 installer refuses to replace runtime files while an instance timer or worker
  is active, an interface lock is held, or a pending journal or safety record exists.
- `install.sh --quiesce <iface>` is the explicit upgrade convenience: it records whether
  the timer was enabled, stops timer and worker, waits for inactivity, checks the lock and
  recovery artifacts, installs in helper/main/setup/unit/template order, validates
  preserved files, and leaves the timer disabled for a manual check.
- Neither the installer nor setup automatically re-enables a previously enabled timer.
  Setup offers re-enablement only after the installed version completes a healthy or
  recovered manual invocation.
- Both v1.0 one-line and v1.1 versioned markers are recognized by v1.1 reconciliation.
  Downgrade to v1.0 is refused while a v2 marker or safety record exists; the current v1.1
  code must finish or roll back that transaction first.
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
- malicious provider profiles with hooks, duplicates, extra peers, malformed keys,
  hostnames, changed identity, or unexpected routes are rejected before tunnel-down;
- only bounded, ordered `PostUp`/`PostDown` commands from the trusted installed fd5 profile
  survive pinning; forged wrappers and every other installed directive fail redacted;
- active-to-candidate and backup-to-candidate identity checks reject changed private key,
  canonical IPv4 `/32`, or optional `Table` without exposing a key through output, logs,
  tracing, process arguments, or helper pipelines;
- 401, 403, 429, 5xx, timeout, and malformed responses preserve the working profile;
- crash injection at every transaction boundary either restores the old verified state or
  retains actionable pending state;
- journal unlink/fsync failure, safety-record state-transition failure, and final safety
  unlink/fsync failure always leave either a rollback owner or committed candidate owner;
- candidate health, identity, route, egress, speed, qBittorrent stop/start, and binding
  failures perform verified rollback;
- unexpected qBittorrent restart, container recreation under the same name, and configured
  tuple drift are contained in both forward and rollback paths;
- rollback failure retains the safety record and any still-valid journal evidence and
  leaves qBittorrent stopped;
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
