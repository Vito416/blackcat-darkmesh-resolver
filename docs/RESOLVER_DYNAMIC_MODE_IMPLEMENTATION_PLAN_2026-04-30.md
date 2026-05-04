# Resolver dynamic mode implementation plan

Date: 2026-04-30
Status: D1 live, D2 next

## Definition

"Dynamic mode" means the resolver control-plane can move from:

- claim
- proof / refresh evidence
- admission decision
- signed projection publication
- verified activation

with much less manual operator glue than today.

It does **not** mean per-request dynamic trust.

We still want:

- slow-changing signed host authority snapshots
- fast-changing content/runtime behind that authority

## What already exists in the AO resolver

The canonical AO resolver source already contains a substantial amount of the
state machine we need.

Present today in `ao/resolver/process.lua`:

- host resolution entrypoints
  - `ResolveHostForNode`
  - `ResolveRouteForHost`
- refresh state inspection
  - `GetDnsRefreshState`
  - `ListHostsDueForDnsRefresh`
- challenge + proof flow
  - `IssueDnsRefreshChallenge`
  - `ApplyDnsRefreshResult`
  - `ApplyHostPolicyFromProof`
  - `ForceDnsRefreshHost`
- admission controls
  - `SetAdmissionRule`
  - `RemoveAdmissionRule`
  - `GetAdmissionState`
- queue/meta internals
  - `refreshMeta`
  - challenge TTLs
  - refresh intervals
  - stale refresh hints
  - bounded pruning / eviction logic

So the missing part is not raw mechanism. The missing part is operational
closure.

## Current gap

Today the live production shape is:

1. build unsigned projection
2. async-worker signs it
3. async-worker publishes the signed snapshot remotely
4. joined serving node fetches, verifies, and activates

That is secure and already covers the first dynamic publication step, but it is
not yet fully autonomous.

The missing automation layers are:

- who decides a new snapshot should be emitted
- who calls the signer
- who publishes the signed snapshot to nodes
- how multiple nodes receive the same new snapshot
- what rollback/degrade policy applies when publication fails

## Design constraints

Dynamic mode must preserve these invariants:

1. serving nodes stay verify-only
2. private signing key stays off-node
3. public read path stays non-mutating by default
4. host authority changes remain batchable and audit-friendly
5. resolver can fail closed without breaking unrelated content updates

## Phase D0 — current secure baseline

This is already done.

- async-worker signer exists
- serving node is verify-only
- signed `v2` projection activates correctly
- nginx map host authority works in production

## Phase D1 — operator-assisted dynamic publish

Goal: remove the manual scp/copy step while keeping operator-triggered control.

This phase is now live:

- async-worker has authenticated publish endpoint:
  - `POST /resolver/projection/publish`
- async-worker has public fetch endpoint:
  - `GET /resolver/projection/current`
- publication backing store is:
  - `RESOLVER_PROJECTION_KV`
- joined serving nodes point `DARKMESH_PROJECTION_URL` to that remote signed
  snapshot URL instead of `file://...`

Benefits:

- no more manual file copy to each VPS
- same signed snapshot can fan out to many low-end nodes
- serving nodes remain verify-only

Still manual at this phase:

- operator chooses when to publish
- operator/automation chooses sequence increments

## Phase D2 — proof-driven refresh automation

Goal: close the loop between AO refresh state and projection emission.

Recommended implementation:

- a control-plane runner consumes AO resolver refresh state:
  - call `ListHostsDueForDnsRefresh`
  - issue challenge where needed
  - gather DNS + AR proof evidence
  - call `ApplyDnsRefreshResult` / `ApplyHostPolicyFromProof`
- after successful AO-side mutations, control-plane rebuilds projection
- async-worker signs the new projection
- publication endpoint updates the active snapshot

At this phase the important rule is:

- AO process remains the authority for policy state
- async-worker remains signer, not admission brain
- serving nodes remain verify-only consumers

## Phase D3 — multi-node fanout and health-aware rollout

Goal: support many stock-HB nodes cleanly.

Recommended implementation:

- single signed snapshot version published centrally
- each VPS polls/fetches with normal verifier flow
- rollout metadata includes sequence + expiry only; not per-node mutations
- optional staged publish:
  - canary node(s)
  - global publish
  - rollback snapshot version

This phase still does **not** require pool-aware resolver host semantics if the
edge/load-balancer already chooses the node.

## Out of scope for dynamic mode

These things should stay separate from dynamic mode:

- tenant secret runtime behavior
- app business logic
- per-request dynamic target selection inside resolver host authority
- replacing edge LB with resolver-side infra balancing too early

## Concrete implementation backlog

### Must

1. define artifact naming/version rules for signed snapshots
2. add publication rollback story
3. add operator/control-plane audit log for:
   - sequence
   - signer
   - publication target
   - node activation evidence

### Should

1. add and use a small control-plane release script that:
   - builds unsigned projection
   - signs via worker
   - publishes artifact
2. add node-side smoke that proves new sequence activated
3. add signed snapshot history retention
4. add publication metadata endpoint or history listing endpoint

### Later

1. close-loop autonomous runner for AO refresh challenge/result flow
2. richer admission evidence bundle format
3. multi-node canary/staged rollout policies
4. optional control-plane dashboards for due-for-refresh and publication state

## Recommended next coding step

The cleanest next move is:

1. keep the current verify-only node + remote publication baseline intact,
2. automate the build -> sign -> publish chain for trusted operator flow,
3. only then automate AO refresh-to-publication.

That keeps the problem sliced in the safest order.
