# Todo Checkpoint: AirVPN API-Managed WireGuard Profiles

Updated: 2026-07-12

## TodoCheckpointDraft

- **Current todo:** implement Task 8's explicit provision, adopt, rotate, restore, status,
  and reset administration while preserving the accepted crash-safe Task 7 owner model.
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
  recovery, and durable safety-record rollback/finalization.
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
  every reproduced fail-closed gap was repaired.
- **Active slice:** Task 8 command ownership and unattended API-mode dispatch.
- **Pending:** implementation Tasks 8-16 from the approved plan.
- **Evidence refs:** accepted Task 7 commits `89bb3cf`, `80356d8`, and `d5b435b` follow the
  provisional `f9231ef` and approved design amendment `0f6c3ea`. Exact final-tree evidence:
  managed Linux 81/81 as root and 77/77 with four intentional root-only skips as a normal
  user; static/runtime 69/69; focused independent recovery gates 9/9 and 7/7; Bash syntax,
  ShellCheck 0.11, diff integrity, and Gitleaks over the tree and 42-commit history are
  green. The reviewers proved identity checks precede effects, Docker name/immutable-ID
  paths cannot collide, pending safety is re-barriered only after qB containment, drift
  restores the old verified tunnel while retaining containment and recovery ownership,
  and no rollback path leaves a candidate success stamp.
- **Blocked on:** nothing at this checkpoint.
- **Next step:** execute Task 8 RED-to-GREEN, then require independent command-contract and
  security review before accepting its checkpoint.

## ResumeStateHint

- Primary checkout: repository `main` at the public baseline.
- Implementation worktree:
  `C:/Users/Ashby/.config/aegis/worktrees/airvpn-wg-healthcheck/airvpn-api-profiles`
- Branch: `Herb/airvpn-api-profiles`
- Last accepted implementation commit: `d5b435b`; the Task 7 checkpoint documentation is
  the next commit before Task 8 begins.
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
  2,263 lines, `bin/wg-healthcheck` is 1,506 lines, `libexec/wg-healthcheck-managed` is
  2,916 lines, and `tests/test_wg_managed_profiles.sh` is 4,588 lines. These exceed the
  plan's review threshold. Task 14's split/ownership decision remains mandatory and cannot
  be waived before release.
- **Evidence decision:** `continue` to Task 8; Tasks 1-7 are accepted, while release and
  live VM completion remain unclaimed.
