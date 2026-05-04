# Resolver alias guide (use human-friendly name, not tx/pid)

Date: 2026-04-22  
Status: Practical operator guide

## Goal

Expose resolver/control-plane endpoints with stable names such as:

- `https://resolver.darkmesh.fun/api/public/site-by-host`
- `https://write.darkmesh.fun/~process@1.0/`

and keep tx/pid identifiers internal only.

## Principle

- Public callers should never need module tx ids in URLs.
- tx/pid stays inside AO registry state and operator config.
- DNS + tunnel + HB config provide a stable named entrypoint.

## 1) Public resolver naming pattern

Use a dedicated subdomain for resolver/read API:

- `resolver.darkmesh.fun` -> CNAME -> `hyperbeam.darkmesh.fun` (proxied in CF)

Then route all public resolver calls through named paths:

- `POST /api/public/site-by-host`
- `POST /api/public/resolve-route`
- `POST /api/public/page`

This keeps URLs readable and stable even when underlying tx/pid changes.

## 2) Write/control-plane naming pattern

Keep write path as named host + device path:

- `https://write.darkmesh.fun/~process@1.0/`

Do not expose raw tx ids in app/web tooling.

## 3) Where tx/pid lives (internal)

Keep resolver identity metadata in AO registry control state:

- use registry trust metadata (`UpdateTrustResolvers`, `GetTrustedResolvers`)
- store resolver entries by stable resolver id/name (e.g. `darkmesh-resolver-v1`)
- include current manifest/pointer metadata in registry state

Clients consume named API endpoints; operators rotate tx/pid behind that layer.

## 4) Rotation without client URL changes

When resolver module/process rotates:

1. Update AO registry trust metadata (new resolver pointer).
2. Keep `resolver.darkmesh.fun` DNS unchanged.
3. Keep `/api/public/*` paths unchanged.
4. Verify with readiness/smoke tools.

Result: external users keep the same readable URL.

## 5) Migration note

If any scripts still require tx in CLI flags, treat that as operator-only detail.
For public documentation and user-facing UX, always publish named endpoints only.
