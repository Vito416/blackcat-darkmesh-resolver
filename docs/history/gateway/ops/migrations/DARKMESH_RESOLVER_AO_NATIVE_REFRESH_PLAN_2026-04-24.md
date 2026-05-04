# Darkmesh resolver refresh - AO-native timer plan

Date: 2026-04-24  
Status: implemented foundation (no VPS-local timer)

## Goal

Refresh cadence must not depend on one HB host-local timer.

Accepted constraint:
- no Node.js runtime install on VPS,
- no systemd timer as source-of-truth for DNS refresh,
- resolver authority remains AO process (`~darkmesh-resolver@1.0`).

## Decision

Use **AO-native refresh cadence**:

1. Resolver stores `nextCheckAt` / `proofState` per host (already staged).
2. AO-side execution calls `RunAutoDnsTick` and receives due-host plan (`relay/cache/cron` metadata + endpoint hints).
3. AO-side execution submits normalized results via `ApplyDnsRefreshResult`.
4. Resolver contract remains authoritative and applies deterministic validation/state transitions.
5. HB host does not run its own refresh timer.

This keeps uptime/ops on HB clean and avoids single-node scheduler risk.

## Why this fits trust model

- Workers are untrusted by default, so resolver never blindly accepts mutable host state.
- Resolver enforces:
  - strict host normalization,
  - dm1 envelope/config shape checks,
  - role-gated mutation actions,
  - deterministic cache invalidation.
- Future hardening path:
  - add anti-rollback sequence in TXT/config,
  - add challenge-response binding for refresh submissions.

## Immediate operational mode

- Keep VPS refresh timer disabled.
- Use AO-native actions only:
  - `RunAutoDnsTick`
  - `ApplyDnsRefreshResult`
- Keep resolver PID alias in HB runtime for serving path only.

## Next implementation milestone

M1 (AO-native cadence hardening) - implemented:
- resolver action `IssueDnsRefreshChallenge(host)` (short TTL nonce),
- `ApplyDnsRefreshResult` can require challenge binding (`autoDns.requireChallenge=true`),
- replay guard: stale challenge and stale `Dns-Proof-Seq` are rejected.

M2 (anti-rollback):
- extend TXT/config schema with monotonic sequence,
- resolver enforces sequence increase per host.

M3 (distributed keeper model):
- publish keeper contract for domain-owner async workers,
- document minimum keeper SLA and AO-native recovery behavior.
