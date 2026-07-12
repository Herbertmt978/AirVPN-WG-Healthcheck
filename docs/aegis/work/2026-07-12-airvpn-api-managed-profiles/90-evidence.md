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

### Task 2: canonical rendering and identity pinning

- Accepted commits: `9abc77675ac665988b7e1993c967588e15f99b65`,
  `422a2a16dbf950a383d4efc12ff392eb94945705`, and
  `8073a50648318e69063ef97cfec9f1d0098861e3`.
- Initial RED: all five planned rendering tests failed only for missing renderer,
  identity, and composition functions.
- Review RED evidence:
  - forged newline content initially escaped rendering validation;
  - 27 forged-object subcases exposed invalid field types, ignored fields, chained
    exceptions, and secret-retaining surrogate encoding failures;
  - 18 comparator subcases exposed raw failures and attacker-controlled key-bearing
    equality exceptions in both public argument positions.
- Final GREEN evidence:
  - focused rendering tests: 5/5 passed;
  - complete helper suite: 45/45 passed;
  - compile and Python 3.10 grammar checks passed;
  - direct surrogate and malicious-equality probes returned generic unchained
    `AirVPNAPIError` with no key retention;
  - canonical bytes, exact public signatures, constant-time private-key comparison, exact
    address equality, and pinned-Table composition remained intact.
- Independent specification and code-quality/security re-reviews approved the final tree
  with no residual findings.
- Scope remained limited to `libexec/airvpn-api` and `tests/test_airvpn_api.py`; the
  worktree and dynamic-key fixture scan were clean.

### Task 3: fixed-origin authenticated generation

- Accepted commits: `7936bce159662f4c4c4eab843c03f55012e9a023` and
  `b2fc23f85b1cd7f787e0856b6d0f62f396b8ff70`.
- Initial RED: 11 generator tests produced 56 expected errors because the
  `generate-profile` command was absent; no fixture/import failures occurred.
- Review RED: 16 focused tests reproduced secret-retaining FD5/request tracebacks,
  escaped HTTP/deep-JSON failures, unbounded `Retry-After`, partial FD4 output, and HTTP
  408 misclassification.
- Final GREEN:
  - generator boundary: 16/16 passed on Python 3.10/Linux, including `/proc` cmdline and
    environment sentinel proof;
  - complete helper suite: 61/61 passed on Python 3.10/Linux and Python 3.14;
  - Python compile/3.10 grammar, healthcheck 59/59, and installer regression passed;
  - exact fixed URL/query/header, no redirects, strict MIME/encoding/body bounds, stable
    exit classes, identity pinning, canonical FD4 output, and exact redacted manifest were
    verified;
  - short-write/flush failures leave FD4 at zero bytes;
  - API keys, private profiles, request headers, caught exceptions, and payload markers
    are unreachable from public error cause/context/traceback locals.
- Independent specification and final code-quality/security reviews approved the repaired
  tree with no residual findings.
- Scope remained the two authorised provider files; no live credential or planning file
  entered implementation commits.

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
