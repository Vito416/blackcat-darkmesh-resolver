# Resolver target architecture without central authority drift

Date: 2026-05-01
Status: target architecture note

## Goal

We want DarkMesh Resolver to avoid hidden central authority drift.

That means:

- no single VPS should be the source of truth
- no single worker KV should be the source of truth
- no nginx map or local file should be the source of truth
- joined serving nodes should be replaceable and reproducible

At the same time, we still want:

- low-latency serving
- deterministic host authority decisions
- safe fail-closed behavior
- scalable fanout to many low-cost HyperBEAM nodes

## The short answer

Yes, we can get very close to "no central authority except DNS + public onchain
state", but only if we separate:

- canonical truth
- from serving cache
- from release/distribution helpers

The right model is:

- DNS = ownership claim
- AR/AO = canonical resolver truth
- joined HB nodes = local deterministic serving cache
- worker/control-plane = helper, not truth

Important trust note:

- worker and joined nodes are mutually untrusted operational layers
- a worker-signed artifact is not authoritative just because it is signed
- joined nodes should eventually activate only after signature/freshness checks
  and AO-derived parity checks both pass

## What should be canonical

### 1) DNS claim plane

DNS should remain the canonical proof that a domain owner wants to join the
system.

Examples:

- `_darkmesh.<domain>` TXT
- optional challenge records for refresh / renewal proof

DNS is the right place for:

- domain ownership claim
- domain-to-config pointer
- refresh challenge response material

DNS is not the right place for:

- full operational state machine
- normalized routing tables
- joined-node rollout state

### 2) AR content/config plane

Arweave should remain the canonical place for tenant-published public config.

Examples:

- site config tx
- landing page tx
- public process references

AR is the right place for:

- immutable public configuration payloads
- content / target references
- public, auditable source material

AR is not the right place for:

- fast-changing operational queues
- per-refresh mutable challenge status

### 3) AO resolver state plane

AO should hold the canonical mutable resolver state machine.

This is the part that DNS alone cannot replace.

AO is the right place for:

- admission decisions
- normalized host policy state
- refresh metadata
- challenge issuance state
- proof application state
- due-for-refresh tracking
- monotonic sequence / mutation history

This means the long-term canonical truth is not:

- "whatever our worker last published"

but rather:

- "what the AO resolver process currently considers valid after DNS/AR proof evaluation"

## What should NOT be canonical

### 1) Joined node local projection

Local files such as:

- `resolver-projection.active.v2.json`
- nginx `map`
- adapter state

must stay derived serving artifacts only.

They are:

- disposable
- replaceable
- node-local

### 2) Async-worker KV

Worker KV is useful, but it should stay:

- publication cache
- release distribution layer
- control-plane observability surface

It should not become:

- the real source of admission truth
- the only place where due-host state exists

### 3) One specific serving VPS

The current small VPS is only:

- a reference joined node

It must not become:

- the authority node
- the only node that knows the latest truth

## The serving model we want

Public request path should stay simple:

1. request lands on a joined HB node
2. node reads local active projection
3. node returns deterministic decision quickly

Public request path should NOT do:

1. DNS lookup
2. AR fetch
3. AO read/compute
4. proof validation
5. authority mutation

for every request

That would be too slow and too fragile.

So the right split is:

- canonical truth is decentralized
- serving is locally cached

## Recommended layer model

### Layer A: Canonical inputs

- DNS TXT
- AR config
- AR content / process references

### Layer B: Canonical mutable resolver truth

- AO resolver process

This is where:

- proof is accepted or rejected
- host policy is normalized
- refresh status is tracked

### Layer C: Deterministic compiled projection

A projection snapshot is compiled from AO truth.

Important property:

- it should be reproducible from AO state

That means a snapshot publisher is allowed to help distribute it, but should not
be the authority that invents new truth.

### Layer D: Publication/distribution helper

This is where `workers/async-worker` fits.

Its job should be:

- sign/distribute snapshots
- publish current artifact
- expose control-plane summaries
- help operators and automation

But even there:

- signing proves who released the artifact
- it does not replace AO as the canonical truth source
- worker output remains distribution/helper state until a joined node verifies it

Its job should NOT be:

- own canonical admission state
- own canonical due-host queue

### Layer E: Joined serving nodes

Each compatible node:

- fetches the published snapshot
- verifies signature/freshness/sequence
- revalidates it against canonical AO-derived inputs in target mode
- activates it locally
- serves traffic

Any number of nodes should be able to do this the same way.

## How to avoid central authority drift in practice

### Rule 1: all real mutations go through AO

If something changes actual resolver truth:

- admission
- challenge outcome
- proof acceptance
- due-host refresh result

then it should land in AO first.

Not only in:

- worker KV
- local file
- node memory

### Rule 2: projection is compiled from AO truth

Projection should be treated as:

- a deterministic release artifact

not as:

- the original authority ledger
- "whatever the worker last published is true"

### Rule 3: publication can be replaceable

It should be possible to replace:

- current async-worker
- current KV
- current rollout helper

without redefining the truth model.

If another publisher can produce the same projection from the same AO truth,
then we are on the right track.

### Rule 4: joined nodes stay verify-only

Serving nodes should:

- never hold the private signing key
- never mutate canonical resolver truth on public request path
- never become silent hidden authorities
- never trust worker/control-plane output as the only activation gate

## What "update on call" should mean

If we say "update on call", there are two very different meanings:

### Bad meaning

"Every public request recomputes truth from DNS + AO."

We do not want that.

### Good meaning

"Certain background/control-plane actions refresh canonical truth and then
publish a new projection."

That is what we do want.

So updates should happen:

- in background loops
- in explicit control-plane runs
- in refresh/admission workflows

not:

- inside normal public serving requests

## What the worker should be allowed to do

The worker is still useful even in a low-central-authority design.

It can safely be:

- signer
- publisher
- summary surface
- release helper
- automation trigger surface
- authenticated relay for AO-derived state

It should not be:

- canonical state database
- hidden policy authority
- final trust anchor used by joined nodes

## Practical target state

### Near-term target

- DNS + AR stay tenant-controlled inputs
- AO holds canonical mutable resolver truth
- async-worker signs and publishes AO-derived projection
- joined nodes fetch and verify signature/freshness

### Later stronger target

- control-plane summaries are AO-derived and published through worker
- multiple publishers could publish the same AO-derived snapshot
- joined nodes validate not only signature/freshness, but also AO linkage and
  compiled payload parity before activation

## What this means for the next implementation steps

1. keep worker control-plane as helper only
2. move real admission/due-host truth into AO-first workflows
3. publish summaries into worker as derived state
4. keep public adapter narrow and serving-focused
5. treat joined nodes as cache/activation layer only

## Final recommendation

The best future-proof direction is:

- DNS for claim
- AO for truth
- worker for helper/orchestration/distribution
- joined HB nodes for deterministic cached serving

That gives us:

- low latency
- reproducibility
- multi-node scale
- and much less risk that one convenient component quietly turns into the real
  central authority.

For the concrete node-side trust boundary, see:

- `docs/RESOLVER_NODE_SIDE_VERIFICATION_WORKFLOW_2026-05-01.md`
