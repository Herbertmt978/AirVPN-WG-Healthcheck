# Todo Checkpoint: AirVPN API-Managed WireGuard Profiles

Updated: 2026-07-12

## TodoCheckpointDraft

- **Current todo:** implement Task 9's guided two-mode setup CLI and secret-input boundary
  over the accepted Task 8 administration commands.
- **Completed:** repository/API reconnaissance; approved design and MIT choice; reviewed
  16-task implementation plan; country-selection and recovery amendments; isolated
  worktree; Task 1 strict profile parsing and credential-free country discovery; Task 2
  canonical rendering, identity pinning, and forged-object redaction; Task 3 fixed-origin
  authenticated generation with descriptor-only secret/profile transport; Task 4 dual-mode
  CLI/config dispatch, trusted managed-module loading, and installed-key/FD isolation;
  Task 5 strict persistent API state, exact rolling attempt history, failed-server
  exclusions, fresh phase clocks, and descriptor-safe global serialization; Task 6 strict
  digest-bound v2 journal durability, factual crash classification, and v1 compatibility;
  Task 7 qBittorrent containment, identity-pinned full-profile switching, immutable Docker
  recovery, and durable safety-record rollback/finalization; Task 8 explicit lifecycle
  commands, redacted status, quiesced state reset, and unattended API-mode dispatch.
- **Completed evidence slice:** green Windows-compatible checks plus a complete Ubuntu
  24.04 container baseline, including POSIX modes and ShellCheck. Task 1 independently
  cleared specification and code-quality/security review. Task 2 cleared both reviews
  after two review-found boundary fixes. Task 3 cleared both reviews after four
  review-found generator boundary fixes. Task 4 cleared both reviews after descriptor and
  lock-contention corrections. Task 5 cleared specification and final quality/security
  review after rolling-window, clock, selector, rollback, output-collision, FD-alias, and
  credential-identity defects were reproduced and repaired. Task 6 cleared specification,
  adversarial durability, and quality/security review after artifact-fsync and classifier
  collision defects were reproduced and repaired. Task 7 cleared specification and
  adversarial security review after its provisional implementation was reopened twice and
  every reproduced fail-closed gap was repaired. Task 8 cleared specification,
  adversarial security, and code-quality review after six exact-SHA findings plus earlier
  live-review findings were reproduced and fixed without amending history.
- **Active slice:** Task 9 guided setup parsing and private secret transport.
- **Pending:** implementation Tasks 9-16 from the approved plan.
- **Evidence refs:** Task 8 commits `2089c78` and `82eb266`. Exact final-tree evidence:
  managed Linux 120/120 as root and 116/116 with four intentional root-only skips as a
  normal user; static/runtime 79/79; exact follow-up specification 20/20 plus 6/6,
  quality 15/15 plus 1/1, and security 14/14 plus 3/3 focused gates; Bash syntax,
  ShellCheck 0.11, JSON standard-library parsing, diff integrity, and Gitleaks over the
  tree and 44-commit history are green. Reviews proved provider-only FD inheritance,
  non-mutating dry-run orphan handling, single-epoch/non-incrementing preflight accounting,
  durable snapshot/reset retries, equal-endpoint crash-safe restore, root-0700 config
  ownership, fixed status redaction, and no managed-to-static failure fallback.
- **Blocked on:** nothing at this checkpoint.
- **Next step:** execute Task 9 RED-to-GREEN, then independently review TTY/file descriptor
  credential handling and country-choice semantics.

## ResumeStateHint

- Primary checkout: repository `main` at the public baseline.
- Implementation worktree:
  `C:/Users/Ashby/.config/aegis/worktrees/airvpn-wg-healthcheck/airvpn-api-profiles`
- Branch: `Herb/airvpn-api-profiles`
- Last accepted implementation commit: `82eb266`; the Task 8 checkpoint documentation is
  the next commit before Task 9 begins.
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
- **Complexity:** `libexec/airvpn-api` is 1,598 lines, `tests/test_airvpn_api.py` is
  2,263 lines, `bin/wg-healthcheck` is 1,656 lines, `libexec/wg-healthcheck-managed` is
  3,770 lines, and `tests/test_wg_managed_profiles.sh` is 6,257 lines. These exceed the
  plan's review threshold. Task 14's split/ownership decision remains mandatory and cannot
  be waived before release.
- **Evidence decision:** `continue` to Task 9; Tasks 1-8 are accepted, while release and
  live VM completion remain unclaimed.
