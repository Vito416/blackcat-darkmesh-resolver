# Resolver off-node signer cutover runbook

Date: 2026-04-30
Status: operator runbook
Target: move resolver projection signing off the serving VPS and into `workers/async-worker`

## Goal

We want three things at once:

1. keep public traffic running,
2. rotate away from the signing key that ever lived on the VPS,
3. end in a verify-only node model.

## Current reality

The live VPS rollout proved the signed `v2` flow works, but the temporary test
shortcut put a projection signing private key on the serving node.

That is not an acceptable steady state.

So this cutover treats the current node-resident signing key as a temporary test
key and rotates to a new off-node key.

## Final target state

- `workers/async-worker` holds the resolver signing private key as a Worker secret
- the serving VPS has only:
  - `projection-trust.json`
  - signed projection snapshot(s)
  - verifier helper
- the serving VPS does **not** have:
  - `/etc/darkmesh/projection-signing-key.pem`
  - `DARKMESH_DM1_SIGN_WITH_PRIVATE_KEY=...`
- `DARKMESH_PROJECTION_REQUIRE_SIGNED=1` stays on
- resolver continues serving from signed `dm-hostmap-envelope.v2`

## Phase 1 — generate a fresh off-node key locally

On your local machine, from the resolver repo:

```bash
python3 scripts/generate-projection-signing-material.py \
  --output-dir /tmp/darkmesh-projection-key-2026-q2 \
  --signed-by darkmesh-resolver-mainnet \
  --key-id darkmesh-projection-key-2026-q2 \
  --not-before 2026-04-30T00:00:00Z \
  --not-after 2026-07-01T00:00:00Z
```

This gives you:

- `projection-signing-key.pem`
- `projection-signing-key.public.base64.txt`
- `projection-trust.json`
- `async-worker-vars.env`

Keep the private key local. Do **not** copy it to the VPS.

## Phase 2 — bootstrap async-worker signer secrets

In `blackcat-darkmesh-gateway/workers/async-worker`:

1. put secrets:

```bash
wrangler secret put RESOLVER_SIGNER_AUTH_TOKEN
wrangler secret put RESOLVER_SIGNER_PRIVATE_KEY
```

2. set or update non-secret vars in `wrangler.toml`:

```toml
[vars]
RESOLVER_SIGNER_SIGNED_BY = "darkmesh-resolver-mainnet"
RESOLVER_SIGNER_KEY_ID = "darkmesh-projection-key-2026-q2"
```

3. deploy the worker:

```bash
npm run deploy
```

## Phase 3 — smoke test the signer before touching the VPS

Build an unsigned projection locally:

```bash
bash ops/live-vps/runtime/scripts/build-host-routing-envelope-from-dm1.sh \
  --domains jdwt.fun,vddl.fun,blgateway.fun \
  --envelope-version v2 \
  --signed-by bootstrap \
  --key-id bootstrap \
  --output /tmp/resolver-projection.unsigned.v2.json
```

Then sign it through the worker:

```bash
export RESOLVER_SIGNER_AUTH_TOKEN=...
bash ops/live-vps/local-tools/sign-projection-via-async-worker.sh \
  --worker-url https://<your-async-worker>/resolver/projection/sign \
  --input /tmp/resolver-projection.unsigned.v2.json \
  --output /tmp/resolver-projection.signed.v2.json
```

Verify locally:

```bash
python3 scripts/projection-envelope-tool.py verify \
  /tmp/resolver-projection.signed.v2.json \
  /tmp/darkmesh-projection-key-2026-q2/projection-trust.json
```

Expected:

- `ok: true`
- `signatureAlg: ed25519`

Do not touch the VPS until this passes.

## Phase 4 — prepare a no-downtime trust bridge on the VPS

For a zero-drama cutover, temporarily trust both keys:

- the current temporary on-node key
- the new async-worker key

That means:

1. back up `/etc/darkmesh/projection-trust.json`
2. merge the new key into `keys`
3. ensure `allowedSigners` still includes the active signer id

This bridge window should be as short as possible.

Reason:

- the VPS is still serving current traffic,
- but we want it ready to verify the first worker-signed snapshot immediately.

## Phase 5 — publish the first worker-signed snapshot to the VPS

Recommended immediate cutover model:

- store the signed snapshot as a local file on the VPS,
- let the VPS fetch it via `file://`,
- keep signing off-node.

Example target path on VPS:

- `/etc/darkmesh/projections/resolver-projection.active.v2.json`

Copy the signed file to the VPS, for example:

```bash
scp -i ~/.ssh/darkmesh_new_vps_adminops \
  /tmp/resolver-projection.signed.v2.json \
  adminops@100.104.75.121:/tmp/resolver-projection.signed.v2.json

ssh -i ~/.ssh/darkmesh_new_vps_adminops adminops@100.104.75.121 \
  'sudo install -d -m 0755 /etc/darkmesh/projections && \
   sudo install -m 0640 /tmp/resolver-projection.signed.v2.json /etc/darkmesh/projections/resolver-projection.active.v2.json'
```

## Phase 6 — flip the VPS to verify-only signed file mode

On the VPS, update `/etc/darkmesh/resolver-projection.env`:

- set:
  - `DARKMESH_PROJECTION_URL=file:///etc/darkmesh/projections/resolver-projection.active.v2.json`
  - `DARKMESH_PROJECTION_REQUIRE_SIGNED=1`
- remove or comment:
  - `DARKMESH_DM1_AUTOBUILD=1` (if present)
  - `DARKMESH_DM1_SIGN_WITH_PRIVATE_KEY=...`

Then refresh:

```bash
sudo systemctl start darkmesh-host-routing-sync.service
cat /var/lib/darkmesh/host-routing/state.json
```

Expected:

- `mode = active`
- `lastEnvelopeVersion = dm-hostmap-envelope.v2`
- `lastKeyId = darkmesh-projection-key-2026-q2`
- `lastVerificationReason = ok`

At this point the VPS is serving from a worker-signed snapshot, not from its own private key.

## Phase 7 — remove the compromised-by-placement key from the VPS

Once the new signed file is active and public smoke is green:

1. delete the old signing env reference from `/etc/darkmesh/resolver-projection.env`
2. remove the file:

```bash
sudo rm -f /etc/darkmesh/projection-signing-key.pem
```

3. remove the old key entry from `/etc/darkmesh/projection-trust.json`
4. run sync again:

```bash
sudo systemctl start darkmesh-host-routing-sync.service
```

5. confirm the state still shows the new key id and signed `v2`

Now the node is truly verify-only.

## Phase 8 — public smoke

Check:

```bash
curl -s https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState | jq
curl -s 'https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/resolve?host=jdwt.fun&path=/&method=GET' | jq
curl -I https://jdwt.fun/
curl -I https://www.jdwt.fun/
```

Expected:

- resolver active
- projection metadata reports signed `v2`
- allow decision for mapped host
- public sites still respond normally

## Rollback plan

If the new worker-signed snapshot fails verification or routing:

1. restore the previous VPS trust manifest backup
2. restore the previous `/etc/darkmesh/resolver-projection.env`
3. restore the previous active signed snapshot or projection URL
4. run:

```bash
sudo systemctl start darkmesh-host-routing-sync.service
```

If needed, use the previously prepared rollout rollback script on the VPS.

## Recommended near-term operating model

Until we automate publication end-to-end, the clean interim workflow is:

1. local/operator machine builds unsigned `v2`
2. async-worker signs it
3. operator copies signed snapshot to VPS
4. VPS verifies and activates

That is already secure enough to keep the serving node verify-only while we
finish the more automated dynamic control-plane path later.
