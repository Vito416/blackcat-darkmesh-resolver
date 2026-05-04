# Resolver signed projection verification plan

Date: 2026-04-30
Status: design proposal
Priority: P0 security + rollout safety

## 1) Why this matters now

Right now the projection-backed runtime path works, but trust is still softer than
it should be.

Current situation:

- `ops/live-vps/runtime/scripts/build-host-routing-envelope-from-dm1.sh` can emit
  an envelope with fields like `signedBy`, `signatureAlg`, `signature`,
  `generatedAt`, `expiresAt`.
- `ops/live-vps/runtime/scripts/sync-nginx-host-routing.sh` currently checks:
  - shape,
  - signer allowlist,
  - freshness / expiry at a basic level,
  - and then activates the snapshot.
- `ops/live-vps/runtime/scripts/darkmesh-resolver-read-adapter.py` currently reads
  the local state/envelope files and trusts them without doing its own
  cryptographic verification.

That is good enough for bootstrap.
It is not good enough for the long-term resolver authority model.

## 2) Security objective

We want a node to activate a host-routing snapshot only when all of this is true:

1. envelope shape is valid
2. signer identity is recognized
3. signature verifies against the canonical payload
4. snapshot is not expired
5. snapshot hash matches the activated content
6. activation is monotonic enough to reject stale rollback unless explicitly allowed

In one sentence:

- **unsigned or unverifiable projection must never become active authority**.

## 3) What the current code does and does not do

## 3.1 Builder

`ops/live-vps/runtime/scripts/build-host-routing-envelope-from-dm1.sh`

Today it can emit metadata fields, but in bootstrap mode they are effectively
placeholders:

- `signedBy=bootstrap-local`
- `signatureAlg=bootstrap-none`
- `signature=bootstrap`

So today the builder is envelope-capable, but not yet a real signer.

## 3.2 Host-routing sync

`ops/live-vps/runtime/scripts/sync-nginx-host-routing.sh`

Today it already has the right place in the flow to become the verifier because
it is the thing that decides whether a snapshot becomes active.

That is exactly where fail-closed activation should live.

## 3.3 Read adapter

`ops/live-vps/runtime/scripts/darkmesh-resolver-read-adapter.py`

Today it trusts whatever is already in the local state/envelope files and exposes
resolver decisions off that data.

That means:

- the adapter is not the place where primary activation trust should happen,
- but it still should refuse to serve from locally marked-invalid state.

So verification should be **centralized at activation time**, and adapter should
only serve from a projection that has already been marked valid.

## 4) Recommended trust model

## 4.1 One verifier of record

Primary verification should happen in:

- `sync-nginx-host-routing.sh`

Reason:

- it is the activation gate,
- it already owns state transitions,
- it already writes fail-closed snippets,
- it is the narrowest place to stop bad snapshots before they influence routing.

## 4.2 Adapter behavior

The adapter should not try to become a second full verifier.
Instead it should:

- read verifier outcome from local state,
- refuse to serve `allow` decisions when projection state is invalid/stale/failed,
- surface explicit denial reasons.

That keeps logic simpler and avoids dual verification drift.

## 4.3 Verification input

Verification should operate on one canonical object:

- the **envelope JSON exactly as fetched/generated**, after normalization rules are
  defined and frozen.

Do not sign ad-hoc derived snippets.
Do not sign nginx output.
Sign the logical envelope payload.

## 5) Proposed signed envelope contract

We should move to a stricter envelope contract.

Required top-level metadata:

- `version`
- `generatedAt`
- `expiresAt`
- `signedBy`
- `signatureAlg`
- `signature`
- `snapshotId`
- `sequence`
- `payload`

Recommended additions:

- `keyId`
- `payloadHash`
- `previousSnapshotHash` (optional, useful later)
- `issuedByNode` or `issuedByResolver`

### Canonical payload fields

Inside `payload` we should require at minimum:

- `entries`
- `cacheHints` or equivalent timing hints
- `source` metadata
- `authority` metadata

### Entry fields

Each entry should be explicit, normalized, and boring:

- `host`
- `enabled`
- `targetType`
- `targetPid` or `targetTx`
- `pathPrefix`
- `cfgTx`
- optional `siteId`
- optional `nodePool` later

## 6) Canonical signing rule

The signature must be computed over a canonical JSON form.

That means we need a frozen normalization rule such as:

1. UTF-8 JSON
2. stable key ordering
3. no insignificant whitespace
4. normalized field casing
5. normalized host casing
6. normalized path prefix representation

If we do not freeze canonicalization, we will create verifier drift across nodes.

## 7) Signature algorithm recommendation

Recommended near-term choice:

- `ed25519`

Why:

- simple
- fast
- easy to verify on small VPS nodes
- good tooling

Suggested fields:

- `signatureAlg: "ed25519"`
- `keyId: "darkmesh-projection-key-2026-q2"`

Verification inputs:

- canonicalized envelope payload bytes
- public key selected by `keyId`

## 8) Key distribution model

Each node should have a local trust manifest containing:

- allowed signer ids
- allowed key ids
- public keys
- activation policy flags

Example local trust config:

- `/etc/darkmesh/projection-trust.json`

Suggested contents:

- `allowedSigners`
- `keys`
- `requireExpiry`
- `maxFutureSkewSec`
- `maxPastAgeSec`
- `allowRollback`
- `minSequence`

This is better than only a comma-separated signer allowlist env var.

## 9) Exact activation workflow we should implement

Target flow for `sync-nginx-host-routing.sh`:

1. fetch or autobuild candidate envelope
2. parse and extract canonical envelope
3. validate schema/shape
4. validate signer identity
5. validate time window:
   - `generatedAt` not too far in future
   - `expiresAt` present and not expired
6. canonicalize payload
7. verify signature using trusted `keyId`
8. verify `payloadHash` if present
9. verify sequence monotonicity:
   - reject lower sequence unless explicit rollback mode
10. write verified envelope to cache
11. mark state as `active`
12. update nginx snippet
13. reload nginx

If any step fails:

- do **not** activate candidate
- keep last known good if it is still within LKG policy
- otherwise fail closed

## 10) State machine we should adopt

Suggested `state.json` modes:

- `active`
- `stale_lkg`
- `invalid_signature`
- `invalid_shape`
- `expired`
- `rollback_rejected`
- `fetch_failed`
- `bootstrap_unverified`
- `fail_closed`

Important point:

- adapter and operational tooling should read these explicit states,
- not infer health indirectly.

## 11) Last-known-good policy

We should keep LKG support, but tighten it.

Recommended rule:

- if fresh verified envelope fails to fetch,
- and previous verified envelope is within bounded LKG age,
- continue serving from LKG with explicit `stale_lkg` state,
- otherwise fail closed.

Important:

- **unsigned bootstrap should never count as durable LKG** once real signed mode is enabled.

## 12) Bootstrap mode vs production mode

We should support two explicit modes, not one fuzzy one.

### Bootstrap mode

- unsigned allowed
- for local demos / first install only
- loud state label: `bootstrap_unverified`
- production docs should treat this as temporary

### Production mode

- signed envelope required
- expiry required
- trusted signer/key required
- rollback policy enforced

That gives us a clean migration path.

## 13) Adapter fail-closed behavior

`darkmesh-resolver-read-adapter.py` should read verifier state and enforce:

- if mode is not `active` or `stale_lkg`, then deny
- if state reason is signature/expiry/shape failure, do not serve stale allow
- surface a clear reason code such as:
  - `DENY_FAIL_CLOSED_PROJECTION_INVALID_SIGNATURE`
  - `DENY_FAIL_CLOSED_PROJECTION_EXPIRED`
  - `DENY_FAIL_CLOSED_PROJECTION_INVALID_STATE`

This keeps public behavior understandable and auditable.

## 14) Multi-node / future load-balancing implications

This signed projection model is exactly what we want before scaling out.

Because later we can:

- generate one signed projection
- distribute it to many low-cost VPS nodes
- let each node verify locally
- keep user DNS stable
- move balancing behind Cloudflare tunnel / load balancer

That is enough for the next scaling phase by itself.

It does **not** require resolver-side pool awareness on day one, because:

- edge/LB can choose the healthy node first,
- resolver on that node only needs to answer `host -> authority`,
- all nodes can stay symmetric as long as they share the same verified
  projection snapshot.

Without signed projection verification, multi-node fanout becomes a trust mess.

## 15) Immediate implementation backlog

### P0

1. define canonical envelope schema v2 for signed mode
2. add trust manifest file format
3. add canonicalization helper (probably Python or small standalone verifier helper)
4. add signature verification step to `sync-nginx-host-routing.sh`
5. add explicit invalid/expired states to `state.json`
6. make adapter deny on invalid projection state

### P1

1. add sequence / rollback controls
2. add `payloadHash`
3. add bootstrap vs production mode switch
4. add smoke tests for:
   - bad signature
   - expired envelope
   - stale-but-allowed LKG
   - rollback rejection

### P2

1. signed projection distributor workflow for multiple nodes
2. trust-key rotation workflow
3. tie projection metadata into future node-pool resolver v2 model

## 16) Recommended implementation split

To keep things maintainable:

- `build-host-routing-envelope-from-dm1.sh`
  - builds logical envelope
- new signer/verifier helper
  - canonicalizes + signs/verifies envelope
- `sync-nginx-host-routing.sh`
  - activation gate
- `darkmesh-resolver-read-adapter.py`
  - serves only from already-verified activation state

That is the clean split.

## 17) Bottom line

The resolver already has the right architecture direction:

- authority separated from serving,
- projection cache in the middle,
- stock HB compatibility preserved.

The missing hardening step is to make projection activation cryptographically
real.

That should be our next security milestone.
