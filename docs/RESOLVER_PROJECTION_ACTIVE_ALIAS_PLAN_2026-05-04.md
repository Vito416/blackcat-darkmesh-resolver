# Resolver projection active alias plan

Date: 2026-05-04
Status: planned compatibility cleanup, not live cutover

## Why this exists

`GET /resolver/projection/current` works fine technically, but the name is easy
to misread as:

- one current site,
- one current page,
- or one currently served request.

That is not what this endpoint means.

It means:

- the current shared active signed routing snapshot,
- distributed to joined nodes,
- so they can all verify and activate the same authority state.

The intent of this note is to make the naming cleanup explicit without creating
an unnecessary breaking change.

It is also explicitly **not** a request to widen the live public surface today.

## Proposed naming model

Preferred public name:

- `GET /resolver/projection/active`

Compatibility name kept during transition:

- `GET /resolver/projection/current`

Meaning:

- both paths should return the same signed projection artifact
- `active` is the clearer operator and reader-facing label
- `current` remains a compatibility alias so existing joined nodes and scripts
  do not break

## What should not change

This is a naming cleanup, not a truth-model change.

The following stays the same:

- joined nodes still fetch one shared signed projection
- nodes still verify signature, freshness, and local parity rules
- the worker still acts as publication/distribution helper, not truth anchor
- historical snapshots remain versioned separately from the moving active
  pointer

## Rollout shape

### Phase 1 - docs first

Done in principle when docs describe:

- `current` as the current active shared snapshot
- `active` as the cleaner future public alias

This phase is intentionally no-risk.

### Phase 2 - add alias without removing current

When the worker/runtime surface is ready:

- add `GET /resolver/projection/active`
- keep `GET /resolver/projection/current` returning the same body

At this point:

- no joined-node config has to change immediately
- no rollback complexity is introduced
- but only do this if the naming gain is worth carrying one more public read
  path, even as a 1:1 alias

Tooling is already being prepared for that phase by preferring neutral
operator flags such as:

- `--worker-projection-url`
- `--projection-path`

instead of hard-coding the word `current` into new operator examples.

### Phase 3 - move examples and operator defaults

After the alias exists:

- update docs examples to prefer `projection/active`
- keep `projection/current` only in compatibility notes and old runbooks

Good first candidates:

- README examples
- joined-node smoke examples
- join checklists
- projection release docs

### Phase 4 - decide long-term compatibility stance

Only after we have enough confidence:

- either keep `projection/current` indefinitely as a harmless alias
- or de-emphasize it strongly while still avoiding urgent breakage

For the current resolver rollout, indefinite compatibility is the safer default.

## Acceptance criteria

The alias work is complete when:

- `GET /resolver/projection/active` returns the same artifact as
  `GET /resolver/projection/current`
- joined-node fetch and smoke tooling can use either path
- docs prefer `active`
- compatibility notes still mention `current`

## Current recommendation

Until the alias is actually implemented:

- keep using `GET /resolver/projection/current` in live examples
- describe it explicitly as the current active shared signed snapshot
- avoid pretending the alias already exists
- do **not** add `/resolver/projection/active` to live infrastructure by
  default just because tooling is alias-ready
