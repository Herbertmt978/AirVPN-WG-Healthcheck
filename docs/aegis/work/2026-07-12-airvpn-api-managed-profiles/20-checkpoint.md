# Todo Checkpoint: AirVPN API-Managed WireGuard Profiles

Updated: 2026-07-12

## TodoCheckpointDraft

- **Current todo:** execute Task 6 versioned managed journal and v1 compatibility with
  RED first.
- **Completed:** repository/API reconnaissance; approved design and MIT choice; reviewed
  16-task implementation plan; country-selection and recovery amendments; isolated
  worktree; Task 1 strict profile parsing and credential-free country discovery; Task 2
  canonical rendering, identity pinning, and forged-object redaction; Task 3 fixed-origin
  authenticated generation with descriptor-only secret/profile transport; Task 4 dual-mode
  CLI/config dispatch, trusted managed-module loading, and installed-key/FD isolation;
  Task 5 strict persistent API state, exact rolling attempt history, failed-server
  exclusions, fresh phase clocks, and descriptor-safe global serialization.
- **Completed evidence slice:** green Windows-compatible checks plus a complete Ubuntu
  24.04 container baseline, including POSIX modes and ShellCheck. Task 1 independently
  cleared specification and code-quality/security review. Task 2 cleared both reviews
  after two review-found boundary fixes. Task 3 cleared both reviews after four
  review-found generator boundary fixes. Task 4 cleared both reviews after descriptor and
  lock-contention corrections. Task 5 cleared specification and final quality/security
  review after rolling-window, clock, selector, rollback, output-collision, FD-alias, and
  credential-identity defects were reproduced and repaired.
- **Active slice:** Task 6 strict v2 journal, digest classification, and v1 reconciliation.
- **Pending:** implementation Tasks 6-16 from the approved plan.
- **Evidence refs:** Task 5 commits `2afabad`, `6cd933b`, and `af6a6b3`; managed Linux
  35/35 as root and 32/32 with three intentional ownership skips as a normal user;
  provider 65/65; static/runtime 67/67. Bash syntax, ShellCheck, Python compile, diff,
  gitleaks, exact rolling/backoff timing, production exclusion selection, lock ordering,
  and credential-FD isolation are green. Earlier accepted evidence remains green.
- **Blocked on:** nothing at this checkpoint.
- **Next step:** dispatch a fresh Task 6 implementer with the exact plan slice and require
  observed RED before adding v2 journal parsing, writes, phases, or reconciliation.

## ResumeStateHint

- Primary checkout: repository `main` at the public baseline.
- Implementation worktree:
  `C:/Users/Ashby/.config/aegis/worktrees/airvpn-wg-healthcheck/airvpn-api-profiles`
- Branch: `Herb/airvpn-api-profiles`
- Last accepted implementation commit: `af6a6b3d8970fb86fd1adc3e04015c57a71b0d0f`.
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
- **Complexity:** `libexec/airvpn-api` is 1,549 lines, `tests/test_airvpn_api.py` is
  2,118 lines, `bin/wg-healthcheck` is 1,481 lines, `libexec/wg-healthcheck-managed` is
  885 lines, and `tests/test_wg_managed_profiles.sh` is 1,893 lines. These exceed the
  plan's review threshold. Task 14's split/ownership decision remains mandatory and cannot
  be waived before release.
- **Evidence decision:** `continue` to Task 6; Tasks 1-5 are accepted and no release or live
  completion claim exists.
