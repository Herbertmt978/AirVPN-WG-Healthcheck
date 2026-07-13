# Todo Checkpoint: AirVPN API-Managed WireGuard Profiles

Updated: 2026-07-13

## TodoCheckpointDraft

- **Current todo:** complete Task 15 download-VM authenticated acceptance, rollback drill,
  final credential removal, and static/API-mode handoff.
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
  generator request from OS-packaged output to the raw single-profile form.
- **Active slice:** Task 15 AirVPN generator response-contract diagnosis and download-VM
  authenticated acceptance.
- **Pending:** implementation Tasks 15-16 from the approved plan.
- **Evidence refs:** compatibility commit `05af6bb` and raw-profile correction commit
  `4acdf43`. Exact `4acdf43` native-Linux verification: Python root 201/201; static/runtime
  root and non-root 89/89 each; managed root 125/125 and non-root 120 passed with five
  intentional root-only skips; installer root 58 passed with one intentional skip and
  non-root 59/59; 27-file release checks; generated-runtime, Bash syntax, installed modes,
  systemd, actionlint, Python 3.10 provider 71/71, and ShellCheck 0.9/0.11 gates passed.
  Two release builds were byte-identical. Pinned Gitleaks found no leaks in the exact
  history, tree, or either extracted archive. Independent Terra/Luna reviews returned
  READY. The exact package was installed quiesced on the VM without changing the active
  profile or health configuration; the timer remained runtime-masked and the client/tunnel
  remained healthy.
- **Blocked on:** both authenticated generator dry runs failed closed at the same
  secret-free `phase=response` boundary. The six-attempt rolling cap is now full and will
  not reopen naturally until 2026-07-14 17:25:27 UTC.
- **Next step:** isolate the response-contract mismatch from public provider evidence and
  local enum-only diagnostics, then run the complete exact-commit Linux/release gate. Do
  not publish API success or retry before the natural window; preserve the verified static
  baseline and require a fresh private credential for any later production migration.

## ResumeStateHint

- Primary checkout: repository `main` at the public baseline.
- Implementation worktree:
  `C:/Users/Ashby/.config/aegis/worktrees/airvpn-wg-healthcheck/airvpn-api-profiles`
- Branch: `Herb/airvpn-api-profiles`
- Last accepted implementation commit: `85abcdd`; its exact root/non-root Linux and release
  gates passed. The VM still runs the byte-identical `4acdf43` runtime installed before the
  documentation-only checkpoint.
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
  generated managed runtime remains one 3,899-line installed owner, assembled from nine
  fixed development fragments no longer than 666 lines. Provider tests use a 48-line
  compatibility loader plus bounded support/groups; health, managed, and installer runners
  are 133, 185, and 102 lines, with every split owner at or below 797 lines. Architecture
  tests enforce the exact owner exceptions, 13 reviewed long blocks, registries, encodings,
  symlink boundaries, and generated-source manifest.
- **Evidence decision:** `continue` within Task 15; deterministic, quiesced-install, safe
  failure-containment, key-removal, and static-routing evidence is accepted, while
  authenticated raw-profile success, live rollback/rotation, release, and API-mode VM
  migration remain unclaimed.
- **Current diagnostic candidate:** `phase=response` may add only one local value from
  `status`, `encoding`, `media`, `read`, `size`, `json`, or `protocol`. Current-tree Linux
  verification passed Python 203/203, managed recovery 125/125, architecture 11/11,
  generated-source drift, Bash syntax, public-doc contracts, and a redacted Gitleaks tree
  scan. Two independent Terra reviews and one Luna documentation/API-scope review returned
  READY. Exact-commit root/non-root and release verification remains the next gate.
