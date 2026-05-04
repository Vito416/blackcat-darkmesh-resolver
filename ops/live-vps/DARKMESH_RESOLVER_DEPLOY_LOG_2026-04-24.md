# Darkmesh Resolver Deploy Log (2026-04-24)

## Arweave gateway simplification (2026-04-26)

- User-approved change: remove nginx `__arweave_chain` shim path and use direct `arweave.net` gateway wiring.
- Updated runtime templates:
  - `ops/live-vps/runtime/nginx/hyperbeam-loopback.conf`
    - removed internal `location ~ ^/__arweave_chain...` block,
    - parity routes (`/graphql`, `/raw/*`, `/tx/*`, `/arweave/*`, `/<43id>`) now proxy directly to `https://arweave.net`.
  - `ops/live-vps/runtime/hb/entrypoint.sh`
    - `ARWEAVE_GATEWAY_CHAIN` compatibility var now defaults to `${REMOTE_GATEWAY}` (`https://arweave.net`),
    - generated HB config `gateway` and `store.cache-arweave.arweave-node` now resolve to `https://arweave.net`.
- Live deploy over tailscale host `adminops@65-109-99-102`:
  - nginx site backup + deploy + `nginx -t` + reload (`bak timestamp: 20260426T165131Z`),
  - hb `entrypoint.sh` backup + deploy,
  - rebuilt/recreated `darkmesh-hyperbeam` image/container to apply new entrypoint default.
- Live verification:
  - container config now shows `"gateway": "https://arweave.net"`,
  - HB logs show:
    - `gateway => https://arweave.net`
    - `arweave-node => https://arweave.net`
  - resolver alias smoke still healthy:
    - `GET https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState` -> `200`.

## Candidate rollout refresh (2026-04-26)

## Scheduler-Location canary + alias shim correction (2026-04-26)

- Spawned resolver canary PID with explicit `Scheduler-Location`:
  - module: `uoIaDISZwTufz8dY102aiIV40X9aPyPIE_frzezV2cU`
  - pid: `HV1d8Jrknb8kWTpIvCAtJWrN-vg3nYBHkl_uQUuOzRI`
  - scheduler: `_wCF37G9t-xfJuYZqc6JXI9VrG4dzM5WUFgDfOn9LdM`
  - scheduler-location: `https://write.darkmesh.fun`
- Public probe result on canary:
  - `GET /<pid>~process@1.0/now?Action=GetResolverState` -> `200` (headers show `scheduler-location` present)
  - confirms that action transport through `/now` is viable when runtime can resolve scheduler location.
- Existing alias shim issue:
  - nginx resolver shim used `POST` body (`{"Action":"..."}`) directly to `/<pid>~process@1.0`,
  - that path returns envelope-only payload (`ao-result` + commitments) and does not surface resolver decision body.
- Template fix prepared in repo:
  - `ops/live-vps/runtime/nginx/hyperbeam-loopback.conf`
  - `ops/live-vps/runtime/nginx/write-loopback.conf`
  - alias endpoints now proxy to `/now?Action=...` instead of posting raw body to process root.
- Operational note:
  - live node currently emits intermittent `429 rate-limited` during heavy probing, so smoke should be paced before/after cutover.

- Source sync:
  - `ops/live-vps/runtime/hb/addons/darkmesh-resolver@1.0.lua` -> `blackcat-darkmesh-ao/ao/resolver/process.lua`
- Build:
  - `scripts/deploy/build_resolver_wasm_docker.sh`
  - output: `blackcat-darkmesh-ao/dist/resolver/process.wasm`
  - SHA256: `74c795c259ce150c8760b0b99d21218be902c8bd9e53441aee07f6f938981274`
- Published module TX:
  - `uoIaDISZwTufz8dY102aiIV40X9aPyPIE_frzezV2cU`
  - publish status: `200`
  - module probe: `GET /<tx>~module@1.0?accept-bundle=true` -> `200`
- Spawned resolver PID:
  - `Vg4smfGt-5F0_KHWf05YsBYdfMqDHaBhZUHx8mzmGzQ`
  - spawn status: `200` (`/push`, `mode=extended`, `variant=ao.TN.1`)
  - scheduler: `_wCF37G9t-xfJuYZqc6JXI9VrG4dzM5WUFgDfOn9LdM`
  - slot probe: `GET /<pid>~process@1.0/slot/current?accept-bundle=true` -> `200` (`0`)
- Local deploy artifacts:
  - `blackcat-darkmesh-ao/tmp/resolver-module-latest.json`
  - `blackcat-darkmesh-ao/tmp/resolver-pid-latest.json`

## Live cutover (2026-04-26)

- Applied over tailscale host `adminops@65-109-99-102`.
- Updated resolver PID references:
  - `/srv/darkmesh/hb/data/rolling/darkmesh-resolver.pid`
  - `/srv/darkmesh/hb/data/darkmesh-resolver.pid`
  - `/etc/nginx/snippets/darkmesh-resolver-pid.conf`
- Active PID now:
  - `Vg4smfGt-5F0_KHWf05YsBYdfMqDHaBhZUHx8mzmGzQ`
- Safety steps:
  - backed up nginx snippet as `darkmesh-resolver-pid.conf.bak-20260426T151317Z`
  - validated config with `nginx -t`
  - reloaded nginx (`systemctl reload nginx`)
- Immediate smoke:
  - `GET https://write.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState` -> `200`
  - `GET https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState` -> `200`
  - `GET https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/resolve?host=jdwt.fun&path=/` -> `200`
- Last-200 nginx access lines after cutover contained no `5xx`.

## Candidate rollout (2026-04-26)

- New WASM module TX (from patched resolver runtime):
  - `9tDlaeBl0HB-2Jzh64ok0nj2Yo4e5Z2e1vTL5lXzQZ4`
- New resolver PID (spawned on `write.darkmesh.fun`):
  - `55AGbHslFMRthfB1xydmTDbxj7jz7WOk9NMsHgGijrQ`
- Observed immediately after spawn:
  - `slot/current` on write host is healthy (`200`, slot advanced),
  - resolver read visibility from `hyperbeam.darkmesh.fun` remains `404` for direct PID paths (same class as previous read-visibility mismatch),
  - direct alias-style POST probes still return envelope-only responses without resolver payload (no safe cutover yet).
- Status:
  - kept as candidate (not promoted into nginx resolver PID snippet yet).

## Published module

- Name: `blackcat-ao-darkmesh-resolver-v1`
- Module TX: `CFrFOhEJbkwGCmgwTW1Al_KZDsWehK72vbp9F6efbY4`
- Variant: `ao.TN.1`
- Publish status: `200`
- Finalization: `finalized` (confirmed)

## Spawned process

- PID: `Uven0OZv1rHZjmkDkSFP3yDhZF3aMI0lk6ouoBciuSM`
- Write URL: `https://write.darkmesh.fun`
- Scheduler: `_wCF37G9t-xfJuYZqc6JXI9VrG4dzM5WUFgDfOn9LdM`
- Finalization: `finalized` (confirmed)

## Superseded deploy IDs (historical)

- Previous module TX: `CHLqat-3DZIALw0-K76VvW4wr7fOGFRSEZPOsfczuZM`
- Previous PID: `BBPZ7D3EUj_VrHObRB8X6sX9CaeiuKx4zEjOjWpSUV8`

## VPS alias wiring

- PID file written to:
  - `/srv/darkmesh/hb/data/rolling/darkmesh-resolver.pid` (effective, because `DATA_DIR=/data/rolling`)
  - `/srv/darkmesh/hb/data/darkmesh-resolver.pid` (compat copy)
- HyperBEAM container restarted after PID update.

### Latest cutover run (2026-04-24, post-finalization)

- Alias PID updated on VPS to:
  - `Uven0OZv1rHZjmkDkSFP3yDhZF3aMI0lk6ouoBciuSM`
- Performed:
  - backup of previous PID files (`*.bak-<utc-timestamp>`)
  - write new PID to both resolver PID file paths
  - `docker compose restart hyperbeam` (does not rebuild image)
  - `docker compose up -d --build hyperbeam` (recreated container with latest `entrypoint.sh`)
- Runtime config verification:
  - `/app/config.json` now contains resolver route with:
    - `with: "/Uven0OZv1rHZjmkDkSFP3yDhZF3aMI0lk6ouoBciuSM~process@1.0"`
- Current smoke outcome:
  - `GET /~darkmesh-resolver@1.0/GetResolverState` returns `500`
  - HB logs show `device_not_loadable` + `module_not_admissable` for `darkmesh-resolver@1.0`
  - direct process probe works on write host:
    - `GET /Uven0OZv1rHZjmkDkSFP3yDhZF3aMI0lk6ouoBciuSM~process@1.0/slot/current?accept-bundle=true` -> `200`
  - indicates resolver PID is alive, but `~darkmesh-resolver@1.0` is still resolved as a device name before route rewrite in this runtime profile.

## Validation

- Resolver fixtures: `OK (16 scenarios, 42 steps)`
- Resolver pack validator: `PASS`
- AO resolver source run against fixture matrix: `OK`

## Important note

Public GET on `~darkmesh-resolver@1.0` still needs final route semantics validation on this runtime profile.
Current operational contract path is stable at process PID level; alias behavior must be finalized in the HB route mapping layer before broad public exposure.
Observed now:
- normal traffic paths are healthy,
- recent 5xx in nginx tail are only manual smoke hits to `/~darkmesh-resolver@1.0`.

## Decentralized onboarding update (DNS+TXT+AR)

- Resolver now supports host onboarding from proof result payload (no pre-seeded host bundle required):
  - `ApplyDnsRefreshResult` can upsert `hostPolicies/sitePolicies` when proof is valid and includes:
    - `Site-Id`, `Process-Id` (required for valid proof apply),
    - optional: `Module-Id`, `Scheduler-Id`, `Route-Prefix`, `Status`, `Action-Hint`.
- Unknown hosts can now be queued for refresh by access path (`host_unmapped` reason), so first contact can enter refresh flow without central pre-registration.
- Refresh listing/tick now tracks union of:
  - configured hosts (`hostPolicies`),
  - discovered hosts waiting in `refreshMeta`.

## Admission controls (HB deny/allow authority only)

- Added admin-only admission actions:
  - `SetAdmissionRule` (`deny` or `allow`),
  - `RemoveAdmissionRule`,
  - `GetAdmissionState`.
- Admission is evaluated before routing decision:
  - explicit deny always blocks,
  - optional allowlist mode denies hosts not explicitly allowed.
- Cache invalidation is performed on admission mutations to prevent stale allow paths.

## Centralization guard (enabled by default)

- `ApplyPolicyBundle` now rejects centralized mapping payloads by default:
  - blocked fields: `hostPolicies`, `sitePolicies`, `routePolicies`, `dnsProofState`
  - error: `FORBIDDEN / centralized_bundle_writes_disabled`
- This keeps domain onboarding decentralized (DNS TXT + AR config + proof refresh path).
- Optional emergency break-glass: set `RESOLVER_ALLOW_CENTRALIZED_BUNDLE_WRITES=1`.

## Updated validation

- Resolver fixtures: `OK (22 scenarios, 61 steps)`
- Resolver pack validator: `PASS`

## Security audit status update

- Latest audit reference:
  - `ops/migrations/DARKMESH_RESOLVER_SECURITY_AUDIT_2026-04-24.md`
- Strict cutover checklist:
  - `ops/live-vps/RESOLVER_STRICT_PREDEPLOY_AND_CUTOVER_PLAYBOOK_2026-04-24.md`
- Current gate: **deploy approved** (strict decentralized defaults applied).
- Security-hardening changes now active in resolver source:
  - direct `ApplyHostPolicyFromProof` path blocked by default,
  - refresh/mapping mutation actions role-gated,
  - public read path no longer mutates refresh queue by default,
  - `refreshMeta` TTL + cap eviction enabled,
  - response scope typo fix (`scope="host"`),
- challenge reference generation upgraded (openssl RNG when available).
- Edge-case audit coverage for tracked security issues: `100% (6/6)` with fixture evidence.

## DM1 TXT onboarding records (generated 2026-04-24)

Owner/KID used:

- `ZqkuoHZ3GTSCVh96BUgO0wlszuOfzFcerd_zN5W4xTU`

Published DM1 config TX (signed payload variant, status at publish time: `202 pending`):

- `jdwt.fun`
  - cfg tx: `q08LJh1nzcGlmUSE6e4wRbVpvhRivgujLBZn2OxAS54`
  - TXT `_darkmesh`: `v=dm1;cfg=q08LJh1nzcGlmUSE6e4wRbVpvhRivgujLBZn2OxAS54;kid=ZqkuoHZ3GTSCVh96BUgO0wlszuOfzFcerd_zN5W4xTU;ttl=3600;seq=2`
- `vddl.fun`
  - cfg tx: `_DuGxYOU5c3ejZdLrfZyZ5rDh_bC4YXveFNs81PpI9c`
  - TXT `_darkmesh`: `v=dm1;cfg=_DuGxYOU5c3ejZdLrfZyZ5rDh_bC4YXveFNs81PpI9c;kid=ZqkuoHZ3GTSCVh96BUgO0wlszuOfzFcerd_zN5W4xTU;ttl=3600;seq=2`
- `blgateway.fun`
  - cfg tx: `qxnPvRak-dj9Q3CNUeT3zhqB-Wmu1eurtG-WmuFR9Hc`
  - TXT `_darkmesh`: `v=dm1;cfg=qxnPvRak-dj9Q3CNUeT3zhqB-Wmu1eurtG-WmuFR9Hc;kid=ZqkuoHZ3GTSCVh96BUgO0wlszuOfzFcerd_zN5W4xTU;ttl=3600;seq=2`

Generated local artifacts:

- `ops/live-vps/local-tools/dm1-domain-configs-2026-04-24/dm1-txt-records.json`
- `ops/live-vps/local-tools/dm1-domain-configs-2026-04-24/dm1-txt-records.signed.json`
- `ops/live-vps/local-tools/dm1-domain-configs-2026-04-24/jdwt.fun.dm1.config.json`
- `ops/live-vps/local-tools/dm1-domain-configs-2026-04-24/vddl.fun.dm1.config.json`
- `ops/live-vps/local-tools/dm1-domain-configs-2026-04-24/blgateway.fun.dm1.config.json`
- `ops/live-vps/local-tools/dm1-domain-configs-2026-04-24/jdwt.fun.dm1.config.signed.json`
- `ops/live-vps/local-tools/dm1-domain-configs-2026-04-24/vddl.fun.dm1.config.signed.json`
- `ops/live-vps/local-tools/dm1-domain-configs-2026-04-24/blgateway.fun.dm1.config.signed.json`

Current config note:

- `siteProcess` and `writeProcess` in these three DM1 JSON configs are currently set to resolver PID `Uven0OZv1rHZjmkDkSFP3yDhZF3aMI0lk6ouoBciuSM` as bootstrap placeholder until per-domain runtime PIDs are finalized.

## DNS + config parity check (2026-04-24, post-publish)

- `_darkmesh` TXT records for all three domains resolve publicly and match generated DM1 signed records (`seq=2`).
- DM1 config TXs are now confirmed on-chain (`status=200`, `confirmed=3` at check time):
  - `q08LJh1nzcGlmUSE6e4wRbVpvhRivgujLBZn2OxAS54` (`jdwt.fun`)
  - `_DuGxYOU5c3ejZdLrfZyZ5rDh_bC4YXveFNs81PpI9c` (`vddl.fun`)
  - `qxnPvRak-dj9Q3CNUeT3zhqB-Wmu1eurtG-WmuFR9Hc` (`blgateway.fun`)
- Runtime verification pass (all 3 domains):
  - TXT envelope `v/cfg/kid/ttl/seq` valid,
  - config `domain` matches queried host,
  - `kid == owner` link valid,
  - RSA-PSS signature verifies against wallet public key,
  - validity window active (`validFrom <= now <= validTo`).

## Alias-fix patch staged (2026-04-24)

- Updated runtime template `ops/live-vps/runtime/hb/entrypoint.sh`:
  - enables request preprocessing hook by default:
    - `on.request -> router@1.0/preprocess`
    - `router_preprocess_default=local`
  - keeps all unmatched traffic local (no forced relay),
  - rewrites resolver alias route target to internal absolute URL:
    - `http://127.0.0.1:${HB_PORT}/<PID>~process@1.0`
    - this is required so relay has an explicit routable target and bypasses local `~device` name collision (`device_not_loadable`).
- Updated runtime note in `ops/live-vps/runtime/README.md`.

Apply on VPS:

1) sync updated template file to `/srv/darkmesh/hb/entrypoint.sh`,
2) restart HyperBEAM container (`docker compose restart hyperbeam`),
3) smoke:
   - `GET https://write.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState`
   - `POST https://write.darkmesh.fun/~darkmesh-resolver@1.0/ResolveHostForNode`
   - or run: `bash ops/live-vps/local-tools/smoke-resolver-alias.sh --pid Uven0OZv1rHZjmkDkSFP3yDhZF3aMI0lk6ouoBciuSM`

Baseline before applying this patch (captured 2026-04-24):
- `smoke-resolver-alias.sh` -> `ok=1 fail=3`
  - alias endpoints (`read` + `write`) currently `500`,
  - direct process slot probe on write URL is `200`.

## Tailscale deploy attempt + rollback (2026-04-24 late evening)

- Connected via Tailscale SSH (`adminops@65-109-99-102`).
- Deployed patched `/srv/darkmesh/hb/entrypoint.sh`, then rebuilt+restarted HB.
- Verification on live container confirmed patched config was active (`router_preprocess_default`, `on.request`, alias rewrite with internal URL).
- Runtime result: resolver alias still returned `500` (`device_not_loadable/module_not_admissable`), so patch did not solve alias path issue.
- Safety rollback executed immediately:
  - restored previous backup file `/srv/darkmesh/hb/entrypoint.sh.bak-20260424T214603Z`,
  - rebuilt+restarted HB again,
  - core routing parity checks back to baseline:
    - `https://hyperbeam.darkmesh.fun/~meta@1.0/info` -> `200`
    - `https://write.darkmesh.fun/~meta@1.0/info` -> `200`
    - domain roots (`jdwt.fun`, `vddl.fun`, `blgateway.fun`) unchanged (`302` baseline behavior).
- 5xx tail audit after rollback:
  - no non-curl 5xx found in tail window (`non_curl_5xx_tail500=0`),
  - observed 5xx are test probes from local curl against resolver alias endpoints.

## Routing normalization (2026-04-24 late evening)

- Applied nginx root routing fix on VPS (`/etc/nginx/sites-enabled/hyperbeam-loopback.conf`):
  - removed forced `location = / { return 302 /~meta@1.0/info; }`,
  - added `absolute_redirect off;`,
  - reloaded nginx (`nginx -t` + `systemctl reload nginx`).
- External parity after reload:
  - `https://hyperbeam.darkmesh.fun/` now returns direct `200` (no leaked `:8744` redirect),
  - `https://jdwt.fun/`, `https://vddl.fun/`, `https://blgateway.fun/` now return direct `404` (no redirect loop/leak).
- Current routing blockers for domain `/` -> per-domain page:
  - resolver alias endpoint still fails (`/~darkmesh-resolver@1.0/*` -> `500`, `device_not_loadable/module_not_admissable`),
  - DNS DM1 configs for all 3 domains still point `siteProcess` to resolver PID placeholder (`Uven0...`), not final per-domain site process/runtime target.

## Root-cause confirmation (2026-04-25, tailscale live check)

Constraints respected during this check:

- no stock HyperBEAM code edits,
- no Node.js/npm install on VPS,
- diagnostics over Tailscale only.

Confirmed from live probes and HB logs:

1) `500` on alias path is deterministic for action-style URL:
   - `GET /~darkmesh-resolver@1.0/GetResolverState` -> `500`
   - log signature: `device_not_loadable` + `module_not_admissable` (`darkmesh-resolver@1.0`)

2) Resolver/action execution path still depends on AO process compute:
   - `slot/current` on resolver/site PIDs returns `200`
   - `compute=<slot>` / `now` routes return `502` on this node

3) Compute failure root cause is local CU bootstrap failure:
   - log signature: missing `/app/hb/genesis-wasm-server/launch-monitored.sh`
   - followed by upstream `status => 572` and Cowboy crash (`cow_http1:status(572)`)

4) Additional data consistency issue found in DM1 config payloads (`seq=3`):
   - `siteProcess` currently points to `Zv01...` which resolves to module-like payload (`Content-Type: application/wasm`) and not a stable renderable domain runtime target.

Operational conclusion:

- Current resolver PID + current site process targets cannot provide stable resolver/domain runtime on this VPS profile without a working compute execution path.
- The remaining `500/502` in this area are structural (path + execution device), not random nginx transport failures.

## Stability patch (2026-04-25, tailscale live)

Applied nginx-only compatibility patch (no stock HB code change):

1) Removed accidental duplicate active site config on port `8744`:
   - deleted `/etc/nginx/sites-enabled/hyperbeam-loopback.conf.bak-20260425T183107Z`
   - this removed conflicting `server_name` behavior and nondeterministic matching.

2) Added resolver alias compatibility endpoints in loopback nginx:
   - `~darkmesh-resolver@1.0` and `~darkmesh-resolver@1.0/GetResolverState`
     are translated to a process `POST` action (`GetResolverState`)
   - `~darkmesh-resolver@1.0/resolve?host=...&path=...`
     is translated to process `POST` action (`ResolveRouteForHost`)
   - strict host/path validation added for resolve query shape.

3) Forced resolver shim upstream host header to `write.darkmesh.fun`:
   - avoids host-dependent `404` behavior observed when resolver actions were sent with `Host: hyperbeam.darkmesh.fun`.

Validation after reload:

- `https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0` -> `200`
- `https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState` -> `200`
- `https://jdwt.fun/~darkmesh-resolver@1.0/GetResolverState` -> `200`
- `https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/resolve?host=jdwt.fun&path=/` -> `404` JSON (`{"body":"Not Found","status":404}`)
- tail check (`access_enriched`) after patch window: no new `5xx` events observed in the sampled window.

Current remaining blocker:

- Domain roots (`jdwt.fun`, `vddl.fun`, `blgateway.fun`) still return `404`.
- This is now a resolver/data state issue (host not resolved to an effective route/site target), not a 500 transport/alias crash path.

## 2026-04-25 follow-up diagnostics (public read/write probes)

### Preflight script behavior corrected

- `ops/live-vps/local-tools/preflight-domain-routing.sh` now checks PID visibility on both:
  - read host (`hyperbeam.darkmesh.fun`)
  - write host (`write.darkmesh.fun`)
- Result for all 3 domains:
  - DM1 TXT + cfg JSON pass,
  - `siteProcess` / `writeProcess` are visible only on write host (`slot=write:*`),
  - root still `404`.

### Resolver alias semantic smoke outcome

- `ops/live-vps/local-tools/smoke-resolver-alias.sh --host jdwt.fun`
  - `GET /~darkmesh-resolver@1.0/resolve?...` -> `200` but payload is only `{"ao-result":"body",...}` (no `decision` / no route output),
  - `POST /~darkmesh-resolver@1.0/ResolveHostForNode` -> `404`,
  - `POST /~darkmesh-resolver@1.0/ResolveRouteForHost` -> `404`.

### Compute-plane blocker confirmed

Direct process compute probes on write host currently fail for all key PIDs:

- `tIItgtK...` (`registry/control-plane`) -> `520`
- `Zv01GLN...` (`siteProcess in current DM1`) -> `520`
- `nczlDAl...` (`writeProcess in current DM1`) -> `520`
- `Uven0OZ...` / `0TE463...` (resolver PIDs) -> `520`

Practical impact:

- alias-to-process rewrites cannot produce resolver decisions while compute is unhealthy,
- domain root routing via resolver cannot be completed until compute path is restored.

## 2026-04-26 resolver runtime fix (handle alias parity)

New finding from live probe against resolver PID `Uven0...`:

- `GET /<resolver-pid>/now?Action=ResolveRouteForHost...` returned runtime error in `results`:
  - `[string "__lua_webassembly__"]:12: attempt to call a nil value (field 'handle')`

Interpretation:

- this runtime profile invokes `Handlers.handle(msg)` in a wasm-lua wrapper path,
- resolver process currently exports `_G.Handle/_G.handle` but did not ensure `Handlers.handle` alias,
- result is runtime fault before resolver action dispatch.

Patch added in source and addon reference:

- `blackcat-darkmesh-ao/ao/resolver/process.lua`
- `ops/live-vps/runtime/hb/addons/darkmesh-resolver@1.0.lua`

What patch does:

- after global handlers are wired, enforce:
  - if `Handlers.handle` is missing, set it to call `_G.handle(msg)`.

Local validations (repo):

- `npm run ops:validate-resolver-fixtures` => `OK (22 scenarios, 61 steps)`
- `npm run ops:validate-resolver-pack` => `PASS`
- `npm run bundle:ao:resolver` (in `blackcat-darkmesh-ao`) => bundle rebuilt successfully.

Next required ops step:

- publish new resolver module + spawn PID from patched source,
- update `/srv/darkmesh/hb/data/rolling/darkmesh-resolver.pid`,
- restart only HB container,
- rerun:
  - `smoke-resolver-alias.sh`
  - domain root probes for `jdwt.fun`, `vddl.fun`, `blgateway.fun`.

## 2026-04-26 resolver WASM rebuild + cutover attempt (tailscale live)

Executed with Docker WASM toolchain:

- Rebuilt resolver WASM from bundled source:
  - output: `blackcat-darkmesh-ao/dist/resolver/process.wasm`
  - SHA256: `e2ebf67732c53fe813a01c39f20e356b29b4cfa7f4835700cf397b0d0ee7ad18`

Published/spawned (write node flow):

- module tx: `eDLm_Ng77OwZV91i5YJb0KbJX956w3EynJH5RZIUkaU`
- spawned PID: `EM7tmCjb2Lu93Y43_mxjU_cMcxfeGMwoZbuN-AAilPY`
- scheduler: `_wCF37G9t-xfJuYZqc6JXI9VrG4dzM5WUFgDfOn9LdM`
- write endpoint: `https://write.darkmesh.fun`

Cutover on VPS:

- updated:
  - `/srv/darkmesh/hb/data/rolling/darkmesh-resolver.pid`
  - `/srv/darkmesh/hb/data/darkmesh-resolver.pid`
- synced nginx snippet with:
  - `sudo DO_RELOAD=1 /usr/local/sbin/sync-nginx-resolver-pid.sh`
- restarted HB container:
  - `sudo docker compose restart hyperbeam` (in `/srv/darkmesh/hb`)

Post-cutover result:

- resolver alias still returns envelope-only payload (`{"ao-result":"body",...}`), no decision body surface.
- `POST /~darkmesh-resolver@1.0/ResolveHostForNode` and `.../ResolveRouteForHost` still return `404`.
- root domains still `404`:
  - `https://jdwt.fun/`
  - `https://vddl.fun/`
  - `https://blgateway.fun/`

Current status:

- new resolver PID is deployed in runtime config, but domain routing is not yet producing resolver-driven site resolution.

## 2026-04-26 second retry (existing lua module spawn sanity)

Retried spawn against previously published resolver lua module:

- module tx: `nGLfSppuixEaUjFvAUeH6HL1gDgZSkNDdPNEDyBsnB8`
- spawned PID: `e-gJnaZjfsZDtTgFThfK7KX8MPIG00PLhPNZL90s2zs`
- profile inferred by spawn helper: `executionDevice=lua@5.3a`, `contentType=text/lua`

Observed:

- `slot/current` returns `200` (`0`) on local and write endpoints.
- `now?Action=GetResolverState` returns `500`.
- no improvement versus current cutover PID behavior.

Conclusion:

- repeating spawn with the older lua module does not restore resolver decision path.

## 2026-04-26 retry after limit reset (WASM module KZT... + new PID)

Spawned from finalized WASM module:

- module tx: `KZTtzm8fIg75e1OeimpmisHY2kZZGvdNCz2ko1LUmKk`
  - `https://arweave.net/tx/KZTtzm8fIg75e1OeimpmisHY2kZZGvdNCz2ko1LUmKk/status` -> confirmed (`block_height=1905450`)
- new PID tx: `_sMgmfTFvEiLlINv44tFGri5ZRWROj-slu96k0FbV6Y`
  - `https://arweave.net/tx/_sMgmfTFvEiLlINv44tFGri5ZRWROj-slu96k0FbV6Y/status` -> pending/not yet indexed at check time

Immediate runtime probes:

- `https://write.darkmesh.fun/_sMgmfTFvEiLlINv44tFGri5ZRWROj-slu96k0FbV6Y~process@1.0/slot/current?accept-bundle=true` -> `200`
- direct read host PID paths still `404 not_found` (expected before full read visibility/index parity)
- signed scheduler smoke (`GetResolverState`) still fails semantic check because compute path returns `520` via public hostname.

Live tailscale host check (`http://127.0.0.1:8734`) confirms root failure type:

- `error_computing_slot` on resolver-like PIDs with:
  - `{"error":"Body is not valid: would attempt to fetch from scheduler in loadMessages"}`
- current active alias PID (`EM7...`) remains broken for separate reason:
  - `{"error":"Gateway returned no transaction for 'eDLm_Ng77OwZV91i5YJb0KbJX956w3EynJH5RZIUkaU'"}`

Operational status after this retry:

- new PID was created successfully and is valid for tracking,
- but no safe cutover yet (same scheduler/loadMessages compute blocker),
- domain roots remain unresolved (`404`) until compute path is healthy for resolver actions.

## 2026-04-26 follow-up (post-limit reset) — external parity check

Ran fresh public probes (no VPS shell) against:

- `https://hyperbeam.darkmesh.fun`
- `https://write.darkmesh.fun`

Findings:

1) Resolver alias endpoints are still envelope-only
- `GET /~darkmesh-resolver@1.0/resolve?...` -> `200`, payload only:
  - `ao-result`, `commitments`, `status`
  - missing resolver decision/body fields
- This indicates action execution is not being surfaced to caller.

2) Action-style alias paths still unavailable
- `POST /~darkmesh-resolver@1.0/ResolveHostForNode` -> `404`
- `POST /~darkmesh-resolver@1.0/ResolveRouteForHost` -> `404`

3) Process target compute remains unhealthy
- `GET /~process@1.0/slot/current?target=<resolver_pid>` -> `200` (numeric slot)
- `GET /~process@1.0/compute?target=<resolver_pid>&slot=<slot>` -> `502`

4) Live HB meta confirms delegated compute routes:
- `/result/*` -> `http://127.0.0.1:6363`
- `/dry-run` -> `http://127.0.0.1:6363`

Interpretation:

- Scheduler/slot ingress is alive, but compute/readback path is still broken.
- Resolver alias cannot produce route decisions until compute path is restored.

## 2026-04-26 image/runtime fix prepared in repo (not yet deployed)

Prepared fix in runtime templates:

- `ops/live-vps/runtime/hb/Dockerfile`
  - now copies bundled CU server into final image:
    - `/app/hb/genesis-wasm-server`
  - ensures `launch-monitored.sh` is executable.

- `ops/live-vps/runtime/hb/entrypoint.sh`
  - startup warning if `GENESIS_WASM_LAUNCH` is missing/non-executable.

- `ops/live-vps/runtime/README.md`
  - clarified delegated compute defaults (`/result`, `/dry-run` -> local `:6363`)
  - documented required `genesis-wasm-server` files and cutover restart requirement.

- `ops/live-vps/local-tools/smoke-resolver-alias.sh`
  - now explicitly flags envelope-only responses as failure,
  - adds process target compute check via stock endpoint:
    - `~process@1.0/slot/current?target=...`
    - `~process@1.0/compute?target=...&slot=...`

## 2026-04-26 fallback compatibility note + new build/spawn

### Why fallback alias was added

- Root runtime failure was `attempt to call a nil value (field 'handle')`.
- This is an execution-wrapper compatibility issue (`Handlers.handle(msg)` vs `handle(msg)` call path), not resolver policy bypass.
- Added compatibility alias in resolver source:
  - `blackcat-darkmesh-ao/ao/resolver/process.lua`
  - `ops/live-vps/runtime/hb/addons/darkmesh-resolver@1.0.lua`
- Behavior: wrapper call path now resolves into the same resolver handler pipeline; auth/role/policy logic remains unchanged.

### New WASM build (with alias patch)

- file: `blackcat-darkmesh-ao/dist/resolver/process.wasm`
- sha256: `a9bca89af3f372013245551e9947ef3d8fddb0d7b4cc5414c9641ca4db46a80e`
- build command:
  - `bash scripts/deploy/build_resolver_wasm_docker.sh`

### Publish + spawn (latest attempt)

- Publish attempt with zero-balance wallet (`wallet_AR.json`) failed as expected:
  - tx: `aAFEXMsS2r2vBdYyrUatV_E6IE80Ujtkz9QYIUbxgrk`
  - post status: `400`
- Successful publish using funded wallet (`wallet.json`):
  - module tx: `sacQHXS6PBIdEeCk68FwWC9PCSS7bS0g_vBa8mIWRIY`
  - post status: `200`
  - `arweave.net/tx/<tx>/status` at check time: `202 Accepted` (finalization pending)
- Successful spawn on write node:
  - pid: `CpYAM1of3M-xlbNqOo2Rj_WRsAW_VzbNE6F_mQh2lic`
  - scheduler: `_wCF37G9t-xfJuYZqc6JXI9VrG4dzM5WUFgDfOn9LdM`
  - endpoint: `https://write.darkmesh.fun`
  - spawn status: `200`

### Immediate probes after spawn

- `~process@1.0/slot/current?target=<PID>` -> `200`, slot `0` (write + read hosts).
- `~process@1.0/compute?target=<PID>&slot=0` -> `502` (write + read hosts) at check time.
- Interpretation: process creation succeeded; compute/readback path is still blocked by existing runtime/scheduler-path issue and needs follow-up before cutover.

## 2026-04-26 deep-dive root cause analysis (why previous attempts did not fix runtime)

### 1) `~process@1.0/compute?target=...` is not a valid health signal on this profile

- Local HB probe (`127.0.0.1:8734`) returns:
  - `500` with details `process_has_no_signers` for `~process@1.0/compute?target=<PID>&slot=<n>`.
- Nginx then surfaces this as `502` on `127.0.0.1:8744`/public edge.
- This endpoint path should not be used as authoritative resolver smoke gate for this runtime profile.
- Smoke tooling updated to use direct process path:
  - `/<PID>~process@1.0/slot/current`
  - `/<PID>~process@1.0/compute=<slot>`

### 2) Resolver alias was still pinned to old PID in live runtime

- Live files still pointed to old PID `Vg4sm...`:
  - `/srv/darkmesh/hb/data/rolling/darkmesh-resolver.pid`
  - `/srv/darkmesh/hb/data/darkmesh-resolver.pid`
  - `/etc/nginx/snippets/darkmesh-resolver-pid.conf`
- So alias-route tests were repeatedly exercising stale process state.

### 3) Critical WASM build pipeline issue (actual blocker)

- Previous resolver WASM build replaced runtime wrapper (`dist/<template>/process.lua`) with pure resolver bundle.
- That drops required AO runtime bridge (`process.handle` path), causing runtime errors like:
  - `[string "__lua_webassembly__"]:12: attempt to call a nil value (field 'handle')`
- Fix implemented in build pipeline:
  - `scripts/deploy/build_resolver_wasm_docker.sh` now composes:
    - runtime wrapper from template `process.lua` **plus**
    - resolver bundle preload/module code,
    - instead of overwrite.
  - Guard checks now assert:
    - `function process.handle` exists,
    - `package.preload["ao.resolver.process"]` exists.

### 4) New build/spawn after runtime-wrapper fix

- module tx: `x_Hw2BaVHywhoWcByQHyIQ5pTzeI3U2CwoKrnlYZo7E` (`status=200` post; chain status `202 Accepted` at check time)
- new PID: `iSPYcIaQW9fCrjClRJTWz5ZGiYwYMJ2731yqRxNAWCA`
- Immediate local compute check shows temporary expected index lag:
  - `Gateway returned no transaction for 'x_Hw2BaVHywhoWcByQHyIQ5pTzeI3U2CwoKrnlYZo7E'`
- Meaning: module is not fully available via gateway yet; retest required after confirmation/finalization.

## 2026-04-26 root-cause isolate (scheduler body fetch vs 43-char hard routes)

New parity evidence (public probes):

- Same process, same slot (`Zv01GL...`, slot `1`):
  - `https://push.forward.computer/<PID>~process@1.0/compute=1?accept-bundle=true` -> `200`
  - `https://write.darkmesh.fun/<PID>~process@1.0/compute=1?accept-bundle=true` -> `500` with:
    - `{"error":"Body is not valid: would attempt to fetch from scheduler in loadMessages"}`

- Scheduler assignment link shape differs in effect on our node:
  - `GET https://write.darkmesh.fun/~scheduler@1.0/schedule?...` returns `assignments+link=<43id>`
  - fetching that `43id` on our node returns HTML (not scheduler object payload),
    while the same pattern on push node returns scheduler object payload.

Interpretation:

- We hard-routed generic 43-char paths to Arweave (HB config route and read nginx route).
- Generic 43-char paths are not always Arweave tx IDs; they can be scheduler/cache object IDs needed by process readback.
- That hard-route can break scheduler/local object resolution and surfaces as
  `loadMessages`/scheduler body validation errors.

Patch prepared in repo (not yet deployed live):

1) `ops/live-vps/runtime/hb/entrypoint.sh`
- removed explicit HB routes:
  - `^/[A-Za-z0-9_-]{43}(?:\?.*)?$`
  - `^/tx/[A-Za-z0-9_-]{43}(?:\?.*)?$`
- keep `/tx`, `/raw`, `/graphql`, `/arweave/*` parity routes intact.

2) `ops/live-vps/runtime/nginx/hyperbeam-loopback.conf`
- removed nginx forced proxy rules for generic 43-char paths on read host.
- retained explicit Arweave parity paths (`/graphql`, `/raw/*`, `/tx/*`, `/arweave/*`).

Expected impact after deploy/restart:

- local scheduler/cache object IDs are no longer forced to Arweave route,
- `compute` readback can resolve scheduler-linked bodies locally,
- resolver alias should stop returning envelope-only for action flow once process
  compute path is healthy.

## 2026-04-26 spawn tooling hardening (scheduler location propagation)

To reduce `No location found for address: _wCF...` failures on non-local nodes and
stabilize cross-node compute/readback, spawn tooling now propagates scheduler URL:

- updated:
  - `blackcat-darkmesh-ao/scripts/deploy/spawn_process_wasm_tn.mjs`
  - `blackcat-darkmesh-write/scripts/cli/spawn_wasm_tn.js`
- behavior:
  - auto-derive `Scheduler-Location` from `--url` (or env),
  - allow explicit override via:
    - `--scheduler-location <URL>`
    - `HB_SCHEDULER_LOCATION` / `HYPERBEAM_SCHEDULER_LOCATION` / `AO_SCHEDULER_LOCATION`

This keeps `Scheduler` (`_wCF...`) + `Scheduler-Location` (`https://write.darkmesh.fun`)
bound together on spawn, improving scheduler discovery parity across HB nodes.

## 2026-04-26 follow-up (runtime parity + resolver spawn diagnostics)

### A) Root cause confirmed for public `/43-char` object fetches on write host

- Symptom: `GET https://write.darkmesh.fun/<43id>` returned `502` while direct HB (`127.0.0.1:8734/<43id>`) returned `200` with body (`1984`).
- Nginx error log showed:
  - `upstream sent too big header while reading response header from upstream`
- Fix applied in write-loopback route for `^/[A-Za-z0-9_-]{43}`:
  - `proxy_buffer_size 128k`
  - `proxy_buffers 16 128k`
  - `proxy_busy_buffers_size 256k`
- Result after reload:
  - `http://127.0.0.1:8745/<43id>` now returns `200` (`1984`) instead of `502`.

### B) Resolver WASM rebuild pipeline hardening

- Updated build script:
  - `blackcat-darkmesh-ao/scripts/deploy/build_resolver_wasm_docker.sh`
- What changed:
  - keep runtime `return process` intact,
  - inject resolver preload bundle without terminal `return require("ao.resolver.process")`,
  - `pcall(require, "ao.resolver.process")` hook,
  - process-handle bridge block injected for compatibility.
- New built WASM SHA256:
  - `cc1362561c146bafb97905409ec0ae4e8ed96973c544664a1783bcb1e3d8cd6c`

### C) New module + PIDs for tracking

- New module tx (v2 bridge build):
  - `kj4fLsrQfExy0mwuyyMC8jj4kn-YBODDW20JXfI1uos`
- New test PIDs:
  - `0TZ42KG9_2GEwy18eqspWdTktg-Jzk6mbrb9JJAZxoU`
  - `kdOo7yopPisflX2e45QwGmBWb1WZp_HB5QrRyANFFIo`
  - `ZsT4aV293cFU14FTq4qo4Fj0rVnNM0P7d5bZT4sfy6c`

### D) Current behavior after fixes

- Process base object fetch is healthy through nginx now (`/<pid>` -> `200` + `1984`).
- Resolver action path still not returning resolver decision payload on plain `now?Action=...` calls:
  - returns `200` + `1984` (default process data) or envelope-only in dry-run variants.
- This means transport-level parity is fixed, but resolver action dispatch over the current plain HTTP shape is still not semantically wired to expected AO contract output.

## 2026-04-27 funded-wallet publish + spawn (continuation)

Wallet verification before deploy:

- `../blackcat-darkmesh-write/wallet.json` (funded):
  - address: `ZqkuoHZ3GTSCVh96BUgO0wlszuOfzFcerd_zN5W4xTU`
  - balance at check: `1462951471063` winston (`~1.462951 AR`)
- `../blackcat-darkmesh-write/wallet_AR.json` (empty):
  - address: `Im52vSBuUry80UZRUvlkvDqraD4-GAQx6AQ-GQfRP8E`
  - balance at check: `0` winston

### Build

- Command:
  - `bash scripts/deploy/build_resolver_wasm_docker.sh`
- Output:
  - `dist/resolver/process.wasm`
  - size: `2.1M`
  - sha256: `0d295ea5e6051683aa967695d4f271398432d541e9b8c5de7cd501a4ca442c17`

### Publish (funded wallet, explicit path)

- Command:
  - `node scripts/deploy/publish_wasm_module.mjs --wasm dist/resolver/process.wasm --wallet ../blackcat-darkmesh-write/wallet.json --name darkmesh-resolver`
- Result:
  - module tx: `hBQgfP0sM9JXmwK7vtYNyl8hzOne1UhGKrSlP16cqus`
  - post status: `200`
  - arweave status right after: `Accepted`

### Spawn (write.darkmesh.fun)

- Command:
  - `node scripts/deploy/spawn_process_wasm_tn.mjs --module hBQgfP0sM9JXmwK7vtYNyl8hzOne1UhGKrSlP16cqus --wallet ../blackcat-darkmesh-write/wallet.json --url https://write.darkmesh.fun --scheduler _wCF37G9t-xfJuYZqc6JXI9VrG4dzM5WUFgDfOn9LdM --scheduler-location https://write.darkmesh.fun --name darkmesh-resolver`
- Result:
  - PID: `PvYcHsA1IiCw_Aw5eK79qwIL_oJQ-_mY_RWAF5qMPu8`
  - spawn status: `200`
  - variant: `ao.TN.1`
  - execution device: `genesis-wasm@1.0`

### Immediate probes

- `GET https://write.darkmesh.fun/~process@1.0/slot/current?target=PvYc...` -> `0`
- `GET https://write.darkmesh.fun/PvYc...~process@1.0/now?Action=GetResolverState&accept-bundle=true` ->
  - `{"error":"Gateway returned no transaction for 'hBQgfP0sM9JXmwK7vtYNyl8hzOne1UhGKrSlP16cqus'"}`
- Interpretation:
  - publish/spawn transport is healthy with funded wallet;
  - module still in early indexing/finalization window, so resolver compute path is not yet usable.

## 2026-04-27 continuation (post-finalization parity check)

### Module/PID state

- module `hBQgfP0sM9JXmwK7vtYNyl8hzOne1UhGKrSlP16cqus` is finalized:
  - `block_height=1905824`
  - confirmations observed: `28` (at check time)
- spawned PIDs seen by scheduler/process APIs but not present as Arweave tx status:
  - `PvYcHsA1IiCw_Aw5eK79qwIL_oJQ-_mY_RWAF5qMPu8`
  - `WLZc01qjklc5o9QhonJZ4opp_4S0K4ZNSZKGs_Oir2A`
  - `arweave.net/tx/<pid>/status` -> `Not Found.` (same behavior as older local PIDs)

### Critical runtime finding (reproduced)

Scheduler direct message flow still fails at compute stage:

1) `POST /~scheduler@1.0/schedule?target=<PID>` returns `200` and slot.
2) `GET /<PID>~process@1.0/compute?slot=<n>&accept-bundle=true` returns:
   - `500`
   - `{"error":"Body is not valid: would attempt to fetch from scheduler in loadMessages"}`

This reproduces consistently for resolver actions and even for `Ping`.

### Hashpath fetch parity (root symptom behind compute failure)

From scheduler response:

- `base-hashpath`: `lQKdsul.../H3huP1n...`

Direct fetches are not resolvable:

- `GET /<base-hashpath>` -> `404 {"body":"Not Found","status":404}`
- `GET /~scheduler@1.0/<base-hashpath>` -> `404 not_found`
- `GET /~scheduler@1.0/read?hashpath=<base-hashpath>` -> `404 not_found`

Interpretation:

- message body retrieval from scheduler hashpaths is currently broken on this node profile;
- resolver AO logic is blocked by scheduler body-load path, so alias-level resolve cannot be considered healthy yet.

### Prepared nginx mitigation patch (repo, pending live deploy)

Updated files:

- `ops/live-vps/runtime/nginx/write-loopback.conf`
- `ops/live-vps/runtime/nginx/hyperbeam-loopback.conf`

Changes:

- scheduler/object routes now force `Host: 127.0.0.1` for local object resolution;
- added explicit two-segment hashpath matcher:
  - `^/[A-Za-z0-9_-]{43}/[A-Za-z0-9_-]{43}(?:\\?.*)?$`
- kept large proxy buffers for commitment-heavy responses.

Goal:

- avoid host-based alias routing side effects for scheduler hashpaths,
- restore `loadMessages` body retrieval path needed by process compute.

## 2026-04-27 hotfix continuation (live nginx + resolver PID)

### Live changes applied on VPS

1) Removed duplicate nginx vhost backups from active load path:

- deleted:
  - `/etc/nginx/sites-enabled/hyperbeam-loopback.conf.bak-`
  - `/etc/nginx/sites-enabled/write-loopback.conf.bak-`
- reason:
  - avoid conflicting server-name warnings and accidental stale routing.

2) Updated resolver PID snippet to a non-crashing process:

- `/etc/nginx/snippets/darkmesh-resolver-pid.conf` ->
  - `set $dm_resolver_pid "PvYcHsA1IiCw_Aw5eK79qwIL_oJQ-_mY_RWAF5qMPu8";`
- result:
  - alias endpoints no longer return `500` from `kdOo...` `loadMessages` failures.

3) Added Arweave chain shim to write host config (`write-loopback` parity):

- file:
  - `ops/live-vps/runtime/nginx/write-loopback.conf`
- added:
  - `location ~ "^/__arweave_chain/([A-Za-z0-9_-]{43})$"` -> `https://arweave.net/tx/<id>`
  - `location ^~ /__arweave_chain/` -> `https://arweave.net/*`
- reason:
  - scheduler-location is `https://write.darkmesh.fun`; module fetches can resolve through write host.
  - without this, runtime emitted `Gateway returned no transaction for '<module-tx>'` for newly spawned processes.

### Current runtime status after hotfix

- `GET /~darkmesh-resolver@1.0/GetResolverState` -> `200` (body `1984`)
- `GET /~darkmesh-resolver@1.0/resolve?...` -> `200` (body `1984`)
- `GET https://jdwt.fun/` -> still `404` (no final resolver decision routing yet)

Interpretation:

- transport/runtime 5xx path is mitigated for alias reads,
- resolver process semantics are still not producing decision payloads (placeholder `1984`),
- domain root routing remains blocked on correct resolver module execution behavior.

### Additional test publishes/spawns (for tracking)

- Lua module test (v2):
  - module: `nOs197OS4JYPp7sEUmgHkeM_WuBRYcz064Hx3R3BD14`
  - pid: `8z6_TrI3vqWn9EnsY5xU8R7axE44k6p-4yiMuwL2FUw`
  - result after chain-shim fix: `422 Module-Format ... not supported`

- Lua module test (v3 with `Module-Format=lua@5.3a` tag):
  - module: `aMjvcg0fZAGVxDlJJ648xfn3qZwxxXJoUD3EG2F2yc0`
  - pid: `ex4PhH4cb48ppx4JIra_DzCHgCgUVlJPxHd1H7DG9As`
  - current state: module still `Accepted` (not finalized/indexed at check time), runtime reports:
    - `Gateway returned no transaction for 'aMjvcg0f...'`

## 2026-04-27 continuation (public probe + scheduler/compute parity)

Observed from fresh public probes:

- alias endpoints still return placeholder output:
  - `GET /~darkmesh-resolver@1.0/GetResolverState` -> `200` with body `1984`
  - `GET /~darkmesh-resolver@1.0/resolve?...` -> `200` with body `1984`
- action POST alias still unresolved:
  - `POST /~darkmesh-resolver@1.0/ResolveHostForNode` -> `404`
  - `POST /~darkmesh-resolver@1.0/ResolveRouteForHost` -> `404`
- domain roots still unresolved:
  - `https://jdwt.fun/` -> `404`
  - `https://vddl.fun/` -> `404`
  - `https://blgateway.fun/` -> `404`

Key parity finding on write node:

- resolver-like PID `kdOo7yopPisflX2e45QwGmBWb1WZp_HB5QrRyANFFIo`:
  - scheduler schedule succeeds (`slot=9`)
  - `compute=9` fails:
    - `500 {"error":"Body is not valid: would attempt to fetch from scheduler in loadMessages"}`
  - `base-hashpath` from schedule response is not fetchable:
    - `/<base-hashpath>` -> `404 {"body":"Not Found","status":404}`
    - `/~scheduler@1.0/<base-hashpath>` -> `404 not_found`
    - `/~scheduler@1.0/read?hashpath=<base-hashpath>` -> `404 not_found`

Interpretation:

- transport is healthy (schedule path works), but resolver execution is blocked by
  unresolved scheduler message-body hashpaths on this runtime profile.
- alias currently points to a non-crashing placeholder PID (`1984`) only to avoid
  5xx until hashpath readback path is fixed.

Tooling hardening applied (local repos):

- spawn PID parsers no longer fall back to generic JSON `id` (message/data-item id)
  when extracting process id:
  - `blackcat-darkmesh-ao/scripts/deploy/spawn_process_wasm_tn.mjs`
  - `blackcat-darkmesh-write/scripts/cli/spawn_wasm_tn.js`
- process id extraction now accepts only process-specific fields:
  - `process`, `Process`, `pid`, `PID`, `process-id`, `processId`.

Prepared nginx parity patch (template-only, pending live deploy):

- files:
  - `ops/live-vps/runtime/nginx/write-loopback.conf`
  - `ops/live-vps/runtime/nginx/hyperbeam-loopback.conf`
- change:
  - two-segment hashpath matcher now captures `A/B` and preserves canonical fetch first,
  - on `404` it retries internal fallback to tail segment `B`,
  - rationale: scheduler `base-hashpath` is frequently emitted as `A/B` while current node profile resolves only `B`.
- expected effect:
  - reduce/clear `loadMessages` failures for resolver-like PIDs where scheduler body
    exists but canonical `A/B` path returns 404.

## 2026-04-27 live deploy (tailscale) — hashpath fallback + PID probe

Applied live over tailscale host `adminops@65-109-99-102`:

1) Deployed updated nginx loopback configs to active paths:
   - `/etc/nginx/sites-enabled/write-loopback.conf`
   - `/etc/nginx/sites-enabled/hyperbeam-loopback.conf`
   - kept same copies in `/etc/nginx/sites-available/*`
   - validated with `nginx -t` and reloaded nginx.

2) Cleaned accidental backup files from `sites-enabled`:
   - removed `*.bak-*` there to avoid duplicate server-name conflicts.

3) Verified hashpath fallback behavior:
   - canonical scheduler-like paths that were previously `404` now resolve `200`:
     - `/<43>/<43>` -> `200` (via fallback-to-tail when needed)
   - example:
     - `/hK0ke.../i-t69...` now returns scheduler object JSON instead of `404`.

4) Resolver PID switch test:
   - switched alias PID to `kdOo7yopPisflX2e45QwGmBWb1WZp_HB5QrRyANFFIo`,
   - result: alias endpoints regressed to `500` and direct compute still fails with:
     - `{"error":"Body is not valid: would attempt to fetch from scheduler in loadMessages"}`
   - rollback applied immediately to non-crashing PID:
     - `PvYcHsA1IiCw_Aw5eK79qwIL_oJQ-_mY_RWAF5qMPu8`
   - after rollback:
     - `~darkmesh-resolver@1.0/GetResolverState` back to `200` (`1984` placeholder).

Current state after live deploy:

- nginx hashpath fallback is active and working,
- resolver semantic routing is still blocked on scheduler/loadMessages path for `kdOo...`,
- alias remains pinned to stable placeholder PID (`PvYc...`) to avoid runtime 5xx.

## 2026-04-27 Variant 1 rollout prep (AO projection -> nginx host-map)

- Deployed runtime components on VPS (`adminops@65-109-99-102`) without downtime:
  - `/usr/local/sbin/sync-nginx-host-routing.sh`
  - `/etc/systemd/system/darkmesh-host-routing-sync.service`
  - `/etc/systemd/system/darkmesh-host-routing-sync.timer`
  - `/etc/darkmesh/resolver-projection.env(.example)`
  - `/etc/nginx/snippets/darkmesh-host-routing.conf(.example)`
  - updated `/etc/nginx/sites-available/hyperbeam-loopback.conf` to include host-map snippet.
- Timer enabled and healthy (`darkmesh-host-routing-sync.timer`).
- Added bootstrap `file:///` projection mode support in projector script to keep timer stable before final AO endpoint cutover.
- Current state file:
  - `/var/lib/darkmesh/host-routing/state.json` => `mode=active`, `reason=projection_ok` (bootstrap envelope).
- Current snippet is intentionally empty (`set $dm_host_target_prefix "";`) until real AO snapshot endpoint is provided.

### DNS/DM1 reality check (why domains still 404 right now)

- `_darkmesh` TXT for `jdwt.fun`, `vddl.fun`, `blgateway.fun` resolves correctly.
- All three `cfg` JSON payloads currently point to the same `siteProcess`:
  - `Zv01GLNx1TBKxoswGi-tWoxNmgVYr1JSJJbjA3DDcJM`
- On current runtime profile:
  - `Host: hyperbeam.darkmesh.fun` + that PID => `404 not_found`
  - `Host: write.darkmesh.fun` + that PID => `200` envelope (not a rendered page body)
- Conclusion: routing infrastructure is now in place; domain render still depends on valid per-domain runtime targets + final AO projection source.

## 2026-04-27 follow-up live patch (scheduler object prefix fallback)

Additional write-node nginx patch applied live:

- file:
  - `ops/live-vps/runtime/nginx/write-loopback.conf`
- change:
  - scheduler prefix route (`/~scheduler@1.0/*`) now retries 404 object/hashpath reads
    by stripping scheduler prefix and resolving via root object path.
  - this covers both:
    - `~scheduler@1.0/<43>`
    - `~scheduler@1.0/<43>/<43>`

Validation after patch:

- previously failing scheduler object reads now resolve:
  - `GET /~scheduler@1.0/<43>` -> `200`
  - `GET /~scheduler@1.0/<43>/<43>` -> `200`
- chained base-hashpath traversal for `kdOo...` schedule responses now stays `200`
  across successive links (`A/B` and scheduler-prefixed variants).

However:

- resolver compute for `kdOo...` still fails:
  - `compute=<slot>&accept-bundle=true` -> `500`
  - error unchanged: `Body is not valid: would attempt to fetch from scheduler in loadMessages`
- alias switched to `kdOo...` for retest still produced `500`, so it was rolled back
  again to stable `PvYc...` to keep endpoint health (`200`, placeholder body `1984`).

## 2026-04-27 follow-up (slot2 isolation test on live write endpoint)

Goal: verify whether the `loadMessages` failure is global runtime breakage or
process-history-specific corruption.

Live probes run against `https://write.darkmesh.fun`:

- failing PID (`kdOo7yopPisflX2e45QwGmBWb1WZp_HB5QrRyANFFIo`):
  - `slot/current` = `11`
  - `compute=1` -> `200`
  - `compute=2` -> `502` (Cloudflare front) / upstream error:
    - `Body is not valid: would attempt to fetch from scheduler in loadMessages`
- control PID (`RWhGUEjdtjpC2D59nRE3xiDq4Hcs5uNuYMbu_32uDBs`):
  - sent additional scheduler-direct signed message (`Action=Ping`) to force slot `2`
  - `compute=1` -> `200`
  - `compute=2` -> `200`

Conclusion:

- this is not a generic scheduler/readback outage on the write node.
- failure is isolated to the historical message chain of `kdOo...` (slot2 replay path).
- keep alias pinned to non-failing PID until resolver logic is respawned on a clean process chain.

## 2026-04-27 additional live check (module bootstrap semantics)

Purpose: verify whether resolver runtime behavior is blocked by route/parity only,
or by process bootstrap semantics.

Test process (new):

- PID: `EfsjtBAYpVBiYiC9dd9YOPZC0K3MpnwVmbo-38WFDf4`
- module: `hBQgfP0sM9JXmwK7vtYNyl8hzOne1UhGKrSlP16cqus`
- spawn mode: standard wasm spawn with seed data `1984`

Messages sent (scheduler-direct):

- slot `1`: `Action=Eval`, data file:
  - `ops/live-vps/runtime/hb/addons/darkmesh-resolver@1.0.lua`
  - data item id: `SOa2uYOh77A7qH64hhfX4yOtrT-dGVTrfP2C0T73DEk`
- slot `2`: `Action=GetResolverState`, data `{}`:
  - data item id: `SS7YK3xGYCoXBbV3nKnpHIQ_BRMd2fNG66zRqyt9e_E`

Observed:

- scheduler accepts both messages (`status=200`, slots advance `1 -> 2`)
- compute replay is healthy (`compute=1` and `compute=2` => `200`)
- but `results.raw` contains no resolver output (`Output=""`, `Error={}`)
- `now?Action=GetResolverState` still returns seed payload (`1984`)

Interpretation:

- transport + scheduler replay are healthy for this process chain,
- but this module/bootstrap path is still envelope-only for resolver semantics
  on current runtime profile (actions are accepted but do not yield resolver decision payload).

## 2026-04-27 parity re-check (current live state)

Fresh public probes (CEST) confirm:

- `https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState` -> `200`, body `1984`
- `https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/resolve?host=jdwt.fun&path=/` -> `200`, body `1984`
- `https://jdwt.fun/`, `https://vddl.fun/`, `https://blgateway.fun/` -> `404`

Resolver alias still points to:

- PID: `PvYcHsA1IiCw_Aw5eK79qwIL_oJQ-_mY_RWAF5qMPu8`
- module: `hBQgfP0sM9JXmwK7vtYNyl8hzOne1UhGKrSlP16cqus` (finalized)
- execution device: `genesis-wasm@1.0`

Scheduler-direct action check on `PvYc...`:

- signed `ResolveRouteForHost` accepted (`slot=9`)
- signed unknown action `FoobarXYZ` accepted (`slot=10`)
- `compute=9` and `compute=10` both return `1984`

Conclusion:

- current PID is transport-stable (no 5xx on alias path),
- but action semantics are not surfacing via current invoke pattern (`now?Action=...`),
- resolver remains non-functional for domain routing despite finalized module + healthy scheduler ingest.

## 2026-04-27 attempt: native path-action inference (no scheduler roundtrip)

Goal:

- make resolver handle direct action-like HTTP paths (`.../GetResolverState`,
  `.../ResolveRouteForHost?...`) without relying on scheduler compute replay.

Code updates applied in source:

- `blackcat-darkmesh-ao/ao/resolver/process.lua`
- mirrored to runtime addon reference:
  - `ops/live-vps/runtime/hb/addons/darkmesh-resolver@1.0.lua`
- added:
  - query-string parsing/merge (`Action`, `Host`, `Path`, `Method`, `Request-Id`, `Node-Id`)
  - action inference from trailing HTTP path segment
  - normalization from lowercase query fields to canonical resolver fields

Build + publish + spawn:

- rebuilt WASM:
  - `blackcat-darkmesh-ao/dist/resolver/process.wasm`
  - sha256: `991b25b20e37fa70b961ffd31918ea81ad5c38985f5383eb83587d758956f110`
- module tx:
  - `T_swJNJ3UwyOpotwX20lrKjUp230arJ-L9giHaKD2m8`
- PID:
  - `W31hTf9uJdmOkls039bmuvW6V7GpI8qeniwfoJXvCuA`

Live probe result on new PID:

- `/<pid>~process@1.0/slot/current` -> `200` (`0`)
- `/<pid>~process@1.0/GetResolverState` -> `404 not_found`
- `/<pid>~process@1.0/ResolveRouteForHost?...` -> `404 not_found`
- `/<pid>~process@1.0/now?Action=GetResolverState` -> `500`

Conclusion:

- path-action inference in resolver code is not enough on this runtime profile,
- direct path invoke does not reach resolver action dispatch in a usable way,
- this confirms blocker is upstream invoke surface semantics (stock profile behavior),
  not only missing parsing inside resolver contract.

## 2026-04-27 approved operating model (test vs production pools)

Approved direction for Variant-1 projection path:

- Test pool:
  - projection pull every `60s`
  - stale policy: LKG `15m`, then fail-closed
  - source: signed AO projection feed
- Production pool:
  - runtime pull every `5-15 min` (target profile: `10 min`)
  - stale policy: longer LKG window (target: `2h`)
  - plus signed AR baseline snapshots (daily/weekly) for audit/replay
- Trust model:
  - no static whitelist of websites in nginx
  - routed hosts come from signed projection entries (`host -> target`)
  - signer allowlist only validates who may publish projection updates

## 2026-04-27 live fix: test-file projection enabled and stabilized

Live actions on VPS (`adminops@100.118.81.41` via tailscale):

- root-cause for "projection works but domains still 404" was nginx layout drift:
  - `/etc/nginx/sites-enabled/hyperbeam-loopback.conf` was a stale copied file
  - while updates were applied to `/etc/nginx/sites-available/hyperbeam-loopback.conf`
- corrected by restoring symlink model:
  - `sites-enabled/hyperbeam-loopback.conf -> sites-available/hyperbeam-loopback.conf`
  - moved backup copies out of `sites-enabled/` to avoid shadowing
- added autonomous test-file projection refresh:
  - `DARKMESH_DM1_AUTOBUILD=1`
  - `DARKMESH_DM1_DOMAINS_FILE=/etc/darkmesh/projection-domains.txt`
  - builder now reads DM1 cfg through `/tx/<cfg>/data` with base64url JSON decode fallback
  - host-routing sync now autobuilds file projection before apply cycle

Live verification:

- host-routing sync logs show:
  - `dm1 autobuild refreshed projection file`
  - `sync completed`
- public domains now route through projection and return `200`:
  - `https://jdwt.fun/`
  - `https://vddl.fun/`
  - `https://blgateway.fun/`

Note:

- all three domains currently point to the same DM1 `siteProcess` (`Zv01...`),
  so all render same HyperBEAM page until per-domain site PIDs are updated in DM1 cfg tx.

## 2026-04-27 live verification (post-autobuild enable)

Validated again over tailscale host `adminops@100.118.81.41`:

- `darkmesh-host-routing-sync.timer` is `active/enabled`.
- each timer tick still reports:
  - `dm1 autobuild refreshed projection file`
  - `sync completed`
- generated projection file contains three hosts with DM1 `cfg` tx references:
  - `jdwt.fun`, `vddl.fun`, `blgateway.fun`
- active nginx host-routing snippet is populated and maps all three hosts to:
  - `/Zv01GLNx1TBKxoswGi-tWoxNmgVYr1JSJJbjA3DDcJM~process@1.0`

Response parity check (`127.0.0.1:8744`, host header override):

- `jdwt.fun` -> `200`, `text/html`, body hash:
  - `10a633cbadf01490c74ca7fcb06b0787241504ba58ef5a0c6ad3c3b21a176794`
- `vddl.fun` -> `200`, same body hash.
- `blgateway.fun` -> `200`, same body hash.

Current state:

- test-file projection pipeline is stable and autonomous on VPS,
- domain routing is operational,
- per-domain content split is pending DM1 cfg updates (`siteProcess` per host).

## 2026-04-27 mixed routing demo (TX + Process)

Goal:

- verify both routing targets in one live cycle:
  - tx mode (`/<txid>`)
  - process mode (`/<pid>~process@1.0`)

Changes applied:

- upgraded host-routing sync parser on VPS to support mixed targets:
  - `/usr/local/sbin/sync-nginx-host-routing.sh`
  - `/usr/local/sbin/build-host-routing-envelope-from-dm1.sh`
- temporary test profile change:
  - `/etc/darkmesh/resolver-projection.env`
  - `DARKMESH_DM1_AUTOBUILD=0` (so manual mixed projection is not overwritten every 60s)
- loaded mixed projection envelope to:
  - `/etc/darkmesh/resolver-projection.bootstrap.json`
- forced one sync:
  - `systemctl start darkmesh-host-routing-sync.service`

Active host map snippet now:

- `jdwt.fun` -> `/uhk0bhly58q2ulNh3VkTlMgpkrg18BzVCMCBi_rJwGQ` (tx mode)
- `vddl.fun` -> `/Zv01GLNx1TBKxoswGi-tWoxNmgVYr1JSJJbjA3DDcJM~process@1.0` (process mode)
- `blgateway.fun` -> `/Zv01GLNx1TBKxoswGi-tWoxNmgVYr1JSJJbjA3DDcJM~process@1.0` (process mode)

Live check:

- `jdwt.fun` => `200`, html hash `cb9f7b6d64ace1cd2fed242cbb4865992d64b16831e00befda24eb966c8973fc`
- `vddl.fun` => `200`, html hash `10a633cbadf01490c74ca7fcb06b0787241504ba58ef5a0c6ad3c3b21a176794`
- `blgateway.fun` => `200`, html hash `10a633cbadf01490c74ca7fcb06b0787241504ba58ef5a0c6ad3c3b21a176794`

Notes:

- mixed routing behavior is now verified end-to-end in nginx projection mode,
- DM1 autobuild was intentionally paused for this isolated test,
- custom inline demo tx is now active on `jdwt.fun`:
  - `uhk0bhly58q2ulNh3VkTlMgpkrg18BzVCMCBi_rJwGQ`

## 2026-04-27 quickstart demo v2 (all 3 domains on Variant 1 TX mode)

Goal:

- deploy a stronger onboarding demo page (resolver branding + host/time/runtime fields),
- keep Variant 1 routing model,
- make `jdwt.fun`, `vddl.fun`, `blgateway.fun` return the same stable quickstart page.

Build + publish:

- source template updated:
  - `blackcat-darkmesh-write/scripts/demo/domain-quickstart-demo.html`
- published tx:
  - `hsSzdS5PAXQyoZksua77WQEOHcLDHznYukTvI8x4qAk`
- status:
  - `https://arweave.net/tx/hsSzdS5PAXQyoZksua77WQEOHcLDHznYukTvI8x4qAk/status` -> confirmed in block

Live routing update (tailscale host `adminops@100.118.81.41`):

- edited:
  - `/etc/darkmesh/resolver-projection.bootstrap.json`
- mapped all three hosts to tx mode:
  - `jdwt.fun` -> `/hsSzdS5PAXQyoZksua77WQEOHcLDHznYukTvI8x4qAk`
  - `vddl.fun` -> `/hsSzdS5PAXQyoZksua77WQEOHcLDHznYukTvI8x4qAk`
  - `blgateway.fun` -> `/hsSzdS5PAXQyoZksua77WQEOHcLDHznYukTvI8x4qAk`
- applied with no downtime:
  - `systemctl start darkmesh-host-routing-sync.service`
  - nginx reloaded by sync service (`reload-on-change`).

Verification:

- `https://jdwt.fun/` -> `200`, `<title>Darkmesh Domain Demo</title>`, marker `Domain Gateway is online`
- `https://vddl.fun/` -> `200`, `<title>Darkmesh Domain Demo</title>`, marker `Domain Gateway is online`
- `https://blgateway.fun/` -> `200`, `<title>Darkmesh Domain Demo</title>`, marker `Domain Gateway is online`

Current intentional mode:

- `/etc/darkmesh/resolver-projection.env` still has `DARKMESH_DM1_AUTOBUILD=0` (manual bootstrap/projection control for test phase).
- To switch back to fully autonomous DM1 projection later, first align live DNS TXT + DM1 cfg tx targets with this desired host map, then set `DARKMESH_DM1_AUTOBUILD=1`.

## 2026-04-27 DM1 cfg tx publish for Variant 1 (all three domains)

Published signed DM1 config transactions (tx-target mode, shared demo target):

- demo target tx: `hsSzdS5PAXQyoZksua77WQEOHcLDHznYukTvI8x4qAk`
- `jdwt.fun` cfg tx: `MliKCVc5EmLncK-KYkcrkGDCsQ43xEMTsODkfVG4dRI`
- `vddl.fun` cfg tx: `_zCtKIygZToC4Ao4bZnJC-MPchtNJjhj16WNXzSHNQo`
- `blgateway.fun` cfg tx: `bSzVjR8ObiTxy2kf_2qNJXPqiXWX9rn5pNJCJ4ofBJM`

TXT records to apply:

- `_darkmesh.jdwt.fun` -> `v=dm1;cfg=MliKCVc5EmLncK-KYkcrkGDCsQ43xEMTsODkfVG4dRI;kid=ZqkuoHZ3GTSCVh96BUgO0wlszuOfzFcerd_zN5W4xTU;ttl=3600;seq=4`
- `_darkmesh.vddl.fun` -> `v=dm1;cfg=_zCtKIygZToC4Ao4bZnJC-MPchtNJjhj16WNXzSHNQo;kid=ZqkuoHZ3GTSCVh96BUgO0wlszuOfzFcerd_zN5W4xTU;ttl=3600;seq=4`
- `_darkmesh.blgateway.fun` -> `v=dm1;cfg=bSzVjR8ObiTxy2kf_2qNJXPqiXWX9rn5pNJCJ4ofBJM;kid=ZqkuoHZ3GTSCVh96BUgO0wlszuOfzFcerd_zN5W4xTU;ttl=3600;seq=4`

Artifacts saved:

- `ops/live-vps/local-tools/dm1-domain-configs-2026-04-27/dm1-jdwt.fun.config.signed.json`
- `ops/live-vps/local-tools/dm1-domain-configs-2026-04-27/dm1-vddl.fun.config.signed.json`
- `ops/live-vps/local-tools/dm1-domain-configs-2026-04-27/dm1-blgateway.fun.config.signed.json`
- `ops/live-vps/local-tools/dm1-domain-configs-2026-04-27/dm1-txt-records.json`

## 2026-04-27 DNS verified + DM1 autobuild enabled

DNS verification:

- `_darkmesh.jdwt.fun` returns `cfg=MliKCVc5EmLncK-KYkcrkGDCsQ43xEMTsODkfVG4dRI;seq=4`
- `_darkmesh.vddl.fun` returns `cfg=_zCtKIygZToC4Ao4bZnJC-MPchtNJjhj16WNXzSHNQo;seq=4`
- `_darkmesh.blgateway.fun` returns `cfg=bSzVjR8ObiTxy2kf_2qNJXPqiXWX9rn5pNJCJ4ofBJM;seq=4`

Cutover:

- `/etc/darkmesh/resolver-projection.env`
  - `DARKMESH_DM1_AUTOBUILD=1` (enabled)
- triggered:
  - `systemctl start darkmesh-host-routing-sync.service`
- service logs confirm:
  - `dm1 autobuild refreshed projection file: /etc/darkmesh/resolver-projection.bootstrap.json`
  - `nginx reloaded (active)`
  - `sync completed`

Resulting active projection (`/etc/darkmesh/resolver-projection.bootstrap.json`):

- `jdwt.fun` -> tx `hsSzdS5PAXQyoZksua77WQEOHcLDHznYukTvI8x4qAk`, cfgTx `MliKCVc5EmLncK-KYkcrkGDCsQ43xEMTsODkfVG4dRI`
- `vddl.fun` -> tx `hsSzdS5PAXQyoZksua77WQEOHcLDHznYukTvI8x4qAk`, cfgTx `_zCtKIygZToC4Ao4bZnJC-MPchtNJjhj16WNXzSHNQo`
- `blgateway.fun` -> tx `hsSzdS5PAXQyoZksua77WQEOHcLDHznYukTvI8x4qAk`, cfgTx `bSzVjR8ObiTxy2kf_2qNJXPqiXWX9rn5pNJCJ4ofBJM`

Smoke check:

- `https://jdwt.fun/` -> `200`, title `Darkmesh Domain Demo`
- `https://vddl.fun/` -> `200`, title `Darkmesh Domain Demo`
- `https://blgateway.fun/` -> `200`, title `Darkmesh Domain Demo`

## 2026-04-27 post-cutover monitor (6-minute window)

Window:

- approx `16:58Z` -> `17:04Z` (6 probe ticks, 60s cadence)

Probe result:

- every tick:
  - `jdwt.fun` -> `200`, title `Darkmesh Domain Demo`
  - `vddl.fun` -> `200`, title `Darkmesh Domain Demo`
  - `blgateway.fun` -> `200`, title `Darkmesh Domain Demo`
- timer remained healthy:
  - `darkmesh-host-routing-sync.timer` = `active (waiting)`
  - service runs completed with `Result=success`
- state progressed each tick:
  - `/var/lib/darkmesh/host-routing/state.json` `updatedAt` advanced in step with timer.

Server-side journal confirmation:

- periodic entries observed:
  - `dm1 autobuild refreshed projection file`
  - `nginx reloaded (active)`
  - `sync completed`
