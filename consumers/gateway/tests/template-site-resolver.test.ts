import { afterEach, describe, expect, it, vi } from 'vitest'

import { handleRequest } from '../src/handler.js'
import { resolveTemplateSiteIdFromHost, resetTemplateSiteResolverCacheForTests } from '../src/runtime/template/siteResolver.js'

function buildTemplateCallRequest(host: string, body: Record<string, unknown>) {
  return new Request(`https://${host}/template/call`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
    },
    body: JSON.stringify(body),
  })
}

describe('template host resolver', () => {
  afterEach(() => {
    vi.restoreAllMocks()
    resetTemplateSiteResolverCacheForTests()
    delete process.env.GATEWAY_SITE_ID_BY_HOST_MAP
    delete process.env.GATEWAY_SITE_RESOLVE_MODE
    delete process.env.GATEWAY_SITE_RESOLVE_AO_URL
    delete process.env.GATEWAY_SITE_RESOLVE_POLICY_MODE
    delete process.env.GATEWAY_SITE_RESOLVE_POLICY_REASON_LOG
    delete process.env.GATEWAY_SITE_RESOLVE_TIMEOUT_MS
    delete process.env.GATEWAY_SITE_RESOLVE_CACHE_TTL_MS
    delete process.env.GATEWAY_SITE_RESOLVE_UNAVAILABLE_CACHE_TTL_MS
    delete process.env.GATEWAY_SITE_RESOLVE_GLOBAL_UNAVAILABLE_CACHE_TTL_MS
    delete process.env.GATEWAY_SITE_RESOLVE_BREAKER_THRESHOLD
    delete process.env.GATEWAY_SITE_RESOLVE_BREAKER_WINDOW_MS
    delete process.env.GATEWAY_SITE_RESOLVE_BREAKER_OPEN_MS
    delete process.env.GATEWAY_SITE_RESOLVE_ALLOW_BODY_FALLBACK
    delete process.env.GATEWAY_PRODUCTION_LIKE
    delete process.env.AO_PUBLIC_API_URL
    delete process.env.WRITE_API_URL
    delete process.env.GATEWAY_TEMPLATE_ALLOW_MUTATIONS
    delete process.env.GATEWAY_TEMPLATE_TOKEN
    delete process.env.GATEWAY_TEMPLATE_TARGET_HOST_ALLOWLIST
    delete process.env.GATEWAY_TEMPLATE_ALLOW_RUNTIME_HINTS
    delete process.env.GATEWAY_TEMPLATE_ALLOW_RUNTIME_WORKER_URL_OVERRIDE
    delete process.env.GATEWAY_TEMPLATE_ALLOW_RUNTIME_WRITE_PID_OVERRIDE
    delete process.env.WORKER_API_URL
    delete process.env.WORKER_AUTH_TOKEN
    delete process.env.NODE_ENV
  })

  it('resolves siteId from host map in map mode', async () => {
    process.env.GATEWAY_SITE_RESOLVE_MODE = 'map'
    process.env.GATEWAY_SITE_ID_BY_HOST_MAP = JSON.stringify({
      'gateway.example': 'site-map',
    })
    process.env.AO_PUBLIC_API_URL = 'https://ao.example'

    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ status: 'OK', route: { pageId: 'home' } }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      }),
    )

    const res = await handleRequest(
      buildTemplateCallRequest('gateway.example', {
        action: 'public.resolve-route',
        payload: { path: '/' },
      }),
    )

    expect(res.status).toBe(200)
    expect(fetchSpy).toHaveBeenCalledTimes(1)
    expect(String(fetchSpy.mock.calls[0]?.[0])).toContain('/api/public/resolve-route')

    const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    const body = JSON.parse(String(init.body || '{}'))
    expect(body.siteId).toBe('site-map')
  })

  it('resolves siteId via AO resolver in ao mode', async () => {
    process.env.GATEWAY_SITE_RESOLVE_MODE = 'ao'
    process.env.GATEWAY_SITE_RESOLVE_AO_URL = 'https://resolver.example'
    process.env.AO_PUBLIC_API_URL = 'https://ao.example'

    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = String(input)
      if (url.includes('/api/public/site-by-host')) {
        return new Response(JSON.stringify({ siteId: 'site-ao' }), {
          status: 200,
          headers: { 'content-type': 'application/json' },
        })
      }
      return new Response(JSON.stringify({ status: 'OK', route: { pageId: 'home' } }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      })
    })

    const res = await handleRequest(
      buildTemplateCallRequest('ao-only.example', {
        action: 'public.resolve-route',
        payload: { path: '/' },
      }),
    )

    expect(res.status).toBe(200)
    expect(fetchSpy).toHaveBeenCalledTimes(2)

    const [, templateInit] = fetchSpy.mock.calls[1] as [string, RequestInit]
    const templateBody = JSON.parse(String(templateInit.body || '{}'))
    expect(templateBody.siteId).toBe('site-ao')
  })

  it('propagates resolver metadata from AO-authoritative response to host resolution success', async () => {
    process.env.GATEWAY_SITE_RESOLVE_MODE = 'ao'
    process.env.GATEWAY_SITE_RESOLVE_POLICY_MODE = 'enforce'
    process.env.GATEWAY_SITE_RESOLVE_AO_URL = 'https://resolver.example'

    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        JSON.stringify({
          decision: 'allow',
          reasonCode: 'ALLOW_HOST_BOUND',
          site: { siteId: 'site-metadata', bindingVersion: 42 },
          proof: {
            dnsProofState: 'valid',
            dnsProofCheckedAt: '2026-04-22T09:00:00Z',
            dnsProofValidUntil: '2026-04-22T15:00:00Z',
          },
          policy: {
            mode: 'enforce',
            snapshotId: 'snap-42',
            snapshotSigOk: true,
          },
        }),
        {
          status: 200,
          headers: { 'content-type': 'application/json' },
        },
      ),
    )

    const resolved = await resolveTemplateSiteIdFromHost('meta.example', true)
    expect(resolved.ok).toBe(true)
    if (!resolved.ok) return

    expect(resolved.siteId).toBe('site-metadata')
    expect(resolved.resolverMetadata).toMatchObject({
      source: 'ao',
      decision: 'allow',
      reasonCode: 'ALLOW_HOST_BOUND',
      proof: {
        bindingVersion: 42,
        dnsProofState: 'valid',
        dnsProofCheckedAt: '2026-04-22T09:00:00Z',
        dnsProofValidUntil: '2026-04-22T15:00:00Z',
      },
      policy: {
        mode: 'enforce',
        snapshotId: 'snap-42',
        snapshotSigOk: true,
      },
    })
  })

  it('parses rich AO resolver envelope status/cache/policy metadata', async () => {
    process.env.GATEWAY_SITE_RESOLVE_MODE = 'ao'
    process.env.GATEWAY_SITE_RESOLVE_POLICY_MODE = 'enforce'
    process.env.GATEWAY_SITE_RESOLVE_AO_URL = 'https://resolver.example'

    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        JSON.stringify({
          status: 207,
          decision: 'allow',
          reasonCode: 'ALLOW_CACHE_WARM',
          site: { siteId: 'site-cache-meta' },
          cache: {
            cacheable: true,
            ttlSec: 120,
            staleWhileRevalidateSec: 600,
            negativeTtlSec: 30,
          },
          policy: { mode: 'soft' },
        }),
        {
          status: 200,
          headers: { 'content-type': 'application/json' },
        },
      ),
    )

    const resolved = await resolveTemplateSiteIdFromHost('cache-meta.example', true)
    expect(resolved.ok).toBe(true)
    if (!resolved.ok) return

    expect(resolved.siteId).toBe('site-cache-meta')
    expect(resolved.resolverMetadata).toMatchObject({
      source: 'ao',
      status: 207,
      decision: 'allow',
      reasonCode: 'ALLOW_CACHE_WARM',
      cache: {
        cacheable: true,
        ttlSec: 120,
        staleWhileRevalidateSec: 600,
        negativeTtlSec: 30,
      },
      policy: { mode: 'soft' },
    })
  })

  it('keeps legacy AO resolver shape compatibility without metadata requirement', async () => {
    process.env.GATEWAY_SITE_RESOLVE_MODE = 'ao'
    process.env.GATEWAY_SITE_RESOLVE_AO_URL = 'https://resolver.example'

    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ siteId: 'site-legacy-shape' }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      }),
    )

    const resolved = await resolveTemplateSiteIdFromHost('legacy-shape.example', true)
    expect(resolved.ok).toBe(true)
    if (!resolved.ok) return
    expect(resolved.siteId).toBe('site-legacy-shape')
    expect(resolved.resolverMetadata).toBeUndefined()
  })

  it('does not emit resolver decision logs by default', async () => {
    process.env.GATEWAY_SITE_RESOLVE_MODE = 'ao'
    process.env.GATEWAY_SITE_RESOLVE_POLICY_MODE = 'enforce'
    process.env.GATEWAY_SITE_RESOLVE_AO_URL = 'https://resolver.example'

    const infoSpy = vi.spyOn(console, 'info').mockImplementation(() => {})
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ decision: 'allow', site: { siteId: 'site-no-log' } }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      }),
    )

    const resolved = await resolveTemplateSiteIdFromHost('nolog.example', true)
    expect(resolved.ok).toBe(true)
    expect(infoSpy).not.toHaveBeenCalled()
  })

  it('emits resolver decision logs when policy reason logging is enabled', async () => {
    process.env.GATEWAY_SITE_RESOLVE_MODE = 'ao'
    process.env.GATEWAY_SITE_RESOLVE_POLICY_MODE = 'enforce'
    process.env.GATEWAY_SITE_RESOLVE_POLICY_REASON_LOG = '1'
    process.env.GATEWAY_SITE_RESOLVE_AO_URL = 'https://resolver.example'

    const infoSpy = vi.spyOn(console, 'info').mockImplementation(() => {})
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        JSON.stringify({
          decision: 'allow',
          reasonCode: 'ALLOW_HOST_BOUND',
          site: { siteId: 'site-log' },
          policy: { mode: 'enforce' },
        }),
        {
          status: 200,
          headers: { 'content-type': 'application/json' },
        },
      ),
    )

    const resolved = await resolveTemplateSiteIdFromHost('log.example', true)
    expect(resolved.ok).toBe(true)
    expect(infoSpy).toHaveBeenCalledTimes(1)
    const rawPayload = String(infoSpy.mock.calls[0]?.[0] || '')
    expect(rawPayload).toContain('gateway_site_resolver_decision')
    expect(rawPayload).toContain('ALLOW_HOST_BOUND')
  })

  it('propagates reason metadata on observe-mode fallback success', async () => {
    process.env.GATEWAY_SITE_RESOLVE_MODE = 'ao'
    process.env.GATEWAY_SITE_RESOLVE_POLICY_MODE = 'observe'
    process.env.GATEWAY_SITE_RESOLVE_AO_URL = 'https://resolver.example'

    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        JSON.stringify({
          decision: 'deny',
          reasonCode: 'DENY_HOST_UNBOUND',
          proof: { dnsProofState: 'missing' },
          policy: { mode: 'observe' },
        }),
        {
          status: 200,
          headers: { 'content-type': 'application/json' },
        },
      ),
    )

    const resolved = await resolveTemplateSiteIdFromHost('observe-metadata.example', true)
    expect(resolved.ok).toBe(true)
    if (!resolved.ok) return
    expect(resolved.siteId).toBeUndefined()
    expect(resolved.resolverMetadata).toMatchObject({
      source: 'ao',
      decision: 'deny',
      reasonCode: 'DENY_HOST_UNBOUND',
      proof: { dnsProofState: 'missing' },
      policy: { mode: 'observe' },
    })
  })

  it('parses AO resolver contract fields decision/site/process while preserving write runtime hints', async () => {
    process.env.GATEWAY_SITE_RESOLVE_MODE = 'ao'
    process.env.GATEWAY_SITE_RESOLVE_POLICY_MODE = 'enforce'
    process.env.GATEWAY_SITE_RESOLVE_AO_URL = 'https://resolver.example'
    process.env.WRITE_API_URL = 'https://write.example'
    process.env.GATEWAY_TEMPLATE_ALLOW_MUTATIONS = '1'
    process.env.GATEWAY_TEMPLATE_TOKEN = 'tmpl-secret'
    process.env.WORKER_API_URL = 'https://worker-fallback.example'
    process.env.WORKER_AUTH_TOKEN = 'worker-token'
    process.env.GATEWAY_TEMPLATE_ALLOW_RUNTIME_HINTS = '1'
    process.env.GATEWAY_TEMPLATE_TARGET_HOST_ALLOWLIST = 'write.example,worker-runtime.example'

    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const url = String(input)
      if (url.includes('/api/public/site-by-host')) {
        return new Response(
          JSON.stringify({
            schemaVersion: '1.0',
            decision: 'allow',
            reasonCode: 'ALLOW_HOST_BOUND',
            site: { siteId: 'site-ao-runtime' },
            process: { writeProcessId: 'B'.repeat(43), workerUrl: 'https://worker-runtime.example' },
            cache: { ttlSec: 300 },
            proof: { dnsProofState: 'valid' },
            policy: { mode: 'enforce' },
          }),
          {
            status: 200,
            headers: { 'content-type': 'application/json' },
          },
        )
      }
      if (url === 'https://worker-runtime.example/sign') {
        return new Response(JSON.stringify({ signature: 'deadbeef', signatureRef: 'worker-ed25519' }), {
          status: 200,
          headers: { 'content-type': 'application/json' },
        })
      }
      if (url === 'https://write.example/api/checkout/order') {
        const headers = new Headers(init?.headers)
        expect(headers.get('x-write-process-id')).toBe('B'.repeat(43))
        return new Response('ok', { status: 200 })
      }
      return new Response('unexpected', { status: 404 })
    })

    const res = await handleRequest(
      new Request('https://resolver-v1.example/template/call', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-template-token': 'tmpl-secret',
        },
        body: JSON.stringify({
          action: 'checkout.create-order',
          requestId: 'req-runtime-site-v1',
          role: 'shop_admin',
          payload: { items: [{ sku: 'sku-1', qty: 1 }] },
        }),
      }),
    )

    expect(res.status).toBe(200)
    expect(fetchSpy).toHaveBeenCalledTimes(3)
    expect(String(fetchSpy.mock.calls[1]?.[0])).toBe('https://worker-runtime.example/sign')
    expect(String(fetchSpy.mock.calls[2]?.[0])).toBe('https://write.example/api/checkout/order')
  })

  it('uses hybrid fallback from host map to AO resolver', async () => {
    process.env.GATEWAY_SITE_RESOLVE_MODE = 'hybrid'
    process.env.GATEWAY_SITE_ID_BY_HOST_MAP = JSON.stringify({
      'mapped.example': 'site-map',
    })
    process.env.GATEWAY_SITE_RESOLVE_AO_URL = 'https://resolver.example'
    process.env.AO_PUBLIC_API_URL = 'https://ao.example'

    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = String(input)
      if (url.includes('/api/public/site-by-host')) {
        return new Response(JSON.stringify({ siteId: 'site-ao-fallback' }), {
          status: 200,
          headers: { 'content-type': 'application/json' },
        })
      }
      return new Response(JSON.stringify({ status: 'OK', route: { pageId: 'fallback' } }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      })
    })

    const res = await handleRequest(
      buildTemplateCallRequest('unknown.example', {
        action: 'public.resolve-route',
        payload: { path: '/' },
      }),
    )

    expect(res.status).toBe(200)
    expect(fetchSpy).toHaveBeenCalledTimes(2)

    const [, templateInit] = fetchSpy.mock.calls[1] as [string, RequestInit]
    const templateBody = JSON.parse(String(templateInit.body || '{}'))
    expect(templateBody.siteId).toBe('site-ao-fallback')
  })

  it('keeps legacy behavior by default when resolver returns decision deny', async () => {
    process.env.GATEWAY_SITE_RESOLVE_MODE = 'ao'
    process.env.GATEWAY_SITE_RESOLVE_AO_URL = 'https://resolver.example'
    process.env.AO_PUBLIC_API_URL = 'https://ao.example'
    process.env.NODE_ENV = 'production'
    process.env.GATEWAY_PRODUCTION_LIKE = '1'

    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = String(input)
      if (url.includes('/api/public/site-by-host')) {
        return new Response(JSON.stringify({ decision: 'deny', reasonCode: 'DENY_HOST_UNBOUND' }), {
          status: 200,
          headers: { 'content-type': 'application/json' },
        })
      }
      return new Response('unexpected', { status: 404 })
    })

    const res = await handleRequest(
      buildTemplateCallRequest('legacy-deny.example', {
        action: 'public.resolve-route',
        payload: { path: '/' },
      }),
    )

    expect(res.status).toBe(403)
    await expect(res.json()).resolves.toEqual({ error: 'site_host_not_allowed' })
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it('observe policy mode bypasses resolver deny decisions', async () => {
    process.env.GATEWAY_SITE_RESOLVE_MODE = 'ao'
    process.env.GATEWAY_SITE_RESOLVE_POLICY_MODE = 'observe'
    process.env.GATEWAY_SITE_RESOLVE_AO_URL = 'https://resolver.example'
    process.env.GATEWAY_SITE_RESOLVE_ALLOW_BODY_FALLBACK = '1'
    process.env.AO_PUBLIC_API_URL = 'https://ao.example'

    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = String(input)
      if (url.includes('/api/public/site-by-host')) {
        return new Response(JSON.stringify({ decision: 'deny', reasonCode: 'DENY_HOST_UNBOUND' }), {
          status: 200,
          headers: { 'content-type': 'application/json' },
        })
      }
      return new Response(JSON.stringify({ status: 'OK', route: { pageId: 'observe-ok' } }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      })
    })

    const res = await handleRequest(
      buildTemplateCallRequest('observe-mode.example', {
        action: 'public.resolve-route',
        payload: { siteId: 'site-body', path: '/' },
      }),
    )

    expect(res.status).toBe(200)
    expect(fetchSpy).toHaveBeenCalledTimes(2)
    const [, templateInit] = fetchSpy.mock.calls[1] as [string, RequestInit]
    const templateBody = JSON.parse(String(templateInit.body || '{}'))
    expect(templateBody.siteId).toBe('site-body')
  })

  it('off policy mode bypasses resolver unavailable responses', async () => {
    process.env.GATEWAY_SITE_RESOLVE_MODE = 'ao'
    process.env.GATEWAY_SITE_RESOLVE_POLICY_MODE = 'off'
    process.env.GATEWAY_SITE_RESOLVE_AO_URL = 'https://resolver.example'
    process.env.GATEWAY_SITE_RESOLVE_ALLOW_BODY_FALLBACK = '1'
    process.env.AO_PUBLIC_API_URL = 'https://ao.example'
    process.env.NODE_ENV = 'production'
    process.env.GATEWAY_PRODUCTION_LIKE = '1'

    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = String(input)
      if (url.includes('/api/public/site-by-host')) {
        return new Response(JSON.stringify({ error: 'down' }), {
          status: 503,
          headers: { 'content-type': 'application/json' },
        })
      }
      return new Response(JSON.stringify({ status: 'OK', route: { pageId: 'off-ok' } }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      })
    })

    const res = await handleRequest(
      buildTemplateCallRequest('off-mode.example', {
        action: 'public.resolve-route',
        payload: { siteId: 'site-body', path: '/' },
      }),
    )

    expect(res.status).toBe(200)
    expect(fetchSpy).toHaveBeenCalledTimes(2)
  })

  it('forwards AO runtime hints to write signer and write pid override header', async () => {
    process.env.GATEWAY_SITE_RESOLVE_MODE = 'ao'
    process.env.GATEWAY_SITE_RESOLVE_AO_URL = 'https://resolver.example'
    process.env.WRITE_API_URL = 'https://write.example'
    process.env.GATEWAY_TEMPLATE_ALLOW_MUTATIONS = '1'
    process.env.GATEWAY_TEMPLATE_TOKEN = 'tmpl-secret'
    process.env.WORKER_API_URL = 'https://worker-fallback.example'
    process.env.WORKER_AUTH_TOKEN = 'worker-token'
    process.env.GATEWAY_TEMPLATE_ALLOW_RUNTIME_HINTS = '1'
    process.env.GATEWAY_TEMPLATE_TARGET_HOST_ALLOWLIST = 'write.example,worker-runtime.example'

    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const url = String(input)
      if (url.includes('/api/public/site-by-host')) {
        return new Response(
          JSON.stringify({
            status: 'OK',
            data: {
              siteId: 'site-ao-runtime',
              runtime: { writeProcessId: 'B'.repeat(43), workerUrl: 'https://worker-runtime.example' },
            },
          }),
          {
            status: 200,
            headers: { 'content-type': 'application/json' },
          },
        )
      }
      if (url === 'https://worker-runtime.example/sign') {
        return new Response(JSON.stringify({ signature: 'deadbeef', signatureRef: 'worker-ed25519' }), {
          status: 200,
          headers: { 'content-type': 'application/json' },
        })
      }
      if (url === 'https://write.example/api/checkout/order') {
        const headers = new Headers(init?.headers)
        expect(headers.get('x-write-process-id')).toBe('B'.repeat(43))
        return new Response('ok', { status: 200 })
      }
      return new Response('unexpected', { status: 404 })
    })

    const res = await handleRequest(
      new Request('https://runtime-write.example/template/call', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-template-token': 'tmpl-secret',
        },
        body: JSON.stringify({
          action: 'checkout.create-order',
          requestId: 'req-runtime-site-1',
          role: 'shop_admin',
          payload: { items: [{ sku: 'sku-1', qty: 1 }] },
        }),
      }),
    )

    expect(res.status).toBe(200)
    expect(fetchSpy).toHaveBeenCalledTimes(3)
    expect(String(fetchSpy.mock.calls[1]?.[0])).toBe('https://worker-runtime.example/sign')
    expect(String(fetchSpy.mock.calls[2]?.[0])).toBe('https://write.example/api/checkout/order')
  })

  it('requires allowlist for AO-trusted runtime write PID overrides', async () => {
    process.env.GATEWAY_SITE_RESOLVE_MODE = 'ao'
    process.env.GATEWAY_SITE_RESOLVE_AO_URL = 'https://resolver.example'
    process.env.WRITE_API_URL = 'https://write.example'
    process.env.GATEWAY_TEMPLATE_ALLOW_MUTATIONS = '1'
    process.env.GATEWAY_TEMPLATE_TOKEN = 'tmpl-secret'
    process.env.WORKER_API_URL = 'https://worker-fallback.example'
    process.env.WORKER_AUTH_TOKEN = 'worker-token'

    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = String(input)
      if (url.includes('/api/public/site-by-host')) {
        return new Response(
          JSON.stringify({
            status: 'OK',
            data: {
              siteId: 'site-ao-runtime',
              runtime: { writeProcessId: 'B'.repeat(43), workerUrl: 'https://worker-runtime.example' },
            },
          }),
          {
            status: 200,
            headers: { 'content-type': 'application/json' },
          },
        )
      }
      return new Response('unexpected', { status: 404 })
    })

    const res = await handleRequest(
      new Request('https://runtime-write.example/template/call', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-template-token': 'tmpl-secret',
        },
        body: JSON.stringify({
          action: 'checkout.create-order',
          requestId: 'req-runtime-site-2',
          role: 'shop_admin',
          payload: { items: [{ sku: 'sku-1', qty: 1 }] },
        }),
      }),
    )

    expect(res.status).toBe(503)
    await expect(res.json()).resolves.toMatchObject({
      error: 'template_target_allowlist_required_for_runtime_overrides',
    })
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it('requires allowlist when runtime overrides are enabled', async () => {
    process.env.GATEWAY_SITE_RESOLVE_MODE = 'ao'
    process.env.GATEWAY_SITE_RESOLVE_AO_URL = 'https://resolver.example'
    process.env.WRITE_API_URL = 'https://write.example'
    process.env.GATEWAY_TEMPLATE_ALLOW_MUTATIONS = '1'
    process.env.GATEWAY_TEMPLATE_TOKEN = 'tmpl-secret'
    process.env.WORKER_API_URL = 'https://worker-fallback.example'
    process.env.WORKER_AUTH_TOKEN = 'worker-token'
    process.env.GATEWAY_TEMPLATE_ALLOW_RUNTIME_HINTS = '1'

    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = String(input)
      if (url.includes('/api/public/site-by-host')) {
        return new Response(
          JSON.stringify({
            status: 'OK',
            data: {
              siteId: 'site-ao-runtime',
              runtime: { writeProcessId: 'B'.repeat(43), workerUrl: 'https://worker-runtime.example' },
            },
          }),
          {
            status: 200,
            headers: { 'content-type': 'application/json' },
          },
        )
      }
      return new Response('unexpected', { status: 404 })
    })

    const res = await handleRequest(
      new Request('https://runtime-write.example/template/call', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-template-token': 'tmpl-secret',
        },
        body: JSON.stringify({
          action: 'checkout.create-order',
          requestId: 'req-runtime-site-3',
          role: 'shop_admin',
          payload: { items: [{ sku: 'sku-1', qty: 1 }] },
        }),
      }),
    )

    expect(res.status).toBe(503)
    await expect(res.json()).resolves.toMatchObject({
      error: 'template_target_allowlist_required_for_runtime_overrides',
    })
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it('fails closed in production-like mode when no resolver source is configured', async () => {
    process.env.GATEWAY_SITE_RESOLVE_MODE = 'ao'
    process.env.NODE_ENV = 'production'
    process.env.GATEWAY_PRODUCTION_LIKE = '1'
    process.env.AO_PUBLIC_API_URL = 'https://ao.example'

    const fetchSpy = vi.spyOn(globalThis, 'fetch')

    const res = await handleRequest(
      buildTemplateCallRequest('blocked.example', {
        action: 'public.resolve-route',
        siteId: 'site-body',
        payload: { siteId: 'site-body', path: '/' },
      }),
    )

    expect(res.status).toBe(503)
    await expect(res.json()).resolves.toEqual({ error: 'site_resolver_not_configured' })
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it('allows explicit body fallback when enabled', async () => {
    process.env.GATEWAY_SITE_RESOLVE_MODE = 'ao'
    process.env.NODE_ENV = 'production'
    process.env.GATEWAY_SITE_RESOLVE_ALLOW_BODY_FALLBACK = '1'
    process.env.GATEWAY_SITE_RESOLVE_AO_URL = 'https://resolver.example'
    process.env.AO_PUBLIC_API_URL = 'https://ao.example'

    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = String(input)
      if (url.includes('/api/public/site-by-host')) {
        return new Response(JSON.stringify({ error: 'resolver_down' }), {
          status: 503,
          headers: { 'content-type': 'application/json' },
        })
      }
      return new Response(JSON.stringify({ status: 'OK', route: { pageId: 'home' } }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      })
    })

    const res = await handleRequest(
      buildTemplateCallRequest('fallback.example', {
        action: 'public.resolve-route',
        siteId: 'site-body',
        payload: { siteId: 'site-body', path: '/' },
      }),
    )

    expect(res.status).toBe(200)
    expect(fetchSpy).toHaveBeenCalledTimes(2)
    const [, templateInit] = fetchSpy.mock.calls[1] as [string, RequestInit]
    const templateBody = JSON.parse(String(templateInit.body || '{}'))
    expect(templateBody.siteId).toBe('site-body')
  })

  it('caches resolver unavailable responses briefly to avoid retry storms', async () => {
    process.env.GATEWAY_SITE_RESOLVE_MODE = 'ao'
    process.env.GATEWAY_SITE_RESOLVE_AO_URL = 'https://resolver.example'
    process.env.AO_PUBLIC_API_URL = 'https://ao.example'
    process.env.NODE_ENV = 'production'
    process.env.GATEWAY_PRODUCTION_LIKE = '1'
    process.env.GATEWAY_SITE_RESOLVE_UNAVAILABLE_CACHE_TTL_MS = '10000'

    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = String(input)
      if (url.includes('/api/public/site-by-host')) {
        return new Response(JSON.stringify({ error: 'down' }), {
          status: 503,
          headers: { 'content-type': 'application/json' },
        })
      }
      return new Response('unexpected', { status: 404 })
    })

    const res1 = await handleRequest(
      buildTemplateCallRequest('cache-unavail.example', {
        action: 'public.resolve-route',
        payload: { path: '/' },
      }),
    )
    const res2 = await handleRequest(
      buildTemplateCallRequest('cache-unavail.example', {
        action: 'public.resolve-route',
        payload: { path: '/' },
      }),
    )

    expect(res1.status).toBe(503)
    await expect(res1.json()).resolves.toMatchObject({ error: 'site_resolver_unavailable' })
    expect(res2.status).toBe(503)
    await expect(res2.json()).resolves.toMatchObject({ error: 'site_resolver_unavailable' })
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it('uses global unavailable cache across hosts when enabled', async () => {
    process.env.GATEWAY_SITE_RESOLVE_MODE = 'ao'
    process.env.GATEWAY_SITE_RESOLVE_AO_URL = 'https://resolver.example'
    process.env.AO_PUBLIC_API_URL = 'https://ao.example'
    process.env.NODE_ENV = 'production'
    process.env.GATEWAY_PRODUCTION_LIKE = '1'
    process.env.GATEWAY_SITE_RESOLVE_UNAVAILABLE_CACHE_TTL_MS = '1'
    process.env.GATEWAY_SITE_RESOLVE_GLOBAL_UNAVAILABLE_CACHE_TTL_MS = '10000'

    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = String(input)
      if (url.includes('/api/public/site-by-host')) {
        return new Response(JSON.stringify({ error: 'down' }), {
          status: 503,
          headers: { 'content-type': 'application/json' },
        })
      }
      return new Response('unexpected', { status: 404 })
    })

    const res1 = await handleRequest(
      buildTemplateCallRequest('cache-global-a.example', {
        action: 'public.resolve-route',
        payload: { path: '/' },
      }),
    )
    const res2 = await handleRequest(
      buildTemplateCallRequest('cache-global-b.example', {
        action: 'public.resolve-route',
        payload: { path: '/' },
      }),
    )

    expect(res1.status).toBe(503)
    await expect(res1.json()).resolves.toMatchObject({ error: 'site_resolver_unavailable' })
    expect(res2.status).toBe(503)
    await expect(res2.json()).resolves.toMatchObject({ error: 'site_resolver_unavailable' })
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it('opens resolver circuit breaker after repeated AO failures', async () => {
    process.env.GATEWAY_SITE_RESOLVE_MODE = 'ao'
    process.env.GATEWAY_SITE_RESOLVE_AO_URL = 'https://resolver.example'
    process.env.AO_PUBLIC_API_URL = 'https://ao.example'
    process.env.NODE_ENV = 'production'
    process.env.GATEWAY_PRODUCTION_LIKE = '1'
    process.env.GATEWAY_SITE_RESOLVE_BREAKER_THRESHOLD = '2'
    process.env.GATEWAY_SITE_RESOLVE_BREAKER_WINDOW_MS = '60000'
    process.env.GATEWAY_SITE_RESOLVE_BREAKER_OPEN_MS = '60000'
    process.env.GATEWAY_SITE_RESOLVE_UNAVAILABLE_CACHE_TTL_MS = '1'

    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = String(input)
      if (url.includes('/api/public/site-by-host')) {
        return new Response(JSON.stringify({ error: 'down' }), {
          status: 503,
          headers: { 'content-type': 'application/json' },
        })
      }
      return new Response('unexpected', { status: 404 })
    })

    const res1 = await handleRequest(
      buildTemplateCallRequest('breaker-1.example', {
        action: 'public.resolve-route',
        payload: { path: '/' },
      }),
    )
    const res2 = await handleRequest(
      buildTemplateCallRequest('breaker-2.example', {
        action: 'public.resolve-route',
        payload: { path: '/' },
      }),
    )
    const res3 = await handleRequest(
      buildTemplateCallRequest('breaker-3.example', {
        action: 'public.resolve-route',
        payload: { path: '/' },
      }),
    )

    expect(res1.status).toBe(503)
    expect(res2.status).toBe(503)
    expect(res3.status).toBe(503)
    await expect(res3.json()).resolves.toMatchObject({ error: 'site_resolver_circuit_open' })
    expect(fetchSpy).toHaveBeenCalledTimes(2)
  })
})
