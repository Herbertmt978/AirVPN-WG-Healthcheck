# Evidence Bundle Draft: AirVPN API-Managed WireGuard Profiles

## Design and planning evidence

- Approved design: `docs/aegis/specs/2026-07-12-airvpn-api-managed-profiles-design.md`
- Independently approved implementation plan:
  `docs/aegis/plans/2026-07-12-airvpn-api-managed-profiles.md`
- Isolated branch/worktree established before implementation.

## Implementation evidence

### Task 1: strict generated-profile boundary

- Accepted implementation commit: `43f04f9f43a3c3416b63d4b94bcf0f2dffff26f3`.
- RED evidence:
  - eight parser tests failed only because `parse_wireguard_profile` was absent;
  - three country-listing tests failed only because `list_eligible_countries` was absent.
- GREEN evidence:
  - parser tests: 8/8 passed;
  - country-listing tests: 3/3 passed;
  - complete helper suite: 40/40 passed;
  - `python -m py_compile libexec/airvpn-api`: passed;
  - Python 3.10 grammar check: passed;
  - independent mutation probe: 3,810 single-byte adversarial mutations produced only
    validated profiles or expected `AirVPNAPIError` failures.
- Independent specification review: approved with no findings.
- Independent code-quality/security review: approved with no blocking findings.
- Scope and secret review: only `libexec/airvpn-api` and `tests/test_airvpn_api.py`
  changed; dummy keys are generated in memory; key-like literal scan and worktree check
  were clean.
- Deferred release gate: the helper and its test file exceed 800 lines. Task 14 must make
  and verify an explicit split decision before release.

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
