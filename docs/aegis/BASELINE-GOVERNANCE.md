# Baseline Governance

## 1. Architecture Defect

A confirmed error, gap, or contradiction in the baseline itself.

- Fix the baseline first, then align implementation to the corrected baseline.
- Do not patch implementation around a defective baseline.

## 2. Architecture Drift

Implementation has deviated from a confirmed, correct baseline.

- Return to baseline via the simplest path.
- Do not update the baseline to match drift without explicit review.

## 3. Baseline Check Protocol

Before non-trivial changes:

1. Read the latest baseline snapshot in `baseline/`.
2. Compare current code structure against the ownership map.
3. Compare current contracts against the contract inventory.
4. Check for new anti-patterns not recorded in the known list.
5. Report: aligned, minor drift (self-correctable), or material drift (needs review).

## 4. Architecture Review — 7 Dimensions

After each non-trivial change:

1. **Ownership integrity** — every component has exactly one canonical owner.
2. **Module boundaries** — no unauthorized cross-module coupling.
3. **Contract changes** — all API, signature, and behavior changes are documented.
4. **Cascade proliferation** — no new cascading dependency chains.
5. **Dependency direction** — dependencies flow toward stability.
6. **Retirement completeness** — old owners, fallbacks, and paths are removed or scheduled.
7. **Entropy flow** — net complexity decreases or remains justified.

## 5. Hard Boundaries

- `BASELINE-GOVERNANCE.md` is the constitution for this project's Aegis workspace.
- Baseline snapshots in `baseline/` are evidence, not authority.
- ADRs in `adr/` record decisions; they do not replace baseline governance.
- This file is never auto-updated; changes require explicit user review.
