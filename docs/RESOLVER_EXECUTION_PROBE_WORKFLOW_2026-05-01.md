# Resolver execution probe workflow

Date: 2026-05-01
Status: active lab workflow for fresh AO-native resolver PIDs

## Why this exists

Fresh resolver PIDs can now show a healthy replay chain while still returning an
empty `results.raw.Output` string for scheduler-triggered reads.

That means the old rule:

- `semantic_output_check_failed` => reject the PID

is too strict for current AO runtime behavior.

What we care about first is:

1. transport works,
2. slot advances,
3. compute replay is `200`,
4. runtime produced a structured compute result with no process error.

The new execution probe makes that explicit.

One important lab finding sits next to this workflow:

- late `process.handle` rebinding is replay-sensitive on the current AO runtime
  path,
- even a no-op identity wrapper can make a fresh PID fail early replay,
- so healthy resolver lab candidates should stay on the registry-style
  `Handlers` / global-handle route unless we have a very specific reason to
  test something narrower.

## Tool

- `ops/live-vps/local-tools/probe-resolver-execution.mjs`

It sends resolver actions through the scheduler and evaluates runtime effect
without requiring a non-empty semantic `Output` envelope.

It also captures direct process HTTP surfaces for the same action:

- `...~process@1.0/now?Action=...`
- `...~process@1.0/<Action>`

Default action set:

- `GetResolverState`
- `ResolveHostForNode`
- `ResolveRouteForHost`

## Example

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

Use `--reply-to` when we want to exercise the resolver reply-message contract
explicitly. A practical lab value is the candidate PID itself; that produces a
safe, self-addressed `Resolver-Command-Result` message without touching
production aliases.

## Success criteria

A candidate is considered execution-healthy when the report shows:

- `summary.transportOk == summary.total`
- `summary.runtimeOk == summary.total`
- `summary.failed == 0`

This is enough to keep using the PID as an AO-native lab candidate.

## Non-blocker

These do **not** automatically fail the candidate anymore:

- `summary.semanticOk == 0`
- per-action empty `results.raw.Output`
- `semantic_output_check_failed` from the legacy smoke helper

Those are runtime surface limitations, not necessarily process-chain failure.

## Baseline parity proof

On 2026-05-03 we re-probed a previously known-good AO registry PID on the public
Forward node:

- PID: `tIItgtKIdmozH0pk_-N6IWr-1cFHYObijGAp0J4ZDtU`
- base URL: `https://push.forward.computer`

It shows the same runtime shape as our healthy resolver lab PIDs:

- `compute=<slot>` returns `200`
- `results.raw.Output == ""`
- `...~process@1.0/now?Action=GetResolverState` returns the seed-style `1984`
  multipart body
- `...~process@1.0/GetResolverState` returns `404 not_found`

That is the strongest current evidence that empty semantic `Output` is not a
resolver-specific regression. It is a parity characteristic of the current AO
runtime surface on healthy processes too.

## Current fresh-PID pattern

On the current fresh lab resolver PID, the probe shows a consistent split:

- scheduler transport: healthy
- compute replay: healthy
- direct `now?Action=...`: still returns the seed-style `1984` payload
- direct action path `/<pid>~process@1.0/<Action>`: still `404 not_found`

So the fresh PID is good enough for AO-native lab replay work, but stock process
HTTP action surfaces are still not semantic resolver read paths yet.

## Most realistic next contract

The most realistic AO-native read contract now is **reply-message data**, not
plain `Output`.

Why:

- healthy public AO processes can still show empty `results.raw.Output`
- but `raw.Messages` survives compute replay and is already treated as a runtime
  signal by the probe
- the site process already uses this pattern by emitting JSON through
  `Send({ Action = "Site-Command-Result", Data = <json> })`

The probe now also looks for JSON envelopes inside `raw.Messages[*].Data`, so it
is ready for a resolver-side reply-message contract without changing stock HB.

## When to use strict semantic output anyway

Only turn on:

- `--strict-semantic-output 1`

when we explicitly want to study output-shape regressions.

That mode is diagnostic, not the default lab health gate.
