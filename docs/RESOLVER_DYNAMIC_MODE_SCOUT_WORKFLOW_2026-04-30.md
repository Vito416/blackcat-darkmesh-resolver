# Resolver dynamic mode scout workflow

Date: 2026-04-30
Status: D2 scaffold

## Goal

Before we automate refresh/admission/release loops, we want one safe scout step
that tells us:

- whether shared signed projection is in sync,
- whether joined nodes are healthy and active,
- which refresh/admission surfaces are already exposed,
- and whether a dry-run release candidate can be prepared cleanly.

## Script

- `ops/live-vps/local-tools/dynamic-mode-scout.sh`

This script is intentionally:

- read-only,
- non-destructive,
- and safe to run before any future D2 automation.

## What it checks

1. worker active shared signed snapshot
2. joined-node resolver state
3. joined-node DNS refresh state
4. optional probe status for:
   - `GetAdmissionState`
   - `ListHostsDueForDnsRefresh`
   - `ForceDnsRefreshHost`
5. optional AO-native readback summary from:
   - `ops/live-vps/local-tools/fetch-ao-control-state-via-aoconnect.mjs`
6. optional release dry-run via `projection-release.sh`

The next optional companion step is:

- publish the resulting scout summary into the worker control-plane surface via
  `ops/live-vps/local-tools/publish-control-state-via-async-worker.sh`
- optionally merge raw AO-derived handler outputs into that published control
  state:
  - `GetAdmissionState`
  - `ListHostsDueForDnsRefresh`
  - `GetDnsRefreshState`

## Why it helps

This gives us one place to see:

- what is already safe/readable on the current surface,
- what still needs a stronger control-plane contract,
- and whether the release side of D2 is ready even before the mutation side is.

Once the AO producer exists, the scout report stops being the only input:

- scout stays the cheap readiness probe,
- AO-derived files replace placeholder `404` summaries for admission / due-host
  state,
- and the worker control-plane stays helpful without becoming a new truth
  authority.

## Example

```bash
export RESOLVER_SIGNER_AUTH_TOKEN=...

bash ops/live-vps/local-tools/dynamic-mode-scout.sh \
  --worker-base-url https://blackcat-async-worker.vitek-pasek.workers.dev \
  --worker-projection-url https://blackcat-async-worker.vitek-pasek.workers.dev/resolver/projection/current \
  --aoconnect-report /tmp/dm-aoconnect-contract-dyi/ao-control-state-aoconnect-report.json \
  --domains jdwt.fun,vddl.fun,blgateway.fun \
  --release-dry-run
```

Notes:

- the neutral flag is now `--worker-projection-url`
- the live default path still stays `GET /resolver/projection/current`
- we are not adding `/resolver/projection/active` to live infrastructure by
  default in the current minimal-surface posture

When `--aoconnect-report` is provided, the scout report also carries:

- `readiness.aoReadHealthy`
- `readiness.aoReadPayloadAvailable`
- `aoNativeReadback.summary`
- per-action `aoNativeReadback.actions[*].readContract`

That keeps AO-native transport/runtime health visible even when the current
runtime still only yields `runtime_effect_only`.
