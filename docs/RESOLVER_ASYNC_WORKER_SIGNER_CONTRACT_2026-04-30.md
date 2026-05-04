# Resolver Async Worker Signer Contract

## Why `workers/async-worker`

`workers/async-worker` is the right home for resolver projection signing because
it already represents operator-owned asynchronous control-plane work.

That gives us the separation we want:

- tenant content claims stay in AR + DNS,
- serving VPS nodes stay verify-only,
- the signing private key stays off-node,
- simple public sites still work without any tenant worker.

## Scope boundary

This signer is for **projection activation authority**, not for tenant app
secrets.

It signs `dm-hostmap-envelope.v2` after an upstream control-plane step has
already built or reviewed the unsigned envelope.

It does **not**:

- crawl DNS,
- decide admission on its own,
- persist long-lived tenant state,
- or run on serving HB nodes.

## Endpoint

- Method: `POST`
- Path: `/resolver/projection/sign`
- Auth: `Authorization: Bearer <RESOLVER_SIGNER_AUTH_TOKEN>`

## Request body

```json
{
  "requestId": "req-projection-2026-04-30-001",
  "envelope": {
    "version": "dm-hostmap-envelope.v2",
    "snapshotId": "snapshot-jdwt-1",
    "sequence": 7,
    "generatedAt": "2026-04-30T18:00:00Z",
    "expiresAt": "2026-04-30T19:00:00Z",
    "signedBy": "bootstrap",
    "keyId": "bootstrap",
    "signatureAlg": "bootstrap-none",
    "signature": "bootstrap",
    "payloadHash": "sha256:PLACEHOLDER",
    "payload": {
      "version": "dm-hostmap.v2",
      "authority": {
        "mode": "bootstrap",
        "sourceType": "dm1",
        "resolverId": "darkmesh-resolver-v2"
      },
      "source": {
        "description": "dm1-build",
        "domains": ["jdwt.fun"],
        "cfgTxs": ["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"]
      },
      "cacheHints": {
        "refreshCadenceSec": 300,
        "lkgMaxAgeSec": 3600
      },
      "entries": []
    }
  }
}
```

## Response body

```json
{
  "ok": true,
  "signed": true,
  "requestId": "req-projection-2026-04-30-001",
  "envelopeVersion": "dm-hostmap-envelope.v2",
  "snapshotId": "snapshot-jdwt-1",
  "sequence": 7,
  "signedBy": "darkmesh-resolver-mainnet",
  "keyId": "darkmesh-projection-key-2026-q2",
  "payloadHash": "sha256:<hex>",
  "envelope": {
    "version": "dm-hostmap-envelope.v2",
    "signedBy": "darkmesh-resolver-mainnet",
    "keyId": "darkmesh-projection-key-2026-q2",
    "signatureAlg": "ed25519",
    "signature": "base64:<signature>",
    "payloadHash": "sha256:<hex>",
    "payload": { "...": "..." }
  }
}
```

## Signing rules

The worker owns and overwrites these fields:

- `signedBy`
- `keyId`
- `signatureAlg`
- `signature`
- `payloadHash`

The caller does **not** get to choose signer identity.

The signature is computed over the canonicalized `payload` bytes, matching the
resolver-side verifier expectations.

## Required env/secrets

Secrets:

- `RESOLVER_SIGNER_AUTH_TOKEN`
- `RESOLVER_SIGNER_PRIVATE_KEY`

Vars:

- `RESOLVER_SIGNER_SIGNED_BY`
- `RESOLVER_SIGNER_KEY_ID`

## Rollout intent

Near-term flow:

1. operator/control-plane builds unsigned `dm-hostmap-envelope.v2`
2. control-plane POSTs it to `workers/async-worker`
3. worker signs it with off-node private key
4. serving VPS fetches signed projection
5. serving VPS verifies using trust manifest public key
6. serving VPS activates nginx host map if verification passes

That keeps the public tenant UX simple while preserving a clean trust boundary.
