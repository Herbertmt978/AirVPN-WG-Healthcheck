# Todo Checkpoint: AirVPN API-Managed WireGuard Profiles

Updated: 2026-07-12

## TodoCheckpointDraft

- **Current todo:** execute Task 1 strict generated-profile parser with RED first.
- **Completed:** repository/API reconnaissance; approved design; approved MIT choice;
  reviewed 16-task implementation plan; country-selection amendment; recovery edge-case
  amendment; isolated worktree creation.
- **Completed evidence slice:** green Windows-compatible checks plus a complete Ubuntu
  24.04 container baseline, including POSIX modes and ShellCheck.
- **Active slice:** Task 1 generated-profile parser.
- **Pending:** implementation Tasks 1–16 from the approved plan.
- **Evidence refs:** commits `b5b79b0`, `884bbe3`, `7eb4357`, `316e427`, and `0dc73aa`;
  Python 29/29, healthcheck 59/59, Linux installer 30 passed/1 root-only skip, release
  package checks, Bash syntax, ShellCheck, systemd verification, and actionlint all passed.
- **Blocked on:** nothing at this checkpoint.
- **Next step:** dispatch the fresh Task 1 implementer with the exact plan slice and require
  observed RED before production code.

## ResumeStateHint

- Primary checkout: repository `main` at the public baseline.
- Implementation worktree:
  `C:/Users/Ashby/.config/aegis/worktrees/airvpn-wg-healthcheck/airvpn-api-profiles`
- Branch: `Herb/airvpn-api-profiles`
- Checkpoint commit before work records: `316e42766459cb95f46144e854062e585d7507b4`.
- Re-read `10-intent.md`, the approved spec, the implementation plan, `git status`, and
  baseline test output before resuming.
- Never use the supplied API key in source, fixtures, arguments, logs, or public CI.

## DriftCheckDraft

- **Intent:** aligned with dual-mode release and VM migration.
- **Compatibility:** static default, existing invocation, v1 marker, and no-account CI are
  preserved by the plan.
- **New owners:** managed Bash module and setup Python tool are explicit and bounded.
- **Fallbacks:** static mode is an explicit product choice, not a managed-error fallback.
- **Retirement:** only obsolete “no credentials anywhere” assertions retire in v1.1.
- **Evidence decision:** `continue` to Task 1; baseline is sufficient and no completion
  claim exists.
