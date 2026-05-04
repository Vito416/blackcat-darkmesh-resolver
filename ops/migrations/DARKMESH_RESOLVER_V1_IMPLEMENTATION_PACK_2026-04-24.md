# Darkmesh Resolver v1 implementation pack (future-proof baseline)

Date: 2026-04-24  
Status: implementation + operator tooling  
Target: upstream-friendly AO resolver contract path (`~darkmesh-resolver@1.0`)

Hardening update (2026-04-24 v1.1):
- idempotency key now includes host/path/method and is skipped when request id is missing,
- unchecked DNS proof is deny-ready in `soft/enforce`,
- host-unmapped decisions now respect `failOpen=false`,
- host->site policy graph is validated (no host mapping without process target),
- cache-hint ranges + relation checks are enforced,
- resolver cache has bounded pruning and state persistence is interval-based (not every request).

Autonomous DNS/TXT update (2026-04-24 v1.2 foundation):
- resolver now exposes refresh-plane actions:
  - `GetDnsRefreshState`
  - `ListHostsDueForDnsRefresh`
  - `RunAutoDnsTick`
  - `ApplyDnsRefreshResult`
  - `ForceDnsRefreshHost`
- this enables CNAME+TXT ownership revalidation pipelines without touching HB core.
- resolver decision payload now emits refresh hints with stock HB paths (`/~relay@1.0`, `/~cache@1.0`, `/~cron@1.0`) and triggers on-access refresh requests for stale/expired proof states.
- HB-native executor path is now first-class: `RunAutoDnsTick` returns due host batch + relay/cache/cron + endpoint plan so AO processes can run the refresh loop without host-local timers.

Challenge + anti-rollback update (2026-04-24 v1.3):
- optional challenge-bound refresh apply (`autoDns.requireChallenge=true`),
- new action `IssueDnsRefreshChallenge` for AO-native keeper flows,
- optional monotonic `Dns-Proof-Seq` enforcement on `ApplyDnsRefreshResult`.

## 1) What is in this pack

1. AO resolver implementation snapshot:
   - `ops/live-vps/runtime/hb/addons/darkmesh-resolver@1.0.lua`
2. Resolver addon notes:
   - `ops/live-vps/runtime/hb/addons/README.md`
3. Resolver policy bundle generator (operator tooling):
   - `ops/live-vps/local-tools/build-resolver-policy-bundle.mjs`
   - `ops/live-vps/local-tools/resolver-bundle-input.example.json`
4. Schema baseline:
   - `ops/migrations/schemas/dm1-config.schema.json`
   - `ops/migrations/schemas/dm1-dns-txt.schema.json`
   - `ops/migrations/schemas/dm-resolver-policy-bundle.schema.json`
   - `ops/migrations/schemas/dm-resolver-decision.schema.json`
5. Fixture validation:
   - `ops/live-vps/runtime/hb/addons/fixtures/resolver-fixtures.v1.lua`
   - `scripts/run-resolver-fixtures.lua`
6. Autonomous DNS/TXT architecture audit:
   - `ops/migrations/DARKMESH_AUTONOMOUS_DNS_TXT_RESOLVER_AUDIT_2026-04-24.md`
7. AO-native refresh cadence decision:
   - `ops/migrations/DARKMESH_RESOLVER_AO_NATIVE_REFRESH_PLAN_2026-04-24.md`

## 2) Runtime architecture boundary

- HyperBEAM stays stock.
- Resolver authority is AO process contract.
- Async Worker is no longer domain authority.
- Domain claims remain untrusted until resolver contract accepts/serves them.

## 3) Resolver contract action surface (v1)

- `ResolveHostForNode`
- `ResolveRouteForHost`
- `GetResolverState`
- `GetResolverCacheStats`
- `ApplyPolicyBundle`
- `InvalidateResolverCache`
- `GetDnsRefreshState`
- `ListHostsDueForDnsRefresh`
- `RunAutoDnsTick`
- `ApplyDnsRefreshResult`
- `ForceDnsRefreshHost`
- `IssueDnsRefreshChallenge`

## 4) Future-proof rules (enforced by design)

1. Version pinning:
   - DM config envelope: `v=dm1`
   - Resolver bundle: `version=dm-resolver-bundle/1`
   - Resolver schema envelope: `schemaVersion=1.0`
2. Controlled extensibility:
   - schemas allow only strict known fields + `x-*` extension namespace.
3. Policy mode gates:
   - `off -> observe -> soft -> enforce`
4. Cache semantics remain explicit:
   - positive/negative/stale windows set in bundle hints.
5. Rollback remains trivial:
   - apply bundle with `policyMode=off` and `failOpen=true`.

## 5) Nice-to-have backlog already enabled by this shape

- Signed bundles (detached signature field in `x-signature` extension namespace).
- Multi-scheduler affinity (host-level route policies + action hints).
- Canary cohorts by host (partial `hostPolicies` apply/invalidate cycle).
- External attestation links (`x-proofRef`, `x-auditRef`) without schema break.

## 6) Operator workflow (practical)

1. Prepare host list JSON from real domains.
2. Generate policy bundle:

```bash
node ops/live-vps/local-tools/build-resolver-policy-bundle.mjs \
  --input ops/live-vps/local-tools/resolver-bundle-input.example.json \
  --output tmp/resolver-policy-bundle.json \
  --mode off \
  --fail-open true
```

3. Submit generated bundle via resolver action `ApplyPolicyBundle`.
4. Check resolver state + cache stats.
5. Promote mode only after observe window evidence is green.

## 7) Non-goals in this pack

- No HB source patching.
- No docker image fork.
- No per-request DNS lookup on HB hot path.

## 8) Definition of "100% ready" for team review

- Contract code is present and readable.
- Bundle generation is deterministic and validated.
- Schema contracts are explicit and migration-safe.
- Worker responsibilities are cleanly split from resolver authority.
- Resolver fixture suite passes (`npm run ops:validate-resolver-fixtures`).
