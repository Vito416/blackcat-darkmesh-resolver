# Resolver tenant, operator, and admission workflow

Date: 2026-04-30
Status: working operating model

## 1) Why this document exists

DarkMesh Resolver now has two very different audiences:

- **tenant / user**
  - wants a simple self-serve publishing flow
- **operator**
  - has to keep the node secure, deterministic, and scalable

This document makes the split explicit so we keep the product UX simple without
keeping the trust model naive.

## 2) High-level product promise

From the tenant point of view, the desired workflow stays simple:

1. publish config to Arweave
2. add DNS records
3. the site starts routing through DarkMesh

That simplicity is still the goal.

What changed is **how much trust we place in that claim directly**.

A tenant publishing AR config + DNS does **not** directly become active routing
authority by itself.

Instead:

- it becomes a **claim**,
- admission evaluates it,
- control plane materializes a projection snapshot,
- only then does the node activate it.

That is the security boundary.

## 3) Tenant workflow

Important product direction:

- tenant workflow should be **web-first**
- operator workflow can stay **CLI/runbook-first**

So the shell commands and release mechanics in this repo are not the intended
tenant UX. They are the backend/operator side of the product.

## 3.1 What the tenant does

Tenant responsibilities should stay minimal:

1. publish site config to Arweave
2. ensure config contains a valid target reference
   - site process and/or site tx
   - valid entry path
3. publish DNS TXT at:
   - `_darkmesh.<domain>`
4. point public DNS to the stable DarkMesh entrypoint
   - typically CNAME / provider equivalent

For example, the TXT record carries:

- `cfg=<arweave-txid>`

The tenant should **not** need to know:

- which VPS node will serve the request,
- which region handles the traffic,
- whether a specific node is healthy,
- how we fan out snapshots internally.

That stays operator/infrastructure responsibility.

## 3.2 What the tenant should expect

If everything is valid:

- the domain becomes routable after admission + activation

If something is invalid:

- the domain should not partially route in a surprising way
- the system should fail closed
- the operator should have enough evidence to explain why it was rejected

## 3.3 Tenant product modes

We should treat tenant onboarding as two explicit product modes.

### Mode A — simple public mode

This is the default low-friction publishing path:

1. tenant publishes config to Arweave
2. config points to:
   - a public `siteTx`
   - or a public `siteProcess`
3. tenant adds `_darkmesh.<domain>` TXT
4. tenant points DNS to the DarkMesh entrypoint

In this mode:

- tenant does **not** need a Worker
- tenant does **not** manage secrets
- resolver + projection activation is enough

This is the mode we want for:

- landing pages
- tx-backed sites
- simple public sites

Preferred tenant UX for this mode:

- a web onboarding page
- not a console walkthrough

### Mode B — secret app mode

This is for sites that need secret-dependent behavior:

- auth
- payments
- mail
- private action signing
- other tenant-private integrations

In this mode:

- the public domain/TXT workflow stays the same
- but secret-dependent operations are backed by a Worker-owned runtime

Important product rule:

- the existence of secret app mode must **not** force simple public tenants to
  create a Worker just to publish a basic site

## 3.4 Split the product surface

The clean split should now be:

- **tenant-facing onboarding pages**
- **operator/backend resolver workflow**

That means:

- tenants see mode selection, DNS instructions, validation, and status pages
- operators keep the deeper control-plane and recovery mechanics

See also:

- `docs/RESOLVER_WEB_ONBOARDING_SPLIT_PLAN_2026-05-05.md`

## 4) Operator workflow

## 4.1 What the operator controls

The operator controls:

- stock HyperBEAM companion install
- nginx edge/runtime config
- projection build cadence
- signing keys / trust manifest
- activation policy
- fail-closed behavior
- rollout to one or many VPS nodes

The operator does **not** manually decide routing on every request.

The operator controls the **control plane**, not the hot path.

## 4.2 Current operator path

Today the intended operator flow is:

1. collect candidate claims from DM1 / AR
2. build projection envelope
3. optionally sign projection envelope (`v2`)
4. distribute projection to nodes
5. node verifies before activation
6. nginx activates local host-routing map
7. resolver adapter serves consistent read decisions from local verified state

## 4.2.1 Resolver signer placement

Resolver projection signing is operator/control-plane work.

That means the private signing key should live:

- outside the serving VPS nodes
- outside tenant-facing request paths
- outside per-site runtime secrets

Current preferred home:

- `workers/async-worker`

Why:

- async worker already matches control-plane / background responsibility
- resolver signing is asynchronous control-plane materialization
- serving nodes should stay verify-only

So the intended split is:

- `async-worker`
  - owns resolver projection signing private key
  - emits signed projection snapshots
- serving VPS nodes
  - hold only the public trust manifest
  - verify + activate
- per-site secret workers
  - remain for tenant/app secrets, not resolver authority signing

## 4.3 Node selection vs authority selection

This distinction matters a lot.

### Node selection

Normally handled by:

- Cloudflare Tunnel
- Cloudflare Load Balancer
- health checks
- edge traffic steering

This decides:

- **which VPS node receives the request**

### Authority selection

Handled by resolver + projection snapshot.

This decides:

- **what the host means on that node**
- which process/tx/path the host is bound to

That means:

- edge/LB chooses the machine
- resolver chooses the host authority on that machine

## 5) Admission workflow

Admission is the layer between:

- tenant claim
- active routing authority

This is where we prevent unsafe or malformed ecosystem input from turning into
live traffic decisions.

## 5.1 Admission inputs

Inputs are untrusted until validated:

- host/domain
- DNS TXT content
- AR config payload
- target process/tx references
- entry path
- metadata bundled into the projection source

## 5.2 Admission checks

At minimum admission must confirm:

1. domain format is valid
2. `_darkmesh.<domain>` TXT exists and parses
3. `cfg` tx id is valid format
4. config payload is valid JSON
5. target reference is valid
   - `siteProcess` or `siteTx`
6. `entryPath` is valid and normalized
7. projection envelope shape is valid
8. projection signature/trust rules are satisfied when signed mode is required
9. activation policy allows the candidate snapshot
   - freshness
   - monotonicity
   - signer/key policy

## 5.3 Admission outcomes

### Accepted

- claim is turned into projection entry
- node may activate it locally

### Rejected

- claim never becomes active authority
- node stays on previous known-good projection or fail-closed state

### Deferred

- claim exists but cannot be promoted yet
- for example waiting for:
  - valid signature
  - enough rollout evidence
  - explicit production promotion

## 6) Activation workflow on a node

The node itself should behave like this:

1. fetch/build candidate envelope
2. extract canonical envelope
3. verify shape + trust policy
4. if valid:
   - render nginx host map
   - activate map
   - mark state `active`
5. if invalid:
   - keep `stale_lkg` if allowed
   - otherwise go `fail_closed`

This is intentionally strict.

The node should never silently “kind of trust” a bad snapshot.

## 7) Runtime read behavior

Once activated, the adapter should read from local node state only.

That means:

- no per-request DM1 lookups
- no per-request AR authority lookup
- no ad-hoc trust in user-supplied hints

The adapter returns:

- allow for mapped hosts under valid projection state
- explicit deny for:
  - unmapped host
  - invalid signature state
  - expired projection
  - signed-required mismatch
  - other fail-closed projection states

## 8) Dynamic mode boundary

This document is intentionally about the **static authority layer**.

Dynamic mode comes later.

Before dynamic mode, we want this to be true:

- tenant claim path is clear
- operator signing/activation path is clear
- admission is explicit
- projection activation is fail-closed
- runtime read behavior is deterministic

Only after that should we let the system become more autonomous.

## 9) Bottom line

The product UX can stay simple:

- publish config to AR
- add DNS records
- site works

But internally the trust model should be:

- claim -> admission -> signed projection -> verified activation -> runtime serving

That is the safe version of self-serve.
