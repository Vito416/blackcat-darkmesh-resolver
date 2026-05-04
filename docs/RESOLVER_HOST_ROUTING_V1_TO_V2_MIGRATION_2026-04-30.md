# Resolver host-routing v1 -> v2 migration

Date: 2026-04-30
Status: active migration plan

## Why this exists

Today the live host-routing sync path was built around:

- `dm-hostmap-envelope.v1`
- loose signer allowlist checks
- bootstrap-style metadata

We now also have:

- `dm-hostmap-envelope.v2`
- `scripts/projection-envelope-tool.py`
- trust manifest driven `ed25519` verification

We need a clean migration path that does not break current installs while we
switch producers and nodes over.

## Migration rule

- `v1` stays as compatibility/bootstrap format for the short term
- `v2` is the signed production target format
- nodes must be able to accept both during transition
- once all producers emit `v2`, nodes can switch to signed-only mode

## Runtime behavior by phase

### Phase 0 — legacy bootstrap only

Inputs:
- `dm-hostmap-envelope.v1`
- signer allowlist only

Node behavior:
- accepts `v1`
- no cryptographic verification
- suitable only for bootstrap / tightly controlled installs

### Phase 1 — dual-stack migration

Inputs:
- `v1` still accepted when `DARKMESH_PROJECTION_REQUIRE_SIGNED=0`
- `v2` verified through trust manifest + `projection-envelope-tool.py`

Node behavior:
- `v1` path keeps old bootstrap compatibility
- `v2` path requires:
  - trust manifest
  - verify helper
  - valid signature / payload hash / signer / key / time window
- `state.json` starts recording extra verification metadata when available

This is the current recommended migration mode.

### Phase 2 — signed-required rollout

Inputs:
- `v2` only

Node behavior:
- set `DARKMESH_PROJECTION_REQUIRE_SIGNED=1`
- reject `v1`
- reject unsigned or unverifiable `v2`
- fail closed after stale LKG window if no valid signed snapshot exists

This should become the default production posture after all projection producers
have switched.

## Current sync script behavior

`ops/live-vps/runtime/scripts/sync-nginx-host-routing.sh` now does this:

- parses direct envelope or AO-style response wrapper
- detects top-level envelope version
- for `v1`:
  - validates shape
  - validates basic freshness
  - checks signer allowlist
  - rejects if `REQUIRE_SIGNED=1`
- for `v2`:
  - validates shape
  - validates basic freshness
  - calls `projection-envelope-tool.py verify`
  - records key/sequence/payload verification metadata

## New env knobs

Recommended envs:

- `DARKMESH_PROJECTION_TRUST_MANIFEST=/etc/darkmesh/projection-trust.json`
- `DARKMESH_PROJECTION_REQUIRE_SIGNED=0`
- `DARKMESH_PROJECTION_VERIFY_BIN=/usr/local/sbin/projection-envelope-tool.py`

Meaning:

- `REQUIRE_SIGNED=0`
  - allow dual-stack migration mode
- `REQUIRE_SIGNED=1`
  - reject legacy `v1`
  - require signed `v2`

## Producer migration order

### Step 1
Keep current bootstrap producers alive.

### Step 2
Introduce `v2` envelope generation/signing in the projection producer.

Current builder support now exists in:

- `ops/live-vps/runtime/scripts/build-host-routing-envelope-from-dm1.sh`

Relevant flags:

- `--envelope-version v2`
- `--key-id <id>`
- `--sequence <n>`
- `--issued-by-resolver <id>`
- `--projection-tool-bin <path>`
- `--sign-with <private-key.pem>`

### Step 3
Run nodes in dual-stack mode:

- `REQUIRE_SIGNED=0`
- trust manifest installed
- verify helper installed

### Step 4
Confirm that all active projections are arriving as valid `v2`.

### Step 5
Flip nodes to:

- `REQUIRE_SIGNED=1`

### Step 6
Remove or archive the legacy `v1` producer path.

## Success condition

We are done when:

- production nodes activate only signed `v2`
- `v1` is no longer needed for normal rollout
- bootstrap mode stays available only as an explicit exception
