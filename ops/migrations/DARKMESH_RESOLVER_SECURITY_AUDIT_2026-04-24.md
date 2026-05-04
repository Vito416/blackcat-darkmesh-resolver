# Darkmesh Resolver Security Audit (v1.5)

Date: 2026-04-24  
Scope:
- `ops/live-vps/runtime/hb/addons/darkmesh-resolver@1.0.lua`
- `../blackcat-darkmesh-ao/ao/resolver/process.lua` (parity)
- fixture matrix and pack validation

## Executive result

Status: **pass with low residual risk**.

The previously flagged critical trust-boundary issues were remediated:

1. `ApplyHostPolicyFromProof` direct mapping bypass: **fixed** (disabled by default).
2. Refresh/mapping mutating actions without role policy: **fixed** (role-gated).
3. Public read mutating persistent refresh queue: **fixed** (read-only by default).
4. `refreshMeta` unbounded growth risk: **fixed** (TTL prune + hard cap eviction).
5. `math.random` challenge nonce: **fixed** (openssl-backed random when available; deterministic fallback).
6. `allowlist_changed` undefined response field: **fixed** (`scope="host"`).

## Findings and disposition

### A) Direct mapping bypass via `ApplyHostPolicyFromProof` (previously High) - RESOLVED

- Current behavior:
  - action is blocked by default unless `RESOLVER_ALLOW_DIRECT_HOST_POLICY_APPLY=1`.
  - keeps decentralized onboarding path as DNS TXT + AR config + proof refresh.

### B) Missing role-gates on mutating actions (previously High) - RESOLVED

Role policy now protects:
- `ApplyDnsRefreshResult`
- `ForceDnsRefreshHost`
- `IssueDnsRefreshChallenge`
- `ApplyHostPolicyFromProof`

Allowed roles:
- `admin`
- `registry-admin`
- `resolver-refresh`

### C) Public reads mutating refresh state (previously High) - RESOLVED

- Default behavior now: public resolve/read path is non-mutating for refresh queue.
- Optional override exists only if explicitly enabled:
  - `RESOLVER_ALLOW_PUBLIC_READ_REFRESH_QUEUE=1`.

### D) `refreshMeta` growth (previously Medium) - RESOLVED

Added controls:
- `RESOLVER_REFRESH_META_STALE_TTL_SEC` (default 86400)
- `RESOLVER_REFRESH_META_MAX_HOSTS` (default 10000)
- periodic prune/eviction in route path.

### E) Challenge entropy quality (previously Medium) - IMPROVED

- Challenge nonce now uses `openssl.rand.bytes` when available.
- If crypto RNG is unavailable, deterministic fallback is used (lower assurance).

Residual recommendation:
- keep crypto backend available in runtime for strongest challenge quality.

### F) `allowlist_changed` undefined in response (previously Low) - RESOLVED

- both affected responses now return explicit `scope = "host"`.

## Security posture summary

The resolver is now aligned with your decentralized model:
- no default centralized host/site mapping writes,
- mutating refresh/mapping actions explicitly role-gated,
- public reads cannot silently mutate state by default.

Remaining residual risk:
- fallback nonce path is lower entropy if crypto RNG is missing.

## Validation evidence (this audit run)

- `luac -p ops/live-vps/runtime/hb/addons/darkmesh-resolver@1.0.lua`
- `luac -p ../blackcat-darkmesh-ao/ao/resolver/process.lua`
- `npm run -s ops:validate-resolver-fixtures`
- `npm run -s ops:validate-resolver-pack`
- `lua scripts/run-resolver-fixtures.lua ../blackcat-darkmesh-ao/ao/resolver/process.lua ops/live-vps/runtime/hb/addons/fixtures/resolver-fixtures.v1.lua`

All checks passed.

Fixture result:
- `22 scenarios / 61 steps` passed.

## Edge-case coverage matrix (targeted security items)

Coverage target for listed security issues: **100% (6/6)**.

1. Direct mapping bypass blocked by default
   - fixture: `direct_host_policy_apply_disabled_by_default`
2. Mutating refresh actions role-gated
   - fixture: `refresh_mutations_role_gated`
3. Public read cannot mutate refresh queue by default
   - fixture: `public_read_refresh_queue_read_only_by_default`
4. `refreshMeta` overflow controls (cap/eviction)
   - fixture: `refresh_meta_cap_prunes_overflow`
5. Cache invalidation response scope typo fixed
   - fixture assertion: `dns_refresh_due_list_and_apply_result` (`payload.cacheInvalidation.scope = "host"`)
6. Break-glass-only direct host policy apply still functional when explicitly enabled
   - fixture: `apply_host_policy_from_proof_sets_mapping` with `RESOLVER_ALLOW_DIRECT_HOST_POLICY_APPLY=1`

## Deployment gate recommendation

Approved for deploy/cutover with these defaults:

- `RESOLVER_ALLOW_CENTRALIZED_BUNDLE_WRITES=0`
- `RESOLVER_ALLOW_DIRECT_HOST_POLICY_APPLY=0`
- `RESOLVER_ALLOW_PUBLIC_READ_REFRESH_QUEUE=0`

And keep:
- `policyMode=off`
- `failOpen=true`

for initial live soak period before any `soft/enforce` step.
