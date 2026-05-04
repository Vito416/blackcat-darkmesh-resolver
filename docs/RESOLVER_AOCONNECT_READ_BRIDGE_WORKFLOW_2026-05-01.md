# Resolver aoconnect read bridge workflow

Date: 2026-05-01
Status: live invoke bridge scaffold

## Goal

Move one step closer to truly AO-derived control-plane summaries by trying to
fetch raw resolver handler outputs through `@permaweb/aoconnect`, instead of
depending only on public adapter URLs.

The new helper is:

- `ops/live-vps/local-tools/fetch-ao-control-state-via-aoconnect.mjs`

## What it does

It targets the resolver process directly and tries to fetch:

- `GetAdmissionState`
- `ListHostsDueForDnsRefresh`
- `GetDnsRefreshState`

Strategy:

1. try `ao.dryrun(...)`
2. if signer material is available, fall back to:
   - `message(...)`
   - `result(...)`
   - `compute=<slot>` fallback if needed
3. if signer material is available, also try scheduler-direct ANS104 ingress:
   - `POST /~scheduler@1.0/schedule?target=<pid>`
   - then `compute=<slot>` replay

For protected actions it can now also attach an application-level auth envelope
before transport:

- `Actor-Role`
- `Nonce`
- `ts`
- `Signature`

The helper currently supports:

- HMAC signing via `--auth-signature-secret-file`
- Ed25519 signing via `--auth-ed25519-private-key-file`

If successful, it writes the same normalized files expected by the publisher:

- `admission-state.json`
- `due-hosts-state.json`
- `dns-refresh-state.json`

and also:

- `ao-control-state-aoconnect-report.json`

## Example

```bash
node ops/live-vps/local-tools/fetch-ao-control-state-via-aoconnect.mjs \
  --process <resolver-pid> \
  --hb-url https://write.darkmesh.fun \
  --scheduler _wCF37G9t-xfJuYZqc6JXI9VrG4dzM5WUFgDfOn9LdM \
  --output-dir /tmp/darkmesh-ao-aoconnect
```

Optional signer fallback:

```bash
node ops/live-vps/local-tools/fetch-ao-control-state-via-aoconnect.mjs \
  --process <resolver-pid> \
  --wallet-jwk-file /path/to/ao-wallet.json \
  --reply-to <reply-target-pid> \
  --scheduler-direct-base-url https://write.darkmesh.fun \
  --compute-base-url https://write.darkmesh.fun \
  --output-dir /tmp/darkmesh-ao-aoconnect
```

`--reply-to` is optional, but it is the cleanest way to test resolver
reply-message envelopes once a candidate is replay-healthy. In lab runs we can
point it back at the candidate PID itself.

Protected-read scaffold (ready for stricter resolver builds):

```bash
node ops/live-vps/local-tools/fetch-ao-control-state-via-aoconnect.mjs \
  --process <resolver-pid> \
  --wallet-jwk-file /path/to/ao-wallet.json \
  --actor-role admin \
  --auth-signature-type hmac \
  --auth-signature-secret-file /secure/resolver-auth-secret.txt \
  --scheduler-direct-base-url https://write.darkmesh.fun \
  --compute-base-url https://write.darkmesh.fun \
  --output-dir /tmp/darkmesh-ao-aoconnect
```

or:

```bash
export AO_WALLET_JSON='{"kty":"RSA",...}'
node ops/live-vps/local-tools/fetch-ao-control-state-via-aoconnect.mjs \
  --process <resolver-pid> \
  --scheduler-direct-base-url https://write.darkmesh.fun \
  --compute-base-url https://write.darkmesh.fun \
  --output-dir /tmp/darkmesh-ao-aoconnect
```

## Current reality on the reference resolver

With the current public setup and **without** signer material, the helper now
finishes cleanly but reports:

- `GetAdmissionState` -> `Error running dryrun`
- `ListHostsDueForDnsRefresh` -> `Error running dryrun`
- `GetDnsRefreshState` -> `Error running dryrun`

And with the currently available local AO wallet material, signed
`message/result` fallback still reports:

- `GetAdmissionState` -> `Error sending message`
- `ListHostsDueForDnsRefresh` -> `Error sending message`
- `GetDnsRefreshState` -> `Error sending message`

On a fresh replay-healthy lab PID, the picture is slightly better:

- `GetDnsRefreshState` through signer-backed `message/result` can now report
  `runtime_effect_without_semantic_output`
- that means transport + compute replay are working,
- but the AO runtime still returns an empty semantic `Output` envelope

That behavior is now known to match a healthy public AO baseline too:

- known-good registry PID `tIItgtKIdmozH0pk_-N6IWr-1cFHYObijGAp0J4ZDtU`
- on `https://push.forward.computer`
- `compute=<slot>` returns `200`
- but `results.raw.Output` is still empty,
- `now?Action=...` still returns the seed-style `1984` multipart body,
- and direct `/<Action>` path still returns `404`

So `runtime_effect_without_semantic_output` should currently be treated as a
runtime-surface parity result, not automatically as a resolver-only defect.

The helper now makes that explicit in `readContract`:

- `state=semantic_payload` means we got a canonical JSON envelope from `Output`
- `state=reply_message_payload` means we got the envelope from `Messages[*].Data`
- `state=runtime_effect_only` means transport + replay are healthy, but the
  current AO runtime did not expose a semantic payload
- `state=transport_unavailable` or `state=runtime_error` are the real blockers

When reply messages do show up, the preferred carrier is:

- `Action = "Resolver-Command-Result"`
- `Read-Contract-Version = "resolver-reply-message.v1"`

The helper now prefers that action over generic message envelopes.

## Practical implication

For resolver control-state reads, the next realistic AO-native contract is:

- scheduler/message transport remains the same
- compute replay remains the same
- semantic payload is carried in `raw.Messages[*].Data` as JSON

This avoids depending on plain `results.raw.Output`, which is now known to be
empty even on healthy public AO baselines.

The bridge helper is now prepared for that shape too:

- it first tries `Output`
- then falls back to JSON envelopes found in `Messages[*]`

Scheduler-direct is now a little clearer too:

- `https://push.forward.computer/~scheduler@1.0/schedule?...` rejected our
  current local wallet path with `No location found for address ...`
- `https://write.darkmesh.fun/~scheduler@1.0/schedule?...` **does** accept the
  same ANS104 message and returns a numeric slot
- but follow-up `compute=<slot>` replay on the current reference resolver path
  still fails at the runtime/fronting layer (`520` via public front, `500` on
  local node replay during read-only testing)

So this bridge scaffold is real and testable, but the current production read
transport is still blocked by one of these layers:

- unsigned dryrun
- signer-backed message transport
- or scheduler-direct compute replay on the current resolver PID/runtime chain
- and even on fresh lab PIDs, semantic output is still thinner than the
  projection-backed adapter surface

## Why this still helps

This narrows the remaining problem a lot:

- the publisher contract is done
- the shell fetcher is done
- the aoconnect bridge is done

What remains is specifically:

1. confirm which runtime path is canonical for the resolver process:
   - `dryrun/message/result`
   - or scheduler-direct + local compute
2. confirm whether the currently available wallet is the right ingress signer
   for long-term operator reads,
3. keep any worker/operator relay explicitly helper-only, not a source of
   truth,
4. once readback is stable, plug these AO-derived outputs into node-side parity
   and control summaries.

## Resolver-side compatibility note

Protected resolver handlers frequently use `require_no_extras(...)` input
contracts. We now strip auth/transport envelope fields before handler-level
validation inside `ao/resolver/process.lua`, so stricter requests can carry:

- nonce
- timestamp
- signature
- JWT/device metadata

without every protected handler needing to duplicate those fields in its local
allowlist.

## Current live blocker

The remaining blocker is now clearly tied to the current reference resolver PID
chain, not just to this bridge helper:

- live PID `PvYcHsA1IiCw_Aw5eK79qwIL_oJQ-_mY_RWAF5qMPu8` replays cleanly only
  through slot `10`
- `compute=11+` fails with `would attempt to fetch from scheduler in loadMessages`

That means the next safe AO-native step is a fresh candidate PID on a clean
process history chain, documented in:

- `docs/RESOLVER_FRESH_AO_PID_RECOVERY_WORKFLOW_2026-05-01.md`

## Next step

Once signer-backed readback is confirmed, this helper can become the canonical
producer for:

- AO-derived `admissionSummary`
- AO-derived `dueHostsSummary`
- and eventually richer AO-native dynamic mode state
