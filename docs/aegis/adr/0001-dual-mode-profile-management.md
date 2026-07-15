# ADR 0001: Dual-mode profile management ownership

Status: Accepted

Date: 2026-07-13

## Context

The project now supports two deliberately separate operating modes. Static mode preserves
an operator-owned single-peer WireGuard profile and can recover without an account
credential. API-managed mode uses one existing AirVPN device to generate a strictly parsed
profile for an eligible server, while preserving interface identity and containing
qBittorrent during every unverified switch.

This is root and network-control software. Its important boundaries are not merely code
organization: they decide which process may read an API key, which remote bytes can become
local configuration, which state owns recovery after a crash, and whether the existing
static path can remain credential-free. The v1.1 implementation also produced several
large review owners. Splitting the installed Bash runtime into dynamically sourced pieces
would make every fragment and parent directory a new root-code admission boundary, so line
count alone cannot justify that runtime design.

## Decision

### Product and component ownership

| Owner | Canonical responsibility | Explicit exclusions |
| --- | --- | --- |
| `libexec/airvpn-api` | HTTPS provider boundary, public inventory validation, country/server selection, authenticated generation, strict profile parsing/rendering, identity comparison, and redacted error classes | Local mutation, persistent retry state, device lifecycle |
| `bin/wg-healthcheck` | Stable CLI, descriptor capture and closure, static recovery, configuration admission, lock ordering, mode dispatch, and admission of one fixed managed module | Provider JSON/profile interpretation, managed transaction details |
| `libexec/wg-healthcheck-managed.d/*.bash` | Canonical review sources for managed state, provider-attempt orchestration, qBittorrent containment, profile effects, recovery, and administration | Runtime discovery or direct sourcing |
| `libexec/wg-healthcheck-managed` | Deterministically generated, sole installed and sourced managed runtime artifact | Canonical hand editing, fragment loading |
| `bin/wg-healthcheck-setup` and `libexec/wg_healthcheck_setup` | Operator choice, credential-free country discovery, private input, prospective validation, transactional application, and explicit timer decision | Routine timer execution or provider contract ownership |
| `install.sh` | Preflight, quiescence, inert upgrade guards, exact file modes, preserved operator data, ordered publication, and explicit enablement | Setup choices or runtime recovery |

The managed review sources have a fixed manifest and are concatenated by
`scripts/build-managed-module.sh`. `--check` proves the tracked runtime is byte-for-byte
current; `--write` is the only regeneration path. The builder does not discover fragments
with a glob. Fragments and the builder are repository development owners only: neither the
runtime, installer, nor curated runtime archive loads or installs them.

The installed admission boundary remains exactly
`/usr/local/libexec/wg-healthcheck/wg-healthcheck-managed`. The runtime validates that file
and its full fixed-path ancestor chain before sourcing it; the provider executable receives
the same ancestor validation before execution. Ancestors must be root-owned, non-symlink
directories and cannot be group/world writable unless a root-owned sticky directory (such
as `/tmp` in isolated tests) protects root-owned descendants. No configurable module path,
relative source, plugin directory, or fallback loader is introduced.

### Static compatibility

Static mode remains the default. With no v2 journal or managed safety record, a timer/check
run does not open an API-key file, load the managed artifact, inspect canonical source
fragments, invoke the builder, or make an authenticated request. A v1 endpoint-only marker
continues to use the built-in static reconciler. Static mode loads the managed artifact
only when a v2 journal or safety record already makes that owner necessary for fail-closed
reconciliation, or for the explicit observational `status` command that reports both mode
families without opening a credential or mutating state. A managed failure never falls
through to static endpoint mutation.

### Security and recovery ordering

Private credentials cross the runtime/provider boundary only on validated file
descriptors. Pre-provider children run with private descriptors closed, and the provider
receives only its fixed descriptor set. Generated profiles use a separate private output
descriptor and are parsed before local use.

The lock order is the administrative setup lease, the interface lock, then the global
authenticated-provider lock. A managed profile change stops and identifies the configured
qBittorrent container before tunnel mutation. The safety record is the crash owner across
the live switch; the journal describes phase and digests. Missing or contradictory proof
keeps qBittorrent stopped and preserves evidence rather than guessing.

### Device lifecycle

API-managed mode targets one existing, fixed AirVPN device. It may provision, adopt, or
refresh server/peer material only when the installed private key and interface address
identity remain compatible. It does not create, renew, replace, revoke, or delete a device,
and it does not allocate forwarded ports. Any device, address, or forwarded-port lifecycle
work requires a separately approved blue/green design covering every routing and consumer
dependency.

### Review-size exceptions and trigger

All new non-generated code owners are limited to 800 lines. The generated managed artifact
is exempt only while `scripts/build-managed-module.sh --check` proves exact fixed-manifest
equivalence. Three production files remain a frozen review-size exception for v1.1:

- `bin/wg-healthcheck` (2,214 lines), because splitting descriptor capture, static dispatch,
  and secure managed admission would add a source or process boundary to the static path;
- `libexec/airvpn-api` (1,718 lines), because splitting its isolated executable would alter
  the fixed private-descriptor, import, installation, and archive contract;
- `install.sh` (1,154 lines), because its inert-guard-to-final-launcher publication order is
  one linear rollback invariant.

These are ceilings, not growth allowances. A new command, persistent record version,
provider transport, installer artifact, device-lifecycle feature, or increase beyond a
frozen ceiling requires a new design decision before implementation. Tests are split into
bounded explicit units and do not receive an exception.

The Task 15 live-upgrade drill reopened the installer ceiling when a safe v1.0-era lock
blocked the reviewed v1.1 path. The accepted increase is limited to an FD-pinned migration
of the selected interface's root-owned, single-link, empty mode-`0644` lock after quiescence;
ordinary upgrades, setup guards, held locks, and every other interface remain strict.

The authenticated Task 15 acceptance then produced the same opaque transient result from
three distinct provider candidates. That live evidence reopened the provider-helper ceiling.
The initial accepted increase from 1,563 to 1,631 lines was limited to a four-value local
phase enum, classification at the existing transport/response/profile boundary, and one
hard-coded phase-only failure manifest. No provider text, new request, persistent field,
credential path, or
administrative command crosses the boundary. Malformed or additional child output is
discarded. The runtime streams raw helper stdout only through SHA-256, preserves the helper
and hasher statuses separately, and compares that digest with independently constructed,
newline-exact allowlisted manifests. This keeps NUL bytes and every other provider byte out
of shell variables while still rejecting any byte-level difference. The hasher executable
and its fixed-path ancestors are revalidated after every credential and candidate descriptor
is closed in that subprocess. A future provider feature still triggers extraction or a
superseding decision; this diagnostic exception is not a general growth allowance.

The next authenticated dry run exposed a different live compatibility boundary: the
trusted installed profile uses root-owned routing commands in repeated `PostUp` and
`PostDown` directives. Rejecting those local directives prevented identity pinning before
the authenticated request, while dropping them would have overwritten operator routing.
The accepted increase from 1,631 to 1,718 lines is limited to a private trusted installed
profile wrapper, strict extraction and redacted validation of those two directive names,
and a private pinned renderer. The public/provider `WireGuardProfile` model, parser, and
renderer remain hook-free. Provider `PreUp`, `PostUp`, `PreDown`, `PostDown`, `SaveConfig`,
peer hooks, and unknown directives are still rejected; trusted fd5 input still rejects
`PreUp`, `PreDown`, `SaveConfig`, peer hooks, and unknown directives. Existing 64-KiB,
64-line, and 1-KiB-line limits remain in force, each raw directive and its repetitions
retain exact installed text and order, and hook values are omitted from representations
and errors. This path is reachable only after the runtime validates the fixed profile as a
root-owned mode-`0600` regular file in its root-owned, non-symlinked mode-`0700` immediate
directory and supplies it on fixed fd5. No provider field can be reclassified as a trusted
installed hook. This compatibility repair does not authorize another helper increase or
relax the future extraction/superseding-decision trigger.

The first request that reached AirVPN used `system=linux` and was rejected at the response
boundary before profile parsing. Public AirVPN raw-configuration examples use
`system=other`, so the generator now requests that raw single-profile form. A second
backoff-compliant request using `system=other` reached the same response boundary. Both dry
runs left the profile, live interface, health configuration, and service state unchanged;
the persistent request ledger advanced within its cap and retained the failed-server
exclusions. The fixed origin, method, authentication header, remaining query parameters,
byte bounds, and strict archive/content rejection are unchanged. No response body or
complete header set was retained, so the rejected response's exact media type is
intentionally not asserted.

A third backoff-compliant request used the refined fixed reason contract and returned
`phase=response`, `reason=media_type`, again without changing the profile, configuration,
credential installation, timer, or live interface. A fourth implementation enabled the
exact `text/html` raw-text policy exception, but the live response returned the same
`media_type` reason with all state unchanged, so that unproductive exception is removed
rather than retained.

The next bounded contract advertises
`application/x-wireguard-profile, text/plain;q=0.9, */*;q=0.01` and explicitly requests
identity content encoding. The parameterless `application/x-wireguard-profile` response
type follows a publicly documented
[WireGuard-profile API convention](https://docs.eduvpn.org/server/v3/api.html), not a claim
about the discarded AirVPN header. The low-priority wildcard exists only in
request negotiation to avoid converting a supported but differently labelled response
into HTTP 406; parser acceptance remains exact. The existing byte bound, JSON-envelope
handling, strict WireGuard grammar, identity pinning, and expected-endpoint check remain
mandatory before any candidate write. HTML, download-specific, wildcard, archive, and
multipart response media types still fail closed.

That repeated result permits one narrower diagnostic: `phase=response` may add exactly one
local reason from `status`, `encoding`, `media_missing`, `media_multiple`, `media_invalid`,
`media_type`, `media_parameter`, `read`, `size`, `json`, or `protocol`.
The values classify only local control-flow branches. They reveal and retain no actual
status, header, URL, response bytes, device/server identity, credential-derived value, or
provider message, and they do not loosen the response or profile contract. API-managed
operation remains acceptance-blocked until a naturally permitted request with a fresh,
privately supplied key generates and validates a profile successfully.

AirVPN's wider API surface was reviewed before freezing this boundary. Version 1.1 uses
the credential-free `status` service for country/server selection, authenticated
`generator` only for a fixed device's profile, and credential-free `whatismyip` for
tunnel-bound egress proof. Read-only `userinfo` and `devices` responses contain account,
session, or device-identity data and are not part of unattended health checks. A future
setup-only device picker may consume a strictly reduced `devices` view, but create, renew,
revoke, delete, or automatic device switching still require the separate blue/green
identity design. `disconnect` is destructive, while `notification` and `dns_lists` have
different privacy and resolver owners; none is an implicit recovery action.

### Block-level review

The release review also found 13 production functions above the preferred 80-line block
size. They are the existing CLI/config/static-rotation/main dispatch owners; provider
profile parser and selector; setup API/static apply and snapshot transactions; and managed
state-load, authenticated-attempt, rollback, and profile-transaction state machines.
`tests/test_architecture.py` records their exact
current spans as frozen exceptions and rejects an unlisted oversized block or any span
change until its ceiling is reviewed and updated downward where possible. They remain
cohesive for v1.1 because their line order encodes one grammar or effect/rollback state
machine; splitting a function immediately before deployment would add parameter and
partial-effect boundaries without reducing runtime privilege. New branches or effects in
one of these blocks trigger extraction or a superseding decision.

## Rejected alternatives

- Runtime loading of `wg-healthcheck-managed.d`, glob sourcing, relative sourcing,
  configurable module paths, or a general plugin system: each expands root-code admission
  and makes partial installation an executable state.
- A Python rewrite of the recovery transaction for v1.1: it would replace a heavily tested
  crash and shell-effect boundary immediately before deployment rather than reduce risk.
- Automatic fallback from API mode to static recovery: it would silently change the
  selected product policy and can mutate the wrong profile after an authenticated failure.
- Automatic AirVPN device or key lifecycle: tunnel identity and forwarded-port consumers
  require a separate blue/green migration and revocation design.
- Accepting every oversized source/test owner indefinitely: review units are bounded now,
  and the three production exceptions have frozen ceilings and explicit retirement triggers.

## Consequences

Positive consequences:

- operators retain a simple static/no-key choice and an explicit API-managed choice;
- reviewers can inspect bounded canonical managed and test units without weakening the
  single installed trust boundary;
- CI detects generated-runtime drift, owner growth, accidental fragment loading, and stale
  architecture documentation;
- installation, package contents, systemd units, and VM migration keep their existing
  fixed paths.

Negative consequences:

- contributors must regenerate the managed artifact after changing a fragment;
- source review includes both fragments and a generated artifact, so equivalence checks are
  mandatory rather than optional;
- the three frozen production exceptions remain larger than the preferred review size and
  require a post-v1.1 design before their responsibilities can grow.

This decision does not itself claim VM acceptance or authorize publication. Those remain
separate gates requiring authenticated redacted testing, rollback proof, complete secret
scans, green CI on the exact merge SHA, and immutable release verification.
