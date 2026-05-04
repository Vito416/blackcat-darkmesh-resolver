# Resolver remote signed snapshot publication plan

Date: 2026-04-30
Status: D1 implemented and live

## Goal

Move from:

- local signed snapshot copied to each node by hand

to:

- one remote signed snapshot publication target
- many verify-only serving nodes fetching the same current signed artifact

without weakening the trust boundary.

## Design choice

For the first implementation, use `workers/async-worker` as both:

- signer
- remote publication surface

with a KV-backed active snapshot store.

That keeps the design simple:

1. control-plane builds unsigned `dm-hostmap-envelope.v2`
2. async-worker signs it
3. control-plane publishes signed envelope to async-worker
4. serving nodes fetch `GET /resolver/projection/current`
5. serving nodes verify + activate locally

## Endpoints

### Sign

- `POST /resolver/projection/sign`
- auth: `RESOLVER_SIGNER_AUTH_TOKEN`

### Publish

- `POST /resolver/projection/publish`
- auth: `RESOLVER_PUBLISH_AUTH_TOKEN`

### Fetch current

- `GET /resolver/projection/current`
- public
- safe because the payload is signed and contains no private signer secret

## KV storage model

The async-worker stores:

- `resolver-projection:current`
- `resolver-projection:meta`
- `resolver-projection:snapshot:<snapshotId>`

This is enough for:

- active fetch
- simple history lookup
- rollback by republishing a prior signed snapshot

## Why KV first

KV is good enough for this phase because:

- snapshot is small
- write frequency is low
- serving nodes poll on coarse cadence
- we want a small first step before more elaborate artifact storage

Later, if we need stronger rollout semantics or richer history retention, we can
move the artifact backing store to R2 or another publication layer without
changing the core trust model.

## Security posture

Important invariants still hold:

- private key remains off-node
- serving VPS remains verify-only
- publication auth is separate from public fetch
- serving node still independently verifies signature + expiry

So even if publication is misused, serving nodes should still reject invalid
artifacts.

## Current helper scripts

The current operator helper chain is:

1. `scripts/generate-projection-signing-material.py`
2. `ops/live-vps/local-tools/sign-projection-via-async-worker.sh`
3. `ops/live-vps/local-tools/publish-projection-via-async-worker.sh`

## Runtime cutover result

This phase is now live in the current reference serving-node production shape:

1. `workers/async-worker` stores the active signed snapshot in KV
2. joined serving node points `DARKMESH_PROJECTION_URL` to:
   - `https://blackcat-async-worker.vitek-pasek.workers.dev/resolver/projection/current`
3. node keeps `DARKMESH_PROJECTION_REQUIRE_SIGNED=1`
4. node verifies and activates from remote fetch

That removes the manual `scp` step without changing the verify-only trust
boundary.
