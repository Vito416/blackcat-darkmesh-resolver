# Resolver current production truth

Date: 2026-04-30
Status: live production summary

## What is live right now

The current production resolver stack is now in this state:

- stock HyperBEAM remains the serving engine
- nginx host authority uses generated `map`, not `if ($host = ...)`
- the serving VPS is **verify-only**
- signed projection snapshots are **signed off-node** by `workers/async-worker`
- the VPS trusts only the public key in `projection-trust.json`
- the active projection is now fetched from the remote async-worker publication
  endpoint
- public resolver alias and public sites continue to work

The current live deployment happens to use one small VPS as the first reference
serving node, but that node is not special in the trust model.

## Trust boundary

The trust boundary is now the one we wanted:

- private signing key lives off-node in `workers/async-worker`
- the serving VPS does not hold the projection signing key
- the serving VPS only:
  - reads signed snapshot
  - verifies signature + expiry
  - activates local host-routing map

This means the resolver serving node is no longer able to mint new trusted
projection authority on its own.

Any other compatible joined node should be able to behave the same way if it
fetches the same signed projection and trusts the same public keys.

## Current serving shape

Operationally the resolver stack now looks like this:

1. tenant claim exists in AR + DNS
2. operator/control-plane builds unsigned `dm-hostmap-envelope.v2`
3. `workers/async-worker` signs it with off-node key
4. `workers/async-worker` publishes the signed snapshot for remote fetch
5. serving VPS fetches that snapshot from the worker
6. serving VPS verifies and activates
7. nginx + adapter expose deterministic routing/read decisions

That same shape should generalize to any future joined serving node.

## What is intentionally still manual

The current production model is secure, but still not fully autonomous.

These steps remain operator-assisted today:

- projection build trigger
- signed snapshot publication trigger
- trust manifest rotation
- key rotation sequencing

That is acceptable for the current phase because it keeps the serving node
verify-only while we finish the dynamic control-plane design.

## What is no longer true

These older statements are now obsolete as production truth:

- projection signing happens on the VPS
- resolver production depends on `DARKMESH_DM1_SIGN_WITH_PRIVATE_KEY`
- node-local autobuild signing is the desired steady state

Those were rollout shortcuts or bootstrap paths, not the target model.

## Current constraints

Even after the off-node signer cutover, the resolver is still not in full
"dynamic mode" yet.

What we have is:

- strong static authority activation
- signed projection portability across stock-HB nodes
- remote signed snapshot fanout from a single publication target
- fail-closed verification on the serving node

What we do not yet have is:

- end-to-end autonomous refresh publication
- automatic signed snapshot fanout
- closed-loop admission-to-activation automation

## Why this is a good stopping point before dynamic mode

This is the right foundation because dynamic mode should build on top of a safe,
audit-friendly static authority layer.

We now have that layer.

## Current live references

The current public publication endpoint is:

- `https://blackcat-async-worker.vitek-pasek.workers.dev/resolver/projection/current`

The current serving VPS fetches that endpoint via:

- `DARKMESH_PROJECTION_URL=https://blackcat-async-worker.vitek-pasek.workers.dev/resolver/projection/current`
