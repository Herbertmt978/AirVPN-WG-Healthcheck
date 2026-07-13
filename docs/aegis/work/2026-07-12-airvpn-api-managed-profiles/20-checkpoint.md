# Todo Checkpoint: AirVPN API-Managed WireGuard Profiles

Updated: 2026-07-13

## TodoCheckpointDraft

- **Current todo:** implement Task 13 versioning, release notes, exact archive contents,
  Ubuntu 22.04/24.04 CI, and release artifact/history secret scans.
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
  documentation, MIT licensing, exact country/setup guidance, and safe operator lifecycle.
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
  reproduced and corrected.
- **Active slice:** Task 13 version, changelog, release notes, packaging, and CI.
- **Pending:** implementation Tasks 13-16 from the approved plan.
- **Evidence refs:** Task 12 commit `0e3f74a`. Public documentation: 12/12 passed; native
  Linux installer contracts: root 57 passed with one intentional non-root skip and non-root
  58/58; Bash syntax, ShellCheck 0.11.0, local-link checks, diff integrity, and pinned
  Gitleaks over the 2.38 MB current tree passed. Independent Terra and Luna reviews returned
  READY for Task 12. They explicitly retain Task 13 blockers for version synchronization,
  v1.1 notes, complete installable archives, dual-version CI, and artifact scans before any
  tag or publication.
- **Blocked on:** nothing at this checkpoint.
- **Next step:** write and verify Task 13 RED release contracts, then make the v1.1 archives
  complete, deterministic, installable, and secret-scanned on both supported Ubuntu lines.

## ResumeStateHint

- Primary checkout: repository `main` at the public baseline.
- Implementation worktree:
  `C:/Users/Ashby/.config/aegis/worktrees/airvpn-wg-healthcheck/airvpn-api-profiles`
- Branch: `Herb/airvpn-api-profiles`
- Last accepted implementation commit: `0e3f74a`; Task 12 is committed and the worktree is
  clean before Task 13 evidence-record updates.
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
- **Complexity:** `libexec/airvpn-api` is 1,563 lines, `tests/test_airvpn_api.py` is
  2,241 lines, `bin/wg-healthcheck` is 2,218 lines,
  `libexec/wg-healthcheck-managed` is 3,792 lines, `tests/test_wg_healthcheck.sh` is 3,206
  lines, `tests/test_wg_managed_profiles.sh` is 6,404 lines, `install.sh` is 1,111 lines,
  and `tests/test_install.sh` is 2,238 lines. The setup owner is a 62-line launcher plus
  focused Python modules, each at or below 723 lines. The remaining Bash/provider/installer
  owners exceed the review threshold; Task 14's split/ownership decision remains mandatory
  and cannot be waived before release.
- **Evidence decision:** `continue` to Task 13; Tasks 1-12 are accepted, while release and
  live VM completion remain unclaimed.
