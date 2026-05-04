# Resolver signer/verifier implementation workflow

Date: 2026-04-30
Status: implementation next steps

This document turns the signed projection design into an execution checklist.

## 1) Files that should exist after this phase

### Schemas / examples

- `ops/migrations/schemas/dm-hostmap-envelope-v2.schema.json`
- `ops/migrations/schemas/dm-projection-trust-manifest.schema.json`
- `ops/live-vps/local-tools/signed-hostmap-envelope.v2.example.json`
- `ops/live-vps/runtime/etc/darkmesh/projection-trust.example.json`

### New helper

Helper path:

- `scripts/projection-envelope-tool.py`

Suggested subcommands:

- `canonicalize`
- `hash`
- `sign`
- `verify`

Status now:

- implemented with `ed25519` sign/verify support via Python `cryptography`
- bootstrap verification path is explicit and only passes when trust manifest
  allows `allowBootstrapUnverified=true` in bootstrap mode

## 2) Helper responsibilities

The helper should be boring and deterministic.

### `canonicalize`

Input:
- raw envelope JSON

Output:
- canonical payload JSON bytes/stdout

Rules:
- stable key ordering
- UTF-8
- no insignificant whitespace
- no derived nginx/path rendering
- operate on logical payload only

### `hash`

Input:
- canonical payload bytes

Output:
- `sha256:<hex>`

### `sign`

Input:
- unsigned or bootstrap envelope
- signing key
- key id
- signer id

Output:
- fully signed envelope v2

### `verify`

Input:
- signed envelope
- trust manifest

Output:
- machine-readable verify result
- non-zero exit on failure

Suggested result shape:

```json
{
  "ok": true,
  "snapshotId": "projection-2026-04-30T22-15-00Z",
  "sequence": 42,
  "signer": "darkmesh-resolver-mainnet",
  "keyId": "darkmesh-projection-key-2026-q2",
  "payloadHash": "sha256:..."
}
```

## 3) Activation wiring into host-routing sync

Main file to change:

- `ops/live-vps/runtime/scripts/sync-nginx-host-routing.sh`

### Current state

Today it validates:
- envelope version
- payload version
- signer allowlist
- generatedAt/expiresAt shape
- expiry ordering

### Next state

It should additionally:

1. require a trust manifest path
2. call verifier helper on candidate envelope
3. reject activation if verifier says no
4. record explicit failure reason in `state.json`
5. only then render nginx snippet + activate

## 4) Planned env/config additions

Suggested env additions for `resolver-projection.env`:

- `DARKMESH_PROJECTION_TRUST_MANIFEST=/etc/darkmesh/projection-trust.json`
- `DARKMESH_PROJECTION_REQUIRE_SIGNED=1`
- `DARKMESH_PROJECTION_ALLOW_BOOTSTRAP_UNVERIFIED=0`
- `DARKMESH_PROJECTION_VERIFY_BIN=/usr/local/sbin/projection-envelope-tool.py`

These should eventually replace the current loose signer-only gating as the
primary trust control.

## 5) Planned state machine changes

`state.json` should move toward explicit security states.

Recommended values:

- `active`
- `stale_lkg`
- `bootstrap_unverified`
- `invalid_signature`
- `invalid_shape`
- `expired`
- `rollback_rejected`
- `fetch_failed`
- `fail_closed`

Also record:

- `lastSigner`
- `lastKeyId`
- `lastSequence`
- `lastPayloadHash`
- `lastVerifiedAt`
- `lastVerificationReason`

## 6) Adapter changes after verifier lands

Main file:

- `ops/live-vps/runtime/scripts/darkmesh-resolver-read-adapter.py`

After sync becomes the verifier, adapter should:

- trust only `active` and `stale_lkg`
- deny all invalid verification states
- map invalid states to explicit deny codes

Examples:

- `DENY_FAIL_CLOSED_PROJECTION_INVALID_SIGNATURE`
- `DENY_FAIL_CLOSED_PROJECTION_EXPIRED`
- `DENY_FAIL_CLOSED_PROJECTION_ROLLBACK_REJECTED`
- `DENY_FAIL_CLOSED_PROJECTION_INACTIVE`

## 7) Signing workflow

### Bootstrap/local testing

1. build envelope
2. optionally use `bootstrap-none`
3. activate only if node is explicitly in bootstrap mode

### Production

1. build logical envelope
2. canonicalize payload
3. compute payload hash
4. sign payload
5. write v2 envelope
6. distribute envelope
7. each node verifies before activation

## 8) Rollback policy

Default recommendation:

- rollback disabled by default
- lower sequence rejected
- same sequence with different payload hash rejected

Allow rollback only when explicitly set in trust manifest.

## 9) Smoke tests we should add

### Happy path
- valid signature
- valid sequence
- valid expiry

### Security failures
- wrong signer
- wrong key id
- invalid signature
- expired envelope
- generatedAt too far in future
- lower sequence rollback attempt
- same sequence but changed payload

### Runtime behavior
- active verified envelope routes `allow`
- stale_lkg continues temporarily
- invalid_signature forces fail-closed
- adapter returns explicit deny code

## 10) Recommended delivery order

1. add schemas/examples
2. implement canonicalize/hash helper
3. implement verify path
4. wire verifier into sync script
5. add explicit state reasons
6. wire adapter fail-closed mapping
7. add smoke tests
8. only then switch production profile to signed-required mode

## 11) Success condition

We are done with this phase when:

- a stock-HB companion node can activate a projection only from a valid signed
  envelope,
- stale or forged snapshots cannot silently become active authority,
- adapter and nginx behave predictably under verifier failure,
- and the whole thing is still easy to install next to a stock HyperBEAM.
