# Implementation Plan: AirVPN API-Managed WireGuard Profiles

## Goal

Ship `v1.1.0` as a dual-mode product: preserve the existing static,
credential-free healthcheck and add an explicitly selected API-managed mode that can
provision, adopt, rotate, verify, and roll back an AirVPN WireGuard profile without
exposing credentials or running untrusted profile content as root. Publish the MIT-licensed
release and migrate the download VM through a controlled rollback drill.

## Architecture

- `bin/wg-healthcheck` remains the stable healthcheck entry point and owns CLI dispatch,
  common tunnel verification, static endpoint recovery, and mode selection.
- `libexec/wg-healthcheck-managed` is a securely sourced Bash module that owns API state,
  managed-profile transactions, qBittorrent stop/start sequencing, and v2 reconciliation.
  Static timer runs do not source it unless a pre-mode pending classifier finds a v2
  journal that must be reconciled.
- `libexec/airvpn-api` remains the Python provider boundary and gains strict profile
  parsing, fixed-origin authenticated generation, canonical rendering, identity pinning,
  and descriptor-only secret/profile transport.
- `bin/wg-healthcheck-setup` is a standard-library Python operator tool that owns hidden
  credential input, two-mode setup, safe configuration rewrites, and fixed-argument
  orchestration. It never owns tunnel transactions.
- The installer owns managed code/directories but preserves profiles, credentials,
  pre-managed snapshots, pending journals, and persistent API state.

## Tech stack

- Bash 5.1+, Python 3.10+ standard library, systemd 249+, WireGuard tools, iproute2,
  curl, GNU coreutils, util-linux, Docker when qBittorrent management is configured.
- Python `unittest`, isolated Bash harnesses, ShellCheck, `systemd-analyze verify`,
  actionlint, Gitleaks, GitHub Actions, GitHub CLI, and reproducible release scripts.

## Baseline and authority references

- Approved design:
  `docs/aegis/specs/2026-07-12-airvpn-api-managed-profiles-design.md`
- Architecture baseline:
  `docs/aegis/baseline/2026-07-12-initial-baseline.md`
- Public contracts: `README.md`, `SECURITY.md`, `CONTRIBUTING.md`, `CHANGELOG.md`
- Existing owners: `bin/wg-healthcheck`, `libexec/airvpn-api`, `install.sh`, `systemd/`,
  `scripts/package-release.sh`, and `tests/`
- Provider authority: AirVPN API Explorer, public status endpoint, generator endpoint,
  technical specifications, and official device lifecycle statements cited by the spec.

## Compatibility boundary

- `wg-healthcheck <iface>` and `wg-healthcheck --version` remain valid.
- Existing health configurations remain valid and default to
  `AIRVPN_PROFILE_SOURCE=static` without opening a key.
- Static endpoint rotation and the v1 one-line pending marker remain supported.
- The installer never overwrites an existing WireGuard profile, health configuration,
  credential, pre-managed snapshot, backup, candidate, marker, or API state.
- Public CI remains deterministic and credential-free.
- API-managed mode never falls back to endpoint-only mutation after an authenticated
  failure; switching modes is an explicit operator action.
- Device creation, renewal, deletion, and port-forward management remain excluded.

## Verification

Each behavior slice follows RED → GREEN → focused regression → commit. Completion requires:

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
bash tests/test_wg_healthcheck.sh
bash tests/test_wg_managed_profiles.sh
bash tests/test_install.sh
bash tests/test_release.sh --ref HEAD
bash -n bin/wg-healthcheck libexec/wg-healthcheck-managed install.sh scripts/*.sh tests/*.sh
shellcheck -x -S style bin/wg-healthcheck libexec/wg-healthcheck-managed install.sh scripts/*.sh tests/*.sh
systemd-analyze verify systemd/wg-healthcheck@.service systemd/wg-healthcheck@.timer
actionlint
```

The exact outgoing history, extracted archives, and deployed runtime tree are scanned with
redacted Gitleaks. Live acceptance additionally proves AirVPN egress, policy routing,
qBittorrent TCP/UDP ownership, public-peer source routing when peers are available, and
verified rollback on the download VM.

## Plan basis

### Facts

- The public branch is clean and the static transaction already provides atomic backup,
  pending-state reconciliation, postcondition verification, and full-file rollback.
- AirVPN exposes a public status API and an authenticated generator that returns a raw
  WireGuard profile, sometimes using HTTP 200 for error payloads.
- The current Bash entry point already exceeds 1,000 lines, so managed logic needs a
  separate securely loaded owner.
- The current project intentionally rejects account credentials and has tests asserting
  that boundary; those assertions must become dual-mode secret-boundary tests.
- The owner approved the MIT License and `v1.1.0` scope.

### Assumptions pinned by the approved design

- The API-managed path uses an existing fixed AirVPN device and IPv4 entry address 1.
- Runtime rotation must preserve the interface private key and IPv4 `/32` address.
- Managed profiles permit only the canonical provider fields and optional validated
  `Table`; hooks and `SaveConfig` are rejected.
- The supplied API key is for acceptance testing only. A fresh key not shared in chat is
  required before leaving the VM in production API mode.

### Unknowns resolved by explicit gates

- The live generator content type and exact response headers are captured only as a
  redacted shape fixture. A contradiction with the approved MIME allowlist stops the live
  test and requires a spec amendment before code accepts another type.
- The VM's root-only profile may contain unsupported hooks. Adoption detects this without
  mutation; unsupported content keeps the VM in static mode until deliberately migrated.
- Public torrent peers may be absent during the acceptance window. After 60 seconds, the
  deterministic substitute is process-owned TCP/UDP binding plus a process-bound route and
  AirVPN egress probe, with the absence reported.

## Ripple Signal Triage

- Configuration grammar changes expand into the template, setup writer, installer tests,
  README reference, migration docs, and release notes.
- Profile mutation expands into qBittorrent state, route/rule verification, v1/v2 pending
  reconciliation, downgrade rules, and uninstall preservation.
- New installed files expand into package allowlists, archive-mode tests, systemd verify,
  CI syntax checks, and release secret scans.
- Credential handling expands into core-dump policy, process arguments/environment,
  journaling/status redaction, support guidance, VM transfer, and removal/rotation.
- Version and license changes expand into runtime version, `VERSION`, README examples,
  changelog links, release notes, package contents, and GitHub metadata.

## File map

### Create

- `libexec/wg-healthcheck-managed`
- `bin/wg-healthcheck-setup`
- `tests/test_wg_managed_profiles.sh`
- `tests/test_setup.py`
- `tests/test_public_docs.py`
- `docs/operations.md`
- `docs/releases/v1.1.0.md`
- `docs/aegis/adr/0001-dual-mode-profile-management.md`
- `LICENSE`

### Modify

- `libexec/airvpn-api`
- `bin/wg-healthcheck`
- `config/wg0.conf.example`
- `install.sh`
- `systemd/wg-healthcheck@.service`
- `tests/test_airvpn_api.py`
- `tests/test_wg_healthcheck.sh`
- `tests/test_install.sh`
- `tests/test_release.sh`
- `scripts/package-release.sh`
- `.github/workflows/ci.yml`
- `.github/workflows/release.yml`
- `README.md`, `SECURITY.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `VERSION`
- `docs/aegis/INDEX.md`

## Critical code contracts

### Provider model and CLI

The immutable, redacted `WireGuardProfile` dataclass has these exact fields:
`address: ipaddress.IPv4Interface`, `private_key: str`, `mtu: int`,
`dns: tuple[str, ...]`, `table: str | None`, `public_key: str`,
`preshared_key: str`, `endpoint: str`, `allowed_ips: str`, and
`persistent_keepalive: int`.

The exact public function signatures are:

- `parse_wireguard_profile(payload: bytes, *, expected_endpoint: str | None = None) -> WireGuardProfile`
- `render_wireguard_profile(profile: WireGuardProfile) -> bytes`
- `profiles_have_same_identity(expected: WireGuardProfile, candidate: WireGuardProfile) -> bool`

```text
airvpn-api generate-profile
  --server NAME
  --device NAME
  --expected-endpoint IPV4:PORT
  [--timeout SECONDS]
  [--pin-identity]

airvpn-api list-countries
  [--url HTTPS_STATUS_URL]
  [--timeout SECONDS]
```

Credential input is fixed FD 3, canonical profile output is fixed FD 4, and
`--pin-identity` reads the installed profile from fixed FD 5. The descriptor numbers are
not configurable. Safe stdout is exactly one TSV manifest; stderr is a bounded generic
error. Expected exit classes are 2 contract/validation, 3 no candidate, 4 permanent
auth/device, 5 rate limit, 6 transient provider/network, and 7 identity mismatch.

`list-countries` is credential-free and prints one sorted TSV row per eligible country:
uppercase code, sanitized name, and healthy IPv4/WireGuard-capable server count.

The existing credential-free `select` command gains repeatable
`--exclude-server NAME` options, defaulting to none and capped at 16. Exclusions use the
same bounded server-name grammar and are applied before deterministic scoring.

### Runtime CLI

```text
wg-healthcheck <iface>
wg-healthcheck provision <iface> --dry-run|--apply [--credential-fd N]
wg-healthcheck adopt <iface> --dry-run|--apply [--credential-fd N]
wg-healthcheck rotate <iface> --dry-run|--apply
wg-healthcheck restore-static <iface> --dry-run|--apply
wg-healthcheck reset-api-state <iface> --dry-run|--apply
wg-healthcheck status <iface> [--json]
wg-healthcheck --version
```

The descriptor override is accepted only by explicit root administrative dry-run/apply
commands and carries a descriptor number, never a secret value.

### Setup CLI

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

## Task 1: Strict generated-profile parser

**Files:** modify `tests/test_airvpn_api.py`, `libexec/airvpn-api`.

**Why:** raw provider output must never become executable root configuration.

**Impact/compatibility:** existing `select` and `verify-egress` APIs, TSV output, URL
validation, and exit codes remain unchanged.

**Verification:** `python3 -m unittest tests.test_airvpn_api.ProfileParsingTests -v`.

- [x] **Write RED tests.** Add `ProfileParsingTests` with
  `test_redacted_real_success_shape_parses`,
  `test_duplicate_sections_fields_and_extra_peer_are_rejected`,
  `test_hooks_saveconfig_unknown_directives_and_shell_syntax_are_rejected`,
  `test_noncanonical_or_zero_wireguard_keys_are_rejected`,
  `test_address_requires_one_ipv4_32`,
  `test_hostname_ipv6_and_wrong_endpoint_are_rejected`,
  `test_mtu_keepalive_and_allowed_ips_are_exact`, and
  `test_control_non_utf8_bare_cr_long_line_and_oversize_are_rejected`. Generate valid
  dummy keys with `base64.b64encode(bytes([value]) * 32)` so no key-like fixture is stored.
  In the same RED change, add
  `test_list_countries_is_credential_free_and_sorted`,
  `test_list_countries_requires_a_healthy_valid_ipv4_server`, and
  `test_list_countries_rejects_duplicate_conflicting_or_malformed_codes`. Expected output
  is exact `CODE<TAB>name<TAB>count` with no key/header access.
- [x] **Verify RED.** Run the class command and require failures for missing
  `parse_wireguard_profile` rather than import or fixture errors.
- [x] **Implement minimal parser.** Add the `WireGuardProfile` dataclass and a bounded
  64-KiB, 64-line, 1-KiB-line UTF-8 parser. Require one `[Interface]` followed by one
  `[Peer]`; allow `Address`, `PrivateKey`, `MTU`, optional numeric `DNS`, optional validated
  `Table`, then `PublicKey`, `PresharedKey`, `Endpoint`, `AllowedIPs`, and
  `PersistentKeepalive`. Reject every other directive and require MTU 1320, keepalive 15,
  IPv4 `/32`, numeric endpoint, and `0.0.0.0/0`. Add `list_eligible_countries` over the
  already validated public server list and the `list-countries` subcommand without any
  credential path.
- [x] **Verify GREEN.** Run the class command and the complete existing Python test file;
  require all prior tests unchanged.
- [x] **Commit.** `git commit -m "Validate generated WireGuard profiles"`.

## Task 2: Canonical rendering and identity pinning

**Files:** modify `tests/test_airvpn_api.py`, `libexec/airvpn-api`.

**Why:** candidates need deterministic bytes and must retain the fixed AirVPN device
identity without exposing it.

**Impact/compatibility:** canonical rendering replaces comments/formatting only in managed
candidates; the pre-managed snapshot preserves original bytes.

**Verification:** `python3 -m unittest tests.test_airvpn_api.ProfileRenderingTests -v`.

- [x] **Write RED tests.** Add tests named
  `test_renderer_has_fixed_header_order_spacing_and_terminal_newline`,
  `test_parse_render_parse_is_stable`,
  `test_identity_compares_private_key_and_address_without_exposure`,
  `test_identity_pinning_preserves_only_validated_table`, and
  `test_profile_and_manifest_repr_are_redacted`.
- [x] **Verify RED.** Require failures for missing renderer/identity functions.
- [x] **Implement minimal rendering.** Implement `render_wireguard_profile` with fixed field
  order and a fixed generated header. Implement `profiles_have_same_identity` with
  `hmac.compare_digest`; composition copies only the validated current `Table` and requires
  exact private-key/address equality.
- [x] **Verify GREEN.** Run focused and full Python tests plus
  `python3 -m py_compile libexec/airvpn-api`.
- [x] **Commit.** `git commit -m "Render pinned managed profiles"`.

## Task 3: Fixed-origin authenticated generation and descriptor transport

**Files:** modify `tests/test_airvpn_api.py`, `libexec/airvpn-api`.

**Why:** the API key and generated private material must never enter observable process
surfaces.

**Impact/compatibility:** the credential is opened only by `generate-profile`; public
status and egress paths remain credential-free.

**Verification:** `python3 -m unittest tests.test_airvpn_api.GeneratorBoundaryTests -v`.

- [x] **Write RED tests.** Cover exact fixed URL/query/header, allowed ports, server/device
  grammar, no redirects, only `text/plain` or `application/octet-stream` identity-encoded
  bodies, JSON error on HTTP 200, 401/403/429/5xx/timeout classification, bounded
  `Retry-After`, FD 3/4/5 behavior, closed descriptors, no partial candidate, and a sentinel
  key absent from URL/argv/env/stdout/stderr/exception text.
- [x] **Verify RED.** Require the new CLI/function tests to fail because the generator
  command is absent while all old tests pass.
- [x] **Implement minimal client.** Add a generator-only no-redirect opener, exact GET
  parameters from the approved spec, a 64-KiB response cap, exact 64-lowercase-hex key
  validation, canonical render after full validation, atomic full write to FD 4, optional
  identity read from FD 5, and one redacted TSV manifest. Close private descriptors in
  `finally` and never include remote bodies or headers in errors.
- [x] **Verify GREEN.** Run focused/full Python tests and compile check; inspect a spawned
  process test proving the sentinel is absent from `/proc/<pid>/cmdline` and `environ`.
- [x] **Commit.** `git commit -m "Add authenticated AirVPN profile generation"`.

## Task 4: Runtime CLI, configuration, and secure module boundary

**Files:** create `libexec/wg-healthcheck-managed`, `tests/test_wg_managed_profiles.sh`;
modify `bin/wg-healthcheck`, `config/wg0.conf.example`, `tests/test_wg_healthcheck.sh`.

**Why:** administrative operations need explicit safety flags while the static timer
contract and credential isolation remain intact.

**Impact/compatibility:** legacy invocation is unchanged. New config defaults are static.

**Verification:** focused Bash runners, then both Bash test files.

- [x] **Write RED tests.** In the existing suite cover legacy/version dispatch, strict
  mutating flags, provision-only missing-profile allowance, new config keys, API device/
  port grammar, country normalization (unique uppercase two-letter codes, maximum 32,
  empty meaning explicit all), fixed paths, and static mode never stat/open/source
  credential/API code. In the managed suite cover installed-key paths that are missing,
  symlinked, oversized, multiline, non-ASCII, wrong-owner, wrong-mode, or under an unsafe
  parent, and require failure before provider, candidate, Docker, or network events.
  In the new suite cover root-owned mode-0644 managed-module validation and rejection of
  symlink/writable source or parent. Add pre-mode pending classification tests proving
  static/no-marker does not source the module, static/v2 loads it only for reconciliation,
  and API/v1 runs the built-in endpoint reconciler before managed dispatch.
- [x] **Verify RED.** Run
  `bash tests/test_wg_healthcheck.sh` and
  `bash tests/test_wg_managed_profiles.sh`; require only the named new contracts to fail.
- [x] **Implement minimal dispatch.** Add `parse_cli`, `load_command_context`, and
  `dispatch_command`; new defaults `AIRVPN_PROFILE_SOURCE=static`, `AIRVPN_DEVICE=`; fixed
  key/state/lock/candidate/pre-managed paths; and `load_managed_module` that validates
  root owner, mode 0644, regular non-symlink file, and non-writable parent. Source the
  module only for API mode or explicit managed commands. Add `open_installed_api_key` that
  validates the root-owned mode-0700 parent and root-owned regular non-symlink mode-0600,
  bounded, one-record file before opening a private descriptor; the provider independently
  validates record bytes. Classify a pending marker before mode dispatch and load only the
  owner required by its version.
- [x] **Verify GREEN.** Run both suites, Bash syntax, and ShellCheck on the two runtime
  files. Confirm current static tests remain byte-for-byte behavior compatible.
- [x] **Commit.** `git commit -m "Add dual-mode runtime dispatch"`.

## Task 5: Persistent API state and lock discipline

**Files:** modify `libexec/wg-healthcheck-managed`, `libexec/airvpn-api`,
`tests/test_wg_managed_profiles.sh`, `tests/test_airvpn_api.py`.

**Why:** timer-driven generation must survive reboot without request storms or repeated
bad-server selection.

**Impact/compatibility:** state is never read in static mode; corrupt state blocks only
authenticated mutation.

**Verification:** `bash tests/test_wg_managed_profiles.sh api_state` through the suite's
name filter.

- [x] **Write RED tests.** Add strict round-trip/security, rolling six-attempt cap,
  five-minute-to-six-hour backoff, 24-hour `Retry-After` ceiling, 16-entry/six-hour
  exclusion set, credential-stat/device reset, clock regression, corrupt-state blocking,
  interface-before-global lock order, and a two-process/two-interface blocking-provider
  test proving maximum authenticated concurrency one and lock release before Docker/
  tunnel work. Add provider tests for repeated `--exclude-server` (maximum 16), filtering
  before scoring, invalid names, and backward-compatible empty exclusions. Add integration
  failure → persisted exclusion → alternate selection → expiry/re-eligibility coverage.
  Add explicit administrative dry-run coverage proving auth/device suppression bypass,
  attempt accounting, daily/rate/transient limits retained, success clearing suppression,
  failure reclassification, and timer runs remaining suppressed.
- [x] **Verify RED.** Require missing state functions to fail without touching candidate,
  Docker, or tunnel doubles.
- [x] **Implement minimal state owner.** Add strict versioned read/write/prune functions,
  atomic mode-0600 writes under root mode-0700 `/var/lib/wg-healthcheck`, credential
  device/inode/mtime/size metadata, fixed lock order, and release of the global API lock
  immediately after response/outcome persistence. Extend `select_candidate` with an empty-
  default exclusion collection and `select` with repeatable `--exclude-server`; record a
  failed managed candidate before rollback and supply only unexpired entries on the next
  API selection. Add an explicit-admin-dry-run flag that bypasses only auth/device
  suppression and clears it only after a successful validation.
- [x] **Verify GREEN.** Run focused/full managed tests, syntax, and ShellCheck.
- [x] **Commit.** `git commit -m "Persist managed API backoff state"`.

## Task 6: Versioned managed journal and v1 compatibility

**Files:** modify `libexec/wg-healthcheck-managed`, `bin/wg-healthcheck`,
`tests/test_wg_managed_profiles.sh`, `tests/test_wg_healthcheck.sh`.

**Why:** a full-profile switch needs digest-bound crash recovery and must not strand a v1
pending transaction after upgrade.

**Impact/compatibility:** endpoint-only marker functions remain canonical for static mode;
the reconciliation dispatcher recognizes both versions.

**Verification:** focused journal tests plus all current pending/rollback tests.

- [x] **Write RED tests.** Cover canonical v2 fields/phases/modes, duplicate/unknown/
  malformed rejection, file and directory sync order, digest verification before every
  transition, active-file classification, digest mismatch fail-closed behavior, v1 marker
  reconciliation, and v1 static rotation regression.
- [x] **Verify RED.** Require new v2 tests to fail while existing v1 tests remain green.
- [x] **Implement minimal journal.** Add SHA-256 validation, strict v2 parser/writer,
  same-directory atomic barriers, phase transitions, digest classifier, and
  `reconcile_pending_rotation` dispatch. A mismatch retains the marker and returns failure;
  it never restores or deletes by guess.
- [x] **Verify GREEN.** Run focused managed tests and every existing durability/
  interruption/reconciliation test.
- [x] **Commit.** `git commit -m "Journal managed profile transactions"`.

## Task 7: qBittorrent sequencing and verified managed rollback

**Files:** modify `libexec/wg-healthcheck-managed`,
`tests/test_wg_managed_profiles.sh`.

**Why:** qBittorrent must not run during an unverified full-profile transition.

**Impact/compatibility:** static endpoint behavior and ordinary missing-binding restart
remain unchanged.

**Verification:** focused managed transaction tests, then all Bash tests.

- [ ] **Write RED tests.** Cover running/stopped container detection, stop-before-down,
  stop failure abort, old-config down ordering, staged digest check, candidate install/up,
  start-after-network-verification, TCP/UDP proof, previously stopped preservation,
  failure rollback, rollback failure leaving client stopped, and crash injection at every
  phase.
- [ ] **Verify RED.** Require ordering assertions to fail before any implementation and
  confirm no static regression.
- [ ] **Implement minimal transaction.** Add container state/stop/restore functions and
  the approved prepared → verified state machine. Down uses the old installed profile;
  candidate is installed only after tunnel-down; rollback revalidates the backup digest,
  restores exact bytes/mode/owner, verifies old tunnel and binding, then clears state.
- [ ] **Verify GREEN.** Run focused/full managed tests, full static tests, syntax, and
  ShellCheck.
- [ ] **Commit.** `git commit -m "Protect qBittorrent during profile switches"`.

## Task 8: Provision, adopt, rotate, restore, and status commands

**Files:** modify `libexec/wg-healthcheck-managed`, `bin/wg-healthcheck`,
`tests/test_wg_managed_profiles.sh`, `tests/test_wg_healthcheck.sh`.

**Why:** operators and setup need safe, scriptable lifecycle operations and secret-free
evidence.

**Impact/compatibility:** every mutation is explicit; normal timer recovery remains the
only legacy no-flag path.

**Verification:** focused command tests plus both Bash suites.

- [ ] **Write RED tests.** Cover redacted/non-mutating dry runs; provision refusing an
  existing/symlink path; durable first install; adoption identity match/mismatch and exact
  pre-managed snapshot; rotate dry-run/apply; static restoration; credential descriptor
  override; text/JSON status schema; credential presence checked by `stat` only; and every
  command refusing non-root mutation. Add
  `test_timer_health_speed_and_qb_failures_dispatch_managed_rotation_in_api_mode` and
  `test_timer_failures_keep_static_endpoint_dispatch_in_static_mode` so unattended API
  recovery is proved rather than only administrative rotation. Add reset-state dry-run,
  worker/timer/lock/pending refusal, corrupt-state apply reset, and directory durability
  tests. Require adopt/restore/mode-change/credential-removal/state-reset commands to refuse
  both v1 and v2 unresolved markers.
- [ ] **Verify RED.** Require only missing command owners to fail and assert zero Docker/
  network events for all dry runs.
- [ ] **Implement minimal commands.** Wire provider FD contracts, candidate staging,
  snapshot creation, managed transaction calls, mode changes through strict atomic config
  rewrite, explicit static restore, and deterministic status rendering with no address,
  endpoint, device key, API key, or profile content. Make the normal health/speed/
  qBittorrent recovery dispatcher call managed rotation only when
  `AIRVPN_PROFILE_SOURCE=api` and rotation is enabled; never downgrade that path to static
  endpoint mutation after failure. Implement `reset-api-state` inside the managed owner;
  `--apply` removes and syncs only the state file after all inactivity checks pass.
- [ ] **Verify GREEN.** Run both Bash suites and manually inspect JSON through `python3 -m
  json.tool` in the test harness.
- [ ] **Commit.** `git commit -m "Add managed profile administration"`.

## Task 9: Guided setup CLI and secret input boundary

**Files:** create `bin/wg-healthcheck-setup`, `tests/test_setup.py`.

**Why:** both modes need a two-command installation path that remains secure for humans
and automation.

**Impact/compatibility:** setup is optional; the installer stays non-interactive.

**Verification:** `python3 -m unittest tests.test_setup.SetupCliTests -v`.

- [ ] **Write RED tests.** Cover exactly two interactive modes, explicit noninteractive
  mode/safety/timer decisions, API requirements, rejection of secret argv/env values,
  `RLIMIT_CORE=0` before secret read, absolute root-owned mode-0600 credential-file input,
  hidden TTY input, fixed subprocess argv/no shell, and redacted dry-run output. Add
  `test_country_menu_lists_only_public_healthy_choices`,
  `test_country_menu_accepts_numbers_and_codes_preserving_order`,
  `test_single_country_is_strict`,
  `test_all_requires_explicit_selection`, and
  `test_noninteractive_countries_requires_codes_or_all`. Cover reset-state requiring a
  safety flag, rejecting timer enable, and allowing an explicit static combined
  remove-credential/reset-state purge while preserving the pre-managed snapshot.
- [ ] **Verify RED.** Require failures because the setup executable is absent, not because
  TTY doubles or ownership fixtures are invalid.
- [ ] **Implement minimal setup parser.** Use `argparse`, `getpass`, `resource.setrlimit`,
  `os.open` with non-follow flags, `fstat`, inherited private FDs, and fixed-list
  `subprocess.run(..., shell=False)`. Never accept `AIRVPN_API_KEY` or a secret option.
  Before reading a secret, call credential-free `airvpn-api list-countries`, render a
  numbered code/name/count menu, normalize one-or-many selections without duplicates, and
  display that order is a soft preference inside a hard allowlist.
- [ ] **Verify GREEN.** Run focused/full setup tests and `python3 -m py_compile
  bin/wg-healthcheck-setup`.
- [ ] **Commit.** `git commit -m "Add guided dual-mode setup"`.

## Task 10: Setup application and credential lifecycle

**Files:** modify `bin/wg-healthcheck-setup`, `tests/test_setup.py`.

**Why:** setup must validate before persistence and recover atomically from key/config/
timer failures.

**Impact/compatibility:** static mode never opens a stored key; key presence never enables
API behavior.

**Verification:** `python3 -m unittest tests.test_setup.SetupApplyTests -v`.

- [ ] **Write RED tests.** Cover identity mismatch preserving static state, key persisted
  only after authenticated validation, failed adoption restoring the previous key,
  replacement revalidation/rollback, explicit unlink+directory sync removal, preservation
  of unrelated valid health keys, pre-managed static restoration, and timer enable only
  after `healthy|recovered` status. Add `--reset-api-state` dry-run/apply orchestration,
  refusal while timer/worker/locks/pending are active, and explicit combined credential/
  state purge without touching the pre-managed recovery snapshot.
- [ ] **Verify RED.** Require state snapshots to show no mutation on each failed path.
- [ ] **Implement minimal application flow.** Pipe the proposed secret to runtime dry run,
  stage/sync/rename the credential with one bounded previous copy, call runtime apply,
  restore on failure, atomically update only source/device/countries, and invoke systemd
  enable only after reading a fresh successful private status file. Route state reset to
  the runtime owner; setup first quiesces and proves the required inactive boundary.
- [ ] **Verify GREEN.** Run focused/full setup tests and a staged temporary-directory
  integration with fixed command doubles.
- [ ] **Commit.** `git commit -m "Make setup changes transactional"`.

## Task 11: Installer and systemd upgrade safety

**Files:** modify `install.sh`, `systemd/wg-healthcheck@.service`,
`tests/test_install.sh`.

**Why:** upgrades must not race an active worker, and new secret/state owners need correct
filesystem and core-dump boundaries.

**Impact/compatibility:** ordinary fresh install syntax remains; `--quiesce` is explicit and
incompatible with `--enable`/`DESTDIR`.

**Verification:** `bash tests/test_install.sh`.

- [ ] **Write RED tests.** Cover staged managed module/setup/state directory; artifact
  order; preservation of key/pre-managed/state; refusal of active worker, held lock, or
  pending journal; `--quiesce` stop/wait/leave-disabled behavior; invalid flag combinations;
  root/modes; and `LimitCORE=0`.
- [ ] **Verify RED.** Require new install contracts to fail while every current preservation
  and atomic-install test stays green.
- [ ] **Implement minimal installer changes.** Validate/install provider helper, managed
  module 0644, main/setup 0755, units/template; create live/staged persistent directory
  0700; implement checked quiesce; preserve operator files; add core limit to systemd.
- [ ] **Verify GREEN.** Run installer tests, Bash syntax, ShellCheck, and
  `systemd-analyze verify` against staged installed executables.
- [ ] **Commit.** `git commit -m "Harden managed-profile installation"`.

## Task 12: Public documentation, MIT license, and operator guide

**Files:** create `LICENSE`, `docs/operations.md`, `tests/test_public_docs.py`;
modify `README.md`, `SECURITY.md`, `CONTRIBUTING.md`, `config/wg0.conf.example`.

**Why:** users must understand the two choices and the expanded account/root trust boundary
before enabling automation.

**Impact/compatibility:** detailed procedures move out of the README, but existing anchors
receive direct replacements or redirects where practical.

**Verification:** `python3 -m unittest tests.test_public_docs -v` plus repository tests.

- [ ] **Write RED tests.** Require a first-100-line mode table; both exact two-command
  paths; status/manual-run/timer decisions; operations links; credential location/
  replacement/removal; kill-switch and fixed-device limits; MIT text/README declaration;
  no private addresses/home paths/key-like values; static/API config examples; and clear
  single-country, multi-country allowlist, soft-order preference, and explicit `ALL`
  instructions.
- [ ] **Verify RED.** Require failures for absent license/operations/two-mode copy.
- [ ] **Implement documentation.** Add standard MIT text with
  `Copyright (c) 2026 Herbertmt978`; rewrite README opening/quick starts; move long upgrade,
  rollback, uninstall, state repair, and key replacement into `docs/operations.md`; update
  security reporting and contribution secret rules; document exact config grammar.
- [ ] **Verify GREEN.** Run doc tests, installer repository-contract tests, link checks,
  and `git diff --check`.
- [ ] **Commit.** `git commit -m "Document dual-mode installation"`.

## Task 13: Version, changelog, release notes, packaging, and CI

**Files:** create `docs/releases/v1.1.0.md`; modify `VERSION`, `bin/wg-healthcheck`,
`CHANGELOG.md`, `scripts/package-release.sh`, `tests/test_release.sh`,
`.github/workflows/ci.yml`, `.github/workflows/release.yml`.

**Why:** the exact public artifact must contain all runtime owners and no secret/runtime
material.

**Impact/compatibility:** `v1.0.0` remains immutable; only `main` and the new annotated tag
are pushed.

**Verification:** release tests, reproducible double build, workflow lint, and secret scans.

- [ ] **Write RED tests.** Require synchronized `1.1.0`; release notes; MIT/setup/managed
  module/operations in exact tar+ZIP contents and modes; absence of keys/profiles/candidates/
  markers/state/host IDs; Ubuntu 22.04+24.04 deterministic CI matrix; branch concurrency;
  credential-free smoke; and non-cancelling release concurrency.
- [ ] **Verify RED.** Run `bash tests/test_release.sh --ref HEAD` and public doc tests; require
  precise failures for old version/missing artifacts.
- [ ] **Implement release surface.** Update version owners, changelog Added/Changed/Security
  sections and non-ancestry v1.1 link, curated notes, archive allowlists, installer-from-
  archive assertions, CI matrix/concurrency, syntax/ShellCheck lists, and setup/provider
  installation in systemd verification.
- [ ] **Verify GREEN.** Run release tests twice into separate dirs and compare all three
  assets, actionlint, full deterministic checks, and pinned redacted Gitleaks on history
  plus extracted archives.
- [ ] **Commit.** `git commit -m "Prepare the 1.1.0 release"`.

## Task 14: Full review, ADR, and release-candidate evidence

**Files:** create `docs/aegis/adr/0001-dual-mode-profile-management.md`; update
`docs/aegis/INDEX.md`; modify any files required by verified review findings.

**Why:** durable ownership and actual verification must be recorded before a root/network
release leaves the branch.

**Impact/compatibility:** the ADR records proved architecture; it does not authorize new
device lifecycle scope.

**Verification:** complete command bundle and clean diff/status.

- [ ] **Write review assertions.** Check every approved spec heading against a task/commit;
  scan for placeholders, stale no-credential/no-license claims, duplicate owners, files over
  800 lines, blocks over roughly 80 lines, and unretired fallbacks. Record actionable gaps.
- [ ] **Verify the assertions fail or pass honestly.** Run the complete verification bundle;
  any failure becomes a focused RED regression before correction.
- [ ] **Implement only verified corrections and ADR.** Record canonical provider/runtime/
  setup owners, alternatives rejected, static compatibility, device-lifecycle exclusion,
  and retirement trigger. Split code owners if complexity gates are crossed rather than
  accepting an unjustified monolith.
- [ ] **Verify GREEN.** Rerun the full bundle, secret scans, archive extraction scans,
  workspace/index checks, staged install, and independent code/security reviews.
- [ ] **Commit.** `git commit -m "Record managed-profile architecture"`.

## Task 15: Download VM authenticated acceptance and rollback drill

**Files:** no repository secret files; remote root-only runtime/config/state paths only.

**Why:** deterministic tests cannot prove the live AirVPN generator, tunnel, Docker, and
policy-routing integration.

**Impact/compatibility:** timer stays disabled throughout; verified v1.0/static rollback
remains available.

**Verification:** redacted evidence from systemd, profile hashes/modes, AirVPN egress,
qBittorrent ownership, and route probes.

- [ ] **Create the preflight evidence bundle.** Record version, enabled/running state,
  owner/modes and SHA-256 hashes without contents, qB state, last status, and absence of a
  pending marker. Preserve a root-only rollback bundle and verified v1.0 package. Stop and
  mask timer, stop worker, wait inactive, and acquire/check the interface lock.
- [ ] **Run authenticated RED-safe dry run.** Transfer the supplied test key through a
  non-echoing protected channel to a temporary root-only descriptor/file, run adoption dry
  run, retain only redacted response shape, prove active profile/tunnel hashes unchanged,
  and stop if identity or managed allowlist does not match.
- [ ] **Install/apply and drill rollback.** Install the branch with `--quiesce`; adopt with
  timer disabled; force post-candidate speed verification to fail with a temporary
  impossible threshold so the old profile is restored without making rollback speed a
  postcondition. Verify exact old hash/mode, cleared or reconciled journal, healthy tunnel,
  and restored qB binding.
- [ ] **Verify successful API operation.** Restore the health config exactly, run one
  controlled managed rotation, verify interface identity, handshake, route/rule, AirVPN
  egress, qB TCP/UDP ownership, and public-peer source routing or the documented substitute;
  then observe five successful timer cycles.
- [ ] **Remove the test key and establish final mode.** Unlink/sync the supplied test key.
  Install and validate a fresh owner-provided production key, or restore verified static
  mode and report the API migration as still open. Commit no remote runtime material.

## Task 16: Merge, publish, and verify `v1.1.0`

**Files:** Git refs and GitHub release state; no new source behavior.

**Why:** publication must use the exact reviewed tree and verified assets.

**Impact/compatibility:** never rewrite `v1.0.0`, force-push, or push private branches.

**Verification:** exact commit IDs across local main, origin/main, tag, CI, release, and
downloaded assets.

- [ ] **Pre-merge gate.** Require clean branch, reviewed staged/commit history, complete
  local/package/secret/VM evidence, and no open GitHub secret-scanning alerts.
- [ ] **Merge and verify main.** Merge `Herb/airvpn-api-profiles` locally into `main`, rerun
  the release bundle on the merge commit, push only `main`, and require green CI on that
  exact SHA.
- [ ] **Tag and publish.** Create annotated `v1.1.0` on the green main SHA, push only that
  tag, and let release CI build, verify, draft, and publish the release.
- [ ] **Verify publication.** Require successful tag/release workflows, non-draft latest
  release, exact three assets, matching notes, fresh-download checksum verification,
  reproducible comparison, extracted secret scan, and staged install from the published
  tar and ZIP.
- [ ] **Final handoff.** Report outcome, evidence, production-key status, residual risk,
  complexity delta, architecture alignment, ADR result, and the 24-hour redacted VM
  follow-up boundary. Use `v1.1.1` for any post-publication correction; never move the tag.

## Risks and rollback

- A generator contract mismatch blocks API mode before mutation; static mode remains usable.
- Unsupported hooks or changed identity block adoption and preserve the current profile.
- Digest/journal mismatch leaves qBittorrent stopped and state intact for operator repair.
- Authentication/device failures back off persistently; they do not affect static health.
- The release can publish without leaving the VM in API mode, but the user's VM-migration
  goal is not complete until a fresh production key is installed.
- Rollback ladder: restore the exact pre-managed/static profile first; reinstall verified
  `v1.0.0` only when code rollback is required and no v2 marker remains.

## Retirement

- No public static behavior retires in `v1.1.0`.
- The old “authenticated telemetry is fully retired” test wording retires and is replaced
  by tests proving static credential isolation plus managed credential safety.
- `rotate_airvpn` becomes a mode dispatcher; its current body remains the canonical static
  endpoint path under `rotate_static_endpoint`.
- The managed module is not a fallback. It is loaded only by explicit API mode/commands.
- Automatic device/key/port lifecycle remains deferred; its trigger is a separately
  approved blue/green design covering address and forwarding consumers.
