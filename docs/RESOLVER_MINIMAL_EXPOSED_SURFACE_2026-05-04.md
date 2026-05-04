# Resolver minimal exposed surface

Date: 2026-05-04
Status: current operator stance

## Goal

Keep the DarkMesh resolver stack on the smallest practical public surface for
the current operator model.

We already have Tailscale access to the serving VPS, so operator actions should
default to private execution paths unless there is a concrete joined-node
distribution reason to keep something public.

## Current preferred split

### Public by design

These are acceptable public surfaces today:

- joined-node serving traffic
- public resolver alias reads needed for user traffic
- `GET /resolver/projection/current`

Why `GET /resolver/projection/current` stays public:

- joined nodes may need a stable internet fetch point for the signed snapshot
- the artifact is signed
- the artifact does not contain private secret material

### Operator-only by default

These should be treated as private/operator surfaces:

- projection release
- projection freshness guard
- joined-node smoke in admin mode
- control-state publish
- AO-native probe/readback tooling
- use of `resolver/control/*`
- signer and publish mutation flows

Current repo tooling for those flows lives under:

- `ops/live-vps/local-tools/`

and should be run from:

- a Tailscale-reachable operator machine,
- or an explicitly chosen operator runner,
- not as broad public automation by default.

## Immediate repo changes we made

To match that stance:

- `.github/workflows/resolver-projection-guard.yml` is now manual-only
  (`workflow_dispatch`) instead of scheduled
- guard docs now describe GitHub workflow usage as optional/manual
- control-plane docs now classify `resolver/control/*` as operator convenience,
  not a permanently exposed public plane

## What this means for auth tokens

Bearer tokens are still used where we currently have helper/operator endpoints,
but in this profile they are:

- access control for helper surfaces
- not source-of-truth authority
- and not a reason to keep public automation turned on

So the rule is:

- if an operation can run over Tailscale or a local operator path, prefer that
- only keep public-facing auth surfaces where distribution or interoperability
  truly requires them

## Current practical operator flow

Preferred today:

1. build/sign/publish from an operator host
2. use Tailscale/private access for guard and joined-node smoke
3. keep public fetch limited to signed projection distribution

## Next hardening step

If we want to tighten further after this:

1. stop relying on public `resolver/control/*` even for convenience
2. collapse operator reads back into Tailscale/local execution paths
3. leave the public worker surface with only signed projection distribution
