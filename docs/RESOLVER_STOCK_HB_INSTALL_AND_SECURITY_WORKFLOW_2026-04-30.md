# Resolver stock-HB install and security workflow

Date: 2026-04-30
Status: target operating model for next phase

## 1) Non-negotiable design goals

These are the rules we should keep unless we consciously decide to break them.

1. **Stock HyperBEAM stays stock**
   - no dependency on a private HB fork,
   - no dependence on a specific patch commit,
   - no resolver feature that only works because we mutated HB core.

2. **Resolver is installable next to an already running HB**
   - copy runtime files,
   - add env,
   - add systemd units,
   - add nginx snippets,
   - reload/restart only the minimum needed pieces.

3. **Per-request chain/AO reads are not the hot path**
   - live traffic should use a local cached host map / projection snapshot,
   - HB should receive a clear routing decision locally,
   - resolver authority may be AO-backed, but serving should be projection-backed.

4. **Unknown or untrusted host input must not become code execution**
   - host headers are untrusted,
   - DM1 / AR site claims are untrusted until verified,
   - AR content is untrusted,
   - runtime should fail closed on authority/control-plane ambiguity.

5. **Scaling must not require tenant DNS churn**
   - user/tenant CNAME should stay stable,
   - balancing should happen behind the stable tunnel entrypoint,
   - future multi-node routing should be infra-controlled, not tenant-controlled.

## 2) The workflow we should target

## 2.1 Authority workflow

Source of truth should be:

- AO resolver state and/or signed projection source

But serving workflow should be:

1. AO / DM1 / signed policy source changes
2. projection builder materializes a signed host-routing snapshot
3. local node verifies and caches that snapshot
4. nginx uses the local snapshot for host -> target routing
5. stock HB only receives already-decided traffic

That means:

- AO is the authority,
- projection is the fast read plane,
- nginx is the first runtime enforcement point,
- HB is the execution/serving engine, not the place where we want to do costly
  authority lookup on every request.

Also important:

- resolver is not the place where we should primarily decide **which VPS node**
  gets a request,
- that choice should normally happen at Cloudflare tunnel / Load Balancer
  level,
- resolver should primarily decide **what host authority means** once the
  request has already reached a healthy node.

## 2.2 Install workflow on a stock HB box

Target install workflow should be simple and repeatable:

1. stock HB is already running
2. install resolver companion pack:
   - adapter script
   - host-routing sync scripts
   - env examples
   - systemd services/timers
   - nginx `conf.d` map file + loopback config
3. set resolver env
4. point nginx at the local resolver projection outputs
   - host routing map loaded in `http{}`
   - HB loopback server consumes `$dm_host_target_prefix`
5. enable timers/services
6. run smoke checks

That is the workflow we should optimize for.

The repo should therefore carry a real companion installer, not just loose
files:

- `ops/live-vps/runtime/install-stock-hb-companion.sh`
- `ops/live-vps/runtime/README.md`

Not this:

- patch HB source,
- rebuild custom HB image,
- depend on internal commit behavior,
- or require invasive runtime mutations for normal install.

## 3) What the runtime topology should look like

Current practical topology should be formalized as:

```text
public domain
  -> cloudflare DNS / CNAME
  -> cloudflared tunnel entry
  -> optional Cloudflare Load Balancer later
  -> nginx on node
  -> local verified projection snapshot lookup
  -> stock HyperBEAM loopback target
  -> site/process path
```

Important point:

- **resolver should decide before traffic enters the dangerous/runtime-heavy part**
- not after untrusted traffic is already deep inside HB.

## 3.1 Public-only sites vs secret apps

The resolver architecture should support both of these without forcing them
into the same operational complexity:

### Public-only sites

- tx-backed landing pages
- simple public process sites
- no tenant Worker required

These should work from:

- Arweave config
- DNS TXT
- signed projection activation

### Secret apps

- auth
- payments
- mail
- private user actions

These can rely on Worker-owned secret runtime, but that must stay optional for
the product as a whole.

Important rule:

- do not make basic public site onboarding depend on Worker provisioning

## 4) Caching model we should commit to

Yes — the right direction is cached host lists / cached routing snapshots.

That cache should contain, at minimum:

- host
- canonical site target
- mode / allow / deny decision inputs
- optional route prefix / process/module/scheduler metadata
- signature metadata
- expiry metadata
- projection version / snapshot id

That gives us:

- fast local decisions,
- predictable behavior during AO slowness,
- clean multi-node fanout later,
- easier debugging and rollback.

What we should avoid as the default path:

- live remote resolution for every request,
- relying on body/query fallback as authority,
- resolving from arbitrary caller-supplied hints.

## 4.1 Slow-changing host authority vs fast-changing runtime state

This distinction matters a lot for scale.

Two different things can change:

1. **host authority**
   - which host belongs to which site / process / pool authority
2. **runtime/content state**
   - what that site serves right now
   - what backend in the pool is healthiest
   - what content/version is current behind the authority

Those should not churn at the same rate.

The host-routing projection should be treated as **slow-changing control
plane**:

- onboarding a new host
- revoking a host
- moving a host to a new site/pool authority
- exceptional failover/cutover

The fast-moving parts should happen **behind** that layer:

- content updates
- internal process state
- pool/node balancing
- health-based routing decisions

Why this matters:

- if we mutate `host -> target` every few seconds for many hosts, nginx reload
  frequency becomes the bottleneck
- if we keep `host -> authority` mostly stable, then reloads stay rare and
  predictable even while content/runtime changes rapidly behind that authority

So the architectural rule should be:

- **slow-changing:** `host -> site/process/pool authority`
- **fast-changing:** content/runtime/pool internals behind that authority

## 4.2 Why the current nginx layer should use `map`

Because host authority is still enforced in nginx, we want that lookup to stay
cheap even when the host set becomes large.

That means:

- do **not** keep growing a long `if ($host = ...)` chain inside `server {}`
- do use an nginx `map` in `http {}` context

The practical benefits are:

- cleaner config
- hash-based host lookup instead of a long condition chain
- easier batch activation of a new projection snapshot
- a clearer separation between:
  - projection generation/verification
  - and request-time routing decisions

For bigger installs we should also tune nginx hash capacity explicitly, not
wait until `nginx -t` starts warning on a large host set:

- `map_hash_bucket_size`
- `map_hash_max_size`

This does **not** remove the need for `nginx reload`.

It just makes reload-driven activation much saner for larger host sets, because
the request path itself is no longer expressed as a giant pile of host `if`
statements.

## 5) Scaling workflow for the future

The user-facing DNS workflow should remain stable:

- tenant/user points CNAME once
- we keep that stable

The scaling workflow behind it should evolve like this:

### Phase A — today
- one tunnel
- one HB node
- local projection snapshot

### Phase B — next
- one public tunnel entry
- multiple VPS nodes behind it
- Cloudflare Load Balancer / traffic steering chooses best healthy node
- each node keeps its own verified local projection snapshot

### Phase C — later
- optional app-aware routing metadata if infra-level LB stops being enough
- projection may include pool-aware metadata for special cases
- edge/load-balancer and resolver semantics may become aligned where useful

Important principle:

- balancing happens **behind** the stable public entry,
- not by forcing every tenant to repoint DNS whenever we grow.
- node selection belongs to the edge/LB layer first,
- resolver authority belongs to the host -> site/process decision layer.

## 6) Security workflow: what we must assume

We need to assume all of this is hostile until proven otherwise:

- host header
- path/query/body
- DM1 config references
- AR content and manifests
- AO messages from outside
- any “site” that enters the ecosystem

That does **not** automatically mean every site can RCE the box.

But it does mean we must separate:

- **routing authority**,
- **content serving**,
- **mutable admin/control plane**,
- **public write surface**.

## 6.1 Core trust boundaries

### Boundary A — public edge vs local runtime

Public internet should hit:

- cloudflared
- nginx

Stock HB should ideally not be directly public on raw admin-like paths.

### Boundary B — authority vs execution

Authority should come from:

- signed projection / AO resolver state

Execution should happen only after authority has already produced a decision.

### Boundary C — untrusted content vs trusted control plane

A malicious AR site should at worst be able to:

- be denied,
- be served as inert content,
- or fail within the constrained site-serving path.

It should **not** be able to:

- mutate resolver authority,
- rewrite host maps,
- influence local routing snapshot without signature/proof,
- or reach privileged runtime paths behind the same tunnel.

### Boundary D — signer vs serving node

Serving VPS nodes should verify and activate, not sign.

Resolver signing private keys belong in the operator control plane, not on the
serving node itself.

Preferred placement:

- `workers/async-worker`

Why:

- it already matches async/control-plane responsibility
- it is not part of the tenant public request path
- it keeps serving nodes verifier-only

## 6.2 What is actually dangerous

Important nuance for us:

Serving bytes from Arweave is not the same thing as executing untrusted server-side code.

The danger is highest where the runtime **interprets** or **executes** something, for example:

- AO process execution paths
- relay/cache/process control paths
- runtime template/render layers
- parser/normalizer code for manifests, headers, and action envelopes
- any public write endpoint that can reach privileged paths

So the workflow should keep the resolver/control-plane side as dumb and explicit as possible.

## 6.3 Security controls the resolver stack should enforce

### Must

1. **Verified signed projection before use**
   - no unsigned snapshot should become active authority
   - expiry must be enforced

2. **Default deny for unmapped/untrusted host authority**
   - unknown host should not silently route

3. **Loopback-only resolver adapter and privileged helper surfaces**
   - public should go through nginx-controlled routes only

4. **Method/path guardrails on write and resolver mutation actions**
   - public read paths and admin mutation paths must stay distinct

5. **No blind trust in AR/DM1 claims**
   - claim acceptance must be proof-driven, not content-driven

6. **Service separation and least privilege**
   - dedicated user/service where possible
   - minimal writable directories
   - no unnecessary public ports

### Should

1. rate limiting on public write paths
2. admission deny/allow state for known-bad hosts
3. public-safe observability endpoints only
4. structured decision logging for allow/deny reasons
5. reproducible smoke tests for hostile inputs

### Later

1. projection signature rotation workflow
2. multi-node trust manifest / node registry
3. health-aware pool routing
4. degraded-mode policy when authority data is stale

## 7) Recommended packaging model

To stay easy to install on stock HB, the resolver should be packaged as a
**companion layer**, not an HB fork.

That companion layer should include:

- canonical resolver source
- generated HB addon copy
- projection builder
- read adapter
- nginx snippets
- systemd units/timers
- smoke scripts
- schemas/docs

This repo is already close to that shape.

## 8) Concrete workflow we should follow from now on

### Development workflow

1. edit canonical resolver behavior in `ao/resolver/process.lua`
2. regenerate/check HB addon copy
3. run AO tests
4. run fixture pack
5. run pack validation
6. if projection/runtime touched, run adapter + host-routing smoke
7. only then deploy

### Deployment workflow

1. publish/update authority source
2. build signed projection
3. distribute projection to nodes
4. verify projection locally
5. activate snapshot in nginx/runtime
6. smoke public routes
7. monitor allow/deny and error rates

### Incident workflow

1. identify whether issue is:
   - authority data,
   - projection generation,
   - projection verification,
   - nginx routing,
   - stock HB serving,
   - public write path
2. rollback by restoring previous projection snapshot first
3. only touch AO/control-plane if snapshot rollback is insufficient

## 9) Immediate decisions we should lock in

I think we should explicitly adopt these positions now:

1. **Resolver remains stock-HB-compatible by design**
2. **Projection-backed cached host list is the primary serving path**
3. **Cloudflare tunnel stays the stable public entrypoint**
4. **Future balancing happens behind that entrypoint, not via tenant DNS churn**
5. **Untrusted ecosystem input is denied or constrained by default**
6. **Resolver/control plane must stay separate from untrusted site content paths**

## 10) Bottom line

If we align on this workflow, then the resolver is not “just a Lua contract.”
It becomes:

- a portable routing authority,
- a stock-HB-compatible install pack,
- a fast local host-map serving system,
- and later a distributed control plane for many cheap VPS nodes.

That is the right direction.
