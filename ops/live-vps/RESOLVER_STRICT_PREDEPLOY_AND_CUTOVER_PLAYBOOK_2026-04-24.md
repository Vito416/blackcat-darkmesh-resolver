# Darkmesh Resolver Strict Pre-Deploy and Cutover Playbook

Date: 2026-04-24  
Scope: `~darkmesh-resolver@1.0` strict security gate + production cutover  
Constraint: stock HB image/config workflow, no Dockerfile fork, no `docker-compose.yml` mutation.

## 1) Strict pre-deploy gate (local repo)

Run from workspace root:

```bash
cd blackcat-darkmesh-gateway

luac -p ops/live-vps/runtime/hb/addons/darkmesh-resolver@1.0.lua
luac -p ../blackcat-darkmesh-ao/ao/resolver/process.lua
luac -p scripts/run-resolver-fixtures.lua

npm run -s ops:validate-resolver-fixtures
npm run -s ops:validate-resolver-pack
lua scripts/run-resolver-fixtures.lua \
  ../blackcat-darkmesh-ao/ao/resolver/process.lua \
  ops/live-vps/runtime/hb/addons/fixtures/resolver-fixtures.v1.lua
```

Pass criteria:
- all commands exit `0`,
- fixture matrix reports `22 scenarios / 61 steps`,
- pack validator reports `PASS`.

## 2) Build, publish, spawn (resolver AO process)

Run from AO repo:

```bash
cd ../blackcat-darkmesh-ao

# Build resolver WASM from current AO resolver source
scripts/deploy/build_resolver_wasm_docker.sh

# Publish module to Arweave
node scripts/deploy/publish_wasm_module.mjs \
  --wasm dist/resolver/process.wasm \
  --name blackcat-ao-darkmesh-resolver-v1 \
  --out tmp/resolver-module.json
```

Extract module tx:

```bash
MODULE_TX="$(node -e 'const fs=require("fs");const j=JSON.parse(fs.readFileSync("tmp/resolver-module.json","utf8"));process.stdout.write(j.tx)')"
echo "${MODULE_TX}"
```

Spawn resolver process on your write node/scheduler:

```bash
node scripts/deploy/spawn_process_wasm_tn.mjs \
  --module "${MODULE_TX}" \
  --name blackcat-ao-darkmesh-resolver-v1 \
  --url https://write.darkmesh.fun \
  --scheduler _wCF37G9t-xfJuYZqc6JXI9VrG4dzM5WUFgDfOn9LdM \
  --mode extended \
  --wait-module 1 \
  --out tmp/resolver-pid.json
```

Extract PID:

```bash
RESOLVER_PID="$(node -e 'const fs=require("fs");const j=JSON.parse(fs.readFileSync("tmp/resolver-pid.json","utf8"));process.stdout.write(j.pid)')"
echo "${RESOLVER_PID}"
```

## 3) VPS cutover (single HB restart)

On VPS (tailscale-admin shell), write alias PID:

```bash
RESOLVER_PID="<PUT_NEW_PID_HERE>"
echo "${RESOLVER_PID}" | sudo tee /srv/darkmesh/hb/data/rolling/darkmesh-resolver.pid >/dev/null
echo "${RESOLVER_PID}" | sudo tee /srv/darkmesh/hb/data/darkmesh-resolver.pid >/dev/null
```

Restart only HB container stack:

```bash
cd /srv/darkmesh/hb
sudo docker compose restart hyperbeam
```

## 4) Post-cutover smoke checks

Use same VPS shell (or any shell with network access):

```bash
curl -sS https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState | jq .

curl -sS -X POST https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/ResolveHostForNode \
  -H 'content-type: application/json' \
  --data '{"Host":"jdwt.fun","Request-Id":"smoke-resolver-host-1"}' | jq .

curl -sS -X POST https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetDnsRefreshState \
  -H 'content-type: application/json' \
  --data '{"Action":"GetDnsRefreshState"}' | jq .
```

Expected:
- resolver endpoint responds `200`,
- no new systemic 5xx burst after restart,
- resolver state includes strict defaults:
  - centralized bundle writes disabled,
  - direct host policy apply disabled,
  - public read refresh queue mutation disabled.

## 5) Rollback (instant)

If cutover regresses:

1. put previous known-good PID back to `/srv/darkmesh/hb/data/rolling/darkmesh-resolver.pid`,
2. `docker compose restart hyperbeam`,
3. re-run smoke checks.

## 6) Operational defaults (must keep)

- `RESOLVER_ALLOW_CENTRALIZED_BUNDLE_WRITES=0`
- `RESOLVER_ALLOW_DIRECT_HOST_POLICY_APPLY=0`
- `RESOLVER_ALLOW_PUBLIC_READ_REFRESH_QUEUE=0`
- `policyMode=off`
- `failOpen=true`

These defaults preserve decentralized onboarding while keeping rollout non-destructive.
