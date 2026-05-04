# Resolver signed projection activation checklist

Date: 2026-04-30
Status: operator runbook

This checklist is the shortest reliable path from:

- stock HyperBEAM already running

to:

- DarkMesh Resolver companion installed
- signed `dm-hostmap-envelope.v2` verified
- local host-routing activated
- resolver adapter serving explicit read decisions

## 1) Preconditions

Confirm the node already has:

1. stock HyperBEAM reachable on `127.0.0.1:8734`
2. nginx installed
3. systemd available
4. Python 3 available
5. `jq`, `curl`, `sha256sum`

Recommended:

- `cloudflared` already working for the public entrypoint
- a dedicated resolver signing key managed outside the node

## 2) Install the companion pack

From the repo root:

```bash
bash ops/live-vps/runtime/install-stock-hb-companion.sh --install-nginx-loopbacks
```

If you want the installer to also enable services immediately:

```bash
sudo bash ops/live-vps/runtime/install-stock-hb-companion.sh \
  --install-nginx-loopbacks \
  --enable-services
```

## 3) Configure local runtime files

Edit:

- `/etc/darkmesh/resolver-projection.env`
- `/etc/darkmesh/resolver-adapter.env`
- `/etc/darkmesh/projection-trust.json`

Minimum fields to review in `resolver-projection.env`:

- `DARKMESH_PROJECTION_URL`
- `DARKMESH_PROJECTION_TRUST_MANIFEST`
- `DARKMESH_PROJECTION_REQUIRE_SIGNED`
- `DARKMESH_PROJECTION_VERIFY_BIN`
- `DARKMESH_NGINX_MAP_HASH_BUCKET_SIZE`
- `DARKMESH_NGINX_MAP_HASH_MAX_SIZE`

## 4) Wire nginx

Ensure nginx loads:

- `/etc/nginx/conf.d/darkmesh-host-routing-map.conf`
- `/etc/nginx/snippets/darkmesh-resolver-pid.conf`

Enable or merge:

- `/etc/nginx/sites-available/darkmesh-hyperbeam-loopback.conf`
- `/etc/nginx/sites-available/darkmesh-write-loopback.conf`

Then validate:

```bash
sudo nginx -t
```

## 5) Bootstrap validation in dual-stack mode

For first install / controlled bootstrap, start with:

- `DARKMESH_PROJECTION_REQUIRE_SIGNED=0`

Then run:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now darkmesh-resolver-read-adapter.service
sudo systemctl enable --now darkmesh-host-routing-sync.timer
sudo systemctl start darkmesh-host-routing-sync.service
```

Confirm the state file:

```bash
cat /var/lib/darkmesh/host-routing/state.json
```

Expected bootstrap success signals:

- `mode = active`
- `lastEnvelopeVersion = dm-hostmap-envelope.v1` or `dm-hostmap-envelope.v2`
- `lastVerificationReason = legacy_v1_bootstrap` for v1
- `lastVerificationReason = ok` for v2

## 6) Manual signed envelope verification

Before flipping production to signed-required, verify the signed envelope
directly:

```bash
python3 /usr/local/sbin/projection-envelope-tool.py verify \
  /path/to/resolver-projection.v2.json \
  /etc/darkmesh/projection-trust.json
```

Expected:

- JSON output with `"ok": true`

## 7) Activate signed-required mode

Once the producer side emits signed `dm-hostmap-envelope.v2`, flip:

```bash
DARKMESH_PROJECTION_REQUIRE_SIGNED=1
```

Then refresh:

```bash
sudo systemctl start darkmesh-host-routing-sync.service
```

Confirm:

```bash
cat /var/lib/darkmesh/host-routing/state.json
```

Expected signed mode success signals:

- `mode = active`
- `lastEnvelopeVersion = dm-hostmap-envelope.v2`
- `lastKeyId` present
- `lastSequence` present
- `lastPayloadHash` present
- `lastVerifiedAt` present
- `lastVerificationReason = ok`

## 8) Fail-closed sanity checks

Resolver must fail closed when signed mode is required and the snapshot is not
acceptable.

Examples to test:

1. trust manifest missing
2. invalid signature
3. expired envelope
4. rollback / sequence rejection
5. legacy `v1` envelope while `DARKMESH_PROJECTION_REQUIRE_SIGNED=1`

Expected state:

- `mode = fail_closed`
- `reason` is explicit

Expected adapter behavior:

- explicit deny code such as:
  - `DENY_FAIL_CLOSED_PROJECTION_INVALID_SIGNATURE`
  - `DENY_FAIL_CLOSED_PROJECTION_EXPIRED`
  - `DENY_FAIL_CLOSED_PROJECTION_SIGNED_REQUIRED`

## 9) Public read-path smoke

Check the resolver adapter locally:

```bash
curl -s http://127.0.0.1:8760/~darkmesh-resolver@1.0/GetResolverState | jq
curl -s 'http://127.0.0.1:8760/~darkmesh-resolver@1.0/resolve?host=jdwt.fun&path=/&method=GET' | jq
```

Check through nginx/public alias path:

```bash
curl -s http://127.0.0.1:8744/~darkmesh-resolver@1.0/GetResolverState | jq
curl -s 'http://127.0.0.1:8744/~darkmesh-resolver@1.0/resolve?host=jdwt.fun&path=/&method=GET' | jq
```

Expected:

- active state
- allow decision for mapped hosts
- explicit deny for unmapped hosts
- projection metadata returned

## 10) Production steady state

When signed mode is healthy, the normal ongoing model is:

1. tenant claim published
2. operator/control-plane builds signed projection
3. node verifies before activation
4. nginx uses stable host authority map
5. stock HB serves traffic behind that authority

That is the boundary we want in place before moving on to dynamic mode.
