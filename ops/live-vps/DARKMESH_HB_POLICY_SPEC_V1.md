# Darkmesh HB Policy Spec v1 (Config-Only, No HB Code Changes)

Date: 2026-04-22  
Status: Implementation spec for future-proof rollout  
Compatibility: stock HyperBEAM + stock Docker image

## 1) Executive summary

This spec defines how Darkmesh introduces resolver/policy controls without touching HyperBEAM source code.

Core principle:
- **edge stays thin, AO stays authoritative**.

Current production-safe posture:
- `policy=off` (no blocking, no uptime risk from enforcement logic).

Future posture:
- `policy=enforce` after endpoint readiness + rollback drill evidence.

## 2) Non-negotiable constraints

1. No HB core patch.
2. No custom Dockerfile requirement for baseline.
3. Write/spawn path remains on `write.darkmesh.fun`.
4. Resolver read path remains non-destructive.
5. Every enforcement step must have one-command rollback to `off`.

## 3) Control planes

## 3.1 Read plane

- Host lookup and route decisions:
  - `site-by-host`
  - `resolve-route`
  - `ResolveHostPolicyBundle`
  - `GetSiteRuntimeBundle`

## 3.2 Write plane

- Controlled mutation path:
  - spawn/update runtime
  - domain bind/unbind
  - policy mode changes
  - DNS proof state updates

## 4) Policy operating modes

- `off`: compatibility mode, no traffic blocking.
- `observe`: decision telemetry only.
- `soft`: partial enforcement with conservative fallback.
- `enforce`: strict policy allow/deny.

Recommended migration order:
- `off -> observe -> soft canary -> enforce`.

## 5) Read-path behavior by mode

| Condition | off | observe | soft | enforce |
|---|---|---|---|---|
| Missing host mapping | allow/fallback | allow + metric | project policy | deny (or masked 404) |
| Policy bundle unavailable | allow | allow + metric | fail-mode rule | fail-mode rule |
| DNS proof invalid | allow + alert | allow + alert | optional deny | deny |
| Cache miss | resolve + cache | resolve + cache | resolve + cache | resolve + cache |

## 6) Rollback policy (mandatory)

Rollback must always be available and documented:

1. Set `policy=off`.
2. Set `failMode=allow`.
3. Keep resolver endpoint wiring intact.
4. Restart/reload runtime via standard service controls.
5. Run readiness checks and smoke checks.

Rollback success criteria:
- no hard blockers,
- domain smoke green,
- control-plane route probes reachable.

## 7) Security and attack-surface notes

## 7.1 Reduced attack surface (config-only)

- no custom HB binary,
- no custom image code path,
- no read-path private keys,
- bounded route/config changes.

## 7.2 Remaining risks

- endpoint misconfiguration (wrong AO path),
- over-aggressive TTL causing stale decisions,
- strict mode enabled before endpoint parity,
- DNS proof drift not revalidated.

## 7.3 Mitigations

- readiness gates before mode switch,
- strict mode only after canary window,
- documented rollback drill every wave,
- periodic DNS proof checks (`_darkmesh`).

## 8) Config-only vs code-level roadmap

Config-only (this phase):
- route mapping to resolver endpoints,
- policy mode/fail-mode toggles,
- cache TTL knobs,
- Cloudflare DNS/proxy mapping.

Code-level (future phase):
- AO contract internals for advanced policy logic,
- payout computation modules,
- optional richer scoring/abuse heuristics.

## 9) Cutover readiness gates

Before `enforce`, all must pass:

1. Readiness script:
   - legacy resolver probes pass,
   - new endpoint probes pass (`GetTemplateActionContract`, `GetSiteRuntimeBundle`, `ResolveHostPolicyBundle`),
   - no hard blockers.
2. Domain smoke for active demo/production domains.
3. Write path parity check still green.
4. Rollback drill evidence recorded.

## 10) Decision record

- Current recommended production mode: **`off`**.
- Enforce mode is allowed only after gate evidence and rollback proof are archived.
