# Todo Checkpoint: AirVPN API-Managed WireGuard Profiles

Updated: 2026-07-29

## TodoCheckpointDraft

- **Current todo:** complete Task 16 protected-main integration and publish `v1.1.0` from
  the exact reviewed tree. DownloadVM's persistent `wg-healthcheck@wg0.timer` remains
  enabled in API mode. A 2026-07-29 live check found a clean seven-day service history,
  current `healthy/all_checks_passed` status, a fresh tunnel handshake, proved qBittorrent
  binding, advanced provider state and an updated active profile consistent with managed
  rotation, and a successful credential-free AirVPN egress proof. Task 15 is complete.
  Never reset, rewrite, or bypass the provider ledger.
- **Completed:** repository/API reconnaissance; approved design and MIT choice; reviewed
  16-task implementation plan; country-selection and recovery amendments; isolated
  worktree; Task 1 strict profile parsing and credential-free country discovery; Task 2
  canonical rendering, identity pinning, and forged-object redaction; Task 3 fixed-origin
  authenticated generation with descriptor-only secret/profile transport; Task 4 dual-mode
  CLI/config dispatch, trusted managed-module loading, and installed-key/FD isolation;
  Task 5 strict persistent API state, exact rolling attempt history, failed-server
  exclusions, fresh phase clocks, and descriptor-safe global serialization; Task 6 strict
  digest-bound v2 journal durability, factual crash classification, and v1 compatibility;
  Task 7 qBittorrent containment, identity-pinned full-profile switching, immutable Docker
  recovery, and durable safety-record rollback/finalization; Task 8 explicit lifecycle
  commands, redacted status, quiesced state reset, and unattended API-mode dispatch;
  Task 9 guided dual-mode setup, credential-free country selection, private credential and
  settings descriptors, prospective configuration validation, and redacted dry runs;
  Task 10 exclusive setup leasing, transactional config/credential persistence, strict
  crash journals and fixed staging, deterministic recovery/rollback, fresh health proof,
  timer commit ordering, and setup-only candidate cleanup; Task 11 exact managed-artifact
  installation, fail-closed live/quiesced upgrades, dual inert entrypoint publication,
  retained cross-instance locks, and signal-safe cleanup; Task 12 dual-mode public
  documentation, MIT licensing, exact country/setup guidance, and safe operator lifecycle;
  Task 13 synchronized v1.1.0 release owners, exact deterministic tar/ZIP packaging,
  Ubuntu 22.04/24.04 CI, installed-layout verification, and release/history secret scans;
  Task 14 canonical generated-runtime ownership, bounded source/test splits, architecture
  assertions, full-ancestor root trust validation, ADR acceptance, and exact-commit release
  verification.
- **Completed evidence slice:** green Windows-compatible checks plus a complete Ubuntu
  24.04 container baseline, including POSIX modes and ShellCheck. Task 1 independently
  cleared specification and code-quality/security review. Task 2 cleared both reviews
  after two review-found boundary fixes. Task 3 cleared both reviews after four
  review-found generator boundary fixes. Task 4 cleared both reviews after descriptor and
  lock-contention corrections. Task 5 cleared specification and final quality/security
  review after rolling-window, clock, selector, rollback, output-collision, FD-alias, and
  credential-identity defects were reproduced and repaired. Task 6 cleared specification,
  adversarial durability, and quality/security review after artifact-fsync and classifier
  collision defects were reproduced and repaired. Task 7 cleared specification and
  adversarial security review after its provisional implementation was reopened twice and
  every reproduced fail-closed gap was repaired. Task 8 cleared specification,
  adversarial security, and code-quality review after six exact-SHA findings plus earlier
  live-review findings were reproduced and fixed without amending history. Task 9 cleared
  setup and runtime specification, security, and quality review after TTY fallback,
  descriptor inheritance, pre-sanitization metadata, signal-handler inheritance, and
  nested-redirection cleanup defects were reproduced and repaired. Task 10 cleared
  specification and adversarial reviews after abandoned credential staging and impossible
  journal semantics were reproduced and fixed. Task 11 cleared specification/quality and
  adversarial security re-reviews after systemd-query, cross-interface, TOCTOU, partial-
  package, reentrant-lock, runtime-parent, dual-entrypoint, and signal-cleanup defects were
  reproduced and fixed. Task 12 cleared specification/usability and adversarial security
  review after unsafe persistent-mask rollback, unchecked installer failure, incomplete
  uninstall, missing prerequisites, stale anchors, and ambiguous `ALL` serialization were
  reproduced and corrected. Task 14 cleared independent architecture/security review after
  extensionless-owner, symlink-root, registry-completeness, generated-order, Bash-dialect,
  ADR-status, and full-ancestor trust gaps were reproduced and corrected. Task 15 preparation
  then preserved trusted installed `PostUp`/`PostDown` routing hooks without admitting
  provider hooks, tightened managed-profile parent permissions, and corrected the AirVPN
  generator request from OS-packaged output to the raw single-profile form. Provider-contract
  diagnosis then confirmed AirVPN's documented exact `result: "ok"` success rule and its
  current top-level `error`-only authentication envelope without making an authenticated
  request. The helper now rejects duplicate JSON keys and every ambiguous or contradictory
  envelope as a redacted transient response-contract failure. Release packaging now pins one
  immutable commit and remains reproducible on Ubuntu 22.04's Git 2.34 without relying on
  the newer `git archive --mtime` option; behavioral tests cover annotated tags and archive
  timestamps.
- **Active slice:** exact runtime candidate `f0beafc` is installed on the download VM in API
  mode with fixed device `DownloadVM` and country policy `GB NL BE DE IE`. After the earlier
  deliberate rollback drill and resolver-failure rollback, a fresh complete preflight
  matched every reviewed installed byte, configuration/snapshot digest, root-only
  credential boundary, inactive runtime mask, free lock, recovery postcondition, live
  tunnel/qBittorrent proof, public country inventory, and strict provider-state rule. It
  exposed one natural rolling slot and zero backoff. Exactly one non-interactive controlled
  rotation then succeeded with no retry. The active profile changed while its private
  identity and local `Table` policy remained fixed and local `DNS` remained absent. The
  pre-managed rollback snapshot was unchanged and the transaction backup retained the old
  profile. A fresh handshake, single peer, tunnel-bound AirVPN egress, qBittorrent TCP/UDP
  ownership with the same immutable container, cleared recovery/staging artifacts, free
  locks, and fixed recovered status/rotation records all passed. The timer and worker remain
  inactive under the runtime mask. The strict ledger now records six active attempts, zero
  rolling slots, two active exclusions, no failure backoff, and state digest
  `66d1f14c2e288d5ba9475be9e8115c23e847574e9ed8d2085acffbbaed7e93bf`.
  The accepted active-profile digest is
  `f44c0bc6e5ed5d690b5b23d42fbdec0816f3dcc11c9e05c289d95cd1327f8499`;
  the health-configuration digest remains
  `768763e6a611952a857e103ffbc6338aa5644c2cdfc7bac6e7332befdf1faaad`.
- **Five-cycle observation:** a fresh read-only preflight found the reviewed branch clean,
  all installed/runtime/profile/configuration bytes exact, both credential files valid by
  metadata only, all recovery artifacts absent, all locks free, `wg0` active, qBittorrent
  proved, policy `GB NL BE DE IE`, all policy countries publicly eligible, zero backoff,
  and all six rolling slots naturally reopened. Because the installed configuration
  intentionally enables managed rotation, the observation made one temporary, atomic,
  root-only change to `AIRVPN_ROTATE_ENABLED=0`; an exact backup lived only in the private
  runtime directory. The standard timer was unmasked and started without persistent
  enablement. Five distinct one-minute records then passed exactly as
  `healthy/all_checks_passed`. Each accepted cycle retained the active-profile,
  pre-managed snapshot, transaction backup, provider-state, private-identity and no-DNS
  invariants; qBittorrent ownership remained proved; and no recovery artifact or held lock
  appeared. Cleanup stopped both units, restored the exact reviewed configuration,
  removed the temporary backup, and reinstated the runtime mask. No authenticated request
  or durable provider-state write occurred.
- **Production activation:** the user attested that the root-only source credential had
  been replaced with a new, never-shared production key. A metadata-only and silent byte
  comparison found the installed credential already identical to that source, so no
  replacement transaction or authenticated generator request was made. Exact hashes,
  key metadata, active tunnel, qBittorrent proof, free locks, and clear recovery artifacts
  passed immediately before activation. The runtime mask was removed and the standard
  timer was persistently enabled. Its immediate timer-owned check and a distinct normal
  one-minute recurrence both completed `healthy/all_checks_passed`; the active profile,
  configuration, snapshots, backup, and strict provider ledger remained byte-identical.
  Only the healthy control path ran, so no authenticated generation or rotation path was
  invoked. The worker returned inactive and observation artifacts were removed while the
  timer remained active.
- **Completed egress evidence:** on 2026-07-29, a fresh credential-free request bound to
  `wg0` passed the installed strict AirVPN egress parser. The response lived only in a
  root-owned mode-0600 runtime file and was removed in the guaranteed cleanup path. The
  request used no API key and made no authenticated provider call. No response, address,
  server, endpoint, profile material, credential, or attempt epoch was retained or
  disclosed.
- **Pending:** the protected-main, annotated-tag, and published-asset portions of Task 16.
- **Evidence refs:** France removal commit `a11dd5d`; exact installed corrected runtime
  candidate `f0beafc`; exact integrated repository candidate
  `0fd9848e96a47df4788288781e930c834fdcf8ea`; complete-history bundle digest
  `6d66d7f767cdc1ccb20585722b1c3a4bf0e7c71736ddd4b78cf51863f0039d1f`.
  Ubuntu 22.04 and 24.04 independently passed the complete root/non-root release matrix and
  emitted byte-identical assets. Exact candidate package hashes are
  `778dd612007e513a8a3e21ff5f34a97c48bf2dee847a7b914621e811a326ef7b`
  for tar, `f107909be5f45ed3eb613475b602a7199dae3302903eab742a40ef449c056d7b`
  for ZIP, and `da0494bc4f9e1f90caaeac439e4721df6af0f91d349c431de2d5c4f8e0ad3c31`
  for the authoritative `SHA256SUMS`. Pinned Gitleaks 8.30.1 passed complete reachable
  history and both extracted archives. The public repository has zero open secret-scanning
  alerts, protected `main` still requires the strict `deterministic-checks` context, and no
  `v1.1.0` tag exists.
- **Blocked on:** no local, package, secret, or live-acceptance blocker remains. Publication
  still requires protected-main CI, annotated-tag release CI, and fresh downloaded-asset
  verification.
- **Next step:** commit this evidence-only gate, push the feature branch, merge through the
  protected `main` check, create and push only annotated `v1.1.0`, then verify the published
  assets. Do not disable the VM timer during repository release administration.

## ResumeStateHint

- Primary checkout: repository `main` at the public baseline.
- Implementation worktree: isolated feature worktree outside the public checkout.
- Branch: `Herb/airvpn-api-profiles`
- Last installed runtime commit: `f0beafc`; its exact root/non-root Linux, release,
  reproducibility, workflow, and secret gates passed. The VM runs its byte-identical
  provider helper in verified API mode after one successful controlled rotation. The
  pre-activation profile and state digests were respectively
  `f44c0bc6e5ed5d690b5b23d42fbdec0816f3dcc11c9e05c289d95cd1327f8499` and
  `66d1f14c2e288d5ba9475be9e8115c23e847574e9ed8d2085acffbbaed7e93bf`.
  The exact pre-managed rollback snapshot remains available; five supervised cycles and
  two later production-timer cycles passed without a provider-state write. The exact health
  configuration is active, the VM timer is persistently enabled and active, the worker is
  idle between checks, recovery artifacts are clear, and both credential paths remain
  root-only. The user attests that their matching content is a fresh production key. The
  2026-07-29 live status remained healthy with a clean seven-day service history; both the
  active profile and provider state had advanced from those baselines, consistent with
  managed rotation. A fresh credential-free AirVPN egress proof passed and its private
  response was removed. The Codex heartbeat remains deleted; do not confuse that deletion
  with the enabled VM timer.
- Re-read `10-intent.md`, the approved spec, the implementation plan, `git status`, and
  baseline test output before resuming.
- Never use any API key in source, fixtures, arguments, logs, or public CI.

## DriftCheckDraft

- **Intent:** aligned with dual-mode release and VM migration.
- **Compatibility:** static default, existing invocation, v1 marker, and no-account CI are
  preserved by the plan.
- **New owners:** managed Bash module and setup Python tool are explicit and bounded.
- **Fallbacks:** static mode is an explicit product choice, not a managed-error fallback.
- **Retirement:** only obsolete "no credentials anywhere" assertions retire in v1.1.
- **Complexity:** the three reviewed production exceptions are `bin/wg-healthcheck` at
  2,214 lines, `libexec/airvpn-api` at 1,718 lines in the current slice, and `install.sh` at
  1,154 lines. The
  generated managed runtime remains one 3,935-line installed owner, assembled from nine
  fixed development fragments no longer than 693 lines. Provider tests use a 50-line
  compatibility loader plus bounded support/groups; health, managed, and installer runners
  are 133, 185, and 102 lines, with every split owner at or below 800 lines. Architecture
  tests enforce the exact owner exceptions, 13 reviewed long blocks, registries, encodings,
  symlink boundaries, and generated-source manifest.
- **Evidence decision:** `continue` into Task 16; deterministic, quiesced-install,
  authenticated raw-profile dry-run, transactional API adoption, exact rollback snapshot,
  deliberate post-candidate failure rollback, corrected successful controlled rotation,
  AirVPN egress, qBittorrent routing/listener evidence, five consecutive supervised timer
  cycles, a fresh production credential, persistent VM-timer activation, and two healthy
  production-timer cycles, subsequent managed state/profile advancement, a clean seven-day
  timer history, and the fresh egress-only proof are accepted. Release and protected-main
  integration remain unclaimed.
- **Superseded compatibility baseline:** exact installed runtime commit `92e2890` omits the
  undocumented response-format query and makes a syntactically valid media label advisory
  only after explicit HTML, multipart, archive/compression, encoding, status, size, and JSON
  gates. It adds no persistent state or fallback and remains at the frozen provider ceiling;
  strict profile, expected-endpoint, and identity validation authorized the successful live
  dry run. Its identity-pinned composer incorrectly inherited provider `DNS`, so it is no
  longer an accepted rotation candidate. Existing Linux, package, secret, VM-install, and
  dry-run evidence remains factual.
- **Accepted corrected candidate:** exact installed runtime commit `f0beafc` changes only
  identity-pinned DNS ownership in the provider helper, adds regression/documentation
  coverage, and introduces no parser field, fallback, executable directive, provider
  authority, persistent state, or authenticated request. Exact dual-Ubuntu, package,
  history/archive secret and VM-install evidence passed. Its first corrected controlled
  rotation preserved the local no-DNS policy and private identity while adopting verified
  provider peer material; the live rotation result is accepted.
