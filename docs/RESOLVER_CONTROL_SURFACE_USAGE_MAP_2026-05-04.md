# Resolver control surface usage map

Date: 2026-05-04
Status: current practical usage map

## Why this exists

We wanted to stop treating `resolver/control/*` as a vague background surface
and write down what is actually:

- still required,
- only used manually,
- or currently just sitting there unused.

This is the concrete map behind the minimal-exposed-surface cutover.

## Current live dependency: keep public

### `GET /resolver/projection/current`

Status:

- actively used
- keep public

Why:

- joined serving nodes fetch the signed projection from here
- this is the only worker-side public distribution surface we still clearly
  need right now

Naming note:

- `current` here means the current shared active signed routing snapshot
- it does **not** mean one current site or one current page
- if we later tighten naming, `projection/active` is the cleanest compatible
  future alias
- the compatibility rollout is captured in
  `docs/RESOLVER_PROJECTION_ACTIVE_ALIAS_PLAN_2026-05-04.md`

## Current operator-only helper usage

### `POST /resolver/control/state/publish`

Status:

- operator-only
- still useful
- manual usage only

Where it is used:

- `ops/live-vps/local-tools/publish-control-state-via-async-worker.sh`
- README / AO-control-state docs examples

Current repo examples now treat that URL as a private/operator surface:

- `https://<private-control-surface>/resolver/control/state/publish`

Why it stays for now:

- it lets us publish normalized control summaries without turning them into
  public joined-node dependencies

### `GET /resolver/control/state/current`

Status:

- operator-only
- optional
- explicit usage only

Where it is used:

- `projection-release-guard.sh` only when `--control-state-url` is passed
- `joined-node-smoke.sh` only when `--control-state-url` is passed
- manual inspection

Important:

- no default public derivation remains in guard/smoke tooling
- this endpoint is no longer an implicit dependency

## Available but currently unused in active operator tooling

These endpoints still exist in the worker surface, but current resolver repo
tooling does not depend on them for normal release/guard/smoke behavior.

### Keep dormant for ad-hoc introspection

- `GET /resolver/control/capabilities`
- `GET /resolver/control/status`
- `GET /resolver/control/publication/current`

Why these are different:

- they are introspection-only
- they do not add new operator authority
- they can still be handy for one-off debugging if we explicitly choose to use
  them

### Best candidates to retire from normal active use first

- `GET /resolver/control/admission-summary`
- `GET /resolver/control/due-hosts-summary`
- `GET /resolver/control/dns-refresh-summary`

Why these are the first retirement candidates:

- they are thin convenience slices of the already-published control state
- current operator flow can already inspect the same information through
  `state/current` when needed
- they increase surface area without being required for serving health or
  current operator automation

Current evidence:

- they are documented in `docs/RESOLVER_CONTROL_PLANE_SURFACE_2026-04-30.md`
- there are no active helper scripts in this repo that require them for
  normal release/guard/smoke behavior

## Live VPS/operator config findings

Current grep across:

- `/srv/darkmesh`
- `/etc/systemd`
- `/etc/darkmesh`

showed:

- no runtime/service config references to `resolver/control/*`
- no persistent `CONTROL_STATE_URL` wiring on the VPS

That means the current serving node/runtime is not depending on worker control
endpoints to keep user traffic healthy.

## GitHub workflow findings

`.github/workflows/resolver-projection-guard.yml` is now:

- manual-only (`workflow_dispatch`)
- not on a public schedule

So hosted automation is no longer a standing public dependency either.

## Practical classification

### Keep public

- `GET /resolver/projection/current`

### Keep available, but operator-only

- `POST /resolver/control/state/publish`
- `GET /resolver/control/state/current`

### Good candidates to retire from normal active use

- `GET /resolver/control/admission-summary`
- `GET /resolver/control/due-hosts-summary`
- `GET /resolver/control/dns-refresh-summary`

The first three introspection endpoints are fine to leave dormant for now.

The three per-summary endpoints above are the stronger retirement candidates,
not because they are broken, but because current practical operator flow does
not need them to stay healthy and `state/current` already covers the same
material.

## Safe next live stance

For now, the safe operational posture is:

1. keep public projection distribution
2. run release/guard/smoke from Tailscale/operator hosts
3. treat `resolver/control/*` as optional helper surface
4. keep `capabilities`, `status`, and `publication/current` dormant only for
   ad-hoc inspection
5. retire the per-summary helper endpoints from normal active use first
