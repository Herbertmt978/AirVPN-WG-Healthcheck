# Todo Checkpoint: AirVPN API-Managed WireGuard Profiles

Updated: 2026-07-12

## TodoCheckpointDraft

- **Current todo:** execute Task 2 canonical profile rendering and identity pinning with
  RED first.
- **Completed:** repository/API reconnaissance; approved design and MIT choice; reviewed
  16-task implementation plan; country-selection and recovery amendments; isolated
  worktree; Task 1 strict profile parsing and credential-free country discovery.
- **Completed evidence slice:** green Windows-compatible checks plus a complete Ubuntu
  24.04 container baseline, including POSIX modes and ShellCheck. Task 1 independently
  cleared specification and code-quality/security review.
- **Active slice:** Task 2 canonical rendering and identity pinning.
- **Pending:** implementation Tasks 2-16 from the approved plan.
- **Evidence refs:** implementation commit `43f04f9`; Python parser 8/8, country listing
  3/3, complete helper suite 40/40, Python compile, Python 3.10 grammar, and 3,810
  adversarial single-byte mutations all passed. Baseline release/package, Bash syntax,
  ShellCheck, systemd verification, and actionlint evidence remains green.
- **Blocked on:** nothing at this checkpoint.
- **Next step:** dispatch a fresh Task 2 implementer with the exact plan slice and require
  observed RED before renderer or identity code.

## ResumeStateHint

- Primary checkout: repository `main` at the public baseline.
- Implementation worktree:
  `C:/Users/Ashby/.config/aegis/worktrees/airvpn-wg-healthcheck/airvpn-api-profiles`
- Branch: `Herb/airvpn-api-profiles`
- Last accepted implementation commit: `43f04f9f43a3c3416b63d4b94bcf0f2dffff26f3`.
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
- **Complexity:** `libexec/airvpn-api` and `tests/test_airvpn_api.py` now exceed the
  plan's 800-line review threshold. This did not block cohesive Task 1 acceptance, but the
  Task 14 split decision remains mandatory and cannot be waived before release.
- **Evidence decision:** `continue` to Task 2; Task 1 is accepted and no release or live
  completion claim exists.
