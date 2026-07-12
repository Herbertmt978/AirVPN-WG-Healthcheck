# Todo Checkpoint: AirVPN API-Managed WireGuard Profiles

Updated: 2026-07-12

## TodoCheckpointDraft

- **Current todo:** execute Task 5 persistent API state and lock discipline with
  RED first.
- **Completed:** repository/API reconnaissance; approved design and MIT choice; reviewed
  16-task implementation plan; country-selection and recovery amendments; isolated
  worktree; Task 1 strict profile parsing and credential-free country discovery; Task 2
  canonical rendering, identity pinning, and forged-object redaction; Task 3 fixed-origin
  authenticated generation with descriptor-only secret/profile transport; Task 4 dual-mode
  CLI/config dispatch, trusted managed-module loading, and installed-key/FD isolation.
- **Completed evidence slice:** green Windows-compatible checks plus a complete Ubuntu
  24.04 container baseline, including POSIX modes and ShellCheck. Task 1 independently
  cleared specification and code-quality/security review. Task 2 cleared both reviews
  after two review-found boundary fixes. Task 3 cleared both reviews after four
  review-found generator boundary fixes. Task 4 cleared both reviews after descriptor and
  lock-contention corrections.
- **Active slice:** Task 5 persistent API backoff/exclusion state and lock discipline.
- **Pending:** implementation Tasks 5-16 from the approved plan.
- **Evidence refs:** Task 4 commits `27ea770` and `5a6cee1`; runtime 67/67 and Linux managed
  8/8 passed, including root owner/mode and `/proc` credential-FD isolation. Bash syntax,
  ShellCheck, static compatibility, marker ordering, explicit rc75 contention, and exact
  managed-owner delivery/closure are green. Earlier baseline evidence remains green.
- **Blocked on:** nothing at this checkpoint.
- **Next step:** dispatch a fresh Task 5 implementer with the exact plan slice and require
  observed RED before persistent state, exclusions, or global API locking.

## ResumeStateHint

- Primary checkout: repository `main` at the public baseline.
- Implementation worktree:
  `C:/Users/Ashby/.config/aegis/worktrees/airvpn-wg-healthcheck/airvpn-api-profiles`
- Branch: `Herb/airvpn-api-profiles`
- Last accepted implementation commit: `5a6cee1721ff7731ec74491cd873bcadb0f41d79`.
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
- **Complexity:** `libexec/airvpn-api` is 1,549 lines and `tests/test_airvpn_api.py` is
  2,118 lines; `bin/wg-healthcheck` is 1,481 lines. These exceed the plan's review
  threshold, while managed logic remains isolated in a 70-line module. Task 14's split
  decision remains mandatory and cannot be waived before release.
- **Evidence decision:** `continue` to Task 5; Tasks 1-4 are accepted and no release or live
  completion claim exists.
