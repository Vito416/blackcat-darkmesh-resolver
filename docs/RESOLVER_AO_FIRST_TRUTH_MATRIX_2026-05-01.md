# Resolver AO-first truth matrix

Date: 2026-05-01
Status: target-state implementation note

## Why this exists

We want two things at once:

- no hidden central authority drift
- fast, reproducible serving on many joined HyperBEAM nodes

The clean way to get both is:

- keep canonical truth in DNS + AR + AO
- keep worker/KV/node state derived and replaceable
- treat worker and joined nodes as mutually untrusted operational layers

This document turns that into a concrete placement matrix so we can implement
`dynamic mode` without quietly making the worker or one VPS the real authority.

## The short version

- DNS proves who controls the domain
- AR stores tenant-published public config/content pointers
- AO stores the mutable resolver state machine
- async-worker signs/publishes summaries and projections as a helper
- joined nodes verify and serve from local cache

## Truth placement matrix

| Data / decision | Canonical home | Derived copies allowed? | Notes |
| --- | --- | --- | --- |
| Domain ownership claim | DNS | yes | `_darkmesh.<domain>` TXT and optional challenge records |
| Public site config pointer | DNS -> AR | yes | DNS points to config, config lives in AR |
| Public landing page / site target reference | AR | yes | Immutable tenant-published source material |
| Host admission accepted/rejected | AO | yes | Mutable, must not live only in worker or node |
| Normalized host policy | AO | yes | AO is the canonical mutable resolver truth |
| Refresh due state | AO | yes | Worker may expose summary only |
| Challenge issuance / proof status | AO | yes | DNS answers prove things, AO records the state machine |
| Monotonic sequence / mutation history | AO | yes | Needed to avoid drift/rollback confusion |
| Signed projection artifact | worker publication cache | yes | Not canonical truth; signature alone is not enough in target mode |
| Current published projection pointer | worker publication cache | yes | Replaceable distribution helper |
| Joined node active projection | node local file | yes | Pure serving artifact |
| Joined node activation state | node local state | yes | Operational fact, not global truth |
| Control-plane summaries | worker control namespace | yes | Helpful, but must be AO-derived and treated as untrusted helper output |

## What each layer is allowed to do

### DNS

Allowed:

- prove domain ownership
- point at tenant config
- answer refresh challenges

Not allowed:

- act as the full mutable resolver database
- store normalized host routing tables
- replace AO admission state

### Arweave

Allowed:

- hold tenant-published config
- hold immutable content or public process references
- provide auditable source material

Not allowed:

- be the fast-changing refresh queue
- be the mutable admission ledger by itself

### AO

Allowed:

- be the canonical mutable resolver state machine
- hold admission truth
- hold due-for-refresh truth
- hold proof/challenge outcomes
- drive deterministic projection compilation

Not allowed:

- be skipped in favor of "whatever the worker currently says"

### async-worker

Allowed:

- sign AO-derived projection artifacts
- publish current active shared signed projection
- expose authenticated control-plane summaries
- help operators run release/refresh workflows

Not allowed:

- invent canonical host truth
- become the only database for admission/due-host state
- become the only trust anchor a joined node uses before activation

### Joined HyperBEAM nodes

Allowed:

- fetch signed projection
- verify it
- revalidate it against canonical AO truth in target mode
- activate it locally
- serve requests from low-latency local cache

Not allowed:

- hold private signer keys
- mutate canonical resolver truth in public request path
- silently become authority nodes

## Request-path rule

Public requests should resolve from local active projection only.

That means the request path is:

1. request reaches joined node
2. node reads local active projection
3. resolver decision is returned immediately
4. content routing continues

It must **not** do all of this per request:

1. fresh DNS lookup
2. fresh AR fetch
3. fresh AO state reconstruction
4. proof validation
5. mutable state transition

That work belongs in background/control-plane flows.

## Background/control-plane rule

If something changes canonical resolver truth, it should flow like this:

1. DNS/AR/public evidence exists
2. AO evaluates and records the canonical mutable result
3. a projection is compiled from AO truth
4. async-worker signs and publishes the derived artifact
5. joined nodes fetch it from an untrusted distribution source
6. joined nodes verify signature + AO parity
7. joined nodes activate it

This keeps serving fast while keeping truth decentralized.

## What "dynamic mode" should mean

Good dynamic mode:

- AO-driven refresh/admission state changes
- signed projection releases triggered by changed AO truth
- joined nodes converging on the new projection

Bad dynamic mode:

- public requests mutating truth inline
- worker KV becoming the only admission database
- one reference VPS deciding what is true for everyone else
- nodes trusting worker output without independent AO-side verification

## Near-term implementation target

Phase D2 should move toward this:

1. `admissionSummary` becomes AO-derived
2. `dueHostsSummary` becomes AO-derived
3. control-plane read surfaces stay separate from public adapter
4. release/publication remains helper-only
5. projection compilation becomes explicitly "AO-first"

## Final recommendation

When we are unsure where a new piece of state belongs, use this test:

- Is it immutable tenant input? -> DNS or AR
- Is it mutable resolver truth? -> AO
- Is it signed/published helper state? -> worker
- Is it local serving/runtime state? -> joined node

If we keep following that split, DarkMesh Resolver stays:

- portable
- reproducible
- multi-node friendly
- and much less likely to drift into a disguised centralized system.

Related target workflow:

- `docs/RESOLVER_NODE_SIDE_VERIFICATION_WORKFLOW_2026-05-01.md`
