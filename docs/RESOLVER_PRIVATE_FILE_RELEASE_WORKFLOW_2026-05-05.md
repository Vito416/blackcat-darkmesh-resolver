# Resolver private file release workflow

Date: 2026-05-05
Status: preferred operator workflow

## Why this exists

We were intentionally moving away from public bearer-token operator flow.

That means the preferred steady-state release path should be:

- local signing material on the operator machine
- private/Tailscale SSH to the joined node
- signed snapshot copied to the node as a local file mirror
- joined node serving in verify-only mode from `file://...`

Not:

- public `resolver/control/*`
- public bearer-token release as the default path

## Preferred command

```bash
bash ops/live-vps/local-tools/projection-release-private-file.sh \
  --domains jdwt.fun,vddl.fun,blgateway.fun \
  --execute-live 1 \
  --ssh-target adminops@100.104.75.121 \
  --ssh-key ~/.ssh/darkmesh_new_vps_adminops \
  --switch-node-to-file-url 1 \
  --verify-node-state-url https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState
```

## What it does

1. builds a fresh `dm-hostmap-envelope.v2` locally from DNS + AR inputs
2. signs it locally with:
   - `~/.config/darkmesh/projection-signer-2026-q2/projection-signing-key.pem`
3. verifies it locally against:
   - `~/.config/darkmesh/projection-signer-2026-q2/projection-trust.json`
4. copies it to:
   - `/etc/darkmesh/projections/resolver-projection.active.v2.json`
5. optionally switches the joined node env to:
   - `DARKMESH_PROJECTION_URL=file:///etc/darkmesh/projections/resolver-projection.active.v2.json`
   - `DARKMESH_PROJECTION_REQUIRE_SIGNED=1`
   - `DARKMESH_DM1_AUTOBUILD=0`
6. starts `darkmesh-host-routing-sync.service`
7. optionally waits for node state to become `active`

## Important stance

This is the minimal-exposed-surface operator path.

It does **not** require:

- `RESOLVER_SIGNER_AUTH_TOKEN`
- `RESOLVER_PUBLISH_AUTH_TOKEN`
- `RESOLVER_CONTROL_AUTH_TOKEN`

Those variables still exist in compatibility tooling for the older async-worker
helper path, but they are no longer the preferred default for routine operator
releases.

## When to still use the async-worker helper path

Only when you intentionally want the older helper/distribution flow:

- worker-side signing
- worker-side publication
- explicit private `resolver/control/*` usage

That path is still supported, but it should be treated as compatibility
automation, not the cleanest operator baseline.
