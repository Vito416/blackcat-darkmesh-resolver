# Resolver AO-derived control-state inputs

Date: 2026-05-01
Status: control-plane summary contract

## Goal

Keep the worker control-plane useful for operators **without** turning it into
another hidden source of truth.

That means:

- `workers/async-worker` can publish control summaries,
- but those summaries should be derived from canonical `AO` handler outputs,
- not invented or manually maintained inside the worker.

## Accepted AO-derived inputs

`ops/live-vps/local-tools/publish-control-state-via-async-worker.sh` now accepts
three optional AO-derived JSON files:

- `--admission-state`
- `--due-hosts-state`
- `--dns-refresh-state`

These are expected to be the raw handler payloads (or faithful saved copies) of:

- `GetAdmissionState`
- `ListHostsDueForDnsRefresh`
- `GetDnsRefreshState`

No extra worker-specific wrapping is required.

## Expected shapes

### Admission state

Expected input is the raw `GetAdmissionState` output:

```json
{
  "schemaVersion": "1.0",
  "admission": {
    "allowlistEnabled": true,
    "allowHosts": {},
    "denyHosts": {},
    "allowCount": 0,
    "denyCount": 0,
    "updatedAt": "2026-05-01T10:00:00Z"
  }
}
```

The control-plane publisher extracts:

- `allowlistEnabled`
- `allowCount`
- `denyCount`
- `updatedAt`

### Due hosts state

Expected input is the raw `ListHostsDueForDnsRefresh` output:

```json
{
  "schemaVersion": "1.0",
  "generatedAt": "2026-05-01T10:00:00Z",
  "limit": 50,
  "counts": {
    "trackedHosts": 6,
    "returned": 2
  },
  "dueHosts": [
    { "host": "jdwt.fun" },
    { "host": "vddl.fun" }
  ]
}
```

The control-plane publisher extracts:

- `trackedHosts`
- `returned`
- `limit`
- `sampleHosts` (first 10 hostnames only)

### DNS refresh state

Expected input is the raw `GetDnsRefreshState` output:

```json
{
  "schemaVersion": "1.0",
  "generatedAt": "2026-05-01T10:00:00Z",
  "autoDns": {
    "enabled": true
  },
  "counts": {
    "trackedHosts": 6,
    "dueNow": 1,
    "withPendingRequest": 0
  }
}
```

The control-plane publisher extracts:

- `trackedHosts`
- `dueNow`
- `withPendingRequest`
- `autoDnsEnabled`

## Fallback behavior

If these AO-derived files are **not** supplied, the publisher still works.

It falls back to the current scout report and publishes:

- probe HTTP codes
- safe placeholder notes such as `not_exposed_yet`

That keeps the control-plane surface honest while we finish the actual AO fetch
path.

## Safe local validation

The publisher now supports:

- `--dry-run`

That means we can validate the final `resolver-control-state.v1` payload locally
without mutating the worker control-plane.

Example:

```bash
bash ops/live-vps/local-tools/publish-control-state-via-async-worker.sh \
  --report /tmp/dynamic-mode-scout-report.json \
  --admission-state /tmp/admission-state.json \
  --due-hosts-state /tmp/due-hosts-state.json \
  --dns-refresh-state /tmp/dns-refresh-state.json \
  --dry-run \
  --output /tmp/resolver-control-state-payload.json
```

## Current remaining gap

This contract is ready now.

What is **not** finished yet is the canonical producer that fetches those
handler payloads cleanly from live AO/HB and writes them to disk.

So the next real implementation step is:

1. build the AO state producer/fetcher,
2. emit these three raw handler JSON files,
3. feed them into the control-state publisher,
4. publish an actually AO-derived `admissionSummary` and `dueHostsSummary`.

That fetcher scaffold now exists in:

- `docs/RESOLVER_AO_CONTROL_STATE_FETCHER_WORKFLOW_2026-05-01.md`
