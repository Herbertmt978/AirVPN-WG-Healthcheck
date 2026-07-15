# Todo Checkpoint: AirVPN API-Managed WireGuard Profiles

Updated: 2026-07-14

## TodoCheckpointDraft

- **Current todo:** finish the bounded, body-validated generator compatibility candidate,
  verify and install its exact package without changing the download VM's static profile,
  then use the final naturally permitted authenticated dry run. If that dry run generates
  and validates an identity-pinned profile, wait for rolling-window capacity to reopen
  naturally before applying API mode; never reset or bypass the provider ledger.
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
  commands, redacted status, quiesced state reset, and unattended API-mode dispatch;
  Task 9 guided dual-mode setup, credential-free country selection, private credential and
  settings descriptors, prospective configuration validation, and redacted dry runs;
  Task 10 exclusive setup leasing, transactional config/credential persistence, strict
  crash journals and fixed staging, deterministic recovery/rollback, fresh health proof,
  timer commit ordering, and setup-only candidate cleanup; Task 11 exact managed-artifact
  installation, fail-closed live/quiesced upgrades, dual inert entrypoint publication,
  retained cross-instance locks, and signal-safe cleanup; Task 12 dual-mode public
  documentation, MIT licensing, exact country/setup guidance, and safe operator lifecycle;
  Task 13 synchronized v1.1.0 release owners, exact deterministic tar/ZIP packaging,
  Ubuntu 22.04/24.04 CI, installed-layout verification, and release/history secret scans;
  Task 14 canonical generated-runtime ownership, bounded source/test splits, architecture
  assertions, full-ancestor root trust validation, ADR acceptance, and exact-commit release
  verification.
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
  live-review findings were reproduced and fixed without amending history. Task 9 cleared
  setup and runtime specification, security, and quality review after TTY fallback,
  descriptor inheritance, pre-sanitization metadata, signal-handler inheritance, and
  nested-redirection cleanup defects were reproduced and repaired. Task 10 cleared
  specification and adversarial reviews after abandoned credential staging and impossible
  journal semantics were reproduced and fixed. Task 11 cleared specification/quality and
  adversarial security re-reviews after systemd-query, cross-interface, TOCTOU, partial-
  package, reentrant-lock, runtime-parent, dual-entrypoint, and signal-cleanup defects were
  reproduced and fixed. Task 12 cleared specification/usability and adversarial security
  review after unsafe persistent-mask rollback, unchecked installer failure, incomplete
  uninstall, missing prerequisites, stale anchors, and ambiguous `ALL` serialization were
  reproduced and corrected. Task 14 cleared independent architecture/security review after
  extensionless-owner, symlink-root, registry-completeness, generated-order, Bash-dialect,
  ADR-status, and full-ancestor trust gaps were reproduced and corrected. Task 15 preparation
  then preserved trusted installed `PostUp`/`PostDown` routing hooks without admitting
  provider hooks, tightened managed-profile parent permissions, and corrected the AirVPN
  generator request from OS-packaged output to the raw single-profile form. Provider-contract
  diagnosis then confirmed AirVPN's documented exact `result: "ok"` success rule and its
  current top-level `error`-only authentication envelope without making an authenticated
  request. The helper now rejects duplicate JSON keys and every ambiguous or contradictory
  envelope as a redacted transient response-contract failure. Release packaging now pins one
  immutable commit and remains reproducible on Ubuntu 22.04's Git 2.34 without relying on
  the newer `git archive --mtime` option; behavioral tests cover annotated tags and archive
  timestamps.
- **Active slice:** exact candidate `671f5e0` is installed and verified on the download VM
  in static mode with the timer runtime-masked and inactive. The active profile and health
  configuration retain their preflight digests, `wg0` remains active, and no API credential
  is installed. The root-only source credential remains outside the package and repository.
  Five backoff-compliant authenticated attempts reached HTTP success and failed closed at
  the response media boundary without mutation; the fifth proved that explicit
  `application/x-wireguard-profile` negotiation did not match the provider response. France
  has been removed from the default policy; the intended allowlist is now `GB NL BE DE IE`.
  Public working examples omit the undocumented `format=text` query and consume the body as
  a profile without documenting a success media type. The current test-first slice therefore
  removes that query and treats any otherwise valid media label not identified as HTML,
  multipart, or a known archive/compression type as advisory only. Bounded JSON handling and
  strict WireGuard, expected-endpoint, and identity checks remain authoritative before any
  write.
- **Pending:** implementation Tasks 15-16 from the approved plan.
- **Evidence refs:** France removal commit `a11dd5d`; exact installed candidate `671f5e0`;
  exact package hashes `45067ad284d3436e6f656ccc15c72f47b77a89dd6bb6be0d4003491f3ccf1ffc`
  for tar, `84183f7e94f7c71e805d8483c092174cb34b7f0cefd06c7a205014fc94b7fdc6`
  for ZIP. The authoritative `SHA256SUMS` digest is
  `69ed003aeb86a7e3aec6bc9ccb911b8ffbc065cb77a24d31f8115c663d632a9e`.
  Its native-Linux gate passed the complete Python, root/non-root health, managed, installer,
  release, Bash syntax, ShellCheck, systemd, and pinned-Gitleaks history/archive checks. The
  fifth dry run returned only `phase=response`, `reason=media_type`; all VM postconditions
  remained unchanged. The current compatibility RED failed only at the intended query/media
  assertions; its focused GREEN suite now passes, including HTML, ZIP, gzip, garbage, and
  JSON-envelope bodies under advisory labels with no writes on failure.
- **Blocked on:** the current compatibility candidate still needs exact native-Linux,
  package, and secret verification followed by quiesced installation. The
  persistent provider ledger records five of six rolling-window attempts and one available
  slot; the recorded backoff must reach zero naturally before another authenticated request.
  The ledger will not be reset or bypassed.
- **Next step:** commit the reviewed diff and run the exact Linux/package/secret gate,
  install that exact package with the timer still masked, recheck the five-country public
  inventory and provider backoff, then run one authenticated dry run. On success, preserve
  its validated result and wait for a rolling slot to reopen before identity-pinned API
  adoption and the later rotation/rollback/five-cycle drill.

## ResumeStateHint

- Primary checkout: repository `main` at the public baseline.
- Implementation worktree: isolated feature worktree outside the public checkout.
- Branch: `Herb/airvpn-api-profiles`
- Last installed implementation commit: `671f5e0`; its exact root/non-root Linux, release,
  reproducibility, workflow, and secret gates passed. The VM runs that byte-identical
  candidate in verified static mode with the timer runtime-masked and inactive.
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
- **Complexity:** the three reviewed production exceptions are `bin/wg-healthcheck` at
  2,214 lines, `libexec/airvpn-api` at 1,718 lines in the current slice, and `install.sh` at
  1,154 lines. The
  generated managed runtime remains one 3,935-line installed owner, assembled from nine
  fixed development fragments no longer than 693 lines. Provider tests use a 50-line
  compatibility loader plus bounded support/groups; health, managed, and installer runners
  are 133, 185, and 102 lines, with every split owner at or below 800 lines. Architecture
  tests enforce the exact owner exceptions, 13 reviewed long blocks, registries, encodings,
  symlink boundaries, and generated-source manifest.
- **Evidence decision:** `continue` within Task 15; deterministic, quiesced-install, safe
  failure-containment, key-removal, and static-routing evidence is accepted, while
  authenticated raw-profile success, live rollback/rotation, release, and API-mode VM
  migration remain unclaimed.
- **Accepted diagnostic candidate:** exact installed commit `671f5e0`; `phase=response`
  admits only the eleven fixed reason values recorded in the design. The next candidate
  removes the undocumented response-format query and makes a syntactically valid media
  label advisory after explicit HTML, multipart, known archive/compression, encoding,
  status, size, and JSON gates. It adds no persistent state or fallback and remains at the
  frozen provider ceiling; strict profile/endpoint/identity validation still authorizes
  every candidate. Focused provider/docs evidence and independent review are green; exact
  Linux, package, secret, and VM evidence remains the next gate.
