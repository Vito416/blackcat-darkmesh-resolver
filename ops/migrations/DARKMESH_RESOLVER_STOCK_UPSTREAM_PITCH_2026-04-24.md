# Darkmesh Resolver `~darkmesh-resolver@1.0` (upstream pitch)

Date: 2026-04-24  
Status: implementation snapshot + worker boundary update

## What this change does

- Moves domain-resolution authority away from `workers/async-worker`.
- Keeps HyperBEAM runtime stock (no HB source patching).
- Stages resolver process implementation for AO-team review:
  - `ops/live-vps/runtime/hb/addons/darkmesh-resolver@1.0.lua`

## Why this is better

- Async worker stays focused on async control plane (mail/jobs), not domain truth.
- Resolver behavior is deterministic and auditable in one AO process contract.
- HB only needs alias route + resolver PID file (already supported in runtime templates).

## Runtime boundary

- **HB stock:** unchanged image/runtime.
- **Resolver authority:** AO process (`~darkmesh-resolver@1.0`).
- **Tenant workers:** untrusted by default; resolver output remains the gate.

## Async worker scope after cleanup

- `GET /health`
- `POST /mail/send` (auth, accepted async stub)
- `POST /jobs/enqueue` (auth, queue if bound)
- `scheduled` tick (no domain refresh)

Removed from async worker:

- DNS TXT parser/validation pipeline
- domain config signature validator
- domain map persistence/state machine
- scheduled domain refresh/promote logic

## Next for AO team

1. Review `darkmesh-resolver@1.0.lua` contract action surface.
2. Keep/adjust cache and proof semantics (`off/observe/soft/enforce`).
3. Upstream as stock-compatible resolver contract path.
