# Todo Checkpoint: AirVPN API-Managed WireGuard Profiles

Updated: 2026-07-13

## TodoCheckpointDraft

- **Current todo:** implement Task 10's transactional setup application and credential
  lifecycle over the accepted guided two-mode planning boundary.
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
  settings descriptors, prospective configuration validation, and redacted dry runs.
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
  nested-redirection cleanup defects were reproduced and repaired.
- **Active slice:** Task 10 transactional setup application and credential lifecycle.
- **Pending:** implementation Tasks 10-16 from the approved plan.
- **Evidence refs:** Task 9 commit `f706c74`. Exact final-tree evidence: Python 92/92
  (including setup 27/27), runtime Linux 84/84, managed Linux 121/121, Bash syntax,
  ShellCheck, diff integrity, and Gitleaks over the 1.51 MB tree are green. Independent
  reviews approved the exact final runtime diff and the setup boundary. Tests prove core
  suppression before secret inspection, strict controlling-TTY behavior, root-0600 stable
  files, distinct descriptor number and inode, no pre-provider child inheritance,
  canonical bounded settings, country allowlist semantics, full prospective validation,
  early close on failure, and child-free interruption cleanup.
- **Blocked on:** nothing at this checkpoint.
- **Next step:** execute Task 10 RED-to-GREEN, including quiescence, credential/config
  rollback, first-provision inert-static recovery, and fresh-status timer enablement.

## ResumeStateHint

- Primary checkout: repository `main` at the public baseline.
- Implementation worktree:
  `C:/Users/Ashby/.config/aegis/worktrees/airvpn-wg-healthcheck/airvpn-api-profiles`
- Branch: `Herb/airvpn-api-profiles`
- Last accepted implementation commit: `f706c74`; the Task 9 checkpoint documentation is
  the next commit before Task 10 begins.
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
- **Complexity:** `libexec/airvpn-api` is 1,598 lines, `tests/test_airvpn_api.py` is
  2,263 lines, `bin/wg-healthcheck` is 1,896 lines, `bin/wg-healthcheck-setup` is 825 lines,
  `libexec/wg-healthcheck-managed` is 3,771 lines, `tests/test_wg_healthcheck.sh` is 2,865
  lines, and `tests/test_wg_managed_profiles.sh` is 6,312 lines. These exceed the plan's
  review threshold. Task 14's split/ownership decision remains mandatory and cannot be
  waived before release.
- **Evidence decision:** `continue` to Task 10; Tasks 1-9 are accepted, while release and
  live VM completion remain unclaimed.
