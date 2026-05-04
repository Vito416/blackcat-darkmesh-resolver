# Resolver DM1 parity verification workflow

Date: 2026-05-01
Status: target-mode node verification scaffold

## Goal

Keep signed projection publication useful **without** making the publication
worker the final trust anchor.

The joined node should eventually check two things before activation:

1. the signed envelope is fresh and cryptographically valid
2. the payload still matches canonical DNS + AR-derived DM1 inputs

This document covers step `2`.

## Current scaffold

Runtime helper:

- `ops/live-vps/runtime/scripts/verify-projection-dm1-parity.sh`

It:

- reads a candidate `dm-hostmap-envelope.v2`
- extracts `payload.source.domains`
- rebuilds a fresh DM1 projection locally from live DNS + Arweave inputs
- compares the rebuilt canonical payload hash to the candidate payload hash

If hashes match, the node has evidence that the published payload still matches
DM1-derived truth for the included domains.

## Why this matters

Signature alone proves:

- who released the artifact

DM1 parity proves:

- the worker did not silently rewrite host authority for the included domains

Together they are much stronger than signature-only activation.

## Important limit

This scaffold proves **included-domain integrity**, not complete ecosystem
coverage.

So today it is best thought of as:

- a strong protection against malicious rewrites
- not yet a full proof that no legitimate domain was omitted from a release

That is still a meaningful trust improvement for joined-node activation.

## Current integration hook

`sync-nginx-host-routing.sh` now supports an optional target-mode gate:

- `DARKMESH_PROJECTION_REQUIRE_DM1_PARITY=1`

Supporting env:

- `DARKMESH_PROJECTION_DM1_PARITY_BIN=/usr/local/sbin/verify-projection-dm1-parity.sh`
- `DARKMESH_PROJECTION_DM1_DNS_URL=https://dns.google/resolve`
- `DARKMESH_PROJECTION_DM1_AR_BASE=https://arweave.net`

When enabled:

- v2 signature verification must pass
- DM1 parity rebuild must pass
- only then does the node activate the new projection

## Example local check

```bash
curl -sS \
  https://blackcat-async-worker.vitek-pasek.workers.dev/resolver/projection/current \
  -o /tmp/current-projection.json

bash ops/live-vps/runtime/scripts/verify-projection-dm1-parity.sh \
  --envelope /tmp/current-projection.json
```

## Why this is only a step, not the end state

Long-term target mode is still broader:

- DM1 parity for included domains
- plus canonical AO-side evidence for mutable resolver state
- plus node-side activation logs that show both checks passed

So this scaffold is the first concrete node-side parity gate, not the final
AO-first verification model.

For that broader trust boundary, see:

- `docs/RESOLVER_NODE_SIDE_VERIFICATION_WORKFLOW_2026-05-01.md`
