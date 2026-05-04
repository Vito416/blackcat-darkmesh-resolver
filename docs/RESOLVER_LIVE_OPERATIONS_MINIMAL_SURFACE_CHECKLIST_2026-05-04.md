# Resolver live operations minimal surface checklist

Date: 2026-05-04
Status: practical day-to-day operator checklist

## Goal

Give operators one short checklist for what to use now that we are tightening
the exposed surface.

This is the practical counterpart to:

- `docs/RESOLVER_MINIMAL_EXPOSED_SURFACE_2026-05-04.md`
- `docs/RESOLVER_PRIVATE_OPERATOR_CUTOVER_CHECKLIST_2026-05-04.md`
- `docs/RESOLVER_CONTROL_SURFACE_USAGE_MAP_2026-05-04.md`

## Use these surfaces

### Public

Use public worker surface only for:

- `GET /resolver/projection/current`

Use public serving surfaces only for:

- user traffic
- joined-node public verification checks

### Operator-only

Use operator-only surfaces for:

- projection release
- projection guard
- joined-node smoke
- control-state publish
- optional explicit control-state read

Run those from:

- a Tailscale-reachable operator machine
- or another explicitly private operator environment

## Normal commands to use

### Release a fresh signed projection

```bash
export RESOLVER_SIGNER_AUTH_TOKEN=...
export RESOLVER_PUBLISH_AUTH_TOKEN=...

bash ops/live-vps/local-tools/projection-release.sh \
  --domains jdwt.fun,vddl.fun,blgateway.fun \
  --worker-base-url https://blackcat-async-worker.vitek-pasek.workers.dev \
  --verify-node-state-url https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState
```

### Run freshness guard

Without control-state helper read:

```bash
bash ops/live-vps/local-tools/projection-release-guard.sh \
  --domains jdwt.fun,vddl.fun,blgateway.fun \
  --worker-base-url https://blackcat-async-worker.vitek-pasek.workers.dev \
  --verify-node-state-url https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState
```

With explicit private control-state read:

```bash
export RESOLVER_CONTROL_AUTH_TOKEN=...

bash ops/live-vps/local-tools/projection-release-guard.sh \
  --domains jdwt.fun,vddl.fun,blgateway.fun \
  --worker-base-url https://blackcat-async-worker.vitek-pasek.workers.dev \
  --control-state-url https://<private-control-surface>/resolver/control/state/current \
  --verify-node-state-url https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState
```

### Run joined-node smoke

Without control-state helper read:

```bash
bash ops/live-vps/local-tools/joined-node-smoke.sh \
  --worker-current-url https://blackcat-async-worker.vitek-pasek.workers.dev/resolver/projection/current \
  --node-state-url https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState \
  --node-read-base-url https://hyperbeam.darkmesh.fun
```

With explicit private control-state read:

```bash
export RESOLVER_CONTROL_AUTH_TOKEN=...

bash ops/live-vps/local-tools/joined-node-smoke.sh \
  --worker-current-url https://blackcat-async-worker.vitek-pasek.workers.dev/resolver/projection/current \
  --control-state-url https://<private-control-surface>/resolver/control/state/current \
  --node-state-url https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState \
  --node-read-base-url https://hyperbeam.darkmesh.fun
```

### Publish control-state on purpose

Only when you explicitly want operator summaries refreshed:

```bash
export RESOLVER_CONTROL_AUTH_TOKEN=...

bash ops/live-vps/local-tools/publish-control-state-via-async-worker.sh \
  --worker-url https://<private-control-surface>/resolver/control/state/publish \
  --report /path/to/dynamic-mode-scout-report.json
```

## Do not use by default

Do not build routine operator flow around these:

- `GET /resolver/control/admission-summary`
- `GET /resolver/control/due-hosts-summary`
- `GET /resolver/control/dns-refresh-summary`

Those are convenience slices, not required health dependencies.

## Keep only as dormant debug helpers

These can stay available, but they should not be part of normal operations:

- `GET /resolver/control/capabilities`
- `GET /resolver/control/status`
- `GET /resolver/control/publication/current`

## Practical rule of thumb

If a step can be done:

- from Tailscale/operator shell tooling,
- without public `resolver/control/*`,

prefer that path.

If a step truly needs a public surface, it should justify itself the same way
`GET /resolver/projection/current` does: joined-node distribution, not operator
convenience.
