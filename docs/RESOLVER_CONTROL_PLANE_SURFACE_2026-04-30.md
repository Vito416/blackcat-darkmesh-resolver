# Resolver control-plane surface

Date: 2026-04-30
Status: first future-proof control-plane scaffold

## Decision

We intentionally do **not** grow D2 read/mutate surfaces inside the public
resolver adapter.

Instead, D2/control-plane behavior is moving into a separate authenticated
worker namespace:

- `workers/async-worker`
- `resolver/control/*`

That keeps the public resolver alias focused on:

- host authority decisions,
- projection state needed for serving,
- and safe read behavior for joined nodes.

Important trust note:

- this authenticated worker surface is an operator convenience layer
- it is not canonical resolver truth
- joined nodes must not treat control-plane responses as their only activation
  trust anchor

## Current control-plane endpoints

Current authenticated worker endpoints:

- `GET /resolver/control/capabilities`
- `GET /resolver/control/status`
- `GET /resolver/control/publication/current`
- `POST /resolver/control/state/publish`
- `GET /resolver/control/state/current`
- `GET /resolver/control/admission-summary`
- `GET /resolver/control/due-hosts-summary`
- `GET /resolver/control/dns-refresh-summary`

These are intentionally separate from:

- `GET /resolver/projection/current` (public signed artifact fetch)
- public resolver alias read endpoints on serving nodes

## Minimal exposed surface profile

For the current smaller-operator deployment model, the preferred split is:

- public:
  - `GET /resolver/projection/current`
  - joined-node serving/read surfaces that must answer user traffic
- operator-only:
  - projection release helpers
  - joined-node smoke in admin mode
  - control-state publish
  - AO readback probes
  - any `resolver/control/*` endpoint usage

That means `resolver/control/*` should be treated as an operator convenience
surface, not as something we rely on for permanent public automation.

In practice this also means:

- GitHub-hosted scheduled automation is intentionally disabled
- Tailscale/local operator execution is preferred for release/guard/smoke flows
- public exposure should be justified only by joined-node distribution needs

## Why this is the right boundary

Pros of this split:

- public serving plane stays narrow
- control-plane auth can evolve independently
- future D2 mutation endpoints have a natural home
- audit logs and permissions stay cleaner
- joined nodes remain verify-only

## What is still intentionally missing

These are not exposed yet in the control-plane surface:

- admission state fetch
- due-host refresh listing
- force refresh mutation
- challenge issuance
- apply refresh result

That is deliberate.

We want to add them carefully, under the control-plane namespace, instead of
leaking them through the public adapter by accident.

## Current state publication shape

The first control-plane summary publisher is:

- `ops/live-vps/local-tools/publish-control-state-via-async-worker.sh`

It consumes:

- `dynamic-mode-scout-report.json`
- optional AO-native readback summary embedded by the scout layer from
  `fetch-ao-control-state-via-aoconnect.mjs`
- optional raw AO-derived handler outputs:
  - `GetAdmissionState`
  - `ListHostsDueForDnsRefresh`
  - `GetDnsRefreshState`

and publishes a normalized:

- `resolver-control-state.v1`

artifact into the worker control-plane surface.

The normalized control-state artifact can now carry:

- `aoNativeReadbackSummary`
- per-surface `aoReadContract`

so operators can distinguish:

- true transport/runtime failure
- missing semantic payload
- and fully materialized AO-derived payloads

That artifact must remain:

- AO-derived when possible
- replaceable
- useful for operators
- but untrusted as a sole activation input on joined nodes

The AO-derived input contract is documented in:

- `docs/RESOLVER_AO_DERIVED_CONTROL_STATE_INPUTS_2026-05-01.md`
- `docs/RESOLVER_NODE_SIDE_VERIFICATION_WORKFLOW_2026-05-01.md`
