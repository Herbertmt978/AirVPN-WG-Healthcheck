# Aegis Engineering Workspace

This directory records durable design, architecture, planning, and verification
artifacts for changes whose security or operational impact is larger than an
ordinary patch.

- `baseline/` records the observed project structure and compatibility surface.
- `specs/` records reviewed requirements and design decisions before implementation.
- `plans/` records implementation plans derived from approved specifications.
- `adr/` records accepted durable architecture decisions when a change warrants one.
- `work/` may hold task-specific checkpoints and evidence for long-running changes.

Repository source, tests, the public README, and release notes remain the product
authority. These records explain why a change is shaped a particular way; they do
not replace executable tests or release verification.
