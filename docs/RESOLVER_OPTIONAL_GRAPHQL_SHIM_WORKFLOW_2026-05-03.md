# Optional DarkMesh-only GraphQL shim

This optional runtime piece exists for small HB-only VPS nodes that should stay
lightweight but still make freshly published DarkMesh resolver/module tx ids
visible to `genesis-wasm-server` before public GraphQL indexers catch up.

It is **not** a trust anchor and it is **not** a stock HyperBEAM patch.

- source of truth stays on Arweave / AO / DNS
- stock HB stays untouched
- the shim is only a metadata transport/cache helper

## Goal

Make this work by changing only a URL/port:

- small VPS mode:
  - `GRAPHQL_URL=http://127.0.0.1:18777/graphql`
- full local indexed node mode later:
  - `GRAPHQL_URL=http://127.0.0.1:<your-graphql-port>/graphql`
- remote mode:
  - `GRAPHQL_URL=https://arweave.net/graphql`

The caller sees the same GraphQL contract either way.

## What the shim does

- listens locally on `127.0.0.1:18777` by default
- accepts normal GraphQL `POST /graphql`
- handles `transactions(ids: [...])` queries itself for an allowlisted set of tx ids
- fetches tx metadata from `/tx/<id>` and converts it into the GraphQL `node` shape
- caches those metadata payloads locally
- optionally proxies misses / unsupported queries upstream, so it can behave like a
  "bigger" GraphQL service when desired

## Why this fits the small VPS

It avoids running:

- a full Arweave miner
- a full local GraphQL indexer
- broad indexing for unrelated apps

And it keeps the optional piece swappable:

- enable shim on small VPS
- disable shim and point `GRAPHQL_URL` to a local full node later
- or point `GRAPHQL_URL` back to a public GraphQL service

## Runtime files

- service:
  - `ops/live-vps/runtime/systemd/darkmesh-graphql-shim.service`
- binary:
  - `ops/live-vps/runtime/scripts/darkmesh-graphql-shim.py`
- env example:
  - `ops/live-vps/runtime/etc/darkmesh/graphql-shim.env.example`
- allowlist example:
  - `ops/live-vps/runtime/etc/darkmesh/graphql-shim-allowlist.txt.example`

## Minimal rollout

1. Stage the runtime files.
2. Copy/edit:
   - `/etc/darkmesh/graphql-shim.env`
   - `/etc/darkmesh/graphql-shim-allowlist.txt`
3. Enable the shim:
   - `sudo systemctl enable --now darkmesh-graphql-shim.service`
4. Point HB metadata lookup at the shim:
   - `GRAPHQL_URL=http://127.0.0.1:18777/graphql`
   - `GRAPHQL_URLS=http://127.0.0.1:18777/graphql,https://arweave.net/graphql`
   - `CHECKPOINT_GRAPHQL_URL=http://127.0.0.1:18777/graphql`
5. Restart HB:
   - `cd /srv/darkmesh/hb && sudo docker compose restart hyperbeam`

## Keeping the allowlist current

Use the local helper whenever a new DarkMesh resolver/module tx should become
visible through the shim:

```bash
bash ops/live-vps/local-tools/update-graphql-shim-allowlist.sh \
  --tx <module-tx> \
  --remote-target adminops@100.104.75.121 \
  --remote-ssh-key ~/.ssh/darkmesh_new_vps_adminops
```

It can also read publish/candidate artifacts directly:

```bash
bash ops/live-vps/local-tools/update-graphql-shim-allowlist.sh \
  --module-json /tmp/module.json \
  --candidate-report /tmp/darkmesh-resolver-candidate-live/candidate-report.json \
  --remote-target adminops@100.104.75.121 \
  --remote-ssh-key ~/.ssh/darkmesh_new_vps_adminops
```

And the fresh candidate flow can call it automatically after publish/reuse:

```bash
bash ops/live-vps/local-tools/fresh-resolver-candidate.sh \
  --wallet /secure/ao-wallet.json \
  --build-wasm 1 \
  --execute-live 1 \
  --graphql-url http://127.0.0.1:18777/graphql \
  --graphql-shim-remote-target adminops@100.104.75.121 \
  --graphql-shim-remote-ssh-key ~/.ssh/darkmesh_new_vps_adminops \
  --output-dir /tmp/darkmesh-resolver-candidate-live
```

If the shim listens only on VPS loopback, that is okay: the candidate flow will
reuse `--graphql-shim-remote-target` to run the GraphQL visibility gate over
ssh against that loopback-only URL before it spawns the candidate PID.

## Full local node later

If an operator later adds a real indexed Arweave GraphQL backend, keep the rest
of the runtime exactly the same and just switch:

- disable `darkmesh-graphql-shim.service`
- change `GRAPHQL_URL` / `GRAPHQL_URLS` / `CHECKPOINT_GRAPHQL_URL`
- restart HB

That is the intended portability contract.
