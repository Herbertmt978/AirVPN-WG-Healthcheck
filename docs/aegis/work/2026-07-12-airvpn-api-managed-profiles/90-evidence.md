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

### Task 4: dual-mode runtime and secure module boundary

- Accepted commits: `27ea770a1372fcefc958a2078744cdb25e570197` and
  `5a6cee1721ff7731ec74491cd873bcadb0f41d79`.
- Baseline: existing healthcheck suite 59/59 passed.
- RED evidence:
  - ten runtime and four managed contracts failed only for missing Task 4 owners;
  - review regressions reproduced noncanonical credential FDs, malformed v1 marker shape,
    JIT helper/order gaps, false-success admin lock contention, and credential-FD
    inheritance into pre-provider children.
- Final GREEN:
  - runtime suite: 67/67 passed;
  - managed Linux/root suite: 8/8 passed with no skips;
  - Bash syntax and ShellCheck style passed;
  - static/no-marker runs avoid credential/provider/managed paths until a credential-free
    helper is actually needed;
  - root/mode/symlink/parent checks protect module and installed-key boundaries;
  - v1/v2 pre-mode classification and API/v1 reconciliation order are verified;
  - Linux `/proc` tests prove pre-provider children cannot see/read a caller FD, the exact
    managed owner receives the unconsumed record, and logging/returns leave it closed;
  - explicit commands return 75 on lock contention while legacy timer checks return 0.
- Both independent specification and code-quality/security re-reviews approved the final
  tree with no residual findings.
- Scope was exactly the five authorised Task 4 files; no live key or key-like literal was
  introduced.

### Task 5: persistent API state and lock discipline

- Accepted commits: `2afabadef34265e2c931db2f5d6d6b0510291185`,
  `6cd933b7abb1f5b6dff08540f9a2796d32d98534`, and
  `af6a6b3d8970fb86fd1adc3e04015c57a71b0d0f`.
- Initial RED: managed state functions and selector exclusions were absent; focused
  managed and provider tests failed without touching candidate, Docker, or tunnel paths.
- Review RED evidence reproduced and then fixed:
  - a fixed daily bucket admitted eleven attempts inside one trailing 24-hour window;
  - clock rollback and implausible credential metadata were accepted;
  - managed exclusions reached only a test adapter, not the production selector;
  - temporary credential-FD closure let Bash reuse the number for the global lock;
  - credential identity came from a reopened path rather than the provider's exact FD;
  - natural output names silently collided with Bash locals and could leak an opened key FD;
  - failed exclusion persistence skipped rollback;
  - pre-lock/pre-provider time shortened backoff, `Retry-After`, and exclusions;
  - suppressed runs failed to durably advance their clock high-water mark.
- Final GREEN evidence:
  - managed Linux/root suite: 35/35 passed;
  - managed normal-user suite: 32/32 passed with three deliberate real root-ownership
    checks skipped; direct non-root production entry remained rejected;
  - complete provider suite: 65/65 passed;
  - complete static/runtime suite: 67/67 passed;
  - exact rolling attempt epochs, strict canonical state, fresh post-lock/post-provider
    clocks, durable backoff/exclusions, production selector trust, private-FD isolation,
    exact-FD identity, two-interface serialization, and rollback ordering were verified;
  - Bash syntax, expanded ShellCheck, Python compile, diff/whitespace checks, and gitleaks
    current-tree scan passed.
- Independent specification, shell/API, and final code-quality/security re-reviews all
  approved the final tree with no residual Task 5 finding.
- No live API key was used. Module/test size now requires the already-planned Task 14
  split and ownership decision before release.

### Task 6: versioned managed journal and v1 compatibility

- Accepted commits: `28af7d623ac609fbc88f848b0982b8d39cb206af` and
  `b2854154920cf5200d229f17f3c12e352d3609fe`.
- Initial RED: five focused journal groups failed at the first absent Task 6 owner while
  the existing pending-dispatch and real static v1 reconciliation controls stayed 2/2 green.
- Review RED evidence reproduced and fixed:
  - correct artifact digests could be paired with false canonical endpoints;
  - rollback-cleanup crash state with active=backup and candidate missing was rejected;
  - backup and candidate were not fsynced before the first durable marker;
  - active/candidate classifier output names could collide with Bash locals.
- Final GREEN evidence:
  - managed Linux/root suite: 45/45 passed;
  - managed normal-user suite: 41/41 passed with four deliberate real ownership checks
    skipped; production root enforcement remained intact;
  - complete provider suite: 65/65 passed;
  - complete static/runtime suite: 68/68 passed;
  - the exact eight-line schema, strict bytes/trust bounds, equal-digest/endpoint rejection,
    backup/candidate/parent pre-journal durability, temp/rename/final/parent journal barriers,
    digest-plus-endpoint double reads, exact forward transitions, factual crash-state enums,
    and fail-closed Task 7 seam were verified;
  - canonical v1 reconciliation and static no-marker managed-module isolation remained green;
  - Bash syntax, expanded ShellCheck, diff/whitespace checks, and gitleaks passed.
- Independent specification, adversarial durability/security, and final code-quality reviews
  approved the final tree with no residual Task 6 finding.
- Task 7 must sequence each phase transition only after its corresponding durable qB/tunnel/
  install effect and treat any transition-write failure as rollback-required. No live API key
  was used; Task 14's mandatory split/ownership gate remains open.

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
