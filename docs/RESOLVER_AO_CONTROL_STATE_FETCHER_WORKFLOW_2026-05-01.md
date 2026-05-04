# Resolver AO control-state fetcher workflow

Date: 2026-05-01
Status: read-only producer scaffold

## Goal

We already have:

- a control-plane surface in `workers/async-worker`
- a publisher that can accept AO-derived raw handler payloads

What we still need between those two is a read-only producer that gathers the
raw AO/HB handler outputs in one place.

That producer is now:

- `ops/live-vps/local-tools/fetch-ao-control-state.sh`

## What it does

The script collects raw JSON for:

- `GetAdmissionState`
- `ListHostsDueForDnsRefresh`
- `GetDnsRefreshState`

It can work in two modes:

1. **URL mode**
   - fetch live payloads from HTTP endpoints
2. **File mode**
   - copy already-captured raw JSON files into a normalized output directory

It then writes:

- `admission-state.json` (if available)
- `due-hosts-state.json` (if available)
- `dns-refresh-state.json` (if available)
- `ao-control-state-fetch-report.json`

## Why this matters

This keeps responsibilities clean:

- fetcher = read-only producer
- publisher = worker control-state writer
- worker = control-plane cache / helper
- AO = canonical mutable truth

No part of this flow requires the worker to invent state on its own.

## Example: file mode

```bash
bash ops/live-vps/local-tools/fetch-ao-control-state.sh \
  --admission-file /tmp/GetAdmissionState.json \
  --due-hosts-file /tmp/ListHostsDueForDnsRefresh.json \
  --dns-refresh-file /tmp/GetDnsRefreshState.json \
  --output-dir /tmp/darkmesh-ao-state
```

## Example: URL mode

```bash
bash ops/live-vps/local-tools/fetch-ao-control-state.sh \
  --node-base-url https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0 \
  --output-dir /tmp/darkmesh-ao-state
```

## Example: future POST/invoke path

If the eventual AO/HB bridge needs POST + body instead of plain GET, the
fetcher is already prepared for that:

```bash
bash ops/live-vps/local-tools/fetch-ao-control-state.sh \
  --admission-url https://example.test/invoke \
  --admission-method POST \
  --admission-body-json '{"Action":"GetAdmissionState"}' \
  --output-dir /tmp/darkmesh-ao-state
```

## Hand-off into control-state publish

Once the fetcher has produced raw files, the publisher can consume them
directly:

```bash
export RESOLVER_CONTROL_AUTH_TOKEN=...

bash ops/live-vps/local-tools/publish-control-state-via-async-worker.sh \
  --worker-url https://<private-control-surface>/resolver/control/state/publish \
  --report /tmp/dynamic-mode-scout-report.json \
  --admission-state /tmp/darkmesh-ao-state/admission-state.json \
  --due-hosts-state /tmp/darkmesh-ao-state/due-hosts-state.json \
  --dns-refresh-state /tmp/darkmesh-ao-state/dns-refresh-state.json
```

## Current reality

The scaffold is ready.

Today on the reference public node, the default GET paths currently behave like
this:

- `GetDnsRefreshState` -> available
- `GetAdmissionState` -> `404`
- `ListHostsDueForDnsRefresh` -> `404`

What is still unresolved is the **best live AO invoke path** for
`GetAdmissionState` and `ListHostsDueForDnsRefresh` on the current production
node.

There is now also a direct AO-process bridge scaffold for that next hop:

- `docs/RESOLVER_AOCONNECT_READ_BRIDGE_WORKFLOW_2026-05-01.md`

So the next implementation step is not another publisher change.
It is:

1. decide the canonical live AO fetch path,
2. wire that path into this fetcher,
3. start publishing real AO-derived admission / due-host summaries.
