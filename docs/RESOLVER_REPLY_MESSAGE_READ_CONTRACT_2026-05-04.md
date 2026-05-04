# Resolver reply-message read contract

Date: 2026-05-04
Status: scaffolded target contract for AO-native readback

## Why this exists

Current healthy AO resolver lab PIDs can show:

- scheduler/message transport = healthy
- compute replay = healthy
- runtime effect = healthy
- semantic payload in `results.raw.Output` = still empty

So the practical next contract is to carry resolver read payloads in reply
messages instead of depending on plain `Output`.

## Target shape

When a resolver read action receives an explicit `Reply-To`, the resolver should
emit:

- `Target = <Reply-To>`
- `Action = "Resolver-Command-Result"`
- `Resolver-Action = <original action>`
- `Request-Id = <original request id>`
- `Read-Contract-Version = "resolver-reply-message.v1"`
- `Content-Type = "application/json"`
- `Data = <same JSON envelope the resolver would otherwise return>`

That contract is now scaffolded in `ao/resolver/process.lua`.

## How tooling should interpret it

Preferred AO-native read order:

1. semantic JSON payload in `Output`
2. semantic JSON payload in `Messages[*].Data` where
   `Action == "Resolver-Command-Result"`
3. if neither exists but runtime effect is healthy, treat the read as:
   - `readContract.state = "runtime_effect_only"`

That means:

- `semantic_payload` = best case
- `reply_message_payload` = equally valid semantic payload
- `runtime_effect_only` = healthy runtime, but payload surface still missing

## What this does not assume

This document does **not** claim that the current public AO runtime already
surfaces those reply messages reliably in compute results.

It only locks the target contract so:

- resolver code,
- probes,
- aoconnect fetch tooling,
- and future control-plane summaries

all converge on one payload shape.

## Practical implication

Until the runtime exposes those reply messages consistently, resolver control
state should treat:

- `readContract.state = "runtime_effect_only"`

as a healthy AO-native transport/runtime result, not as an automatic failure.
