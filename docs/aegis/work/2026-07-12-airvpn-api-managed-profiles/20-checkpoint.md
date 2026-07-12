# Todo Checkpoint: AirVPN API-Managed WireGuard Profiles

Updated: 2026-07-12

## TodoCheckpointDraft

- **Current todo:** execute Task 3 fixed-origin authenticated generation with
  RED first.
- **Completed:** repository/API reconnaissance; approved design and MIT choice; reviewed
  16-task implementation plan; country-selection and recovery amendments; isolated
  worktree; Task 1 strict profile parsing and credential-free country discovery; Task 2
  canonical rendering, identity pinning, and forged-object redaction.
- **Completed evidence slice:** green Windows-compatible checks plus a complete Ubuntu
  24.04 container baseline, including POSIX modes and ShellCheck. Task 1 independently
  cleared specification and code-quality/security review. Task 2 cleared both reviews
  after two review-found boundary fixes.
- **Active slice:** Task 3 fixed-origin generation and descriptor-only transport.
- **Pending:** implementation Tasks 3-16 from the approved plan.
- **Evidence refs:** Task 1 commit `43f04f9`; Task 2 commits `9abc776`, `422a2a1`, and
  `8073a50`; focused rendering 5/5 and complete helper suite 45/45 passed, with compile,
  Python 3.10 grammar, forged-object, surrogate-context, and comparator-leak probes green.
  Baseline release/package, Bash syntax, ShellCheck, systemd verification, and actionlint
  evidence remains green.
- **Blocked on:** nothing at this checkpoint.
- **Next step:** dispatch a fresh Task 3 implementer with the exact plan slice and require
  observed RED before authenticated request or descriptor code.

## ResumeStateHint

- Primary checkout: repository `main` at the public baseline.
- Implementation worktree:
  `C:/Users/Ashby/.config/aegis/worktrees/airvpn-wg-healthcheck/airvpn-api-profiles`
- Branch: `Herb/airvpn-api-profiles`
- Last accepted implementation commit: `8073a50648318e69063ef97cfec9f1d0098861e3`.
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
- **Complexity:** `libexec/airvpn-api` is 1,013 lines and `tests/test_airvpn_api.py` is
  1,248 lines, above the plan's 800-line review threshold. This did not block cohesive
  Task 2 acceptance, but the Task 14 split decision remains mandatory and cannot be waived
  before release.
- **Evidence decision:** `continue` to Task 3; Tasks 1-2 are accepted and no release or live
  completion claim exists.
