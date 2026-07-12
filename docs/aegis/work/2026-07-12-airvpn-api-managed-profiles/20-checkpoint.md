# Todo Checkpoint: AirVPN API-Managed WireGuard Profiles

Updated: 2026-07-12

## TodoCheckpointDraft

- **Current todo:** execute Task 4 runtime CLI, configuration, and secure module boundary with
  RED first.
- **Completed:** repository/API reconnaissance; approved design and MIT choice; reviewed
  16-task implementation plan; country-selection and recovery amendments; isolated
  worktree; Task 1 strict profile parsing and credential-free country discovery; Task 2
  canonical rendering, identity pinning, and forged-object redaction; Task 3 fixed-origin
  authenticated generation with descriptor-only secret/profile transport.
- **Completed evidence slice:** green Windows-compatible checks plus a complete Ubuntu
  24.04 container baseline, including POSIX modes and ShellCheck. Task 1 independently
  cleared specification and code-quality/security review. Task 2 cleared both reviews
  after two review-found boundary fixes. Task 3 cleared both reviews after four
  review-found generator boundary fixes.
- **Active slice:** Task 4 dual-mode Bash dispatch and secure managed-module/key boundary.
- **Pending:** implementation Tasks 4-16 from the approved plan.
- **Evidence refs:** Task 3 commits `7936bce` and `b2fc23f`; generator boundary 16/16 and
  complete helper suite 61/61 passed on Python 3.10/Linux, including the `/proc` sentinel
  proof. Python compile/grammar, healthcheck 59/59, installer regression, exact request,
  exception-graph redaction, and FD staging probes are green. Earlier baseline evidence
  remains green.
- **Blocked on:** nothing at this checkpoint.
- **Next step:** dispatch a fresh Task 4 implementer with the exact plan slice and require
  observed RED before runtime dispatch or managed-module/key code.

## ResumeStateHint

- Primary checkout: repository `main` at the public baseline.
- Implementation worktree:
  `C:/Users/Ashby/.config/aegis/worktrees/airvpn-wg-healthcheck/airvpn-api-profiles`
- Branch: `Herb/airvpn-api-profiles`
- Last accepted implementation commit: `b2fc23f85b1cd7f787e0856b6d0f62f396b8ff70`.
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
  2,118 lines, above the plan's 800-line review threshold. This did not block cohesive
  Task 3 acceptance, but the Task 14 split decision remains mandatory and cannot be waived
  before release.
- **Evidence decision:** `continue` to Task 4; Tasks 1-3 are accepted and no release or live
  completion claim exists.
