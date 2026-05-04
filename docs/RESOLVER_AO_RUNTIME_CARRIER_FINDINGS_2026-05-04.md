# Resolver AO runtime carrier findings

Date: 2026-05-04
Status: current practical findings for AO-native readback

## Why this exists

We spent a long stretch testing why healthy resolver lab PIDs still show:

- `results.raw.Output == ""`
- `raw.Messages == []`
- direct `~process@1.0/<Action>` returns `404`
- `now?Action=...` returns the seed-style `1984` body

This note locks the current findings so we do not keep revisiting the same
replay-unsafe experiments.

## What we confirmed

### 1) Stock HB is not the thing we are patching

We did **not** modify stock HyperBEAM / Hyperengine.

All runtime experiments stayed inside our composed resolver runtime or local
operator tooling.

### 2) Effective wasm execution uses exported `handle`

On the reference node, `@permaweb/ao-loader` calls exported wasm `handle` and
then returns the resulting:

- `Output`
- `Messages`
- `Spawns`
- `Assignments`

So the effective boundary is the wasm `handle` return, not a later worker-side
rewrite.

### 3) Late `process.handle` wrapping is replay-unsafe

Fresh lab A/B runs showed that even a plain identity late rebind of
`process.handle` is replay-sensitive on the current AO runtime path.

Practical rule:

- keep resolver-specific late `process.handle` wrapping **off by default**
- only enable replay-unsafe variants intentionally in lab runs

That default is now reflected in `ao/resolver/process.lua` and guarded in
`ops/live-vps/local-tools/resolver-lab-cycle.sh`.

### 4) Empty semantic `Output` is not resolver-only

The same empty-output pattern also reproduces on a known-good public AO
baseline process:

- healthy scheduler/message transport
- healthy replay
- healthy runtime effect
- still empty semantic `Output`

So empty `Output` alone is not a good reason to keep patching resolver runtime
glue.

### 5) Reply-message payload is the right target contract, but not yet visible

Resolver code now scaffolds a reply-message contract:

- `Action = "Resolver-Command-Result"`
- `Read-Contract-Version = "resolver-reply-message.v1"`
- `Data = <resolver JSON envelope>`

But current healthy lab PIDs still surface:

- `readContract.state = "runtime_effect_only"`
- no visible `Resolver-Command-Result` in `raw.Messages[*]`

So this is a **target contract**, not yet a currently-observable runtime
carrier.

## Current operator conclusion

For AO-native resolver health, treat:

- `readContract.state = "runtime_effect_only"`

as a healthy result today when:

- transport succeeded
- replay succeeded
- runtime effect was observed
- and no runtime error surfaced

That is why live control-plane summaries now carry:

- `aoNativeReadbackSummary`
- per-surface `aoReadContract`

instead of treating missing payloads as automatic failure.

## What not to do next

Do **not** keep pushing these as default fixes:

- late `process.handle` wrappers
- result-capture passthrough hooks
- preserve-handler-result hooks
- post-return reply injection around `process.handle`

Those paths were useful for forensics, but they were not safe steady-state
runtime fixes.

## Best next direction

The safe direction now is:

1. keep operator/control-plane health wired to `readContract`
2. keep reply-message payload shape documented as the target
3. treat missing payload carriers as an AO runtime surface limitation until a
   cleaner AO-native carrier becomes observable
