# Darkmesh autonomous DNS/TXT resolver audit (CNAME + TXT only)

Date: 2026-04-24  
Status: architecture/security audit + implementation plan  
Goal: domain onboarding must require only DNS records:
- `CNAME` traffic target
- `_darkmesh` `TXT` pointer

---

## 1) Executive summary

Yes, this is realistic without forking HyperBEAM core, but not with resolver v1 as-is.

What is missing in v1 today:
- DNS TXT is not fetched live by resolver (only consumes `dnsProofState` already provided in bundle).
- Resolver does not yet pull AR config JSON directly from TXT pointer.
- Resolver enforces optional monotonic proof sequence on refresh apply (`Dns-Proof-Seq`), but TXT->cfg fetch/verify pipeline is still external.

Best path now:
- keep stock HyperBEAM,
- keep `~darkmesh-resolver@1.0`,
- add autonomous refresh loop (cron + relay + resolver state updates),
- keep request-path decisions from local map/cache (fast).

---

## 2) Current state audit (what is true today)

## 2.1 Resolver v1 status

`ops/live-vps/runtime/hb/addons/darkmesh-resolver@1.0.lua` currently:
- supports policy modes (`off/observe/soft/enforce`),
- supports host/route resolution and cache,
- supports `dnsProofState` enforcement,
- supports challenge-bound refresh apply (`IssueDnsRefreshChallenge` + `ApplyDnsRefreshResult` with `autoDns.requireChallenge=true`),
- supports anti-rollback guard via optional `Dns-Proof-Seq`,
- **does not perform DNS fetch itself** (state-driven only).

So v1 is safe for enforcement gates, but not autonomous TXT ownership revalidation.

## 2.2 HyperBEAM stock capability audit (relevant features)

From current upstream code (`main`) and docs:

1) `dev_router` supports dynamic `route_provider`:
- routes can be computed dynamically by provider message.
- useful for host-based route map updates without nginx-side DB.

2) `dev_relay` supports HTTP(S) call/cast:
- can call external endpoints (sync/async),
- useful for DNS-over-HTTPS and AR gateway fetches.

3) `dev_cron` supports scheduled loops:
- `once/every/stop`,
- useful for periodic TXT/cfg revalidation.

4) `dev_cache` exists with trusted writer model:
- can cache external fetch payloads,
- writes require trusted identity (`cache_writers`).

5) `dev_lookup` and `name@1.0` exist but are local resolver chains:
- good for local indirection,
- **not** native DNS TXT resolver.

6) No stock built-in DNS TXT device in current preloaded defaults:
- means DNS must be queried via external endpoint (DoH API) or other integration.

## 2.3 Important drift note

Your runtime uses `~copycat@1.0` indexing path in `entrypoint.sh`, but upstream `main` preloaded device list does not include `dev_copycat`.  
This can still work when remote devices are loaded (`load_remote_devices=true`), but treat it as version-sensitive behavior and keep it explicitly monitored.

---

## 3) Architecture options evaluated

## Option A: keep manual policy bundle updates only

Pros:
- simplest operationally.

Cons:
- DNS ownership drift window is unacceptable (domain can change owner between updates).
- does not satisfy autonomous requirement.

Decision: reject for final state.

## Option B: per-request live DNS+AR lookup in resolver

Pros:
- always freshest source-of-truth.

Cons:
- high latency and external dependency on hot path,
- easier to DoS by forcing repeated TXT/AR fetches,
- unnecessary cost/complexity.

Decision: reject for normal runtime.

## Option C (recommended): autonomous background refresh + fast local decisions

Pros:
- request path remains fast and deterministic,
- TXT ownership still revalidated frequently,
- clean CNAME+TXT onboarding UX,
- no HyperBEAM core fork.

Cons:
- needs refresh jobs and strict state machine.

Decision: **recommended**.

---

## 4) Recommended autonomous model (CNAME + TXT only)

## 4.1 DNS and config contract

Required records:
- `CNAME @ -> <darkmesh ingress>`
- `TXT _darkmesh.<domain> = "v=dm1;cfg=<AR_TX>;kid=<ADDR>;ttl=<sec>;seq=<n>"`

Config JSON on Arweave (`cfg` pointer):
- contains routing/process metadata + signature + validity window.

## 4.2 Runtime decision path (no external call on each request)

1. Request arrives with `Host`.
2. Resolver reads local policy map/cache.
3. If entry is `valid` -> allow/route.
4. If `stale` and inside grace -> allow with stale marker + async refresh.
5. If `invalid/missing` in `soft/enforce` -> deny.

## 4.3 Autonomous refresh path

Periodic job:
1. Select hosts due for refresh.
2. Query TXT (`_darkmesh.<host>`) via DoH endpoint.
3. Parse `dm1` envelope.
4. Fetch `cfg` JSON from AR gateway.
5. Verify:
   - host match,
   - signature/key binding,
   - validity window,
   - anti-rollback sequence/hash.
6. Upsert resolver host/site/dns state.
7. Invalidate host cache key(s).

No manual operator write required for ordinary freshness.

---

## 5) Security audit (threats and controls)

## 5.1 Threats

1. Domain ownership changed but stale mapping still serves old target.
2. Replay/rollback to older valid config (`cfg` tx reuse).
3. TXT tampering to point at malicious config.
4. External dependency outage (DNS/AR transient failure).
5. Abuse by forcing expensive refresh loops.

## 5.2 Required controls

1. Strict host canonicalization (already in resolver v1).
2. Signed config validation (required before `valid`).
3. Monotonic anti-rollback guard (`seq` and/or config hash timeline).
4. Bounded refresh cadence + retry budget + jitter.
5. Grace window (`stale-if-error`) with hard cap.
6. Hard deny in `soft/enforce` when no trustworthy mapping.
7. Host-level cache invalidation on proof/config change.

---

## 6) What to add next in resolver v1.1 (concrete backlog)

## 6.1 New state sections

- `autoDns`:
  - `enabled`
  - `refreshIntervalSec`
  - `retryBackoffSec`
  - `maxHostsPerRun`
  - `staleGraceSec`
- `txtPointers`:
  - host -> `{ cfgTx, kid, ttlSec, seq, seenAt }`
- `cfgHistory`:
  - host -> `{ lastSeq, lastCfgHash, lastCfgTx }`
- `refreshMeta`:
  - host -> `{ nextCheckAt, lastCheckAt, lastError, retryCount }`

## 6.2 New resolver actions

- `ListHostsDueForDnsRefresh` (admin/internal)
- `ApplyDnsRefreshResult` (admin/internal signed mutation)
- `GetDnsRefreshState` (read-safe summary)
- `ForceDnsRefreshHost` (admin manual trigger)

Rationale:
- keep resolver authoritative,
- allow cron/refresher execution path to be decoupled from user requests.

## 6.3 Validation additions

- enforce TXT envelope fields (`v,cfg,kid,ttl,seq`),
- enforce max/min ttl bounds,
- enforce monotonic `seq`,
- enforce `cfg` hash/version continuity.

---

## 7) HyperBEAM config-level reuse plan (no Dockerfile change)

Use stock features:
- `~cron@1.0` for periodic refresh trigger.
- `~relay@1.0` for DoH + AR fetch calls.
- `~router@1.0` dynamic provider only if route table itself must auto-shift.
- `~cache@1.0` optionally for fetch acceleration (with trusted writer guard).

Keep existing:
- resolver alias route in `entrypoint.sh`,
- stock image boundary.

Do not require:
- HB core patch,
- custom external resolver microservice by default.

---

## 8) Rollout plan (safe)

1. Phase 0:
- implement v1.1 state/actions,
- keep policy mode `off`.

2. Phase 1:
- run autonomous refresh in observe mode,
- compare resolved host decisions vs manual baseline.

3. Phase 2:
- enable `soft` for canary domains,
- watch deny reasons and refresh error rates.

4. Phase 3:
- enforce for opt-in cohorts,
- keep one-command rollback to `off`.

---

## 9) Acceptance criteria

Autonomous DNS/TXT is accepted when all are true:

1. New domain onboarding requires only CNAME + TXT + AR cfg publish.
2. Ownership change in TXT propagates automatically within bounded window.
3. No per-request DNS call is required in steady state.
4. Replay/rollback attempts are rejected.
5. `soft/enforce` deny behavior is deterministic and auditable.
6. No HyperBEAM core patch is needed.

---

## 10) Sources used for capability audit

- HyperBEAM `hb_opts.erl` (preloaded devices, relay client option, routes default):  
  https://raw.githubusercontent.com/permaweb/HyperBEAM/main/src/hb_opts.erl
- HyperBEAM `dev_router.erl` (routes, dynamic `route_provider`, preprocess):  
  https://raw.githubusercontent.com/permaweb/HyperBEAM/main/src/dev_router.erl
- HyperBEAM `dev_relay.erl` (`call`/`cast`, relay mechanics):  
  https://raw.githubusercontent.com/permaweb/HyperBEAM/main/src/dev_relay.erl
- HyperBEAM `dev_cron.erl` (`once/every/stop` scheduling):  
  https://raw.githubusercontent.com/permaweb/HyperBEAM/main/src/dev_cron.erl
- HyperBEAM `dev_cache.erl` (`cache_writers` trust boundary):  
  https://raw.githubusercontent.com/permaweb/HyperBEAM/main/src/dev_cache.erl
- HyperBEAM `dev_lookup.erl` (local lookup semantics):  
  https://raw.githubusercontent.com/permaweb/HyperBEAM/main/src/dev_lookup.erl
- HyperBEAM `dev_name.erl` (resolver-chain behavior):  
  https://raw.githubusercontent.com/permaweb/HyperBEAM/main/src/dev_name.erl
