# DarkMesh Resolver workflow and audit

Date: 2026-04-30
Status: current split-out baseline

## 1) Why this repo exists

The resolver had become strategically important, but operationally fragmented.
By the time domain resolution was working correctly, the implementation was
spread across three different layers:

1. AO canonical resolver source
2. HyperBEAM reference/addon copy
3. projection-backed runtime adapter + host-routing builder + nginx glue

That fragmentation made the resolver hard to audit, hard to port to new
HyperBEAM builds, and risky to extend toward a multi-VPS / multi-provider
future.

This repo is the first step to fix that.

## 2) What works today

Today the resolver can already do the following reliably:

- resolve mapped domains to site/runtime targets,
- serve public resolver endpoints through `~darkmesh-resolver@1.0`,
- support `www` aliases for current demo domains,
- generate and validate resolver policy bundles,
- expose a working production shim without patching stock HyperBEAM,
- run on a small HB-only VPS profile.

That is enough for real serving.

## 3) Current architecture (real, not idealized)

Current live path is:

1. DM1 / projection inputs define domain -> route intent.
2. Host-routing projection is built locally.
3. Nginx host-routing projection serves site traffic.
4. `~darkmesh-resolver@1.0` is currently served by a local read adapter.
5. AO resolver process remains the canonical policy/process candidate, but is
   not yet the only live authority surface.

Important consequence:

- the resolver is **working**,
- but the public path is still partly a runtime adapter system,
- not yet a pure AO-native end state.

## 4) Critical audit findings

### 4.1 `Node-Id` is not yet a real routing selector

Current resolver state is still fundamentally single-target.

What that means:

- `Node-Id` is accepted,
- `Node-Id` can be echoed,
- but routing does not actually branch by node, provider, region, or pool.

This blocks the future vision of:

- multiple low-end VPS nodes,
- provider diversity,
- geo-aware or provider-aware routing,
- health-based selection.

### 4.2 AO canonical source and HB addon have already drifted

The repository includes both:

- `ao/resolver/process.lua`
- `ops/live-vps/runtime/hb/addons/darkmesh-resolver@1.0.lua`

Those are not identical in behavior anymore.

Known example:

- `www` fallback / alias behavior exists in the HB addon path,
- but that same behavior is not yet guaranteed by the AO canonical source.

This is the most dangerous class of drift because it creates the illusion that
“resolver is fixed” while only one delivery path is actually fixed.

### 4.3 Public resolver API is still projection-backed

The live read adapter (`ops/live-vps/runtime/scripts/darkmesh-resolver-read-adapter.py`)
currently fronts the public resolver surface.

That is practical and stable.
It is also a compromise.

Current limitation:

- public resolver reads are not yet purely AO-native execution results.

### 4.4 Projection adapter trust is softer than it should be

The adapter currently reads local projection/state artifacts and does not yet
fully enforce all of the following as hard runtime invariants:

- signature verification,
- expiry enforcement,
- strict canonical origin for all projected identity fields.

That is acceptable for a controlled single-stack rollout.
It is not strong enough for a future distributed resolver fabric.

### 4.5 Dynamic refresh / dynamic run is not fully closed-loop

The resolver already contains significant refresh-state machinery:

- DNS refresh state,
- refresh challenges,
- forced refresh actions,
- refresh-result apply actions,
- due-for-refresh introspection.

But the end-to-end autonomous control plane is not finished.

What is missing is not raw state shape, but operational closure:

- who runs refreshes,
- where evidence comes from,
- who reconciles outcomes,
- how that feeds back into live routing decisions.

### 4.6 Validation is split between two different truths

Today we have two strong but not identical validation worlds:

- fixture/addon pack validation,
- AO process integration validation.

Current reality:

- fixture pack is still the best reflection of the live shim behavior,
- AO integration spec is now aligned with the default secure posture,
- and the same AO integration spec can still be re-run with
  `RESOLVER_ALLOW_CENTRALIZED_BUNDLE_WRITES=1` to exercise the compatibility
  path.

That means release confidence is less asymmetrical than before, but the product
contract question still remains: centralized bundle writes are no longer the
default truth and should be treated as compatibility behavior unless we choose
otherwise.

## 5) Priority groups

### 5.1 Must

These are the things the resolver should gain before it is treated as a real
portable platform.

1. **Single canonical source of truth**
   - AO resolver source must become the canonical behavioral source.
   - HB addon should be generated from it, or diff-checked against it.

2. **Real multi-backend data model**
   - host/site policy must move from one target to a pool of candidates.
   - fields should support:
     - node id,
     - region,
     - provider,
     - role/capability,
     - weight,
     - health status,
     - failover priority.

3. **Actual `Node-Id` decision semantics**
   - routing should branch by node profile, not just return node metadata.

4. **Signed projection verification**
   - adapter/runtime must verify signature and expiry on the projection data it
     trusts.

5. **Aligned release gates**
   - AO integration tests,
   - fixture pack validation,
   - runtime adapter smoke,
   - host-routing smoke
     all need to describe the same contract.

6. **Closed-loop dynamic refresh workflow**
   - dynamic run needs a clearly defined operator or automation path, not only
     latent AO actions.

### 5.2 Nice to have

1. canonical `www` policy (`alias` vs `301 redirect`)
2. richer public-safe observability endpoints
3. schema validation in CI for all resolver decision payloads
4. release artifact generation (resolver snapshot, smoke evidence, diff report)
5. cleaner consumer harness for gateway callers

### 5.3 Future-proof

1. signed projection fanout to many low-cost VPS nodes
2. graceful degraded mode when AO or projection source becomes stale
3. resolver node registry and admission policy
4. optional app-aware pool metadata for cases where edge/LB routing is not enough
5. optional geo/provider/capability hints for special-case tenants
6. sticky-but-revocable target choice only if it becomes necessary above infra LB

## 6) Recommended development workflow

This is the workflow we should use from now on.

Single-source-of-truth mechanics for that workflow are tracked in:

- `docs/RESOLVER_SINGLE_SOURCE_OF_TRUTH_PLAN_2026-04-30.md`

### Step 1 — change the AO canonical source first

Start in:

- `ao/resolver/process.lua`

If behavior matters to resolver correctness, it starts there first.
Do **not** start with the HB addon copy.

### Step 2 — explicitly sync or regenerate the HB resolver addon

Then update:

- `ops/live-vps/runtime/hb/addons/darkmesh-resolver@1.0.lua`

Goal:

- no silent drift,
- no “fixed in live addon but not in canonical source” situations.

Current mechanism in this repo:

- generator:
  - `scripts/generate-hb-addon-from-canonical.py`
- explicit overlay:
  - `ops/live-vps/runtime/hb/addons/patches/www-host-alias-overlay.lua`
- drift gate:
  - `npm run check:hb-addon-drift`

### Step 3 — update fixtures before rollout

If behavior changes, update:

- `ops/live-vps/runtime/hb/addons/fixtures/resolver-fixtures.v1.lua`

Then run:

```bash
lua scripts/run-resolver-fixtures.lua
node scripts/validate-resolver-pack.js
```

These checks should remain cheap and mandatory.

### Step 4 — run the AO integration truth separately

Run:

```bash
lua tests/integration/resolver_process_spec.lua
```

Current expectation:

- default run must pass while asserting that centralized bundle writes are
  blocked,
- optional env-enabled run should also pass if we still want to preserve the
  compatibility path:

```bash
RESOLVER_ALLOW_CENTRALIZED_BUNDLE_WRITES=1 lua tests/integration/resolver_process_spec.lua
```

### Step 5 — when execution/runtime changed, test the adapter and projection path too

If the change touches any of the following:

- read adapter,
- projection shape,
- host normalization,
- `www` handling,
- alias path behavior,
- runtime wiring,

then test these files too:

- `ops/live-vps/runtime/scripts/darkmesh-resolver-read-adapter.py`
- `ops/live-vps/runtime/scripts/build-host-routing-envelope-from-dm1.sh`
- `ops/live-vps/runtime/scripts/sync-nginx-host-routing.sh`
- `ops/live-vps/local-tools/smoke-resolver-alias.sh`
- `ops/live-vps/local-tools/check-resolver-migration-readiness.sh`

### Step 6 — only then rebuild resolver WASM if needed

If AO execution artifact changed, rebuild with:

```bash
bash scripts/deploy/build_resolver_wasm_docker.sh
```

This repo already carries the minimum baseline runtime scaffold in
`dist/registry/` so the resolver wasm build can remain reproducible inside this
split-out repo.

### Step 7 — record rollout evidence

For every meaningful rollout, keep:

- fixture result,
- pack validation result,
- AO integration result,
- public alias smoke result,
- projection build proof,
- PID / module / bundle metadata if applicable.

That keeps the resolver portable and auditable.

## 7) What should be separated next

This split-out repo is the first cut, not the final one.

The next separations that make sense are:

1. **Canonical resolver package**
   - AO source + tests + schemas only
2. **HB delivery package**
   - addon copy/generator + fixtures + alias compatibility surface
3. **Runtime adapter package**
   - projection-backed API shim + nginx/systemd integration
4. **Control-plane package**
   - DNS refresh runner, projection signer/verifier, release tooling

For now they remain together because that is still the easiest way to audit the
whole resolver stack end to end.

## 8) Multi-VPS future: what this repo needs before that plan is safe

The future idea is good:

- cheap VPS nodes,
- multiple regions/providers,
- same resolver authority,
- load-balanced or health-aware tunnel/front door,
- founder-fee powered distribution.

For that plan to be safe, the resolver needs at least these additions:

1. signed projection distribution
2. clear stale-data behavior
3. anti-drift deployment workflow across many HB builds
4. node registry / node profile model for observability and controlled rollout
5. optional app-aware routing metadata only if edge/LB becomes insufficient

Until those are done, the resolver should be treated as:

- production-capable for single-stack or tightly controlled multi-stack use,
- not yet a finished distributed traffic authority.

## 9) Recommended immediate backlog

### P0

- make AO source the explicit canonical behavior source
- remove/add gate against AO vs HB drift
- align integration spec with current security defaults

### P1

- define the minimal multi-node contract where edge/LB chooses node and resolver chooses host authority
- keep pool-aware resolver v2 as optional follow-up, not as required immediate scope

- add signed projection verification in adapter/runtime
- expose public-safe cache/admission/debug endpoints
- finish dynamic refresh/control-plane workflow

### P2

- add node registry and pool selection semantics
- add health/failover logic
- add multi-provider rollout workflow and release evidence automation

## 10) Bottom line

Today the resolver is already useful.
That is a real achievement.

But the next leap is not “more patching.”
It is turning the resolver from a working routing shim into a fully auditable,
portable routing authority.

That is exactly what this repo is meant to support.
