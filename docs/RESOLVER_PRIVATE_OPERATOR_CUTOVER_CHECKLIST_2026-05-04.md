# Resolver private operator cutover checklist

Date: 2026-05-04
Status: immediate hardening checklist

## Goal

Move day-to-day operator behavior onto the smallest practical surface:

1. stop relying on public `resolver/control/*`
2. run release/guard/smoke from a Tailscale-reachable operator host
3. only then decide whether some worker control endpoints should fade out of
   active use entirely

## Step 1 — stop relying on public `resolver/control/*`

Current repo defaults now help with that:

- `projection-release-guard.sh` no longer auto-derives a control-state URL from
  the public worker base URL
- `joined-node-smoke.sh` no longer auto-derives a control-state URL from the
  public projection fetch URL
- `.github/workflows/resolver-projection-guard.yml` is manual-only

Operational rule:

- if you want AO health from control-state, pass `--control-state-url`
  explicitly
- otherwise the flow should work without touching `resolver/control/*`

## Step 2 — run release/guard/smoke from a Tailscale operator host

Preferred operator posture:

- keep tokens on the operator host
- run shell helpers from a machine that already has Tailscale access to the
  serving node
- only use public worker projection fetch for joined-node distribution

Practical commands:

### Release

```bash
export RESOLVER_SIGNER_AUTH_TOKEN=...
export RESOLVER_PUBLISH_AUTH_TOKEN=...

bash ops/live-vps/local-tools/projection-release.sh \
  --domains jdwt.fun,vddl.fun,blgateway.fun \
  --worker-base-url https://blackcat-async-worker.vitek-pasek.workers.dev \
  --verify-node-state-url https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState
```

### Guard

```bash
export RESOLVER_CONTROL_AUTH_TOKEN=...

bash ops/live-vps/local-tools/projection-release-guard.sh \
  --domains jdwt.fun,vddl.fun,blgateway.fun \
  --worker-base-url https://blackcat-async-worker.vitek-pasek.workers.dev \
  --control-state-url https://<private-control-surface>/resolver/control/state/current \
  --verify-node-state-url https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState
```

### Joined-node smoke

```bash
export RESOLVER_CONTROL_AUTH_TOKEN=...

bash ops/live-vps/local-tools/joined-node-smoke.sh \
  --worker-current-url https://blackcat-async-worker.vitek-pasek.workers.dev/resolver/projection/current \
  --control-state-url https://<private-control-surface>/resolver/control/state/current \
  --node-state-url https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState \
  --node-read-base-url https://hyperbeam.darkmesh.fun
```

If you do not have a private control-state URL yet, omit that flag and treat AO
health as an operator-side optional check, not a required public dependency.

## Step 3 — decide whether to retire active use of worker control endpoints

After steps 1 and 2 are stable, decide whether any of these should remain part
of normal operator flow:

- `GET /resolver/control/state/current`
- `GET /resolver/control/admission-summary`
- `GET /resolver/control/due-hosts-summary`
- `GET /resolver/control/dns-refresh-summary`
- `POST /resolver/control/state/publish`

Current recommendation:

- keep them as helper/operator surfaces for now
- but stop treating them as always-on public automation inputs

That gives us a safer intermediate posture:

- public distribution remains available
- joined-node behavior still works
- operator tooling stays usable
- public control-plane dependence drops sharply

## What stays public even in this model

We still expect to keep:

- `GET /resolver/projection/current`

because joined nodes may need a stable public fetch point for the signed
projection artifact.

## Follow-up question to answer later

Once this operator cutover is routine, the next hardening decision is:

- keep authenticated worker control endpoints as rarely-used convenience tools
- or remove them from normal active use and collapse everything back into
  operator-host/Tailscale execution paths
