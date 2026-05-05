# Resolver web onboarding backend contract

Date: 2026-05-05
Status: frontend/backend planning note

## Why this document exists

If onboarding is going to be web-first, we need a clean backend contract before
we build pages.

This contract is not about public trust truth.

It is about:

- what the onboarding pages ask for
- what the backend validates
- what the UI can display

## Design rule

The web UI should call one coherent onboarding backend contract.

The UI should **not** assemble product behavior out of random shell scripts or
raw operator docs.

## Modes

The backend should expose three onboarding modes:

- `static_tx`
- `static_ao_process`
- `dynamic_ao`

Each mode should return:

- label
- short description
- required inputs
- optional inputs
- validation rules

## Shared request shape

```json
{
  "mode": "static_tx",
  "domain": "example.com",
  "canonicalHost": "example.com",
  "entryPath": "/",
  "target": {
    "txId": "..."
  }
}
```

Mode-specific `target` shapes:

### `static_tx`

```json
{
  "txId": "..."
}
```

### `static_ao_process`

```json
{
  "processId": "...",
  "entryPath": "/"
}
```

### `dynamic_ao`

```json
{
  "processId": "...",
  "entryPath": "/",
  "dynamicPolicy": "admission_controlled"
}
```

## Step 1 — input validation contract

The first backend call should validate user input and return:

```json
{
  "ok": true,
  "mode": "static_tx",
  "normalized": {
    "domain": "example.com",
    "canonicalHost": "example.com",
    "entryPath": "/",
    "targetType": "tx",
    "targetId": "..."
  },
  "errors": [],
  "warnings": []
}
```

Possible error classes:

- `invalid_domain`
- `invalid_entry_path`
- `invalid_tx_id`
- `invalid_process_id`
- `target_not_resolvable`
- `target_type_mismatch`

## Step 2 — DNS instruction contract

The UI should not manually construct DNS guidance.

The backend should return it:

```json
{
  "ok": true,
  "instructions": {
    "txtHost": "_darkmesh.example.com",
    "txtValue": "v=dm1;cfg=<cfgTx>;ttl=3600;seq=1",
    "edgeTarget": "darkmesh entrypoint",
    "wwwPolicy": "alias"
  }
}
```

This is what the onboarding page should render as copyable records.

## Step 3 — readiness / preflight contract

After the user claims DNS is set, the backend should answer:

```json
{
  "ok": true,
  "readiness": {
    "cfgPublished": true,
    "dnsTxtVisible": true,
    "targetReachable": true,
    "modeReady": true
  },
  "errors": [],
  "warnings": []
}
```

This becomes the “Ready to activate” state in the UI.

## Step 4 — activation status contract

The UI should poll a backend status object, not raw operator state:

```json
{
  "ok": true,
  "status": {
    "phase": "active",
    "phaseLabel": "Live",
    "domain": "example.com",
    "mode": "static_tx",
    "dnsSeen": true,
    "admissionState": "accepted",
    "projectionState": "active",
    "lastUpdatedAt": "2026-05-05T09:00:00Z"
  },
  "operatorDetails": null
}
```

Suggested `phase` values:

- `draft`
- `waiting_for_dns`
- `ready_for_admission`
- `admission_pending`
- `accepted`
- `projection_pending`
- `active`
- `rejected`
- `error`

## Error translation rule

The backend should map raw operator/runtime reasons into UI-safe messages.

Examples:

- `generated_at_too_old` -> “The node is waiting for a fresh signed routing snapshot.”
- `dm1_rebuild_failed` -> “We could not confirm the DNS/config projection yet.”
- `invalid_tx_id` -> “That Arweave transaction id does not look valid.”

The UI should not be forced to interpret raw internal reasons by itself.

## Operator/private boundary

This backend contract should be built from private/operator-capable internals,
but the tenant-facing page should only see the cleaned product surface.

Keep out of the normal tenant contract:

- raw SSH details
- raw systemd state
- raw trust manifest details
- raw local file mirror paths
- raw projection sequence churn unless explicitly useful

## Recommended implementation order

1. define the validation + DNS instruction contract
2. build the `static_tx` onboarding page first
3. reuse the same response shape for `static_ao_process`
4. then extend for `dynamic_ao`

## Companion docs

- `docs/RESOLVER_WEB_ONBOARDING_SPLIT_PLAN_2026-05-05.md`
- `docs/RESOLVER_TENANT_OPERATOR_ADMISSION_WORKFLOW_2026-04-30.md`
