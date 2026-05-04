# Resolver node-side verification workflow

Date: 2026-05-01
Status: target trust-boundary note

## Why this exists

We need one rule to stay true even as the system grows:

- the worker is **not** the source of truth
- the serving HyperBEAM node is **not** the source of truth

Both sides are operationally useful, but each side is untrusted from the
other's perspective.

That means a joined node must never activate routing truth only because:

- "the worker published it"
- or "this specific VPS currently serves it"

Canonical truth must stay:

- DNS claim
- AR public config / target references
- AO mutable resolver state

## Core principle

Worker output may be:

- a transport artifact
- a cache
- a hint
- a release convenience

Worker output may **not** be the final trust anchor.

The final activation decision belongs on the joined node.

## Target activation flow

For every new projection candidate:

1. node fetches candidate projection from an untrusted distribution source
   - today that may be `async-worker`
   - later it could be any mirror
2. node verifies envelope integrity
   - schema version
   - signature format
   - signer allowlist / trust manifest
   - `generatedAt` / `expiresAt`
   - monotonic `sequence`
3. node derives or fetches canonical AO evidence
   - `GetAdmissionState`
   - `ListHostsDueForDnsRefresh`
   - `GetDnsRefreshState`
   - and any other host-policy inputs needed for compile parity
4. node deterministically recompiles or verifies the projection payload against
   AO truth
5. node activates only if:
   - signature is valid
   - snapshot is fresh
   - deterministic AO-derived verification matches
6. otherwise node:
   - keeps last-known-good
   - or goes fail-closed

## What the worker is allowed to do

Allowed:

- sign a release artifact
- host the latest published artifact
- provide authenticated operator summaries
- relay AO-derived control-plane state

Not allowed:

- invent admission truth
- invent due-host truth
- override AO-derived compile results
- become the only thing a node trusts before activation

## What the node must verify itself

At minimum:

- projection signature is cryptographically valid
- signer is in local trust manifest
- `sequence` is not a rollback
- `expiresAt` is still valid
- compiled host authority output matches canonical AO truth

In other words:

- signature proves *who released the artifact*
- node-side verification proves *the artifact matches truth*

Both are needed.

## Transitional vs target mode

### Transitional mode (today)

Today we are still partly here:

- worker hosts current signed projection
- joined node verifies signature/freshness
- full AO-side revalidation at activation is not finished yet

This is acceptable as a temporary operating mode, but it is **not** the final
trust model.

### Target mode

Target mode is:

- worker remains an untrusted helper
- node activation is guarded by AO-derived verification
- a compromised worker cannot silently change host authority

## Practical verification outputs

A joined node should eventually materialize verification results in local state
such as:

- `verification.mode = "ao_revalidated"`
- `verification.inputSequence`
- `verification.payloadHash`
- `verification.aoEvidenceHash`
- `verification.verifiedAt`
- `verification.reason`

That makes operator audit easier and lets us distinguish:

- valid signature only
- valid signature + AO parity verified
- rejected due to mismatch / rollback / stale evidence

## Recommended next implementation step

The next strong trust-model milestone is:

1. make `fetch-ao-control-state-via-aoconnect.mjs` reliably obtain canonical AO
   handler payloads
2. define deterministic projection compile inputs from that AO state
3. add node-side parity check before activation in the companion/runtime flow

That is the step that prevents the worker from becoming a hidden authority even
if it remains the publication transport.

## Current stepping-stone scaffold

Before full AO-side activation parity is finished, we now have a practical
joined-node scaffold for DM1-derived payload integrity:

- `docs/RESOLVER_DM1_PARITY_VERIFICATION_WORKFLOW_2026-05-01.md`

That gives us:

- signature/freshness verification
- plus local DNS + AR rebuild parity for the domains included in the projection

It is not the final AO-first trust model, but it is a meaningful improvement
over trusting the worker-signed artifact alone.
