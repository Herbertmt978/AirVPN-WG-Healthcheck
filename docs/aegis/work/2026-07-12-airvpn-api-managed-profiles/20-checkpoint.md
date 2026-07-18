# Todo Checkpoint: AirVPN API-Managed WireGuard Profiles

Updated: 2026-07-18

## TodoCheckpointDraft

- **Current todo:** preserve the accepted `f0beafc` controlled rotation and the five
  supervised healthy cycles. DownloadVM now also has its own persistent
  `wg-healthcheck@wg0.timer` enabled in API mode with the exact reviewed configuration.
  Its activation cycle and a distinct one-minute recurrence both passed as
  `healthy/all_checks_passed` without changing the profile or provider ledger. The Codex
  continuation heartbeat remains deleted; it is unrelated to the VM timer. Task 15 still
  has one evidence-only gap because the fresh credential-free, tunnel-bound `whatismyip`
  result was inconclusive and was not retried. Never reset, rewrite, or bypass the provider
  ledger.
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
- **Incomplete egress evidence:** a fresh credential-free request was made before timer
  activation and its private response was deleted in the guaranteed cleanup path. The
  acceptance wrapper incorrectly required the provider helper's safe country display to
  be an ISO code, while the reviewed helper contract and regression test permit a country
  name. Because the discarded result cannot be reconstructed, this attempt is recorded as
  inconclusive rather than passed or failed, and it was not retried. The earlier accepted
  controlled-rotation egress proof still applies to the unchanged active profile, but the
  fresh evidence-only public egress gate remains unclaimed. No response, address, server,
  endpoint, profile material, credential, or attempt epoch was retained or disclosed.
- **Pending:** implementation Tasks 15-16 from the approved plan.
- **Evidence refs:** France removal commit `a11dd5d`; exact installed corrected runtime
  candidate `f0beafc`; complete-history bundle digest
  `7d0657a974e8443d23501a1b96af31287b8c3ebcafc0eff3939a9a671035ca5e`.
  Exact package hashes are
  `eba46513cd454cf829489c5607c453f165ac64e68f55da6574a19c7ac5765095`
  for tar, `2453a854c1478873723802279aedefb0453e6f6cbc1a803d8fdf0017fa25e038`
  for ZIP, and `398b6f1423e6f238e13ebd8bc0791ea4f15903438fc02b5a98dbdf6239feb253`
  for the authoritative `SHA256SUMS`. Pinned Gitleaks 8.30.1 passed reachable history and
  both extracted archives.
- **Blocked on:** release evidence still needs one fresh credential-free, tunnel-bound
  AirVPN egress proof. The successful rotation, supervised cycles, production credential,
  and now-enabled VM timer are preserved and must not be repeated to work around this
  evidence gap. The Codex egress-proof automation is deleted; no continuation is armed.
- **Next step:** revalidate the enabled healthy runtime and perform one separately reviewed
  egress-only public proof through `wg0`, with no authenticated request and no timer or
  profile mutation. If it passes, continue protected-main integration and the `v1.1.0`
  release gates. Do not disable the VM timer merely because the Codex continuation was
  removed.

## ResumeStateHint

- Primary checkout: repository `main` at the public baseline.
- Implementation worktree: isolated feature worktree outside the public checkout.
- Branch: `Herb/airvpn-api-profiles`
- Last installed runtime commit: `f0beafc`; its exact root/non-root Linux, release,
  reproducibility, workflow, and secret gates passed. The VM runs its byte-identical
  provider helper in verified API mode after one successful controlled rotation. The
  accepted active profile and state digests are respectively
  `f44c0bc6e5ed5d690b5b23d42fbdec0816f3dcc11c9e05c289d95cd1327f8499` and
  `66d1f14c2e288d5ba9475be9e8115c23e847574e9ed8d2085acffbbaed7e93bf`.
  The exact pre-managed rollback snapshot remains available; five supervised cycles and
  two later production-timer cycles passed without a provider-state write. The exact health
  configuration is active, the VM timer is persistently enabled and active, the worker is
  idle between checks, recovery artifacts are clear, and both credential paths remain
  root-only. The user attests that their matching content is a fresh production key. The
  post-cycle public egress proof remains unresolved and must be retried only as a separate
  credential-free continuation. Its Codex heartbeat was deleted at the user's request;
  do not confuse that deletion with the enabled VM timer.
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
- **Evidence decision:** `continue` within Task 15; deterministic, quiesced-install,
  authenticated raw-profile dry-run, transactional API adoption, exact rollback snapshot,
  deliberate post-candidate failure rollback, corrected successful controlled rotation,
  AirVPN egress, qBittorrent routing/listener evidence, five consecutive supervised timer
  cycles, a fresh production credential, persistent VM-timer activation, and two healthy
  production-timer cycles are accepted. The fresh egress-only proof, release, and
  protected-main integration remain unclaimed.
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
