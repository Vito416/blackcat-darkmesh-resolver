# HyperBEAM addon references

This folder contains **reference implementation artifacts** for the resolver alias path (`~darkmesh-resolver@1.0`).

Current file:

- `darkmesh-resolver@1.0.lua` – AO resolver process implementation candidate used for team review/upstream proposal.
  - module dependencies: `ao.shared.codec`, `ao.shared.validation`, `ao.shared.auth`, `ao.shared.idempotency`, `ao.shared.metrics`, `ao.shared.persist`
  - autonomous DNS refresh foundations:
  - `GetDnsRefreshState`
  - `ListHostsDueForDnsRefresh`
  - `RunAutoDnsTick` (HB-native cron tick planning + queue marking)
  - `ApplyDnsRefreshResult`
  - `ApplyHostPolicyFromProof`
  - `ForceDnsRefreshHost`
  - `IssueDnsRefreshChallenge`
  - admission controls:
    - `SetAdmissionRule`
    - `RemoveAdmissionRule`
    - `GetAdmissionState`
  - on-access stale/proof refresh hints now include stock HyperBEAM paths:
    - `refresh.paths.relayPath` (`/~relay@1.0`)
    - `refresh.paths.cachePath` (`/~cache@1.0`)
    - `refresh.paths.cronPath` (`/~cron@1.0`)
- `fixtures/resolver-fixtures.v1.lua` – fixture matrix for resolver safety regressions.
- AO-native refresh path only (`RunAutoDnsTick` + `ApplyDnsRefreshResult`); no VPS control-plane runner.

Important boundary:

- HyperBEAM runtime remains stock.
- The resolver process is AO-side logic.
- HyperBEAM only needs the alias route in `entrypoint.sh` + PID file (`/srv/darkmesh/hb/data/rolling/darkmesh-resolver.pid`).
- Centralized host/site/route bundle writes are disabled by default (`RESOLVER_ALLOW_CENTRALIZED_BUNDLE_WRITES=0`).
  - `ApplyPolicyBundle` still updates global toggles (mode/cache/auto-dns), but host ownership/onboarding is expected through DNS TXT + AR config + proof refresh.
  - Optional emergency override exists via `RESOLVER_ALLOW_CENTRALIZED_BUNDLE_WRITES=1`.

How to use this file:

1. Treat it as source-of-truth proposal for AO team review.
2. Deploy resolver process through your AO/write flow.
3. Write resulting resolver PID into `/srv/darkmesh/hb/data/rolling/darkmesh-resolver.pid`.
4. Restart HyperBEAM container only when alias route PID changes.

Related implementation pack:

- `ops/migrations/DARKMESH_RESOLVER_V1_IMPLEMENTATION_PACK_2026-04-24.md`
- `ops/migrations/DARKMESH_RESOLVER_SECURITY_AUDIT_2026-04-24.md`
- `ops/live-vps/RESOLVER_STRICT_PREDEPLOY_AND_CUTOVER_PLAYBOOK_2026-04-24.md`

Security note (current):

- Latest audit marks resolver as **deploy-ready with low residual risk**.
- Security defaults:
  - `RESOLVER_ALLOW_CENTRALIZED_BUNDLE_WRITES=0`
  - `RESOLVER_ALLOW_DIRECT_HOST_POLICY_APPLY=0`
  - `RESOLVER_ALLOW_PUBLIC_READ_REFRESH_QUEUE=0`
- Mutating refresh/mapping actions are role-gated (`admin`, `registry-admin`, `resolver-refresh`).
- `refreshMeta` now has TTL pruning + hard-cap eviction controls.
- Keep `policyMode=off` and `failOpen=true` for initial live soak before any `soft/enforce`.

Local validation:

- `npm run ops:validate-resolver-fixtures`
  - current matrix: `22 scenarios / 61 steps` (includes hardening edge cases)
- `npm run ops:validate-resolver-pack`
  - fixture runner defaults to compatibility mode for legacy bundle scenarios; set
    `RESOLVER_FIXTURE_COMPAT_ALLOW_BUNDLE_WRITES=0` to test strict decentralized behavior.
  - for strict CI of new hardening gates also set:
    - `RESOLVER_FIXTURE_COMPAT_ALLOW_DIRECT_PROOF_APPLY=0`
    - `RESOLVER_FIXTURE_COMPAT_ALLOW_PUBLIC_REFRESH_QUEUE=0`
    - `RESOLVER_FIXTURE_COMPAT_BYPASS_ROLE_GATES=0`
