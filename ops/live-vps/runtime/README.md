# Stock HB companion runtime

This directory is the portable companion pack for installing DarkMesh Resolver
next to an already running stock HyperBEAM node.

## What it contains

- helper binaries for projection build/verify/activation
- nginx map + loopback configs
- systemd services/timers
- example env and trust files

## Primary install path

Stage the companion pack onto a node:

```bash
bash ops/live-vps/runtime/install-stock-hb-companion.sh
```

Useful options:

```bash
bash ops/live-vps/runtime/install-stock-hb-companion.sh --root /tmp/dm-root
bash ops/live-vps/runtime/install-stock-hb-companion.sh --install-nginx-loopbacks
bash ops/live-vps/runtime/install-stock-hb-companion.sh --enable-services
```

## Installed paths

The installer targets these runtime paths:

- `/usr/local/sbin/projection-envelope-tool.py`
- `/usr/local/sbin/build-host-routing-envelope-from-dm1.sh`
- `/usr/local/sbin/verify-projection-dm1-parity.sh`
- `/usr/local/sbin/darkmesh-resolver-read-adapter.py`
- `/usr/local/sbin/sync-nginx-host-routing.sh`
- `/usr/local/sbin/sync-nginx-resolver-pid.sh`
- `/usr/local/sbin/set-host-routing-profile.sh`
- `/etc/darkmesh/resolver-projection.env`
- `/etc/darkmesh/resolver-adapter.env`
- `/etc/darkmesh/projection-domains.txt`
- `/etc/darkmesh/projection-trust.json`
- `/etc/systemd/system/darkmesh-*.service`
- `/etc/systemd/system/darkmesh-*.timer`
- `/etc/nginx/conf.d/darkmesh-host-routing-map.conf`
- `/etc/nginx/snippets/darkmesh-resolver-pid.conf`

Loopback nginx server blocks are installed as examples unless the operator
passes `--install-nginx-loopbacks`.

## Recommended rollout order

1. install companion pack
2. edit env/trust files
3. merge or enable nginx loopback configs
4. enable resolver adapter + host-routing sync
5. validate bootstrap or signed projection activation

For the full activation path, use:

- `docs/RESOLVER_SIGNED_PROJECTION_ACTIVATION_CHECKLIST_2026-04-30.md`
- `docs/RESOLVER_DM1_PARITY_VERIFICATION_WORKFLOW_2026-05-01.md`

## Optional GraphQL shim

Use this only on small VPS nodes when you want a tiny DarkMesh-only metadata
cache instead of a full local Arweave GraphQL backend.

Installed/runtime pieces:

- `/usr/local/sbin/darkmesh-graphql-shim.py`
- `/etc/systemd/system/darkmesh-graphql-shim.service`
- `/etc/darkmesh/graphql-shim.env`
- `/etc/darkmesh/graphql-shim-allowlist.txt`

Default local endpoint:

- `http://127.0.0.1:18777/graphql`

The portability contract is intentional:

- small VPS mode: point `GRAPHQL_URL` to the shim URL
- full local node mode later: point `GRAPHQL_URL` to the local indexed node
- remote mode: point `GRAPHQL_URL` back to a public GraphQL service

That switch should only be a URL/port change, not a stack redesign.
