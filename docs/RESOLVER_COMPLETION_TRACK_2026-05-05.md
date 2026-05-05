# Resolver completion track

Date: 2026-05-05
Status: current completion target before tenant onboarding work

## Goal

Finish DarkMesh Resolver into one coherent operator-ready resolver stack before
we split focus into tenant onboarding flows.

The key discipline here is:

- finish the resolver platform first,
- then package onboarding cleanly for:
  - static tx-backed sites,
  - static AO process-backed sites,
  - dynamic AO-backed sites.

## Definition of "complete enough"

For the current phase, DarkMesh Resolver is "complete enough" when all of the
following are true:

### 1. Shared signed projection is production-stable

- shared signed projection publication is routine
- joined nodes fetch the same artifact
- verify-only activation remains healthy
- release / guard / joined-node smoke flows are operator-friendly

This is mostly in place today.

### 2. Joined-node trust is stronger than signature + freshness alone

- node-side DM1 parity checks are available
- AO-derived parity direction is clear
- worker helper output is treated as transport/convenience, not truth

This is partially in place today and still needs finishing work.

### 3. AO-native read contract is explicit

- operator tooling distinguishes:
  - `semantic_payload`
  - `reply_message_payload`
  - `runtime_effect_only`
  - `runtime_error`
  - `transport_unavailable`
- `runtime_effect_only` is treated honestly as healthy runtime transport, not
  as rich semantic readback
- reply-message contract remains the target, but not a fake present-tense claim

This is in a good transitional state today, but not finished.

### 4. Minimal exposed surface is the default operator posture

- public surface stays as narrow as possible
- `GET /resolver/projection/current` remains the only clearly justified public
  worker dependency
- `resolver/control/*` stays operator-only, explicit, and non-canonical
- no silent public fallback is required in normal operator tooling

This is mostly in place today.

### 5. Resolver onboarding modes are ready to package

We should be able to explain, test, and operate three clean tenant modes:

#### Static tx-backed site

- tenant points config at a public Arweave tx
- no worker required
- resolver authority path is clear

#### Static AO process-backed site

- tenant points config at a public AO/site process
- no dynamic operator loop required for ordinary serving
- resolver authority path is clear

#### Dynamic AO-backed site

- AO truth can change over time
- control-plane/operator flow is explicit
- trust boundaries stay clear
- serving behavior does not depend on hidden worker authority

This packaging work should begin only after the resolver platform itself feels
stable enough.

## What is already done

- split resolver repository exists and is pushed
- current production truth is documented
- minimal-surface operator posture is documented
- projection tooling is alias-ready without forcing live alias rollout
- AO-native read health is surfaced into control-state
- operator runbooks are largely aligned to the current posture

## Main remaining technical gaps

### A. Projection-backed read adapter still carries the public alias path

This is the biggest "not fully done yet" marker.

We need to keep reducing reliance on that adapter without regressing live
serving.

### B. AO-native semantic payload path is still not a reliable live assumption

Current reality is still:

- runtime transport can be healthy,
- while rich semantic payloads are absent.

That is acceptable operationally only because tooling now models this honestly.

### C. AO-derived activation parity is not fully closed

DM1 parity scaffolding exists, but the end-state should be stronger:

- node verifies not only signature/freshness,
- but also enough AO-derived truth to resist helper-plane drift.

### D. Tenant onboarding is not yet turned into one polished operator story

The raw ingredients exist, but not yet the finished "this is how you onboard
mode A / B / C" product experience.

## Recommended execution order

### Phase 1 - finish resolver-core technical posture

1. keep live projection publication / joined-node flows stable
2. continue narrowing operator surfaces
3. strengthen AO-derived parity and adapter exit strategy
4. keep AO-native read contract explicit and honest

### Phase 2 - declare resolver-core stable

Resolver-core is stable enough when:

- the remaining transitional pieces are understood, documented, and operational
- no hidden public dependency is required for normal operator flow
- joined-node rollout story is repeatable

### Phase 3 - build onboarding packs

Only then package:

1. static tx onboarding
2. static AO process onboarding
3. dynamic AO onboarding

## Immediate next recommendation

The next best technical direction is still resolver-core work, not onboarding:

1. keep pushing down the transitional reliance on the projection-backed read
   adapter
2. continue strengthening node-side AO-derived verification logic
3. avoid widening public surface while doing it
