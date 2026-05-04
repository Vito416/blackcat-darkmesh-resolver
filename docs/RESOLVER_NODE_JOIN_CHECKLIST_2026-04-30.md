# Resolver node join checklist

Date: 2026-04-30
Status: practical checklist

## Goal

Bring a new stock-HB node into the DarkMesh Resolver serving set so it behaves
the same as existing joined nodes.

This is **not** a special "VPS activation" workflow.
It is a replication workflow for any compatible serving node.

## Preconditions

The joining operator has:

- a running stock HyperBEAM node,
- nginx in front of it,
- the DarkMesh Resolver companion pack installed,
- network access to the current signed projection publication URL,
- the current trust manifest public key(s).

## Node join checklist

1. Install the companion pack
   - use `ops/live-vps/runtime/install-stock-hb-companion.sh`
   - install helper scripts, nginx map config, adapter, and systemd units

2. Configure resolver trust
   - place the current `projection-trust.json` on the node
   - ensure the node has only public verification material, never the signer private key

3. Configure remote projection fetch
   - point `DARKMESH_PROJECTION_URL` at the shared publication endpoint
   - keep `DARKMESH_PROJECTION_REQUIRE_SIGNED=1`

4. Enable local activation loop
   - enable/start host-routing sync timer
   - ensure nginx reload path works
   - ensure resolver adapter reads projection state

5. Verify local state
   - projection mode should become `active`
   - envelope version should be `dm-hostmap-envelope.v2`
   - verification reason should be `ok`

6. Verify public behavior
   - resolve endpoint should return the same authority decision as existing nodes
   - mapped public sites should serve successfully
   - unmapped hosts should still deny correctly

Recommended helper:

- `ops/live-vps/local-tools/joined-node-smoke.sh`

Example:

```bash
export RESOLVER_CONTROL_AUTH_TOKEN=...

bash ops/live-vps/local-tools/joined-node-smoke.sh \
  --worker-current-url https://blackcat-async-worker.vitek-pasek.workers.dev/resolver/projection/current \
  --node-state-url https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState \
  --node-read-base-url https://hyperbeam.darkmesh.fun
```

If the control token is present, the smoke check also verifies that the live
control-plane AO-native read summary is healthy before comparing projection
sequence and public behavior.

## What makes joined nodes equivalent

Joined nodes should behave the same when they share:

- the same signed projection URL,
- the same trust manifest,
- the same companion/runtime contract,
- and the same stock-HB serving assumptions.

The node does **not** need to know anything special about another node.
It only needs to trust and activate the same signed authority snapshot.

## What DNS does

DNS or edge routing may point traffic to:

- one node,
- another joined node,
- or a load-balanced set of joined nodes.

That is fine.

Resolver correctness should come from:

- shared signed authority,
- not from one privileged origin machine.

## What this checklist deliberately does not do

This checklist does not:

- mint new authority,
- sign snapshots,
- change resolver policy,
- or decide which edge node should receive a request.

Those are control-plane concerns.

The joined node is only a:

- verifier,
- activator,
- and serving participant.
