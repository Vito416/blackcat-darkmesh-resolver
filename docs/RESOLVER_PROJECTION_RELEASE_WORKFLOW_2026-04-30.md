# Resolver projection release workflow

Date: 2026-04-30
Status: D1 shared control-plane release workflow

## Goal

Provide one shared control-plane release step for resolver authority changes.

This is intentionally **not**:

- a per-VPS activator,
- a node-local signer,
- or a special operation tied to one machine.

It is a shared release flow for the signed authority snapshot that many joined
serving nodes can consume.

## Current release shape

The current D1 release flow is:

1. build unsigned `dm-hostmap-envelope.v2`
2. sign through `workers/async-worker`
3. verify the signed envelope locally against the trust manifest
4. publish it through `workers/async-worker`
5. confirm `GET /resolver/projection/current` now serves the new snapshot
6. optionally confirm joined nodes activated the new sequence

## Script

The current wrapper for that flow is:

- `ops/live-vps/local-tools/projection-release.sh`

It stitches together:

- `ops/live-vps/runtime/scripts/build-host-routing-envelope-from-dm1.sh`
- `ops/live-vps/local-tools/sign-projection-via-async-worker.sh`
- `ops/live-vps/local-tools/publish-projection-via-async-worker.sh`
- `scripts/projection-envelope-tool.py`

## Why this exists

Without this wrapper, the operator has to remember and run multiple manual
control-plane steps in the right order.

With this wrapper, the release unit becomes:

- one build/sign/publish action,
- one artifact directory,
- one release sequence bump,
- one optional activation proof across joined nodes.

That gives us a safer base before we automate the later D2 proof-driven loop.

## Safety defaults

The wrapper intentionally ships with two conservative defaults:

- `www` aliases are included by default, so we do not accidentally regress known
  public alias behavior
- if the newly built projection would remove or retarget existing host
  authority entries, the wrapper stops before publish unless the operator
  explicitly passes `--allow-routing-diff`

That makes it much harder to accidentally publish a destructive host-authority
change during normal releases.

## Important boundary

This release script does **not** make joined nodes special.

Joined nodes still remain:

- verify-only,
- fetchers of shared signed authority,
- local activators of nginx/adapter state.

The script only releases a new shared projection snapshot into the control
plane.

## Recommended usage

Minimal example:

```bash
export RESOLVER_SIGNER_AUTH_TOKEN=...
export RESOLVER_PUBLISH_AUTH_TOKEN=...

bash ops/live-vps/local-tools/projection-release.sh \
  --domains jdwt.fun,vddl.fun,blgateway.fun \
  --worker-base-url https://blackcat-async-worker.vitek-pasek.workers.dev
```

With joined-node verification:

```bash
bash ops/live-vps/local-tools/projection-release.sh \
  --domains jdwt.fun,vddl.fun,blgateway.fun \
  --worker-base-url https://blackcat-async-worker.vitek-pasek.workers.dev \
  --verify-node-state-url https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState
```

## What comes later

This D1 script is the right bridge to:

- CI-driven release jobs,
- AO refresh -> sign -> publish automation,
- and later D2 dynamic mode.

But today it should stay an explicit, audit-friendly control-plane step.
