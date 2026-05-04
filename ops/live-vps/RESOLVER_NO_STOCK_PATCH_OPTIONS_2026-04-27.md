# Darkmesh Resolver: No-Stock-HB-Patch Design Analysis (2026-04-27)

## Scope

Goal: domain routing (`jdwt.fun`, `vddl.fun`, `blgateway.fun`) must work via resolver logic **without modifying stock HyperBEAM code**.

Constraints:

- no stock HB patching,
- keep AO-native source-of-truth where possible,
- avoid Node.js/npm runtime dependency on VPS hot path,
- preserve current write/read parity and avoid new 5xx regressions.

---

## Observed design gaps (expected vs real behavior)

## 1) Alias GET does not execute resolver contract action semantics

Expected:

- `GET /~darkmesh-resolver@1.0/resolve?host=<host>&path=/` returns resolver decision JSON.

Observed:

- returns process payload (`1984`) or not_found envelopes, no decision object.
- current alias shim calls:
  - `/<resolver_pid>~process@1.0/now?Action=...`
- on this runtime profile, that path is not a reliable contract-action surface.

Impact:

- domains remain `404` even when resolver/module/pid are finalized.

---

## 2) Direct action-like paths are not a valid invoke surface on current profile

Expected:

- `POST /<pid>~process@1.0/ResolveRouteForHost` or `.../GetResolverState` should dispatch action.

Observed:

- returns `404 not_found` from process device.
- fallback parser/action inference added in resolver code did not change this.

Impact:

- routing by path-convention cannot be relied on without upstream behavior changes.

---

## 3) Scheduler accepts messages, but public read path cannot consume results as resolver API

Expected:

- schedule action -> retrieve decision via a stable public read endpoint.

Observed:

- `POST /~scheduler@1.0/schedule?target=<pid>` accepts action (slot advances),
- but process read path still yields process snapshot payloads (`data=1984`) rather than decision API shape.

Impact:

- scheduler-direct is useful for state mutation, not a drop-in public GET resolver API.

---

## 4) Domain root (`/`) requires deterministic host->target mapping before HB process resolution

Expected:

- generic `/` request on any onboarded host should resolve to correct process/site.

Observed:

- without a deterministic host map at ingress, request falls through to default HB behavior (Hyperbuddy/404).

Impact:

- resolver contract existing in AO is insufficient unless ingress can consume its decision in a stable way.

---

## Candidate solutions without stock HB patch

## Option A (Recommended): AO resolver as authority + nginx host-map snapshot projection

Design:

1. AO resolver process remains authority for domain policy/proof state.
2. A projection job materializes read-only snapshot:
   - `host -> target process/site route`.
3. Snapshot is signed and published (AR tx or AO-produced signed payload).
4. VPS ingress (nginx) pulls snapshot and generates `map` include.
5. Runtime `/` routing uses `$host` lookup from map and rewrites to target process path.

Why this fits constraints:

- no stock HB code changes,
- no Node required in runtime path (bash + curl + jq + nginx reload),
- deterministic, low-latency public routing for `/`,
- AO remains source-of-truth (ingress is projection, not authority).

Trade-offs:

- eventual consistency (refresh interval),
- requires ops projection script + signed snapshot verification policy.

---

## Option B: Per-request Cloudflare Worker resolver (DNS/TXT+AR verify live)

Design:

- Worker verifies host config and routes each request dynamically.

Pros:

- fully dynamic, no local map reload.

Cons:

- runtime dependency on worker infra,
- added trust/attack surface you explicitly wanted to minimize.

Status:

- not preferred given current security posture.

---

## Option C: Static per-domain nginx blocks managed manually

Design:

- each domain hardmapped in nginx config.

Pros:

- simplest technically.

Cons:

- not scalable,
- loses decentralized onboarding flow (CNAME + TXT only).

Status:

- only emergency fallback, not product path.

---

## Recommended implementation plan (Option A)

## Phase 1 — Projection contract shape

- Define canonical projection payload:
  - `version`, `generatedAt`, `entries[]` with `host`, `targetPid`, `pathPrefix`, `ttl`, `proofRef`.
- Sign payload with existing authority model.
- Publish payload ref (txid) in stable location consumed by projector.

## Phase 2 — VPS projector (no Node runtime)

- Add bash tool:
  - fetch projection payload,
  - verify minimal integrity gates (schema/version/signer allowlist),
  - render nginx `map` file (`/etc/nginx/snippets/darkmesh-host-map.conf`),
  - `nginx -t && nginx -s reload` only on diff.
- Add systemd timer (short interval + jitter).

## Phase 3 — Ingress routing

- In nginx loopback:
  - use `$host` from map to set `$dm_target_pid`,
  - if mapped: rewrite `/` to `/$dm_target_pid~process@1.0/...`,
  - if unmapped: current default behavior.
- Keep existing arweave parity routes untouched.

## Phase 4 — Safety gates

- stale snapshot policy (`max_age`),
- atomic swap of map file,
- fallback to last-known-good on fetch/verify failure,
- audit log on each projection update.

---

## Why this is the best no-patch path now

- It avoids waiting for uncertain upstream invoke semantics on alias/process paths.
- It keeps AO as authority while making ingress behavior deterministic and fast.
- It gives clean operational control (observability + rollback) without introducing new heavy runtime dependencies.

---

## Open approval points

1. Projection cadence:
   - `30s`, `60s`, or `120s`.
2. Snapshot source:
   - direct AR tx list,
   - or AO endpoint producing signed projection.
3. Stale policy:
   - serve last-known-good up to `N` minutes vs fail-closed for unmapped hosts.

---

## Approved parameters (2026-04-27)

- Projection cadence: **60 seconds**
- Snapshot source: **AO endpoint returning signed payload**
- Stale policy: **last-known-good for 15 minutes, then fail-closed**

Implementation artifacts (runtime templates):

- `ops/live-vps/runtime/scripts/sync-nginx-host-routing.sh`
- `ops/live-vps/runtime/systemd/darkmesh-host-routing-sync.service`
- `ops/live-vps/runtime/systemd/darkmesh-host-routing-sync.timer`
- `ops/live-vps/runtime/etc/darkmesh/resolver-projection.env.example`
- `ops/live-vps/runtime/nginx/snippets/darkmesh-host-routing.conf.example`

---

## Future topology recommendation (test vs production HB pools)

### Test pool (current)

- Keep fast cadence (`60s`) to validate onboarding and routing changes quickly.
- Keep strict stale policy (`15m` LKG, then fail-closed).
- Snapshot source can be AO endpoint directly (signed envelope).
- No manual domain whitelist in nginx:
  - projection payload itself is the routing set (`host -> target`).
  - ingress trusts signature (signer allowlist), not static host lists.

### Production pool (recommended)

- Do not run weekly-only runtime refresh for active domain routing.
  - Weekly-only refresh creates long takeover/recovery lag when DNS/TXT or ownership changes.
- Use a two-layer model:
  1. **Runtime projection feed** (signed AO endpoint): pull every `5-15 min`.
  2. **AR baseline snapshot** (signed, immutable): publish daily/weekly for audit/replay.
- Keep emergency revocation path:
  - AO signer can push immediate update;
  - production HB pulls on next short interval (or via manual force sync).

### Practical profile values

- **Test**: interval `60s`, `LKG=900s`.
- **Prod**: interval `600s` (10 min), `LKG=7200s` (2 h), plus daily/weekly AR baseline archive.

This keeps production stable/cost-efficient while preserving security freshness for real domain changes.
