# Todo Checkpoint: AirVPN API-Managed WireGuard Profiles

Updated: 2026-07-14

## TodoCheckpointDraft

- **Current todo:** after enough provider-ledger slots reopen naturally, complete Task 15
  download-VM authenticated generator acceptance with the fresh private credential, then
  run the API adoption, rollback, rotation, final API-mode handoff, and five-cycle drill.
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
- **Active slice:** exact candidate `b44d320` is installed and verified on the download VM
  in static mode. A newly created credential supplied outside chat has passed metadata-only
  ownership, mode, size, and shape checks without its content being read or printed. The
  owner supplied the fixed device name and retained the existing six-country allowlist.
  Authenticated acceptance is waiting on the rolling provider window; the latest public
  inventory currently exposes eligible servers for five of those six countries.
- **Pending:** implementation Tasks 15-16 from the approved plan.
- **Evidence refs:** response-envelope commits `5e7b4f9` and `7f75fe8`, portable-release
  commit `0e19ba6`, documentation commits `2ead395` and `2121085`, and lint annotation
  commit `b44d320`. Exact `b44d320` native-Linux verification: Python root 206/206;
  static/runtime root and non-root 89/89 each; managed root 125/125 and non-root 120 passed
  with five intentional root-only skips; installer root 58 passed with one intentional skip
  and non-root 59/59; 27-file annotated-tag release checks; generated-runtime, Bash syntax,
  systemd, and ShellCheck 0.9/0.11 gates passed. Pinned Gitleaks found no leaks through the
  release candidate's history or either extracted archive. Independent Terra/Luna final
  reviews returned READY. The exact `b44d320` package is installed byte-for-byte on the VM
  without changing the active static profile, health configuration, or six-attempt provider
  ledger. Manual and timer-triggered static checks passed with WireGuard up, AirVPN egress
  verified, qBittorrent proved, no installed API key or recovery artifact, and the timer
  enabled and active. The repository remains public with only `v1.0.0` released; current
  `origin/main` CI is green and GitHub reports no open secret-scanning alerts. Branch
  `HEAD` differs from the installed candidate only in this checkpoint record.
- **Blocked on:** both authenticated generator dry runs failed closed at the same
  secret-free `phase=response` boundary. The six-attempt rolling cap is full; historical
  slots expire naturally between 2026-07-14 17:25:27 UTC and 21:37:36 UTC. One slot is
  sufficient for the dry run, but the two-call setup transactions must wait until two slots
  are simultaneously available. The complete six-call acceptance cannot finish before the
  final historical slot expires. The retained country policy must also be fully represented
  in the fresh public eligibility inventory before setup may read the credential.
- **Next step:** at the first natural slot, recheck the public country inventory and run
  one controlled generator dry run only if all six selected countries are eligible. On
  success, use later naturally reopened slots for identity-pinned API adoption, a real
  managed rotation, verified static rollback, final API adoption, qBittorrent containment,
  tunnel-bound egress, and five timer cycles. Do not reset the provider ledger or use the
  credential that was shared in chat.

## ResumeStateHint

- Primary checkout: repository `main` at the public baseline.
- Implementation worktree: isolated feature worktree outside the public checkout.
- Branch: `Herb/airvpn-api-profiles`
- Last accepted implementation commit: `b44d320`; its exact root/non-root Linux, release,
  reproducibility, workflow, and secret gates passed. The VM runs that byte-identical
  candidate in verified static mode with the timer enabled and active.
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
  2,214 lines, `libexec/airvpn-api` at 1,718 lines, and `install.sh` at 1,154 lines. The
  generated managed runtime remains one 3,935-line installed owner, assembled from nine
  fixed development fragments no longer than 693 lines. Provider tests use a 50-line
  compatibility loader plus bounded support/groups; health, managed, and installer runners
  are 133, 185, and 102 lines, with every split owner at or below 800 lines. Architecture
  tests enforce the exact owner exceptions, 13 reviewed long blocks, registries, encodings,
  symlink boundaries, and generated-source manifest.
- **Evidence decision:** `continue` within Task 15; deterministic, quiesced-install, safe
  failure-containment, key-removal, and static-routing evidence is accepted, while
  authenticated raw-profile success, live rollback/rotation, release, and API-mode VM
  migration remain unclaimed.
- **Accepted diagnostic candidate:** exact commit `b44d320`; `phase=response` may add only
  one local value from
  `status`, `encoding`, `media`, `read`, `size`, `json`, or `protocol`. Current-tree Linux
  and exact-commit verification passed Python 206/206, root/non-root health 89/89 each,
  managed root 125/125 and non-root 120 with five intentional skips, installer root 58 with
  one intentional skip and non-root 59/59, architecture 11/11, generated-source drift,
  Bash syntax, ShellCheck, systemd, workflow, 27-file reproducible release, and redacted
  Gitleaks history/tree/archive scans. Two independent Terra reviews and one Luna
  documentation/API-scope review returned READY.
