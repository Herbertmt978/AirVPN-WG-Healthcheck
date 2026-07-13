# Contributing

## Before opening a change

- Keep changes narrow and preserve the single-peer, fail-closed recovery model.
- Never commit real WireGuard configuration, AirVPN API keys, credentials, private keys, tokens, endpoint inventories, hostnames, private network layouts, generated profiles, or unredacted operational logs. Redact secrets before attaching any test evidence.
- Update the README and configuration example when behavior or accepted settings change.
- Add a focused regression test for every recovery, parsing, installer, or systemd behavior change.

## Verification

Run the complete checks documented in [README.md](README.md#development-checks) on Linux. Documentation changes must also pass `python3 -m unittest tests.test_public_docs -v`. Pull requests should pass the repository's GitHub Actions workflow.

## Review expectations

Changes that can restart WireGuard, mutate its configuration, or access Docker should explain failure behavior, rollback behavior, and the manual validation performed. Do not weaken root ownership, file-mode, HTTPS, timeout, or pending-transaction checks to make a test pass.

## Release discipline

Maintainers update `VERSION`, move changelog entries from `Unreleased` into a dated release, add matching notes under `docs/releases/`, and run `tests/test_release.sh`. Release tags are annotated and must point to the exact reviewed tree. `scripts/package-release.sh` builds the attached archives only from tracked Git content and emits `SHA256SUMS`; do not assemble public assets from an untracked working directory.
