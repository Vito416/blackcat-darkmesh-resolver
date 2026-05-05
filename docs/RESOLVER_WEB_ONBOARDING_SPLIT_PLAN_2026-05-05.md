# Resolver web onboarding split plan

Date: 2026-05-05
Status: next-phase product plan

## Goal

Now that the reference node satisfies:

- `production-stable`
- `pre-onboarding-complete`

we should stop thinking about onboarding as one giant console-first workflow.

The right split is:

1. **resolver-core / operator backend**
2. **tenant-facing onboarding web experience**

That keeps the trust boundary honest while giving tenants the product UX they
actually want.

## Product stance

Tenants should not be expected to:

- run shell scripts
- read runbooks
- reason about projection snapshots
- understand signed file distribution
- care which VPS node is serving them

Tenants should be able to use a web flow that says, in plain language:

1. choose onboarding mode
2. fill in domain + target details
3. see required DNS records
4. verify readiness
5. watch admission / activation progress

Console-first tooling remains important, but for operators only.

## Split architecture

## Track A — operator/backend workflow

This stays private, explicit, and infrastructure-oriented.

Examples:

- signed projection release
- trust / parity posture
- node activation checks
- control-plane summaries
- recovery / cutover / audit

Users:

- operators
- maintainers
- automation

Primary tools:

- `ops/live-vps/local-tools/projection-release-private-file.sh`
- runtime posture audit
- completion gate
- private AO/control-state helpers

## Track B — tenant-facing onboarding web workflow

This becomes the primary product surface for end users.

Examples:

- choose `static tx`, `static AO process`, or `dynamic AO`
- generate or validate `_darkmesh.<domain>` TXT
- generate edge DNS target instructions
- validate config tx / process id / entry path
- show activation status and errors in human language

Users:

- site owners
- creators
- non-operator tenants

Primary output:

- one or more onboarding pages, not shell commands

## The three onboarding web modes

## 1. Static tx-backed site

Tenant-facing page should handle:

- domain
- Arweave tx target
- optional canonical host / `www` policy
- DNS instructions
- validation and activation tracking

The tenant should never need CLI for the normal happy path.

## 2. Static AO process-backed site

Tenant-facing page should handle:

- domain
- AO/site process id
- entry path
- DNS instructions
- validation and activation tracking

Again, CLI should stay an operator/debug fallback, not the main UX.

## 3. Dynamic AO-backed site

Tenant-facing page should handle:

- domain
- resolver/dynamic mode selection
- AO process references
- proof/admission readiness hints
- status visibility

This mode may still expose more operator nuance, but the default UX should
still be web-first.

## What should stay out of the tenant UI

Do not leak raw operator concepts into the normal onboarding surface:

- trust manifest internals
- snapshot sequence numbers as primary UX
- direct systemd operations
- private file mirror mechanics
- reference node SSH details

Those belong to the operator/backend layer.

## Recommended implementation order

## Phase 1 — backend contract definition

Define the web onboarding backend inputs/outputs clearly:

- mode selection contract
- validation contract
- DNS instruction contract
- activation status contract
- error reason contract

## Phase 2 — static tx onboarding page

Start with the simplest tenant mode first:

- least moving parts
- best first user experience
- fastest path to a polished onboarding page

## Phase 3 — static AO process onboarding page

Reuse the same page model, but swap target validation rules.

## Phase 4 — dynamic AO onboarding page

Only after the first two flows feel product-grade.

## Success criteria

We should consider onboarding productization successful when:

- normal tenants can complete the happy path from a web page
- CLI becomes optional for users, not mandatory
- operator-only complexity stays behind the curtain
- resolver trust boundaries stay as strict as they are now
