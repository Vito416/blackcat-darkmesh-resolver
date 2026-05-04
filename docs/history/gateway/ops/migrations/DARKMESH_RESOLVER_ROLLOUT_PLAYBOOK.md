# Darkmesh Resolver Rollout Playbook

Date: 2026-04-22  
Status: Execution playbook  
Scope: resolver/policy rollout with stock HyperBEAM only (no HB code changes)

## 1) Rollout objective

Move from gateway-heavy behavior to AO-authoritative resolver behavior with:
- zero-destructive steps,
- controlled policy mode progression,
- guaranteed rollback path.

## 2) Current operating target

- Production safety target: `policy=off`.
- Migration target: validate endpoint parity + cache behavior while still non-blocking.

## 3) Read and write lanes (must stay separate)

## 3.1 Read lane

- Host lookup and route resolution.
- AO read endpoints only.
- No signing/spawn actions.

## 3.2 Write lane

- Spawn/update/bind/policy state writes.
- Runs via write control plane (`write.darkmesh.fun`).

## 4) Mode progression

- Stage A: `off`
- Stage B: `observe`
- Stage C: `soft` (canary domains only)
- Stage D: `enforce` (after full evidence)

Never skip directly from `off` to `enforce`.

## 5) Required endpoint set for migration readiness

Legacy read endpoints:
- `/api/public/site-by-host`
- `/api/public/resolve-route`
- `/api/public/page`

New cutover endpoints:
- `/api/public/GetTemplateActionContract`
- `/api/public/GetSiteRuntimeBundle`
- `/api/public/ResolveHostPolicyBundle`

## 6) Operational runbook (recommended wave)

## 6.1 Stage A - baseline (`off`)

1. Run readiness checks in non-strict mode.
2. Run domain smoke checks.
3. Archive artifacts.

## 6.2 Stage B - observe

1. Switch policy mode to `observe`.
2. Keep fail-mode `allow`.
3. Monitor for endpoint errors, 5xx, and latency drift.
4. Hold for at least one stability window.

## 6.3 Stage C - soft canary

1. Enable `soft` only for canary domains.
2. Keep strict rollback plan active.
3. Validate deny behavior is deterministic and scoped.

## 6.4 Stage D - enforce

1. Confirm all readiness gates are green.
2. Confirm rollback drill was successful.
3. Enable `enforce` in scoped rollout, then expand.

## 7) Rollback (authoritative)

If any major regression appears:

1. Set `policyMode=off`.
2. Set `failMode=allow`.
3. Keep AO endpoint mapping unchanged.
4. Restart/reload runtime through normal service manager.
5. Re-run readiness + smoke suite.

Rollback pass criteria:
- no hard blockers,
- domain smoke healthy,
- write path still parity-ready.

## 8) Security notes for rollout

## 8.1 What stays config-only

- route wiring,
- endpoint path/base selection,
- mode toggles,
- cache TTL/fail-mode knobs.

## 8.2 What is code-level and out of this playbook

- AO internal contract implementation details,
- payout engine logic,
- advanced policy scoring algorithms.

## 8.3 Attack surface reminders

- do not put signing keys in read path,
- do not enable strict enforcement before endpoint parity,
- keep DNS proof checks periodic, not per-request,
- keep fallback behavior explicit and audited.

## 9) Evidence checklist per wave

Minimum artifacts to keep:
- readiness report (text and optional JSON summary),
- domain smoke logs,
- runtime audit logs,
- mode-change timestamp log,
- rollback drill output.

## 10) Go / no-go decisions

GO to next stage only when:
- hard blockers = 0,
- endpoint set is reachable,
- no sustained error trend in runtime audit,
- rollback is proven for current stage.

Otherwise:
- hold current mode or rollback to `off`.
