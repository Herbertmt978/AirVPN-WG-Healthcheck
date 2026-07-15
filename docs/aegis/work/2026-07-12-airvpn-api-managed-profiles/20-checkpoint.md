# Todo Checkpoint: AirVPN API-Managed WireGuard Profiles

Updated: 2026-07-14

## TodoCheckpointDraft

- **Current todo:** finish the bounded WireGuard-profile media negotiation candidate,
  verify and install its exact package without changing the download VM's static profile,
  then use one naturally permitted authenticated dry run. Apply API mode only after that
  dry run generates and validates an identity-pinned profile.
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
- **Active slice:** exact candidate `eadae01` is installed and verified on the download VM
  in static mode with the timer runtime-masked and inactive. The active profile and health
  configuration retain their preflight digests, `wg0` remains active, and no API credential
  is installed. The root-only source credential remains outside the package and repository.
  Four backoff-compliant authenticated attempts reached HTTP success and failed closed at
  the response media boundary without mutation. France has been removed from the default
  policy; the intended allowlist is now `GB NL BE DE IE`. The current test-first slice
  replaces the unsuccessful HTML policy exception with exact, parameterless
  `application/x-wireguard-profile` response acceptance and explicit identity negotiation.
- **Pending:** implementation Tasks 15-16 from the approved plan.
- **Evidence refs:** France removal commit `a11dd5d`; exact installed candidate `eadae01`;
  exact package hashes `325b6b59bd95bb2223ebf3d9e3971cf73b02f3209622e8b4320aba32312628dc`
  for tar and `cc4e89dc88e2c0d19d295dda55aa90652aa7cccdb6c03eb2a7345712b49a2d45`
  for ZIP. Its native-Linux gate passed Python 206/206, all root/non-root health,
  managed, and installer suites with only intentional privilege skips, reproducible release,
  Bash syntax, both ShellCheck versions, systemd verification, and pinned Gitleaks across
  full history and both archives. The current media-contract RED run failed only for the
  missing headers/new type/retained HTML path; the matching GREEN run passed all four
  focused tests, then all 88 provider and 17 public-documentation tests passed. Independent
  Terra/Luna reviews found no secret, parser wildcard, content-encoding, or documentation
  drift; their one 406-classification coverage request is now included.
- **Blocked on:** the next exact candidate still needs its native-Linux gate and quiesced
  installation. The persistent provider ledger recorded four of six rolling-window attempts
  and two available slots after the fourth failure; the recorded backoff must reach zero
  naturally before another authenticated request. The ledger will not be reset or bypassed.
- **Next step:** finish local review, commit and run the exact Linux/package/secret gate,
  install that exact package with the timer still masked, recheck the five-country public
  inventory and provider backoff, then run one authenticated dry run. On success, use the
  remaining naturally permitted call for identity-pinned API adoption before the later
  rotation/rollback/five-cycle drill.

## ResumeStateHint

- Primary checkout: repository `main` at the public baseline.
- Implementation worktree: isolated feature worktree outside the public checkout.
- Branch: `Herb/airvpn-api-profiles`
- Last installed implementation commit: `eadae01`; its exact root/non-root Linux, release,
  reproducibility, workflow, and secret gates passed. The VM runs that byte-identical
  candidate in verified static mode with the timer runtime-masked and inactive.
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
  2,214 lines, `libexec/airvpn-api` at 1,717 lines in the current slice, and `install.sh` at
  1,154 lines. The
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
- **Accepted diagnostic candidate:** exact installed commit `eadae01`; `phase=response`
  admits only the eleven fixed reason values recorded in the design. The next candidate
  changes only HTTP negotiation and the exact response-media allowlist; it removes the
  unsuccessful HTML branch, adds no persistent state or fallback, and remains below the
  provider ceiling. Current focused/provider/docs evidence is green; exact Linux,
  package, secret, and VM evidence remains the next gate.
