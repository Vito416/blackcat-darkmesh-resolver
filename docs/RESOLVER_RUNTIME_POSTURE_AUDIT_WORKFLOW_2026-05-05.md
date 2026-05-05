# Resolver runtime posture audit workflow

Date: 2026-05-05
Status: practical completion helper

## Goal

Give operators one read-only command that answers:

- are we still serving through the projection-backed adapter?
- are signed projections actually required?
- is DM1 parity actually required?
- are the sync service/timer really enabled?

This helps the resolver completion phase because it turns "I think this node is
closer to target mode" into one explicit runtime posture report.

## Script

- `ops/live-vps/local-tools/audit-resolver-runtime-posture.sh`

## What it inspects

- resolver env file:
  - default `/etc/darkmesh/resolver-projection.env`
- host-routing state:
  - default `/var/lib/darkmesh/host-routing/state.json`
- optional `systemctl` state for:
  - `darkmesh-resolver-read-adapter.service`
  - `darkmesh-host-routing-sync.service`
  - `darkmesh-host-routing-sync.timer`

## What it reports

### Projection posture

- `projection.url`
- `projection.requireSigned`
- `projection.requireDm1Parity`
- `projection.trustManifestPath`
- whether a signer allowlist is configured

### Runtime state

- current state mode/reason
- last known sequence
- last verification reason
- last payload hash

### Service posture

- read-adapter enabled/active state
- sync service enabled/active state
- sync timer enabled/active state

### Derived completion posture

- `posture.readPathMode`
- `posture.activationTrustMode`
- `posture.completionGaps[]`

Typical gaps include:

- `projection_adapter_still_in_serving_path`
- `signed_projection_not_required`
- `dm1_parity_not_required`
- `sync_timer_not_enabled`
- `sync_timer_not_active`

## Example

On a real node:

```bash
bash ops/live-vps/local-tools/audit-resolver-runtime-posture.sh \
  --output /tmp/resolver-runtime-posture.json
```

Against the example env only:

```bash
bash ops/live-vps/local-tools/audit-resolver-runtime-posture.sh \
  --env-file ops/live-vps/runtime/etc/darkmesh/resolver-projection.env.example \
  --state-file /tmp/nonexistent-darkmesh-state.json \
  --skip-systemctl
```

## How to use it in the completion track

This script is most useful before onboarding work because it gives a crisp
answer to:

- how transitional the node still is
- whether parity enforcement is actually on
- whether we are still definitely adapter-backed

That makes it a good checkpoint tool while we finish resolver-core before
packaging:

1. static tx onboarding
2. static AO process onboarding
3. dynamic AO onboarding
