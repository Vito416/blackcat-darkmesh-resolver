# DarkMesh Resolver

Standalone working repository for the current DarkMesh Resolver stack.

This repo is a curated split-out of the resolver-related source, runtime shims,
fixtures, schemas, playbooks, and live operational artifacts that were
previously spread across:

- `blackcat-darkmesh-ao`
- `blackcat-darkmesh-gateway`
- small pieces of the live VPS runtime profile

## What is included

- Canonical AO resolver source:
  - `ao/resolver/process.lua`
  - `ao/shared/*.lua`
- AO-side integration test:
  - `tests/integration/resolver_process_spec.lua`
- Resolver WASM build tooling:
  - `scripts/build-ao-bundles.mjs`
  - `scripts/deploy/build_resolver_wasm_docker.sh`
  - vendored baseline runtime scaffold in `dist/registry/`
- HyperBEAM resolver reference implementation:
  - `ops/live-vps/runtime/hb/addons/darkmesh-resolver@1.0.lua`
  - `ops/live-vps/runtime/hb/addons/fixtures/resolver-fixtures.v1.lua`
- Current live read/runtime bridge:
  - `ops/live-vps/runtime/scripts/darkmesh-resolver-read-adapter.py`
  - `ops/live-vps/runtime/scripts/build-host-routing-envelope-from-dm1.sh`
  - `ops/live-vps/runtime/scripts/sync-nginx-host-routing.sh`
  - `ops/live-vps/runtime/nginx/*`
  - `ops/live-vps/runtime/systemd/*resolver*`
- Validation and smoke tooling:
  - `scripts/run-resolver-fixtures.lua`
  - `scripts/validate-resolver-pack.js`
  - `ops/live-vps/local-tools/smoke-resolver-alias.sh`
  - `ops/live-vps/local-tools/check-resolver-migration-readiness.sh`
- Resolver schemas and historical decision docs:
  - `ops/migrations/schemas/*resolver*`
  - `ops/migrations/*.md`
  - `ops/live-vps/*.md`
- Provenance log:
  - `docs/SOURCE_INVENTORY.tsv`

## Current truth

Today the resolver is in a useful but transitional state:

- domain resolution works,
- `www.*` aliases work,
- public resolver endpoints work,
- but the public alias path is still served by a local projection-backed read
  adapter rather than a pure AO-native execution path.

In other words: this repo already contains a production-capable resolver stack,
with signed `v2` projection now live in verify-only mode on the current
reference serving node, and with remote signed snapshot publication/fetch
already running through `workers/async-worker`, but not yet the full
proof-driven dynamic control-plane platform.

One important runtime detail is now explicit:

- the active host-routing projection is rendered as an nginx `map` in
  `http{}` context,
- not as a long `if ($host = ...)` chain inside the HB server block.

That keeps the current projection-backed serving path much healthier once the
host set grows.

Another scope decision is now explicit too:

- edge/tunnel/load-balancer should normally choose the VPS node,
- resolver should normally choose host authority on that node,
- resolver-side pool awareness is an optional later phase, not a required
  immediate dependency for multi-node rollout.

## Status snapshot

### Working today

- shared signed projection publication is live
- joined-node verify-only activation is live
- nginx `map`-based host routing is live
- minimal exposed surface posture is documented and reflected in current
  operator tooling defaults
- AO-native read health is surfaced into control-state as a first-class
  operator signal

### Still transitional

- the public alias path still depends on the projection-backed read adapter
- AO runtime readback is still practically `runtime_effect_only`, not rich
  semantic payload delivery
- worker control helpers still exist as operator convenience surfaces, even
  though normal flow is being narrowed

### Next real technical goals

- reduce reliance on the projection-backed read adapter
- keep moving joined-node activation toward stronger AO-derived parity checks
- improve AO-native read contracts without widening public surface

## Known limitations

- the public resolver alias still uses the projection-backed adapter instead of
  a fully AO-native serving path
- AO runtime reads are still healthiest at the `runtime_effect_only` contract
  level; rich semantic payload delivery is not yet a safe default assumption
- worker-side control helpers are still present as operator convenience tools,
  even though we are actively narrowing normal flow away from them
- tenant onboarding modes are not yet packaged as a finished operator-facing
  resolver product; that is the next completion phase

## Completion track

Before we shift focus to tenant onboarding, the practical "complete resolver"
target is:

- stable shared signed projection distribution and joined-node activation
- stronger AO-derived parity checks at activation time
- clear AO-native read contract expectations for operator health and debugging
- minimal-exposed-surface operator flow as the default posture
- one explicit onboarding story for:
  - static tx-backed sites
  - static AO process-backed sites
  - dynamic AO-backed sites

That completion plan is tracked in:

- `docs/RESOLVER_COMPLETION_TRACK_2026-05-05.md`
- `docs/RESOLVER_RUNTIME_POSTURE_AUDIT_WORKFLOW_2026-05-05.md`

## Replication model

The important serving model is now:

- one shared signed projection is published centrally,
- many compatible stock-HB nodes can fetch it,
- each node verifies and activates locally,
- DNS / edge routing may point traffic at any of those nodes.

That means the current small VPS is only the **first live reference node**.
It is not a special authority node.

If another operator runs:

- stock HyperBEAM,
- the DarkMesh Resolver companion pack,
- the same trust manifest,
- and the same remote signed projection URL,

then that node should resolve the same host authority decisions too.

## Tenant modes

DarkMesh Resolver should support two clean tenant-facing modes:

- `simple public mode`
  - tenant publishes config to Arweave
  - tenant adds `_darkmesh.<domain>` TXT + public DNS entry
  - config points to a public `tx` or a public `siteProcess`
  - tenant does **not** need a Worker
- `secret app mode`
  - tenant still uses the same domain/TXT workflow
  - but secret-dependent features (auth, payments, mail, private actions) are
    backed by a Worker-owned runtime

The resolver should keep those modes separate:

- simple public sites must stay easy and Worker-free
- secret-dependent app behavior must stay behind a dedicated Worker boundary

## Resolver signer placement

Resolver projection signing is **control-plane** work, not tenant site runtime
work.

So the preferred owner for the resolver signing private key is:

- `workers/async-worker`

not:

- a serving node
- a tenant/site secrets worker

That does **not** make the worker the source of truth.

In the target model:

- the worker is a signing/publication helper
- canonical truth still lives in DNS + AR + AO
- joined nodes should eventually verify not only signature/freshness, but also
  AO-derived parity before activation

The serving node should only:

- fetch or receive the projection
- verify it with the public trust manifest
- activate it locally

The current signer contract for that worker is documented in:

- `docs/RESOLVER_ASYNC_WORKER_SIGNER_CONTRACT_2026-04-30.md`
- `docs/RESOLVER_CURRENT_PRODUCTION_TRUTH_2026-04-30.md` describes the current live verify-only production shape.
- `docs/RESOLVER_CONTROL_PLANE_SURFACE_2026-04-30.md` describes the separate authenticated D2/control-plane surface.
- `docs/RESOLVER_TARGET_ARCHITECTURE_NO_CENTRAL_AUTHORITY_2026-05-01.md` describes the long-term truth/caching split.
- `docs/RESOLVER_AO_FIRST_TRUTH_MATRIX_2026-05-01.md` turns that split into a concrete "what lives where" implementation matrix.
- `docs/RESOLVER_AO_DERIVED_CONTROL_STATE_INPUTS_2026-05-01.md` defines how worker control summaries stay AO-derived instead of becoming a second authority.
- `docs/RESOLVER_AO_CONTROL_STATE_FETCHER_WORKFLOW_2026-05-01.md` covers the read-only producer that gathers raw AO/HB state before publish.
- `docs/RESOLVER_AOCONNECT_READ_BRIDGE_WORKFLOW_2026-05-01.md` covers the direct AO process read bridge scaffold via `@permaweb/aoconnect`.
- `docs/RESOLVER_NODE_SIDE_VERIFICATION_WORKFLOW_2026-05-01.md` defines the target activation rule where joined nodes treat worker output as helper transport, not truth.
- `docs/RESOLVER_DM1_PARITY_VERIFICATION_WORKFLOW_2026-05-01.md` covers the current joined-node parity scaffold that rebuilds DM1-derived payloads locally before activation.
- `docs/RESOLVER_FRESH_AO_PID_RECOVERY_WORKFLOW_2026-05-01.md` covers the clean-process-chain recovery path for future AO-native resolver work.

The first remote publication endpoint is now:

- `https://blackcat-async-worker.vitek-pasek.workers.dev/resolver/projection/current`

## Minimal surface quick matrix

This is the current small-operator posture at a glance:

- Public keep:
  - `GET /resolver/projection/current`
- Operator-only active:
  - projection release
  - projection freshness guard
  - joined-node smoke
  - `POST /resolver/control/state/publish`
  - optional explicit `GET /resolver/control/state/current`
- Operator-only dormant debug helpers:
  - `GET /resolver/control/capabilities`
  - `GET /resolver/control/status`
  - `GET /resolver/control/publication/current`
- First endpoints to retire from normal day-to-day use:
  - `GET /resolver/control/admission-summary`
  - `GET /resolver/control/due-hosts-summary`
  - `GET /resolver/control/dns-refresh-summary`

Naming note:

- `projection/current` means the current shared active signed routing snapshot
  for all joined nodes, not "the current page" or "one currently served site"
- if we rename the public distribution path later, `projection/active` is the
  clearest future alias; `projection/current` should then remain as a
  compatibility path
- in the current minimal-surface posture we are **not** adding that live alias
  yet; `projection/active` stays a documented future option, not a new active
  public endpoint

For the longer operator cutover rationale and day-to-day checklist, see:

- `docs/RESOLVER_MINIMAL_EXPOSED_SURFACE_2026-05-04.md`
- `docs/RESOLVER_CONTROL_SURFACE_USAGE_MAP_2026-05-04.md`
- `docs/RESOLVER_LIVE_OPERATIONS_MINIMAL_SURFACE_CHECKLIST_2026-05-04.md`
- `docs/RESOLVER_PROJECTION_ACTIVE_ALIAS_PLAN_2026-05-04.md`

## Quick commands

Run the fixture pack:

```bash
lua scripts/run-resolver-fixtures.lua
```

Generate the HB addon from canonical AO source:

```bash
npm run build:hb-addon
```

Check that the committed HB addon still matches canonical AO source + explicit overlay:

```bash
npm run check:hb-addon-drift
```

Validate the resolver pack:

```bash
node scripts/validate-resolver-pack.js
```

Audit current runtime posture (adapter vs parity vs signed-only):

```bash
bash ops/live-vps/local-tools/audit-resolver-runtime-posture.sh \
  --sudo \
  --output /tmp/resolver-runtime-posture.json
```

Check resolver-core completion posture:

```bash
bash ops/live-vps/local-tools/check-resolver-core-completion.sh \
  --profile pre-onboarding-complete \
  --sudo \
  --output /tmp/resolver-core-completion.json
```

Use the signed projection helper:

```bash
python3 scripts/projection-envelope-tool.py hash ops/live-vps/local-tools/signed-hostmap-envelope.v2.example.json
python3 scripts/projection-envelope-tool.py verify <envelope.json> <trust-manifest.json>
python3 scripts/generate-projection-signing-material.py \
  --output-dir /tmp/darkmesh-projection-key-2026-q2 \
  --signed-by darkmesh-resolver-mainnet \
  --key-id darkmesh-projection-key-2026-q2 \
  --not-before 2026-04-30T00:00:00Z \
  --not-after 2026-07-01T00:00:00Z
```

Or through npm:

```bash
npm run projection:tool -- verify <envelope.json> <trust-manifest.json>
```

Build a bootstrap DM1 projection:

```bash
bash ops/live-vps/runtime/scripts/build-host-routing-envelope-from-dm1.sh \
  --domains jdwt.fun,vddl.fun \
  --output /tmp/resolver-projection.v1.json
```

Build a signed-ready DM1 projection:

```bash
bash ops/live-vps/runtime/scripts/build-host-routing-envelope-from-dm1.sh \
  --domains jdwt.fun,vddl.fun \
  --envelope-version v2 \
  --signed-by darkmesh-resolver-mainnet \
  --key-id darkmesh-projection-key-2026-q2 \
  --sign-with /path/to/projection-signing-key.pem \
  --output /tmp/resolver-projection.v2.json
```

Bootstrap async-worker signer config from generated material:

```bash
bash ops/live-vps/local-tools/bootstrap-async-worker-signer.sh \
  --material-dir /tmp/darkmesh-projection-key-2026-q2 \
  --worker-dir ../blackcat-darkmesh-gateway/workers/async-worker
```

Preferred minimal-surface operator release path:

```bash
bash ops/live-vps/local-tools/projection-release-private-file.sh \
  --domains jdwt.fun,vddl.fun,blgateway.fun \
  --execute-live 1 \
  --ssh-target adminops@100.104.75.121 \
  --ssh-key ~/.ssh/darkmesh_new_vps_adminops \
  --switch-node-to-file-url 1 \
  --verify-node-state-url https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState
```

That path:

- signs locally with `~/.config/darkmesh/projection-signer-2026-q2`
- copies the signed artifact to the joined node over Tailscale/private SSH
- can flip the joined node into `file://` verify-only mode
- does **not** require `RESOLVER_*_AUTH_TOKEN`

The older async-worker bearer-token release path remains available as a
compatibility helper, but it is no longer the preferred operator default in the
minimal-exposed-surface model. Details:
`docs/RESOLVER_PRIVATE_FILE_RELEASE_WORKFLOW_2026-05-05.md`.

Publish a signed projection through the async worker:

```bash
export RESOLVER_PUBLISH_AUTH_TOKEN=...
bash ops/live-vps/local-tools/publish-projection-via-async-worker.sh \
  --worker-url https://<your-async-worker>/resolver/projection/publish \
  --input /tmp/resolver-projection.signed.v2.json
```

The next natural wrapper around those steps is a **projection release script**:

- build unsigned projection
- sign it through `async-worker`
- publish it
- verify that joined nodes activated the new sequence

That is a shared control-plane release step, not a special per-VPS activator.

Current wrapper:

```bash
export RESOLVER_SIGNER_AUTH_TOKEN=...
export RESOLVER_PUBLISH_AUTH_TOKEN=...

bash ops/live-vps/local-tools/projection-release.sh \
  --domains jdwt.fun,vddl.fun,blgateway.fun \
  --worker-base-url https://blackcat-async-worker.vitek-pasek.workers.dev \
  --verify-node-state-url https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState
```

Guard projection freshness and only publish when the current signed snapshot is
too close to expiry:

```bash
export RESOLVER_CONTROL_AUTH_TOKEN=...

bash ops/live-vps/local-tools/projection-release-guard.sh \
  --domains jdwt.fun,vddl.fun,blgateway.fun \
  --worker-base-url https://blackcat-async-worker.vitek-pasek.workers.dev \
  --control-state-url https://<private-control-surface>/resolver/control/state/current \
  --verify-node-state-url https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState \
  --min-valid-sec 1800 \
  --release-ttl-sec 86400
```

When `RESOLVER_CONTROL_AUTH_TOKEN` and an explicit `--control-state-url` are
present, the guard also reads control-plane AO health and records
`aoReadHealthy`, `aoReadPayloadAvailable`, and
`aoReadRuntimeEffectOnlyActions` in the decision output. In the
minimal-exposed-surface profile this is explicit on purpose, so the script does
not silently fall back to public `resolver/control/*`.

There is also an optional GitHub workflow for that guard:

- `.github/workflows/resolver-projection-guard.yml`
- configure GitHub secrets:
  - `RESOLVER_SIGNER_AUTH_TOKEN`
  - `RESOLVER_PUBLISH_AUTH_TOKEN`
  - `RESOLVER_CONTROL_AUTH_TOKEN`
- it is intentionally `workflow_dispatch`-only in the minimal-exposed-surface
  profile
- details in `docs/RESOLVER_CONTROL_PLANE_GUARD_AUTOMATION_2026-05-01.md`

Smoke-check a joined serving node:

```bash
export RESOLVER_CONTROL_AUTH_TOKEN=...

bash ops/live-vps/local-tools/joined-node-smoke.sh \
  --worker-projection-url https://blackcat-async-worker.vitek-pasek.workers.dev/resolver/projection/current \
  --control-state-url https://<private-control-surface>/resolver/control/state/current \
  --node-state-url https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState \
  --node-read-base-url https://hyperbeam.darkmesh.fun \
  --public-url https://jdwt.fun/ \
  --public-url https://www.jdwt.fun/ \
  --public-url https://vddl.fun/ \
  --public-url https://blgateway.fun/ \
  --write-guard-url https://write.darkmesh.fun/push
```

When the control token and an explicit control-state URL are present,
joined-node smoke also checks the live control-plane AO health summary before
it compares projection state.

Alias-readiness note:

- `joined-node-smoke.sh` and `dynamic-mode-scout.sh` now prefer the neutral
  `--worker-projection-url` flag
- `--worker-current-url` still works as a compatibility alias
- `projection-release.sh` and `projection-release-guard.sh` now also accept
  `--projection-path`, so we can move to `/resolver/projection/active` later
  without rewriting the scripts themselves
- that does **not** mean we should switch live defaults now; routine operator
  use should still stay on `/resolver/projection/current`

Scout current D2 readiness without mutating production:

```bash
export RESOLVER_SIGNER_AUTH_TOKEN=...

bash ops/live-vps/local-tools/dynamic-mode-scout.sh \
  --worker-base-url https://blackcat-async-worker.vitek-pasek.workers.dev \
  --domains jdwt.fun,vddl.fun,blgateway.fun \
  --release-dry-run
```

Publish the scout summary into the separate control-plane namespace:

```bash
export RESOLVER_CONTROL_AUTH_TOKEN=...

bash ops/live-vps/local-tools/publish-control-state-via-async-worker.sh \
  --worker-url https://<private-control-surface>/resolver/control/state/publish \
  --report /path/to/dynamic-mode-scout-report.json
```

If you already have raw AO handler outputs, you can merge them into the control
summary instead of publishing placeholder probe results:

```bash
bash ops/live-vps/local-tools/fetch-ao-control-state.sh \
  --node-base-url https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0 \
  --output-dir /tmp/darkmesh-ao-state

bash ops/live-vps/local-tools/publish-control-state-via-async-worker.sh \
  --report /path/to/dynamic-mode-scout-report.json \
  --admission-state /tmp/darkmesh-ao-state/admission-state.json \
  --due-hosts-state /tmp/darkmesh-ao-state/due-hosts-state.json \
  --dns-refresh-state /tmp/darkmesh-ao-state/dns-refresh-state.json \
  --dry-run \
  --output /tmp/resolver-control-state-payload.json
```

Then do the real publish once the payload looks right:

```bash
export RESOLVER_CONTROL_AUTH_TOKEN=...

bash ops/live-vps/local-tools/publish-control-state-via-async-worker.sh \
  --worker-url https://<private-control-surface>/resolver/control/state/publish \
  --report /path/to/dynamic-mode-scout-report.json \
  --admission-state /tmp/darkmesh-ao-state/admission-state.json \
  --due-hosts-state /tmp/darkmesh-ao-state/due-hosts-state.json \
  --dns-refresh-state /tmp/darkmesh-ao-state/dns-refresh-state.json
```

If the public GET surfaces are still too narrow, there is now also a direct
AO-process bridge scaffold via `@permaweb/aoconnect`:

```bash
node ops/live-vps/local-tools/fetch-ao-control-state-via-aoconnect.mjs \
  --process <resolver-pid> \
  --hb-url https://write.darkmesh.fun \
  --actor-role admin \
  --auth-signature-type hmac \
  --auth-signature-secret-file /secure/resolver-auth-secret.txt \
  --scheduler-direct-base-url https://write.darkmesh.fun \
  --compute-base-url https://write.darkmesh.fun \
  --output-dir /tmp/darkmesh-ao-aoconnect
```

Probe replay health on an existing resolver PID without touching alias cutover:

```bash
bash ops/live-vps/local-tools/probe-resolver-pid-history.sh \
  --pid <resolver-pid> \
  --base-url https://write.darkmesh.fun \
  --slot-max 12 \
  --output-dir /tmp/darkmesh-resolver-probe
```

Then run the resolver-specific execution probe on a fresh lab PID:

```bash
node ops/live-vps/local-tools/probe-resolver-execution.mjs \
  --pid <candidate-pid> \
  --wallet /secure/ao-wallet.json \
  --base-url https://write.darkmesh.fun \
  --reply-to <reply-target-pid> \
  --host jdwt.fun \
  --path / \
  --method GET \
  --output-dir /tmp/darkmesh-resolver-exec-probe
```

This probe treats empty `results.raw.Output` as a runtime-surface limitation,
not an automatic process failure, as long as transport + compute runtime effect
stay healthy.

As of 2026-05-03, that is not just a resolver lab quirk: a known-good public AO
registry PID on `https://push.forward.computer` shows the same pattern
(`compute=200`, empty `results.raw.Output`, `now?Action=...` => `1984`,
direct `/<Action>` => `404`).

Because of that, the most realistic next AO-native read contract is reply
messages (`raw.Messages[*].Data` carrying JSON), not more patching around plain
`Output`. The probe and aoconnect bridge are now prepared to parse that shape.
For lab validation they also support `--reply-to`, so we can deliberately give
resolver reads an explicit reply target and check whether
`Resolver-Command-Result` shows up in `raw.Messages`.

Prepare a fresh AO-native resolver candidate on a clean process chain:

```bash
bash ops/live-vps/local-tools/fresh-resolver-candidate.sh \
  --wallet /secure/ao-wallet.json \
  --build-wasm 1 \
  --graphql-url https://arweave.net/graphql \
  --output-dir /tmp/darkmesh-resolver-candidate-plan
```

Actually publish + spawn + probe a fresh candidate only with explicit opt-in:

```bash
bash ops/live-vps/local-tools/fresh-resolver-candidate.sh \
  --wallet /secure/ao-wallet.json \
  --build-wasm 1 \
  --execute-live 1 \
  --graphql-url https://arweave.net/graphql \
  --probe-slot-max 12 \
  --strict-smoke 1 \
  --output-dir /tmp/darkmesh-resolver-candidate-live
```

This live candidate flow now runs two gates by default:

- GraphQL module visibility gate (`--graphql-url`, default `https://arweave.net/graphql`)
- replay probe (`probe-resolver-pid-history.sh`)
- resolver execution probe (`probe-resolver-execution.mjs`)

Optional small-VPS metadata mode:

- use `ops/live-vps/runtime/scripts/darkmesh-graphql-shim.py` only if you want a
  tiny DarkMesh-only GraphQL helper
- keep it optional by switching only `GRAPHQL_URL` / `GRAPHQL_URLS` /
  `CHECKPOINT_GRAPHQL_URL`
- if a node later gets a full local indexed Arweave backend, disable the shim
  and point those URLs at the full service instead
- workflow: `docs/RESOLVER_OPTIONAL_GRAPHQL_SHIM_WORKFLOW_2026-05-03.md`
- helper for keeping the allowlist current:
  - `ops/live-vps/local-tools/update-graphql-shim-allowlist.sh`

If you want each fresh module publish to update the optional shim allowlist
automatically, pass the allowlist target(s) directly to the candidate flow:

```bash
bash ops/live-vps/local-tools/fresh-resolver-candidate.sh \
  --wallet /secure/ao-wallet.json \
  --build-wasm 1 \
  --execute-live 1 \
  --graphql-url http://127.0.0.1:18777/graphql \
  --graphql-shim-remote-target adminops@100.104.75.121 \
  --graphql-shim-remote-ssh-key ~/.ssh/darkmesh_new_vps_adminops \
  --output-dir /tmp/darkmesh-resolver-candidate-live
```

When `--graphql-url` points at a loopback-only shim such as
`http://127.0.0.1:18777/graphql`, the candidate flow now reuses
`--graphql-shim-remote-target` to perform the GraphQL visibility gate on that
remote node over ssh before spawn.

If you want the whole shim-aware lab cycle in one command, use:

```bash
bash ops/live-vps/local-tools/resolver-lab-cycle.sh \
  --wallet /secure/ao-wallet.json \
  --output-dir /tmp/darkmesh-resolver-lab-cycle \
  -- --module-name blackcat-ao-darkmesh-resolver-lab \
     --process-name darkmesh-resolver-lab
```

That wrapper:

- runs `fresh-resolver-candidate.sh`
- auto-updates the optional GraphQL shim allowlist
- reuses the remote loopback GraphQL gate
- then runs `fetch-ao-control-state-via-aoconnect.mjs` against the resulting PID

Keep late `process.handle` wrapper experiments opt-in only. A plain identity
rebind of `process.handle` has been replay-unsafe on the current AO runtime
path, while the registry-style `Handlers` / global-handle route remains
replay-healthy for fresh resolver lab PIDs.

If we ever need to revisit those replay-unsafe experiments, make that explicit:

```bash
bash ops/live-vps/local-tools/resolver-lab-cycle.sh \
  --allow-replay-unsafe-experiments 1 \
  --build-env PROCESS_HANDLE_IDENTITY_WRAPPER=1 \
  ...
```

For current AO-native readback, treat `readContract.state=runtime_effect_only`
as a healthy transport/runtime result. It means replay worked and the process
ran, even though current AO runtime surfaces still do not provide a semantic
payload envelope.

If you want to thread that health signal into D2/control-plane reporting, pass
the resulting aoconnect report into the scout layer:

```bash
bash ops/live-vps/local-tools/dynamic-mode-scout.sh \
  --aoconnect-report /tmp/dm-aoconnect-contract-dyi/ao-control-state-aoconnect-report.json \
  --output-dir /tmp/darkmesh-d2-scout
```

The target reply-message payload shape is documented in:

- `docs/RESOLVER_REPLY_MESSAGE_READ_CONTRACT_2026-05-04.md`
- `docs/RESOLVER_AO_RUNTIME_CARRIER_FINDINGS_2026-05-04.md`
- `docs/RESOLVER_MINIMAL_EXPOSED_SURFACE_2026-05-04.md`
- `docs/RESOLVER_PRIVATE_OPERATOR_CUTOVER_CHECKLIST_2026-05-04.md`
- `docs/RESOLVER_CONTROL_SURFACE_USAGE_MAP_2026-05-04.md`
- `docs/RESOLVER_LIVE_OPERATIONS_MINIMAL_SURFACE_CHECKLIST_2026-05-04.md`

If a module is finalized on Arweave but the fresh PID still fails with
`Gateway returned no transaction`, watch GraphQL visibility explicitly:

```bash
bash ops/live-vps/local-tools/watch-candidate-readiness.sh \
  --module-tx <module-tx> \
  --pid <candidate-pid> \
  --max-polls 20
```

Important release defaults:

- `www` aliases are included by default
- destructive routing diffs (removals / target changes) are blocked unless you
  explicitly pass `--allow-routing-diff`

Run the AO integration spec:

```bash
lua tests/integration/resolver_process_spec.lua
```

This spec now reflects the real security posture:

- by default it asserts centralized bundle writes are blocked and then seeds
  equivalent fixture state through the test harness,
- with opt-in env it also verifies the legacy centralized write path:

```bash
RESOLVER_ALLOW_CENTRALIZED_BUNDLE_WRITES=1 lua tests/integration/resolver_process_spec.lua
```

Build resolver WASM through Docker:

```bash
bash scripts/deploy/build_resolver_wasm_docker.sh
```

Stage the stock-HB companion pack:

```bash
bash ops/live-vps/runtime/install-stock-hb-companion.sh
```

Scale note for larger host sets:

- nginx host authority is now rendered as `map`, not a long `if ($host=...)`
  chain
- tune via:
  - `DARKMESH_NGINX_MAP_HASH_BUCKET_SIZE`
  - `DARKMESH_NGINX_MAP_HASH_MAX_SIZE`

## Recommended reading order

1. `docs/RESOLVER_STOCK_HB_INSTALL_AND_SECURITY_WORKFLOW_2026-04-30.md`
2. `docs/RESOLVER_TENANT_OPERATOR_ADMISSION_WORKFLOW_2026-04-30.md`
3. `docs/RESOLVER_SIGNED_PROJECTION_ACTIVATION_CHECKLIST_2026-04-30.md`
4. `docs/RESOLVER_SIGNED_PROJECTION_VERIFICATION_PLAN_2026-04-30.md`
5. `docs/RESOLVER_ASYNC_WORKER_SIGNER_CONTRACT_2026-04-30.md`
6. `docs/RESOLVER_OFF_NODE_SIGNER_CUTOVER_RUNBOOK_2026-04-30.md`
7. `docs/RESOLVER_CURRENT_PRODUCTION_TRUTH_2026-04-30.md`
8. `docs/RESOLVER_DYNAMIC_MODE_IMPLEMENTATION_PLAN_2026-04-30.md`
9. `docs/RESOLVER_REMOTE_SIGNED_SNAPSHOT_PUBLICATION_PLAN_2026-04-30.md`
10. `docs/RESOLVER_PROJECTION_RELEASE_WORKFLOW_2026-04-30.md`
11. `docs/RESOLVER_CONTROL_PLANE_SURFACE_2026-04-30.md`
12. `docs/RESOLVER_TARGET_ARCHITECTURE_NO_CENTRAL_AUTHORITY_2026-05-01.md`
13. `docs/RESOLVER_AO_FIRST_TRUTH_MATRIX_2026-05-01.md`
14. `docs/RESOLVER_AO_DERIVED_CONTROL_STATE_INPUTS_2026-05-01.md`
15. `docs/RESOLVER_AO_CONTROL_STATE_FETCHER_WORKFLOW_2026-05-01.md`
16. `docs/RESOLVER_AOCONNECT_READ_BRIDGE_WORKFLOW_2026-05-01.md`
17. `docs/RESOLVER_FRESH_AO_PID_RECOVERY_WORKFLOW_2026-05-01.md`
18. `docs/RESOLVER_CONTROL_PLANE_GUARD_AUTOMATION_2026-05-01.md`
19. `docs/RESOLVER_OPTIONAL_GRAPHQL_SHIM_WORKFLOW_2026-05-03.md`
20. `docs/RESOLVER_DYNAMIC_MODE_SCOUT_WORKFLOW_2026-04-30.md`
21. `docs/RESOLVER_NODE_JOIN_CHECKLIST_2026-04-30.md`
22. `docs/RESOLVER_HOST_ROUTING_V1_TO_V2_MIGRATION_2026-04-30.md`
23. `docs/RESOLVER_SIGNER_VERIFIER_IMPLEMENTATION_WORKFLOW_2026-04-30.md`
24. `docs/RESOLVER_WORKFLOW_AND_AUDIT_2026-04-30.md`
25. `docs/RESOLVER_SINGLE_SOURCE_OF_TRUTH_PLAN_2026-04-30.md`
26. `ops/migrations/DARKMESH_RESOLVER_CONTRACT_V1.md`
27. `ops/migrations/DARKMESH_RESOLVER_SECURITY_AUDIT_2026-04-24.md`
28. `ops/live-vps/RESOLVER_NO_STOCK_PATCH_OPTIONS_2026-04-27.md`
29. `docs/upstream/ao/07-hb-policy-contract-draft.md`

## Scope boundary

This repo intentionally focuses on resolver authority, adapter/runtime wiring,
and release evidence.

It does **not** try to fully re-home every consumer implementation that calls
into the resolver. For example, `consumers/gateway/tests/template-site-resolver.test.ts`
is included as a reference consumer artifact, not yet as a fully standalone
consumer test harness.
