# Resolver control-plane guard automation

Date: 2026-05-01
Status: practical D1.5 automation

## Goal

Keep signed resolver projections fresh without relying on somebody manually
noticing that `expiresAt` is getting too close.

This is intentionally still **control-plane automation**, not full dynamic mode.

## What we added

### 1) Freshness guard script

- `ops/live-vps/local-tools/projection-release-guard.sh`

It:

1. fetches current published projection from `async-worker`
2. checks the remaining validity window
3. optionally fetches authenticated control-plane AO health from
   `resolver/control/state/current`
4. skips publish if current snapshot is still healthy
5. otherwise runs `projection-release.sh`

### 2) Optional GitHub workflow

- `.github/workflows/resolver-projection-guard.yml`

It can run the guard on manual `workflow_dispatch` and upload the
decision/release artifacts as a workflow artifact.

In the current minimal-exposed-surface profile we intentionally do **not** keep
this workflow on a public schedule. If we want unattended runs later, that
should come back only behind an operator path we are comfortable exposing.

## Required GitHub secrets

The workflow expects:

- `RESOLVER_SIGNER_AUTH_TOKEN`
- `RESOLVER_PUBLISH_AUTH_TOKEN`
- `RESOLVER_CONTROL_AUTH_TOKEN`

These are the same control-plane tokens already used by the local release flow.

The script itself still keeps the control token optional for manual operator
use, but the GitHub workflow requires it so AO-native health is always part of
manual workflow runs too.

## Current default automation values

The workflow currently uses:

- worker base URL:
  - `https://blackcat-async-worker.vitek-pasek.workers.dev`
- domains:
  - `jdwt.fun,vddl.fun,blgateway.fun`
- `min-valid-sec = 1800`
- `release-ttl-sec = 86400`
- `refresh-cadence-sec = 300`
- `lkg-max-age-sec = 3600`

Meaning:

- if less than 30 minutes of validity remain, a new release is published
- new snapshots are published with roughly a 24 hour horizon

## Why this is useful

It closes the specific production failure mode we just hit:

- current signed projection expires
- joined node enters `fail_closed`
- public sites drop to `404`

The guard keeps that from depending on human memory.

With the control token present, the guard also records:

- `controlState.aoReadHealthy`
- `controlState.aoReadPayloadAvailable`
- `controlState.aoReadRuntimeEffectOnlyActions`

in `guard-decision.json`, so the freshness decision now carries live AO-native
read health too.

## What it does not do

This workflow still does **not**:

- make worker KV canonical truth
- make joined nodes special
- replace AO as the mutable resolver truth plane
- implement full AO-driven dynamic mode

It only protects the already-established D1 static authority layer.

## Why it is still future-proof

This is a safe intermediate layer because:

- the guard only decides whether to run a release
- the release still builds/signs/publishes a shared snapshot
- joined nodes remain verify-only
- canonical truth placement still stays:
  - DNS / AR inputs
  - AO mutable truth
  - worker helper/distribution
  - node local cache

## Recommended operator flow

### Normal operation

Run the guard from a Tailscale-reachable operator host, or invoke the GitHub
workflow manually only when you explicitly want the hosted runner to do that
work.

### Manual check

Use `workflow_dispatch` with:

- `dry_run = true`

when you want to inspect what the guard would do without publishing.

### Forced release

Use `workflow_dispatch` with:

- `force = true`

when you intentionally want to republish a fresh snapshot even if the current
one is still healthy.

## Next step after this

Once the freshness problem is safely automated, the next correct step is:

1. make `admissionSummary` AO-derived
2. make `dueHostsSummary` AO-derived
3. only then deepen D2 dynamic mode automation
