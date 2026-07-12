# Evidence Bundle Draft: AirVPN API-Managed WireGuard Profiles

## Design and planning evidence

- Approved design: `docs/aegis/specs/2026-07-12-airvpn-api-managed-profiles-design.md`
- Independently approved implementation plan:
  `docs/aegis/plans/2026-07-12-airvpn-api-managed-profiles.md`
- Isolated branch/worktree established before implementation.

## Implementation evidence

No production implementation has been accepted yet.

### Isolated baseline

- Windows Python: 29 tests passed.
- Git Bash healthcheck: 59 tests passed.
- Git Bash installer: 23 passed, 8 POSIX-mode checks skipped on the Windows filesystem.
- Ubuntu 24.04 container:
  - Python: 29 tests passed.
  - Healthcheck: 59 tests passed.
  - Installer: 30 passed, 1 non-root execution check skipped because the container user
    was root.
  - Release archives: 12 files verified and package checks passed.
  - Bash syntax, ShellCheck, and systemd unit verification passed.
- Native actionlint passed.

The first Git Bash release attempt failed only because Git Bash could not resolve the
Windows `python3` alias and its `/tmp` lacks POSIX mode fidelity. The Linux rerun covered
the actual release contract successfully.

## Release and live evidence

No release or VM acceptance claim exists yet. The supplied API key has not been committed
or intentionally transmitted during design/planning.
