# Resolver fresh AO PID recovery workflow

Date: 2026-05-01
Status: next-step recovery workflow after live PID replay failure

## Why this exists

The current reference resolver PID is good enough for the projection-backed
serving shim, but it is not a safe foundation for AO-native readback work.

Current observed reality on the live reference PID
`PvYcHsA1IiCw_Aw5eK79qwIL_oJQ-_mY_RWAF5qMPu8`:

- `slot/current` is healthy and returns `19`
- `compute=1..10` return `200`
- `compute=11+` fail
- HyperBEAM logs show:
  - `error_computing_slot`
  - `Body is not valid: would attempt to fetch from scheduler in loadMessages`

That means the blocker is no longer just transport experimentation. The current
process history chain is itself not replay-safe past slot `10`.

## Operating rule

Do **not** cut production over to a new resolver PID until a fresh candidate
passes a clean replay-health gate.

Production may continue using the projection-backed adapter path while we prove
AO-native behavior on a fresh candidate chain.

## New helper scripts

### 1) Probe an existing resolver PID

- `ops/live-vps/local-tools/probe-resolver-pid-history.sh`

Purpose:

- read-only slot sweep on an existing PID
- optional signed scheduler smoke using a wallet
- report the first broken replay slot before any cutover discussion

Example:

```bash
bash ops/live-vps/local-tools/probe-resolver-pid-history.sh \
  --pid PvYcHsA1IiCw_Aw5eK79qwIL_oJQ-_mY_RWAF5qMPu8 \
  --base-url https://write.darkmesh.fun \
  --slot-max 12 \
  --output-dir /tmp/darkmesh-resolver-probe-current
```

Optional signed smoke:

```bash
bash ops/live-vps/local-tools/probe-resolver-pid-history.sh \
  --pid <candidate-pid> \
  --base-url https://write.darkmesh.fun \
  --slot-max 12 \
  --wallet /secure/ao-wallet.json \
  --smoke-action GetResolverState \
  --strict-smoke 1 \
  --require-semantic-smoke 1 \
  --output-dir /tmp/darkmesh-resolver-probe-candidate
```

### 2) Prepare a fresh candidate process chain

- `ops/live-vps/local-tools/fresh-resolver-candidate.sh`

Purpose:

- optional local resolver WASM rebuild
- publish a fresh module
- wait for GraphQL transaction visibility on the module tx
- spawn a fresh process on the write node
- immediately probe replay health on the new PID
- **no nginx alias update and no public cutover**

Safe default behavior:

- without `--execute-live 1`, it only writes a plan JSON
- with `--execute-live 1`, it publishes/spawns/probes for real

Plan-only example:

```bash
bash ops/live-vps/local-tools/fresh-resolver-candidate.sh \
  --wallet /secure/ao-wallet.json \
  --build-wasm 1 \
  --graphql-url https://arweave.net/graphql \
  --output-dir /tmp/darkmesh-resolver-candidate-plan
```

Real candidate creation example:

```bash
bash ops/live-vps/local-tools/fresh-resolver-candidate.sh \
  --wallet /secure/ao-wallet.json \
  --build-wasm 1 \
  --execute-live 1 \
  --graphql-url https://arweave.net/graphql \
  --graphql-shim-remote-target adminops@100.104.75.121 \
  --graphql-shim-remote-ssh-key ~/.ssh/darkmesh_new_vps_adminops \
  --probe-slot-max 12 \
  --smoke-action GetResolverState \
  --strict-smoke 1 \
  --require-semantic-smoke 1 \
  --output-dir /tmp/darkmesh-resolver-candidate-live
```

One-command shim-aware lab cycle:

```bash
bash ops/live-vps/local-tools/resolver-lab-cycle.sh \
  --wallet /secure/ao-wallet.json \
  --output-dir /tmp/darkmesh-resolver-lab-cycle \
  -- --module-name blackcat-ao-darkmesh-resolver-lab \
     --process-name darkmesh-resolver-lab
```

Only bring back replay-unsafe `process.handle` / capture experiments with
explicit opt-in:

```bash
bash ops/live-vps/local-tools/resolver-lab-cycle.sh \
  --allow-replay-unsafe-experiments 1 \
  --build-env PROCESS_HANDLE_IDENTITY_WRAPPER=1 \
  ...
```

This wrapper uses the same optional GraphQL shim flow, then immediately runs
the AO read bridge against the spawned PID so we can compare replay health vs
semantic output in one place.

Why the GraphQL gate matters:

- the `genesis-wasm-server` module loader throws
  `Gateway returned no transaction for '<tx>'`
  when the GraphQL response does not contain
  `data.transactions.edges[0].node`
- a module tx can already be visible on:
  - `/tx/<id>`
  - `/raw/<id>`
  - `arweave.net/tx/<id>/status`
  while still being absent from GraphQL indexing
- if we skip this gate, we can spawn a candidate PID that looks published but
  still fails `compute=1` only because GraphQL has not caught up yet

## Acceptance gates for a fresh candidate

Before we even think about alias/cutover, a fresh candidate should pass all of
these:

1. `slot/current` returns a numeric slot
2. the candidate module tx is visible on the GraphQL endpoint used by the
   runtime (`--graphql-url`, default `https://arweave.net/graphql`)
3. if the optional small-VPS GraphQL shim is enabled, the module tx is also
   pushed into the shim allowlist (either explicitly or via the integrated
   `--graphql-shim-*` options)
4. `compute=1..N` are all `200` for at least the first `12` slots
5. signed scheduler smoke does not fail transport
6. signed scheduler smoke shows runtime effect in the report:
   - `semanticSmoke.runtimeSummary.runtimeEffectOk == true`
7. semantic output is a bonus, not a blocker:
   - `semanticSmoke.ok == true` is nice to have,
   - but `semantic_output_check_failed` alone is not enough to reject a PID
8. no `loadMessages` scheduler-fetch replay error appears in HB logs
9. avoid late `process.handle` wrapper experiments on the candidate build:
   - on the current runtime path even an identity `process.handle = function(...) return orig(...) end`
     rebind has been replay-unsafe,
   - keep resolver routing on the `Handlers` / global-handle path unless a lab
     run explicitly proves otherwise

If replay health or runtime effect fail, the candidate stays a lab PID only.
If only semantic output is missing, treat it as an AO runtime surface gap, not
an automatic process-chain failure.

## What this workflow intentionally does not do

It does **not**:

- rewrite `/etc/nginx/snippets/darkmesh-resolver-pid.conf`
- touch the public alias route
- replace the current projection-backed production adapter
- move source-of-truth to the worker

It is only the clean-room path for proving that AO-native resolver behavior can
live on a replay-safe process chain.

## Recommended next execution order

1. Run `probe-resolver-pid-history.sh` on the current live PID and archive the
   failure report.
2. Use `fresh-resolver-candidate.sh --execute-live 0` to freeze the exact plan.
3. When ready, run the live candidate spawn against a wallet you trust.
4. Run the resolver-specific execution probe to confirm runtime effect across
   `GetResolverState`, `ResolveHostForNode`, and `ResolveRouteForHost`.
5. If the candidate passes, use that PID for the next AO-native readback phase.
6. Only later discuss adapter alias migration or public cutover.

Example:

```bash
node ops/live-vps/local-tools/probe-resolver-execution.mjs \
  --pid <candidate-pid> \
  --wallet /secure/ao-wallet.json \
  --base-url https://write.darkmesh.fun \
  --output-dir /tmp/darkmesh-resolver-exec-probe
```
