# Resolver single-source-of-truth plan

Date: 2026-04-30
Status: phase 1 started

## Goal

Make `ao/resolver/process.lua` the single canonical behavioral source for the
DarkMesh Resolver, and make every HyperBEAM-facing addon artifact either:

- generated from it, or
- explicitly diff-gated against it.

That removes the current class of bugs where the live resolver appears fixed in
one delivery path but the canonical source still lags behind.

## Current state

We already know the first real drift example:

- the HB addon supports `www -> apex` fallback,
- the canonical AO resolver source does not yet include that behavior,
- both are shipped under the same resolver identity.

That is exactly the kind of divergence we want to stop.

## Phase model

### Phase 1 — stop silent drift

Implemented in this repo:

- canonical source lives at `ao/resolver/process.lua`
- HB addon copy lives at `ops/live-vps/runtime/hb/addons/darkmesh-resolver@1.0.lua`
- explicit overlay lives at:
  - `ops/live-vps/runtime/hb/addons/patches/www-host-alias-overlay.lua`
- generator lives at:
  - `scripts/generate-hb-addon-from-canonical.py`
- drift check is available as:
  - `python3 scripts/generate-hb-addon-from-canonical.py --check`
  - or `npm run check:hb-addon-drift`

Effect:

- we now have one place where drift is declared,
- one place where the HB-specific compatibility patch is expressed,
- and one gate that can fail loudly if someone edits only the addon copy.

### Phase 2 — shrink overlay surface

Target:

- move behavior from overlay into canonical AO source wherever it is truly part
  of resolver semantics.

That likely includes:

- host alias lookup policy,
- `www` fallback / host candidate logic,
- any future canonical host normalization behavior.

Rule of thumb:

- if a behavior affects resolver correctness, it belongs in canonical source,
- if a behavior is only a temporary HB/runtime compatibility shim, it may stay
  in overlay for one bounded phase.

### Phase 3 — generated addon becomes the only accepted addon source

At that point the workflow becomes:

1. edit `ao/resolver/process.lua`
2. run `npm run build:hb-addon`
3. run `npm run check:hb-addon-drift`
4. run fixture/tests/smokes

And manual edits to:

- `ops/live-vps/runtime/hb/addons/darkmesh-resolver@1.0.lua`

should be treated as a release blocker unless they are mirrored back into the
canonical source or into a clearly documented overlay.

### Phase 4 — reduce or eliminate overlay

Best end state:

- addon file is generated directly from canonical source,
- overlay is empty or near-empty,
- runtime-specific glue moves outside the resolver behavior surface.

That gives us the cleanest path for:

- future upstream pitch,
- porting to new HB builds,
- multi-VPS rollout consistency,
- review and security audit.

## Allowed edit paths from now on

### Allowed

- edit `ao/resolver/process.lua`
- edit overlay patch files in `ops/live-vps/runtime/hb/addons/patches/`
- regenerate addon
- run drift check

### Not allowed silently

- hand-edit addon behavior and leave canonical source untouched
- ship addon changes without re-running drift check
- add new addon-only logic without documenting whether it is canonical behavior
  or temporary runtime shim behavior

## Release checklist for resolver behavior changes

1. update canonical source first
2. decide whether any delta is truly overlay-only
3. regenerate addon:

```bash
npm run build:hb-addon
```

4. verify no drift:

```bash
npm run check:hb-addon-drift
```

5. run cheap pack validation:

```bash
npm run test:fixtures
npm run validate:pack
```

6. run AO integration truth:

```bash
npm run test:ao
```

7. if `test:ao` fails because of known contract drift, capture that explicitly in
   release notes rather than pretending the resolver is fully aligned.

## Why an overlay exists at all

Because right now we are in a transition:

- we want to stop drift immediately,
- but we do not want to rewrite canonical behavior and deployment assumptions in
  one risky jump.

So the overlay is not the final architecture.
It is a controlled bridge.

That is healthy as long as:

- the overlay stays small,
- it is explicit,
- it is generated through one script,
- and it is treated as debt to retire, not a second hidden source of truth.

## Immediate next backlog after this phase

1. move `www` fallback decision into canonical AO source or consciously reject it
   there
2. align AO integration spec with current write/role policy expectations
3. add CI gate for `check:hb-addon-drift`
4. decide whether runtime adapter response shaping also needs a canonical schema
   generator path

## Bottom line

We do not have the final clean resolver architecture yet.
But we do now have the first important guardrail:

- canonical AO source is the starting point,
- HB addon drift is explicit and machine-checkable,
- future work can reduce the overlay instead of multiplying hidden forks.
