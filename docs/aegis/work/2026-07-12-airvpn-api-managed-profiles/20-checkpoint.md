# Todo Checkpoint: AirVPN API-Managed WireGuard Profiles

Updated: 2026-07-15

## TodoCheckpointDraft

- **Current todo:** wait for three rolling-window slots to be available naturally, then
  reverify the exact installed runtime candidate and use the validated setup path to adopt
  API mode on the download VM. Keep the timer runtime-masked through adoption and the
  complete live rollback, rotation, qBittorrent, routing, and repeated-cycle acceptance
  sequence; never reset or bypass the provider ledger.
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
- **Active slice:** exact runtime candidate `92e2890` is installed and verified on the
  download VM in static mode with the timer runtime-masked and inactive. The active profile
  and health configuration retain their preflight digests, `wg0` remains active,
  qBittorrent remains proved, and no API credential is installed. The root-only source
  credential remains outside the package and repository. After the recorded backoff reached
  zero, all five configured countries (`GB NL BE DE IE`) were publicly eligible and the
  sixth authenticated dry run succeeded: the returned profile cleared the bounded response,
  strict WireGuard, expected-endpoint, and fixed-device identity checks. The dry run changed
  no profile, configuration, timer, worker, interface, installed credential, candidate, or
  recovery artifact. Its required accounting record advanced the natural ledger to six of
  six active attempts with `failure_class=none` and no backoff. At the first scheduled
  adoption gate, one slot had reopened and every VM/provider invariant passed. A direct
  setup call-graph audit then proved that first-time static-to-API setup performs three
  separately accounted generator attempts: prospective validation, installed-credential
  revalidation, and activation. Starting with one slot would therefore consume capacity
  and force rollback before adoption. No authenticated request or VM mutation was made;
  adoption now waits for three natural slots.
- **Pending:** implementation Tasks 15-16 from the approved plan.
- **Evidence refs:** France removal commit `a11dd5d`; exact installed runtime candidate
  `92e2890`; complete-history bundle digest
  `8deb1ba300764f23e33ad5e624f8f1a5be3cfacfd9736ad777875a7d5bae512c`.
  Exact package hashes are
  `8624ebe9c659762ab0aa3addda8963d717452f8be441cec615ab20bba95b8668`
  for tar, `ded2ce3b788717b45f68d0e184acf732191662a6c8b008c075a09447e5165043`
  for ZIP, and `be2eb63519c6e8cbdca793b8af1f6e980a566d5c08315d7b624b6c98d3770f6c`
  for the authoritative `SHA256SUMS`. The detached Ubuntu 24.04 gate passed the complete
  Python, root/non-root health, managed, installer, release, Bash syntax, ShellCheck,
  systemd, and pinned-Gitleaks history/archive checks. The sixth dry run returned rc 0 and
  only the setup tool's fixed redacted success contract; all static-mode postconditions
  remained unchanged and its private temporary capture was removed.
- **Blocked on:** one of the three required rolling-window slots is currently available;
  two more attempts must expire naturally before the transactional apply can complete. The
  ledger has no failure backoff and will not be reset or bypassed.
- **Next step:** when three natural slots are available, reverify exact installed bytes,
  profile and configuration digests, source-credential metadata, timer/worker inactivity,
  `wg0`, qBittorrent, recovery artifacts, five-country public eligibility, and ledger
  capacity. Then perform one API-mode apply for fixed device `DownloadVM`, followed by the
  complete identity-pinned adoption, rollback, rotation, and repeated-cycle live acceptance
  sequence.

## ResumeStateHint

- Primary checkout: repository `main` at the public baseline.
- Implementation worktree: isolated feature worktree outside the public checkout.
- Branch: `Herb/airvpn-api-profiles`
- Last installed runtime commit: `92e2890`; its exact root/non-root Linux, release,
  reproducibility, workflow, and secret gates passed. The VM runs that byte-identical
  runtime in verified static mode with the timer runtime-masked and inactive.
- Re-read `10-intent.md`, the approved spec, the implementation plan, `git status`, and
  baseline test output before resuming.
- Never use the supplied API key in source, fixtures, arguments, logs, or public CI.

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
  authenticated raw-profile dry-run success, key-removal, and static-routing evidence is
  accepted, while API-mode adoption, live rollback/rotation, release, and API-mode VM
  migration remain unclaimed.
- **Accepted compatibility candidate:** exact installed runtime commit `92e2890` omits the
  undocumented response-format query and makes a syntactically valid media label advisory
  only after explicit HTML, multipart, archive/compression, encoding, status, size, and JSON
  gates. It adds no persistent state or fallback and remains at the frozen provider ceiling;
  strict profile, expected-endpoint, and identity validation authorized the successful live
  dry run. Exact Linux, package, secret, VM-install, and dry-run evidence is accepted.
