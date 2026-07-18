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

### Task 7: qBittorrent-safe managed transition (accepted)

- Provisional commit `f9231ef` passed its original focused 16/16 transaction groups,
  complete managed root 60/60 and normal-user 56/56 plus four ownership skips, static
  68/68, syntax, ShellCheck, diff, and current-tree Gitleaks checks.
- Independent and direct adversarial review nevertheless reproduced five release blockers:
  - a candidate with a different Interface private key and address committed successfully;
  - an external qBittorrent restart during tunnel downtime was accepted as restoration;
  - configuration drift could make rollback target a new/empty container instead of the
    original immutable container;
  - journal removal followed by parent-sync and marker-recreation failure left no recovery
    owner while the candidate was active and qBittorrent was stopped;
  - a failure after success-stamp creation rolled back the profile but retained the stamp.
- The approved design and plan were amended to add secret-safe active/backup identity
  comparisons, immutable Docker identity and containment checkpoints, and a strict durable
  `pending|committed|finalizing` safety record whose state transition is the commit point.
- An independent amendment review approved the final schema, exact recovery table,
  post-cleanup commit proof, transition-error reclassification, static/v1 compatibility,
  and all five review-blocker closures.
- Follow-up commits `89bb3cf` and `80356d8` added strict active/backup identity pinning,
  immutable Docker-ID ownership, exact Docker response parsing, managed-only rejection of
  ambiguous 64-hex container names, durable safety ownership, drift-tolerant network
  rollback, and post-status final proof.
- A final adversarial reproduction on `80356d8` found that a persistent pending-safety
  re-barrier failure returned before qB containment. RED proved qB remained running while
  the candidate tunnel was active. Commit `d5b435b` now contains the recorded/current qB
  targets immediately after strict safety load, then retries the barrier; a failure keeps
  safety, journal, and candidate evidence, leaves the candidate profile/tunnel untouched,
  and performs no WireGuard-down or profile-move effect.
- Final GREEN evidence on exact clean commit
  `d5b435b37e6a60c109401f6564dcf09225337b88`:
  - managed Ubuntu 24.04 root suite: 81/81 passed;
  - managed normal-user suite: 77/77 passed with four expected root-only skips;
  - static/runtime suite: 69/69 passed;
  - implementer focused recovery/barrier gates: 3/3 passed;
  - adversarial focused parser, identity, re-barrier, drift, classifier, and fresh-process
    gates: 9/9 passed;
  - final specification focused gates: 7/7 passed;
  - Bash syntax, ShellCheck 0.11.0 at style severity, diff integrity, and Gitleaks over the
    exact tree and 42-commit history passed with no leak.
- Independent adversarial/security and final specification reviewers both approved the
  immutable commit. No remaining Task 7 contradiction, crash-owner gap, wrong-target
  recovery path, or static compatibility regression was found.
- No live API credential was used. Task 14 must still resolve the now 2,916-line managed
  module and 4,588-line managed test owner before release.

### Task 8: managed administration and unattended dispatch (accepted)

- Commit `2089c78` added explicit provision, adopt, rotate, restore-static, reset-state,
  and redacted text/JSON status commands plus mode-aware unattended dispatch.
- Exact-SHA review then reproduced six fail-closed gaps: provider-error cleanup inherited
  the credential FD; dry-run removed an existing orphan candidate; new helpers leaked
  `errexit`; identical snapshot retry skipped the durability barrier; absent-file reset
  retry skipped its parent barrier; and config writes did not consistently prove a
  root-owned mode-0700 parent.
- Follow-up commit `82eb266dc35c8fd560f45a92835b36201e54a2af` fixed all six without
  rewriting history. The final design keeps credential access limited to the exact
  generator process, refuses unsafe candidate/state/config paths, uses one captured
  preflight epoch, and never falls back from a managed failure to the static profile.
- Final GREEN evidence on exact clean commit `82eb266`:
  - managed Ubuntu 24.04 root suite: 120/120 passed;
  - managed normal-user suite: 116/116 passed with four expected root-only skips;
  - static/runtime suite: 79/79 passed;
  - exact follow-up specification gates: 20/20 managed and 6/6 runtime passed;
  - exact follow-up security gates: 14/14 managed and 3/3 runtime passed, including
    provider cleanup probes proving FDs 3, 4, and 5 closed while the provider exit code
    remained intact;
  - exact follow-up quality gates: 15/15 managed and 1/1 runtime passed;
  - Bash syntax, ShellCheck 0.11.0, JSON standard-library parsing, diff integrity, and
    Gitleaks over both the tree and 44-commit history passed with no leak.
- Independent specification, adversarial security, and code-quality reviewers approved
  the exact follow-up commit with no remaining Task 8 blocker.
- No live API credential, provider mutation, or VM change was used. Task 14 must still
  resolve the 3,770-line managed module and 6,257-line managed test owner before release.

### Task 9: guided setup and private settings transport (accepted)

- Commit `f706c740cb25fdd6316342c4c994d3d1cba93b43` added the optional two-mode setup
  command, credential-free eligible-country discovery and selection, strict hidden/file
  credential input, a bounded canonical proposed-settings descriptor, and runtime dry-run
  validation without persistent changes.
- Security review reproduced and closed failures involving getpass echo fallback, unsafe
  credential ancestors and special files, unstable metadata, pre-sanitization metadata
  children, original settings-descriptor inheritance, signal-path child inheritance, and
  nested Bash redirection restoring an unowned credential descriptor.
- Final GREEN evidence on the exact implementation commit:
  - Python discovery: 92/92 passed, including 27/27 setup tests;
  - runtime Ubuntu 24.04 root suite: 84/84 passed;
  - managed Ubuntu 24.04 root suite: 121/121 passed with no skip;
  - focused sanitizer/descriptor cleanup regression: 3/3 passed;
  - Python compile, Bash syntax, ShellCheck, diff integrity, and Gitleaks over the 1.51 MB
    tree passed with no leak.
- Independent setup, runtime specification, adversarial security, and code-quality reviews
  approved the final boundary. The runtime closes both private descriptors before every
  pre-provider child and keeps credential ownership in `main` until Bash has restored any
  temporarily hidden descriptor.
- No live API credential, provider mutation, persistent setup application, or VM change was
  used. Task 10 owns transactional persistence and Task 14 must split oversized owners.

### Task 10: transactional setup application and credential lifecycle (accepted)

- Commit `eae050477a373208dbb215e47b1b3720f18f839d` split the setup launcher into a
  bounded Python package and added exclusive administrative leasing, quiesced config/key
  transactions, strict v1/v2/v3 recovery journals, repeatable snapshots, fresh-health
  commit proof, post-commit timer handling, and the setup-only runtime candidate cleanup
  seam. Commit `f6d3359` normalized the existing provider sources to the pinned formatter.
- Adversarial review reproduced two final crash-safety blockers before acceptance:
  - random private write names could strand an undiscoverable credential-bearing temporary
    after power loss;
  - a syntactically valid static journal could claim `key_changed=1`, causing rollback to
    ignore credential recovery evidence.
- The repaired tree uses fixed same-directory, exclusive-create private staging names;
  apply recovery durably discards only those known unpublished entries while holding the
  exclusive setup lease, and dry runs fail closed without mutation. Strict journal
  semantics now reject static key changes and API states that claim no prior or new key.
- Final GREEN evidence on the exact accepted tree:
  - Python 3.12 compile plus discovery: 167/167 passed;
  - focused setup application/recovery/store/journal/maintenance: 74/74 passed;
  - static/runtime Ubuntu root suite: 89/89 passed;
  - managed Ubuntu 24.04 root suite: 122/122 passed with no skips;
  - pinned Ruff 0.12.3 check and format: all 21 Python owners passed;
  - Bash syntax, ShellCheck 0.11.0 style, diff integrity, and Gitleaks over the 2.33 MB
    current tree passed.
- Independent specification and adversarial re-reviews returned READY after the repairs.
  They verified static no-key isolation, lease/lock ordering, fixed-stage refusal and
  cleanup, strict reachable journal states, exact rollback, inert first provisioning,
  fresh proof before commit, timer containment, and candidate cleanup ownership.
- No live API credential, VM mutation, installer change, or public release action occurred.
  Task 11 owns installation/upgrade safety and Task 14 remains a mandatory complexity gate.

### Task 11: installer and systemd upgrade safety

- Commit `ae71fa4` installs the provider, managed runtime module, guided setup launcher and
  package, persistent state directory, and systemd owners with exact modes while preserving
  the API credential, pre-managed profile, API state, and existing health configuration.
- Live upgrades fail closed on ambiguous systemd output or return codes, active instances,
  unsafe runtime paths, held setup/interface/global locks, and pending journal or safety
  records. `--quiesce` disables and stops the selected instance, never re-enables it, and
  reports incomplete post-disable work.
- Runtime and setup entrypoints are atomically replaced with inert exit-75 guards before
  any shared dependency changes. The installer then rechecks all instances and newly
  appeared locks, installs dependencies/package/units/config, reloads systemd, publishes
  setup and runtime launchers with runtime last, releases every retained descriptor, and
  only then honors an explicit `--enable`.
- Exact setup-package manifests reject missing, extra, linked, directory, or bytecode-cache
  entries. Lock creation uses a private umask plus lstat/open-descriptor identity and exact
  ownership/mode/link checks. Scoped HUP/INT/TERM/EXIT cleanup preserves status, releases
  locks, and emits the disabled-timer diagnostic once.
- Fresh final-tree verification:
  - root-path installer suite: 57 passed, one intentional non-root check skipped;
  - non-root installer suite: 58 passed, no skips;
  - Bash syntax, ShellCheck 0.11.0, staged `systemd-analyze verify`, and diff checks passed;
  - pinned Gitleaks 8.30.1 scanned 2.13 MB and found no leaks.
- Independent specification/quality and adversarial security re-reviews returned READY.
  The mandatory Task 14 complexity split remains open because installer and test owners now
  exceed the approved review threshold.
- No VM, release, remote-history, or repository-visibility mutation occurred in Task 11.

### Task 12: public dual-mode documentation and MIT license

- Commit `0e3f74a` adds the standard MIT license, a first-screen static/API choice,
  exact interactive quick starts, explicit country-selection semantics, root/credential
  boundaries, a complete operator guide, and current security/contribution rules.
- The operator guide provides safe manual-health/timer decisions, credential replacement
  and removal, API-state maintenance, quiesced upgrades, runtime-masked rollback with an
  installer-failure gate, and all-instance package removal that preserves recovery data.
- RED documentation contracts initially failed for the absent license/operator guide and
  stale v1.0-only claims. Review then reproduced and fixed an unsafe persistent systemd
  mask, unchecked rollback installer failure, incomplete removal steps, vague prerequisites,
  a broken development-checks link, missing WireGuard mode, and ambiguous `ALL` storage.
- Fresh final-tree verification:
  - public documentation contract: 12/12 passed;
  - root-path installer suite: 57 passed, one intentional non-root check skipped;
  - non-root installer suite: 58 passed, no skips;
  - native Linux Python discovery remained 179/179 green, with the final documentation
    contract rerun separately after the last prose-only corrections;
  - Bash syntax, ShellCheck 0.11.0 style, local Markdown links, and diff checks passed;
  - pinned Gitleaks 8.30.1 scanned 2.38 MB and found no leaks.
- Independent Terra specification/usability review and Luna adversarial security review
  returned READY for Task 12. Both reviews explicitly block release until Task 13 updates
  `VERSION`, adds v1.1 notes, includes every runtime/setup owner plus license/operations in
  both archives, and extends CI/release scanning.
- No VM, tag, release, history rewrite, push, or repository-visibility mutation occurred.

### Task 13: v1.1.0 release surface and deterministic packaging

- Commit `66f8a57` synchronizes `VERSION` and the runtime at `1.1.0`, adds release notes and
  changelog Added/Changed/Security sections, updates public issue redaction guidance, and
  introduces Ubuntu 22.04/24.04 branch-cancelling CI plus non-cancelling tag publication.
- The curated source release contains exactly 27 files. Tar and ZIP payloads are generated
  deterministically from the requested Git tree, normalize regular-file modes to `0644`
  and the four launchers/helpers to `0755`, reject duplicate or unexpected members, and
  install every runtime, setup-package, configuration, and systemd owner from both formats.
- Release contracts require the checked-out packager/test to match the requested ref,
  validate static defaults plus offline API country selection, reject runtime artifacts,
  labelled key/profile assignments, bare 64-hex key records, and serialized host IDs, and
  verify exact installed contents and private modes.
- The new non-root managed CI lane reproduced one stale test-fixture failure: the
  descriptor-privacy test simulated root for the interface lock but still executed the
  real root-only setup-guard metadata owner. Commit `c99c472` keeps the production check
  unchanged, substitutes only that fixture seam, and now proves the credential descriptor
  is closed inside the guard metadata child before reaching the exact managed owner.
- Fresh native Linux verification:
  - Python discovery as root: 179/179 passed;
  - static/runtime Bash: root 89/89 and non-root 89/89 passed;
  - managed Bash: root 122/122; non-root 118 passed with four expected root-only skips;
  - installer: root 57 passed with one expected non-root skip; non-root 58/58 passed;
  - release contract: 27 files verified; deterministic tar/ZIP installation checks passed;
  - public documentation: 12/12 passed;
  - Bash syntax, ShellCheck style, actionlint, and diff integrity passed.
- Pinned Gitleaks 8.30.1 found no leak across 56 commits (~2.53 MB), the current source tree
  (~2.41 MB), the extracted tar (~465.15 KB), or the extracted ZIP (~465.15 KB).
- Luna adversarial release review found and closed ref/worktree packager skew, a broken
  offline v1.0 link, incomplete archive-install assertions, duplicate-member/mode gaps,
  raw-key scanning, and missing extracted country-selection coverage. Terra workflow review
  established the exact root/non-root execution and sanitized Python path requirements.
- No API credential, live provider mutation, VM change, tag, push, release, history rewrite,
  or repository-visibility mutation occurred. Task 14 remains mandatory because the named
  runtime/test owners exceed the approved review threshold.

### Task 14: managed-profile architecture and release-candidate evidence

- Commit `a57b535` records ADR 0001 and resolves the mandatory bounded-owner gate. The
  installed runtime remains a single root-validated `libexec/wg-healthcheck-managed` file;
  nine fixed development fragments under `libexec/wg-healthcheck-managed.d/` are assembled
  by a manifest-driven builder and are never sourced by runtime, installer, or package.
  `--check` proves the generated artifact is exact and rejects missing, extra, non-regular,
  symlinked, reordered, drifting, or unsafe output inputs.
- The provider suite is a 48-line compatibility loader plus bounded support and four fixed
  groups; health, managed, and installer shell suites use explicit fixed registries and
  bounded support/groups. Architecture tests prove each test definition or provider class
  is registered exactly once, runners use no globs, code owners are UTF-8 without BOMs,
  and all non-exception owners remain at or below 800 lines.
- ADR 0001 records static and API-managed ownership, the country-selection boundary,
  rejected runtime-fragment and device-lifecycle alternatives, the status-only exception,
  trust boundaries, and retirement criteria. It documents the three reviewed production
  exceptions (`bin/wg-healthcheck`, `libexec/airvpn-api`, and `install.sh`); architecture
  tests lock those exceptions and the 13 reviewed production blocks over 80 lines.
- Luna's adversarial review reproduced a mismatch between the ADR and executable trust
  validation: the healthcheck previously validated only a helper/module and its immediate
  parent. A focused RED regression now proves every ancestor is absolute, root-owned,
  non-symlinked, and not group/world writable except for a root-owned sticky directory.
  The shared validator preserves exact helper/module mode checks and passed real-root tests.
- Fresh release-candidate verification:
  - architecture assertions: 11/11 passed;
  - Python discovery as root: 189/189 passed, including the unchanged 65-test provider
    registry;
  - static/runtime Bash: root 89/89 and non-root 89/89 passed;
  - managed Bash: root 122/122; non-root 118 passed with four expected root-only skips;
  - installer: root 57 passed with one expected non-root skip; non-root 58/58 passed;
  - Bash syntax, exact Bash-dialect ShellCheck style, actionlint, generated equivalence,
    whitespace/diff integrity, and targeted root trust regressions passed.
- A fresh native-Linux detached clone of exact commit `a57b535` verified both deterministic
  release formats and their exact 27-file manifest. Pinned Gitleaks 8.30.1 found no leaks
  in the 2.68 MB current tree, 48 branch commits (~2.34 MB), or either extracted 467.25 KB
  archive. SHA-256 verification passed for both generated assets.
- Independent Terra and Luna architecture/security reviews returned READY after closing
  extensionless-owner, BOM, symlink-root/entry, registry-completeness, generated-order,
  Bash-dialect, ADR-status, and ancestor-validation findings.
- No API credential, provider mutation, VM change, tag, push, release, history rewrite, or
  repository-visibility mutation occurred in Task 14.

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

### Task 15: live acceptance in progress

- The supplied test key was never committed, logged, placed in an argument/environment,
  or transmitted to browsers, search, CI, review tooling, or repositories. It was
  transferred privately to one root-owned mode-0600 temporary VM file, supplied to the
  provider helper through its fixed descriptor, and sent only to the helper's fixed AirVPN
  HTTPS origin.
- Authenticated, read-only `userinfo` and `devices` schema probes returned `result=ok`.
  Only allowlisted field names and success state were retained; account, session, device,
  address, identifier, and key values were discarded. This proves the credential itself is
  valid without adding either endpoint to the unattended runtime.
- The first authenticated generator dry run reached AirVPN but returned the safe transient
  `phase=response` classification. It changed no active profile, configuration, interface,
  installed credential, candidate, journal, safety record, timer, or qBittorrent state.
  No response body or complete header set was retained, so its exact media type is not
  asserted.
- Public AirVPN raw-configuration examples use `system=other`; exact request tests first
  failed with the production `system=linux` value and then passed after the minimal change.
  Commit `4acdf432fe840dd6b40e78b5b815212c5cdb485a` requests the raw form while retaining the
  fixed origin, `API-KEY` header, redirect refusal, size/MIME/encoding bounds, strict parser,
  identity pinning, and archive rejection. Independent Terra/Luna reviews returned READY.
- Exact-commit verification from a complete Git bundle passed Python root 201/201,
  healthcheck root/non-root 89/89, managed root 125/125, managed non-root 120 with five
  intentional root-only skips, installer root 58 with one intentional skip, installer
  non-root 59/59, Python 3.10 provider 71/71, generated-runtime equivalence, Bash syntax,
  ShellCheck 0.9 and pinned 0.11, installed modes, systemd verification, actionlint, and the
  27-file release contract.
- Two exact-commit package builds were byte-identical. SHA-256 values are
  `25cb58870b775881d6c3ca88e2cda23f14df38267eee51334b4dfbed0ee6fcae` for the tar,
  `aaf773e670f937bc13b6f5c82e64cd1eaa0da067c2be8f189f77d781ba56d435` for the ZIP, and
  `ba8ef697cbfa26d67c1a230b347025178790958a0b5a84aa7d00b5604fff7738` for `SHA256SUMS`.
  Pinned Gitleaks 8.30.1 found no leaks in 57 exact-history commits, the exact tree, or
  either extracted archive.
- The exact tar was transferred and hash-verified on the VM, then installed with
  `--quiesce`. Installed program bytes match the package; the active profile and health
  configuration remained byte-identical to preflight, the timer remained runtime-masked,
  and WireGuard plus qBittorrent remained active. No installed API key, candidate, journal,
  or safety record exists.
- Exact commit `85abcdd6d0893c9145aadd7227454b92ac74ed19` documents the reviewed API
  boundary and public setup path. A fresh root-owned Linux clone passed 202 Python tests,
  healthcheck root/non-root 89/89, managed root 125/125, managed non-root 120 with five
  intentional root-only skips, installer root 58 with one intentional skip, installer
  non-root 59/59, and the reproducible 27-file release check. Pinned Gitleaks 8.30.1 found
  no leaks across 70 reachable commits.
- The sixth and final rolling-window slot was used only after the recorded backoff elapsed.
  The corrected `system=other` request again returned rc 64 and the allowlisted
  `phase=response` result. The accounting ledger advanced to six attempts and recorded the
  transient outcome, as specified; it was not reset or bypassed.
- The second live failure changed no profile, health configuration, live interface,
  installed credential, candidate, recovery journal, safety record, timer, or qBittorrent
  state. The original profile and health-configuration digests still match preflight,
  WireGuard and qBittorrent remain active, and the timer remains runtime-masked.
- The root-only response log, supplied test key, and complete task-specific temporary
  directory were deleted and the runtime parent was synchronized. No API credential is
  installed. The ledger intentionally retains non-secret metadata for the consumed
  temporary credential identity until a later explicit setup or state reset.
- qBittorrent uses host networking and is pinned to `wg0`; its peer TCP and UDP listener
  bind the WireGuard address, a route lookup from that address selects `wg0`, and the
  tunnel-bound AirVPN egress proof returned `airvpn=true`. The wildcard Web UI and local
  discovery sockets are separate local-service surfaces.
- The public AirVPN API Explorer was re-read without a credential. It classifies `status`,
  `dns_lists`, and `whatismyip` as public and `userinfo`, `notification`, `devices`,
  `generator`, and `disconnect` as account-scoped. The asynchronous device list/add/renew/
  delete/modify lifecycle is intentionally deferred to a separate blue/green identity
  design; version 1.1 keeps only public status selection, fixed-device generation, and
  tunnel-bound egress proof.
- Response-boundary diagnostics were implemented test-first as seven local-only reasons:
  `status`, `encoding`, `media`, `read`, `size`, `json`, and `protocol`. The provider emits
  a reason only with `phase=response`; setup and the managed runtime accept only exact
  newline-terminated allowlisted manifests. Actual status values, headers, URLs, response
  bytes, devices, servers, provider messages, and credential-derived values remain outside
  every diagnostic and persistence boundary.
- The first implementation correctly passed focused provider/setup/managed tests but
  failed the architecture gate because several review owners exceeded their frozen limits.
  The repair extracted bounded helpers and split test owners without increasing a ceiling:
  `libexec/airvpn-api` remains exactly 1,718 lines, `_read_generator_response` is 20 lines,
  `managed_generate_candidate_provider` is 42 lines, and the existing 132-line authenticated
  attempt ceiling is unchanged. Refactoring exposed and fixed a close-failure precedence
  regression before acceptance.
- Exact commit `47e75114bb18b67a34d54214a292a4ce08460923` was cloned from a complete
  Git bundle into separate native-Linux root-owned and ordinary-user worktrees. Python
  discovery passed 203/203; healthcheck passed 89/89 as root and 89/89 non-root; managed
  recovery passed 125/125 as root and 120 with five intentional ownership skips non-root;
  installer passed 58 with one intentional root-only skip and 59/59 non-root. Architecture
  11/11, generated-module equivalence, Bash syntax, ShellCheck 0.9.0, systemd 255.4
  verification, and actionlint also passed.
- The exact release check verified 27 files. Two independent builds produced byte-identical
  tar, ZIP, and `SHA256SUMS` artifacts. Their SHA-256 values are
  `b51557be42032af357cc1e974b91944876ec8eba77d2b1e05159d94e1abed29c`,
  `bd1d819feb3e34a022a71cfb0110804b0f03693f926186aed4c08394057a7fc8`, and
  `635ecf701ea422381b91f480a305b476cc2207ba0629b275035d31b44883e315`.
  Pinned Gitleaks 8.30.1 found no leak in the 59 reachable commits, exact tree, or either
  extracted 27-file archive. Two independent Terra integration/architecture reviews and a
  Luna documentation/API-scope review returned READY.
- A Windows-mounted staged-installer run was rejected only by the expected lack of native
  POSIX ownership/mode semantics and is not counted as release evidence; the corresponding
  fresh native-Linux root and non-root installer gates above passed.
- The preserved exact `47e7511` tar was transferred to the download VM in a private,
  root-owned staging area and independently matched
  `b51557be42032af357cc1e974b91944876ec8eba77d2b1e05159d94e1abed29c` before extraction.
  `install.sh --quiesce wg0` completed successfully. Every installed program, helper,
  setup package file, and systemd unit matched the reviewed archive byte-for-byte; the
  existing WireGuard profile and health configuration retained their preflight digests.
- The diagnostic-build acceptance ran with the timer runtime-masked and no API credential.
  The one-shot service completed with `mode=static`, `tunnel=up`, a healthy or recovered
  result, `pending=none`, and `qbittorrent=proved`. A separate HTTPS request bound to `wg0`
  was accepted by AirVPN's public `whatismyip` service with `result=ok` and `airvpn=true`;
  its address and response body were not retained.
- The runtime mask was removed only after that acceptance. The timer is enabled and active,
  has triggered the installed service, and the latest automated check remains successful
  in static mode with qBittorrent proved. No API key, managed candidate, setup transaction,
  pending journal, or safety record exists. Both private deployment directories and the
  temporary egress response were securely removed after validation.
- A fresh read-only AirVPN API audit confirmed the eight-service boundary recorded in the
  public guide and the provider's source-IP-wide 600-request/10-minute ceiling. The safest
  later uplift is a setup-only reduced `devices?action=list` picker; device mutations remain
  asynchronous identity changes requiring a separate blue/green design. Public status and
  egress URL overrides, aggregate multi-interface rate budgeting, and IPv4/IPv6 leak-policy
  boundaries are now explicit in the operator documentation.

- After rolling-window capacity reopened naturally, a third authenticated attempt on the
  refined reason contract returned `phase=response`, `reason=media_type`. Exact candidate
  `eadae01` then enabled the conservative HTML-label policy and a fourth attempt returned
  the same reason. Both attempts preserved the profile/configuration digests, left the
  source credential uninstalled, kept the timer masked and inactive, and left `wg0` active.
  The provider ledger recorded four of six attempts and retained its required backoff; it
  was not reset or bypassed.
- Exact `eadae01` passed the native-Linux root/non-root, generated-runtime, Bash syntax,
  ShellCheck, systemd, reproducible release, checksum, and pinned Gitleaks full-history and
  archive gates. Its tar and ZIP SHA-256 values are
  `325b6b59bd95bb2223ebf3d9e3971cf73b02f3209622e8b4320aba32312628dc` and
  `cc4e89dc88e2c0d19d295dda55aa90652aa7cccdb6c03eb2a7345712b49a2d45`.
  That exact package is installed byte-for-byte on the VM in verified static mode.
- France was removed from the shipped starting policy in commit `a11dd5d`; runtime,
  configuration example, tests, README, changelog, and release notes consistently use
  `GB NL BE DE IE` while preserving operator-selected countries and explicit `ALL`.
- The next media-contract slice was implemented test-first. RED evidence showed the exact
  missing `Accept`/`Accept-Encoding` headers, unrecognized WireGuard profile media type,
  and still-admitted HTML path. GREEN evidence passed the four focused boundary tests,
  all 88 provider tests, and all 17 public-documentation tests. The request now prefers
  the publicly documented parameterless `application/x-wireguard-profile` convention,
  then text/plain, with identity encoding and a low-priority request-only wildcard. Parser
  acceptance remains exact; HTML and parameterized profile types fail closed. Terra/Luna
  reviews found no secret or contract drift and requested one explicit 406-permanent
  regression assertion, which was added without changing runtime behavior.
- Exact commit `671f5e07c935f19385ed5dd43c2236c8ec9c820a` passed the complete
  detached Ubuntu 24.04 gate from a Git bundle: generated-runtime equivalence, Bash syntax,
  Python discovery, root/non-root health, managed and installer suites, exact deterministic
  release checks, both ShellCheck passes, and systemd verification. Pinned Gitleaks 8.30.1
  found no leak across reachable history or either extracted archive. The tar, ZIP, and
  `SHA256SUMS` SHA-256 values were respectively
  `45067ad284d3436e6f656ccc15c72f47b77a89dd6bb6be0d4003491f3ccf1ffc`,
  `84183f7e94f7c71e805d8483c092174cb34b7f0cefd06c7a205014fc94b7fdc6`, and
  `69ed003aeb86a7e3aec6bc9ccb911b8ffbc065cb77a24d31f8115c663d632a9e`.
- The exact `671f5e0` package was installed with `--quiesce wg0`. Installed files matched
  the archive byte-for-byte; profile, health configuration, and persistent state retained
  their pre-install digests; the timer remained runtime-masked and inactive; the worker
  remained inactive; `wg0` remained active; no credential or candidate was installed; and
  the root-only source credential retained its strict metadata outside the package.
- After the recorded backoff reached zero and all five configured countries were eligible,
  the fifth authenticated dry run used exact `671f5e0` and returned rc 64 with only
  `phase=response`, `reason=media_type`. The provider ledger advanced from four to five of
  six rolling-window attempts and recorded the required transient backoff. Every profile,
  configuration, key, candidate, timer, worker, and interface postcondition remained
  unchanged; no provider body or media value was retained or disclosed.
- Public AirVPN working examples omit the undocumented `format=text` query and consume the
  generator body as a profile, but no public source documents the successful response media
  type. The next local slice was therefore started test-first: its RED run failed only
  because the query still included that parameter and otherwise valid advisory media labels
  were rejected before strict parsing. GREEN now omits the parameter while preserving fixed
  origin/method/fields and identity encoding. It requires exactly one syntactically valid
  media label, rejects HTML, multipart, and known archive/compression labels, bounds the
  body to 64 KiB, sniffs JSON envelopes under every label, and authorizes output only after
  strict canonical WireGuard, expected-endpoint, and identity validation. Focused tests
  cover valid arbitrary labels plus HTML, ZIP, gzip, garbage, JSON, duplicate encoding,
  status-before-read, redaction, and zero-write failure behavior.
- Exact commit `92e2890360f831a1cef6b1570c83c80396bb157d` passed a detached Ubuntu
  24.04 gate created from a complete-history Git bundle. Generated-runtime equivalence,
  Bash syntax, Python discovery, root/non-root health, managed and installer suites,
  deterministic release checks, both ShellCheck passes, and systemd verification passed.
  Pinned Gitleaks 8.30.1 found no leak across all 77 reachable commits or either extracted
  archive. The bundle, tar, ZIP, and authoritative `SHA256SUMS` SHA-256 values were
  `8deb1ba300764f23e33ad5e624f8f1a5be3cfacfd9736ad777875a7d5bae512c`,
  `8624ebe9c659762ab0aa3addda8963d717452f8be441cec615ab20bba95b8668`,
  `ded2ce3b788717b45f68d0e184acf732191662a6c8b008c075a09447e5165043`, and
  `be2eb63519c6e8cbdca793b8af1f6e980a566d5c08315d7b624b6c98d3770f6c`.
- The exact `92e2890` package was installed with `install.sh --quiesce wg0`. Every
  installed program, provider helper, managed owner, setup-package file, and systemd unit
  matched the reviewed archive byte-for-byte. The active profile, health configuration,
  and provider state retained their pre-install digests; the timer remained runtime-masked
  and inactive; the worker remained inactive; `wg0` remained active; qBittorrent remained
  proved; and neither an installed credential nor a candidate/recovery artifact appeared.
- Immediately before the final dry run, exact installed bytes and private-file metadata
  were reverified. The active profile and health configuration still matched preflight,
  static status reported `tunnel=up`, `pending=none`, `credential_present=false`, and
  `qbittorrent=proved`, all five policy countries (`GB NL BE DE IE`) were publicly eligible,
  and the unmodified provider ledger recorded five active attempts, one natural slot, and
  zero backoff.
- The sixth authenticated dry run used the fixed `DownloadVM` device and five-country
  allowlist through the non-interactive setup path. It returned rc 0 with only the fixed
  redacted success contract: the provider body passed the bounded response, strict canonical
  WireGuard, expected-endpoint, and fixed-device identity checks. No profile, endpoint,
  server, provider header/body, credential value, or attempt timestamp was retained or
  disclosed.
- The successful dry run advanced the required provider ledger to six of six active
  attempts with `failure_class=none` and zero backoff. It left the static profile and health
  configuration byte-identical, kept the source credential root-owned and uninstalled,
  preserved the runtime timer mask and inactive worker, left `wg0` active and qBittorrent
  proved, created no candidate or recovery artifact, and removed its private temporary
  capture. The ledger was not reset, rewritten, or bypassed.
- At the first scheduled adoption gate, exact installed bytes, profile/configuration/state
  digests, root-only source-credential metadata, timer/worker inactivity, free locks,
  recovery-artifact absence, active `wg0`, static status, qBittorrent proof, five-country
  public eligibility, and the strict provider ledger all passed. One of six rolling slots
  had reopened naturally and backoff remained zero.
- Before mutation, a direct setup call-graph review found that first-time static-to-API
  adoption makes three separately accounted generator attempts: prospective dry-run
  validation, installed-credential dry-run revalidation, and identity-pinned apply. With
  only one slot, starting the transaction would consume that slot and force rollback before
  activation. The apply was therefore deferred without an authenticated request or VM
  mutation; the timer remains runtime-masked and static operation remains proved while two
  more slots reopen naturally.
- After three slots reopened naturally, the adoption preflight again matched the clean
  feature candidate and exact installed `92e2890` bytes. The static profile, health
  configuration, and provider-state digests matched their reviewed values; the root-only
  source credential was inspected by metadata only; no installed credential or recovery
  artifact existed; timer and worker were inactive under the runtime mask; all locks were
  free; `wg0` and qBittorrent were proved; all five policy countries were publicly eligible;
  and the strict provider ledger exposed exactly three available slots with zero backoff.
- Exactly one non-interactive API apply used fixed device `DownloadVM`, countries
  `GB NL BE DE IE`, and the root-only out-of-repository credential file while leaving the
  timer disabled. It returned rc 0, empty stderr, and byte-for-byte the setup tool's fixed
  redacted twelve-line success contract. No retry was made. The prospective validation,
  installed-credential revalidation, and identity-pinned activation each consumed their
  required durable ledger attempt.
- Post-adoption verification proved that the active profile remained byte-identical to the
  reviewed static profile and that `/etc/wireguard/wg0.conf.pre-managed` is an exact
  root-owned mode-0600 rollback copy. The installed credential is a root-owned mode-0600
  65-byte regular file and was never read or printed during verification. API configuration,
  live interface identity, fresh handshake, required route/rule, tunnel-bound AirVPN egress,
  and qBittorrent TCP/UDP process ownership all passed. API status reported an active tunnel,
  a healthy or recovered fresh check, present credential, no pending transaction, and proved
  qBittorrent state. Timer and worker remained inactive under the runtime mask, locks were
  free, and every candidate, pending, safety, setup-journal, setup-snapshot, and staging
  artifact was absent.
- The committed API health-configuration digest is
  `768763e6a611952a857e103ffbc6338aa5644c2cdfc7bac6e7332befdf1faaad`;
  the strict successor provider-state digest is
  `2b0dffb5fa92b4ec74709cbbcc83c25672b6d227fdb500fcdb70c33e2040c874`.
  The ledger correctly contains six active attempts, no exclusions, `failure_class=none`,
  zero backoff, and metadata bound to the installed credential. No attempt epoch, profile,
  server, endpoint, address, egress address, provider response/header, credential, or stored
  access secret was retained or disclosed.

API adoption is accepted. Live rollback/rotation, five-cycle timer observation, fresh
production-credential replacement, protected-main integration, release, tag, and publication
remain unclaimed. The VM remains healthy in verified API mode with the timer runtime-masked.
The adoption returned the ledger to six of six; two slots must reopen naturally before the
paired rollback drill and controlled successful rotation.

- After capacity reopened naturally, the planned post-candidate verification failure drill
  used exactly one authenticated attempt and no retry. The candidate was rejected by the
  deliberately unreachable speed threshold, and the transaction restored the original
  active profile byte-for-byte. AirVPN egress, `wg0`, qBittorrent routing/listeners, free
  locks, cleared recovery artifacts, inactive worker, and the runtime-masked timer all
  passed. The strict ledger then recorded four active attempts, two natural slots, one
  exclusion, and zero backoff; it was not reset, rewritten, or bypassed.
- The following controlled rotation passed a fresh local preflight and used exactly one
  additional authenticated attempt with no retry. Candidate tunnel start failed, and the
  transaction again restored the original profile byte-for-byte. The pre-managed snapshot
  and transaction backup both matched that original profile, the API runtime remained
  healthy, AirVPN egress and qBittorrent remained proved, all recovery artifacts cleared,
  locks were free, and timer and worker remained inactive under the runtime mask.
- Fixed-enum, server-side classification identified `candidate_network`,
  `tunnel_start_failed`, and `resolver_failure` without retaining or disclosing raw journal
  text, provider data, endpoint, server, address, egress address, or credential material.
  The generated candidate carried `DNS` while the validated working profile did not, so
  `wg-quick` attempted an unavailable `resolvconf` integration. Provider state now has
  digest `9b115b763697c03e8d6aa14a1327691689510e872e134d9ae5dc61c7383c991e`
  and records five active attempts, one natural slot, two exclusions, no failure backoff,
  and a verified-rollback status. No further authenticated request is authorized in this
  evidence slice.
- The ownership defect was reproduced test-first at both the canonical composer and fixed
  fd5 generator boundary. Identity-pinned candidates now preserve the validated installed
  numeric `DNS` policy, including absence, together with local `Table` and retained
  `PostUp`/`PostDown`; generated AirVPN peer fields remain authoritative. Fresh provisioning
  still retains validated provider DNS when present and conditionally requires the host's
  `wg-quick` resolver backend. Focused absent-DNS, non-empty-DNS, and public-documentation
  tests pass. A clean tracked Ubuntu 24.04 export passed generated-runtime equivalence,
  Bash syntax, 213 Python contracts, root and non-root health, managed-profile and installer
  suites, both ShellCheck passes, exact installed modes, systemd verification, and the
  reproducible 27-file release gate before commit or installation.
- The same clean tracked candidate passed the complete Ubuntu 22.04 minimum-version matrix
  with Python 3.10, Git 2.34, ShellCheck 0.8, systemd 249, all root/non-root suites, and the
  reproducible release gate. Actionlint passed and pinned Gitleaks 8.30.1 found no leak in
  the current worktree. No VM mutation or authenticated provider request occurred during
  either deterministic matrix.
- Commit `f0beafc2aef0930a78a2f425eab61a4e2e01267a` records the corrected DNS ownership,
  regression coverage, operator/public documentation, and live failure evidence. A complete
  bundle of reachable refs has SHA-256
  `7d0657a974e8443d23501a1b96af31287b8c3ebcafc0eff3939a9a671035ca5e`.
  The exact commit passed fresh Python and release-contract verification before packaging.
- The exact tar, ZIP, and authoritative `SHA256SUMS` SHA-256 values are respectively
  `eba46513cd454cf829489c5607c453f165ac64e68f55da6574a19c7ac5765095`,
  `2453a854c1478873723802279aedefb0453e6f6cbc1a803d8fdf0017fa25e038`,
  and `398b6f1423e6f238e13ebd8bc0791ea4f15903438fc02b5a98dbdf6239feb253`.
  Pinned Gitleaks 8.30.1 found no leak in reachable history or either extracted archive.
- Before deployment, DownloadVM matched exact installed `92e2890` program/setup/systemd
  bytes and the expected profile, pre-managed snapshot, transaction backup, API
  configuration, and provider-state digests. Source and installed credentials passed
  root-only metadata checks without being read. The runtime mask, inactive timer/worker,
  free locks, clean recovery state, active `wg0`, API status, qBittorrent proof, and country
  policy `GB NL BE DE IE` all passed.
- The hash-verified package was transferred through private root-only staging and installed
  once with `install.sh --quiesce wg0`. The installed provider helper now has exact reviewed
  SHA-256 `d4d41226d3d77bee97f7994d221a3f1124f5b094a9db8fb423b1c6f2cacd0653`;
  every other installed program, setup-package file, and systemd unit remained byte-identical.
  The active profile, pre-managed snapshot, transaction backup, API configuration, provider
  state, and credential metadata remained unchanged. Timer and worker remain inactive under
  the runtime mask; locks are free; recovery artifacts are absent; `wg0` and qBittorrent
  remain proved; and private package/install staging was removed.
- A final public `whatismyip` request bound to `wg0` passed the strict AirVPN egress parser
  without retaining or disclosing its response or address. Provider-state bytes and the
  timer mask remained unchanged. No authenticated provider request was made after the
  failed controlled rotation, during the fix, packaging, deployment, or postflight.
- The existing `resume-airvpn-final-dry-run` heartbeat was updated rather than duplicated.
  It is scheduled for 11:30 BST on 2026-07-16 and requires exact corrected bytes, every live
  safety postcondition, zero backoff, and one natural slot before exactly one controlled
  rotation with no retry. It keeps the timer masked and defers five-cycle observation,
  credential replacement, merge, tag, and publication to later reviewed stages.
- At the scheduled continuation, local branch `43d7077f60319df768c89e36afbcfcc872abc42d`
  was clean and DownloadVM matched every exact reviewed runtime/setup/systemd byte, including
  provider-helper SHA-256
  `d4d41226d3d77bee97f7994d221a3f1124f5b094a9db8fb423b1c6f2cacd0653`.
  The original active profile, immutable pre-managed snapshot, old-profile transaction
  backup, API configuration, and provider state matched their accepted digests. Source and
  installed credentials passed root-only regular-file mode/size metadata checks without
  being read. The timer and worker were inactive under the runtime mask; setup, interface,
  and global locks were free; recovery and staging artifacts were absent; `wg0` and
  qBittorrent were proved; policy was exactly `GB NL BE DE IE`; and all five policy countries
  remained in the current credential-free eligible inventory.
- The strict provider-state parser confirmed five active authenticated attempts, one natural
  rolling slot, two active exclusions, `failure_class=none`, zero backoff, and exact binding
  to fixed device `DownloadVM` and the installed credential metadata. The preflight read the
  ledger only for validation and aggregates; it did not reset, rewrite, bypass, or disclose
  any attempt epoch, exclusion name, or provider response.
- Exactly one `wg-healthcheck rotate wg0 --apply` invocation then consumed that slot. It
  returned success with the exact redacted manifest contract, and no retry was made. The
  active profile changed while private identity and local `Table` policy remained unchanged;
  the corrected composer preserved the installed absence of `DNS`. The immutable
  pre-managed snapshot was unchanged, and the secure transaction backup retained the exact
  old profile.
- Postflight proved the fixed recovered status and rotation records, one newly durable
  authenticated attempt, six active attempts, zero rolling slots, two active exclusions,
  and zero backoff. Provider-state SHA-256 is
  `66d1f14c2e288d5ba9475be9e8115c23e847574e9ed8d2085acffbbaed7e93bf`;
  accepted active-profile SHA-256 is
  `f44c0bc6e5ed5d690b5b23d42fbdec0816f3dcc11c9e05c289d95cd1327f8499`.
  Fresh single-peer handshake and tunnel-bound AirVPN egress checks passed without retaining
  their server, endpoint, address, profile, or provider response. qBittorrent retained the
  same immutable container identity and passed its configured TCP/UDP listener ownership
  proof. Candidate, pending, safety, setup-journal, snapshot, staging, and transaction temp
  artifacts were absent; locks were free; root-only key metadata remained valid; and timer
  and worker remained inactive under the runtime mask.
- Successful controlled rotation acceptance is complete. Five consecutive healthy timer
  cycles, fresh production-credential replacement, protected-main integration, release,
  tag, and publication remain deliberately unclaimed.
- The docs-only handoff passed `git diff --check`, all 19 public-documentation contracts,
  all 11 architecture contracts from a clean tracked Linux export, and pinned Gitleaks
  8.30.1 over the complete worktree with redaction enabled. No credential, provider payload,
  endpoint, address, server, or generated profile was added to the repository evidence.
- On 2026-07-17, a fresh redacted preflight found branch `8da7f710b453f620218949101a65dd18885d3c01`
  clean and DownloadVM still byte-identical to the accepted runtime and live state. Both
  credentials passed root-only metadata checks without being read. Timer/worker inactivity,
  the runtime mask, free setup/interface/global locks, cleared recovery/staging artifacts,
  active `wg0`, qBittorrent ownership, exact `GB NL BE DE IE` policy, current public country
  eligibility, strict provider state, zero backoff, and six naturally reopened rolling
  slots all passed. No authenticated request was made.
- To make failure recovery credential-free during the supervised observation, the exact
  reviewed health configuration was copied to a root-only runtime backup and atomically
  changed only from enabled managed rotation to `AIRVPN_ROTATE_ENABLED=0`. The standard
  timer was unmasked and started without persistent enablement. Five distinct one-minute
  service records then passed exactly as `healthy/all_checks_passed`. Every accepted cycle
  retained the active profile, private identity, absence of local DNS, immutable
  pre-managed snapshot, old-profile transaction backup and provider-state digests. The
  latter proves zero durable authenticated attempts. qBittorrent routing/listener ownership,
  its container identity, active tunnel state, clear recovery artifacts and free locks also
  passed throughout.
- The bounded cleanup stopped both units, restored the reviewed configuration byte-for-byte,
  removed its private runtime backup, and reinstated the runtime mask. The final
  credential-free, tunnel-bound `whatismyip` proof did not pass, so the overall Task 15 gate
  remains open and the proof was not retried. A separate read-only containment audit proved
  the exact configuration, profile, snapshots, provider state and provider helper; valid
  root-only key metadata; healthy final status; active `wg0`; proved qBittorrent binding;
  unchanged container provenance predating the cycle window; free locks; cleared artifacts;
  and masked inactive units. No provider response, egress address, server, endpoint, profile
  material, credential, attempt epoch or raw log was retained or disclosed.
- On 2026-07-18 the user stopped the egress-proof heartbeat before another proof was run.
  The automation was deleted rather than left active or repurposed. A final read-only VM
  check found the committed evidence branch clean; exact runtime/configuration/profile/
  snapshot/provider-state/helper bytes; exact API device and `GB NL BE DE IE` policy;
  valid root-only credential metadata without reading either key; runtime-masked inactive
  units; free locks; cleared recovery artifacts; healthy API-mode status; a fresh `wg0`
  handshake; and proved qBittorrent binding. No public or authenticated provider request,
  rotation, timer cycle, profile generation, ledger write, or runtime mutation occurred.
- The user subsequently confirmed that the root-only source file contains a new,
  never-shared production credential. A silent comparison found the installed credential
  already byte-identical to that source, with both paths still root-owned regular mode-0600
  files. The setup replacement path was therefore not invoked and no authenticated
  generator capacity was consumed. Neither credential content nor a derived identifier was
  printed, logged, or added to the repository.
- One fresh credential-free request was issued through `wg0` before production timer
  activation. Its private response was removed in guaranteed cleanup. The local acceptance
  wrapper required an ISO country code even though the reviewed provider helper deliberately
  emits a sanitized country display name when one is available, as its regression test
  confirms. The result could not be reconstructed after cleanup, so the attempt is recorded
  as inconclusive and was not retried. No provider response, egress address, server,
  endpoint, profile material, credential, or attempt epoch was retained or disclosed.
- A separate read-only containment audit then matched the accepted profile, health
  configuration, pre-managed snapshot, transaction backup, provider state, and provider
  helper digests. Both credentials passed strict metadata and silent equality checks;
  `wg0` had a fresh single-peer handshake; API policy was exactly fixed device `DownloadVM`
  and countries `GB NL BE DE IE` with managed rotation enabled; qBittorrent was proved;
  all locks were free; recovery and probe artifacts were absent; and the timer/worker were
  still inactive under the runtime mask.
- The runtime mask was removed and DownloadVM's own
  `wg-healthcheck@wg0.timer` was persistently enabled. Its immediate timer-owned check and
  a separate normal one-minute recurrence both completed exactly as
  `healthy/all_checks_passed`. After each observation the timer was enabled and active, the
  worker was inactive, qBittorrent and the tunnel remained proved, and observation artifacts
  were absent. The active profile, health configuration, rollback snapshots, transaction
  backup, and strict provider ledger retained their accepted digests. Both checks took only
  the healthy control path, so no authenticated generation or rotation path ran during
  activation. The deleted Codex heartbeat remains deleted and is operationally independent
  from this enabled VM timer.
- A later read-only snapshot, after further timer opportunity, still found the timer enabled
  and active, the worker idle, final status healthy, `wg0` active with a fresh single peer,
  and qBittorrent proved. Profile, configuration, both rollback copies, provider state, and
  provider-helper digests were exact; production-key metadata/equality and API policy were
  exact; and every acceptance/recovery artifact was absent. The evidence-only change passed
  `git diff --check`, all 19 public-documentation contracts, all 11 architecture contracts
  from a clean tracked Linux export, independent factual/secret review, and pinned Gitleaks
  8.30.1 over the current worktree with redaction enabled.
