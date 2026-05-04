#!/usr/bin/env node
import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const REPO_ROOT = path.resolve(__dirname, '../../..')
const WORKSPACE_ROOT = path.resolve(REPO_ROOT, '..')

const DEFAULT_BASE_URL = 'https://write.darkmesh.fun'
const DEFAULT_ACTIONS = ['GetResolverState', 'ResolveHostForNode', 'ResolveRouteForHost']

function usage() {
  console.log(`Usage:
  node ops/live-vps/local-tools/probe-resolver-execution.mjs --pid <resolver-pid> --wallet <wallet.json> [options]

Resolver-specific AO execution probe for fresh lab PIDs.

What it does:
  1. sends resolver actions through the scheduler
  2. reads slot/current
  3. fetches compute replay for assigned slots
  4. evaluates runtime effect without requiring non-empty Output

Options:
  --pid <id>                    Resolver process ID. Required.
  --wallet <path>               Arweave JWK wallet. Required.
  --base-url <url>              Base write/HB URL. Default: ${DEFAULT_BASE_URL}
  --actions <csv>               Default: ${DEFAULT_ACTIONS.join(',')}
  --host <domain>               Host for resolve probes. Default: jdwt.fun
  --path <path>                 Path for route probe. Default: /
  --method <verb>               Method for route probe. Default: GET
  --timeout-ms <ms>             Default: 30000
  --output-dir <path>           Output directory. Default: mktemp dir
  --reply-to <target>           Optional explicit Reply-To target for resolver reply messages.
  --strict-semantic-output <0|1>
                                 Fail when Output stays empty. Default: 0
  -h, --help                    Show help.
`)
}

function clean(value) {
  if (value === undefined || value === null) return undefined
  const out = String(value).trim()
  return out === '' ? undefined : out
}

function parseBool(value, fallback = false) {
  const normalized = clean(value)
  if (normalized === undefined) return fallback
  const lower = normalized.toLowerCase()
  if (['1', 'true', 'yes', 'on'].includes(lower)) return true
  if (['0', 'false', 'no', 'off'].includes(lower)) return false
  return fallback
}

function must(value, name) {
  if (!clean(value)) throw new Error(`Missing --${name}`)
  return clean(value)
}

function argValue(name, fallback) {
  const idx = process.argv.indexOf(`--${name}`)
  if (idx === -1) return fallback
  return process.argv[idx + 1] ?? fallback
}

function hasArg(name) {
  return process.argv.includes(`--${name}`)
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

async function fetchWithTimeout(url, init = {}, timeoutMs = 30000) {
  const ctl = new AbortController()
  const timer = setTimeout(() => ctl.abort(), timeoutMs)
  try {
    return await fetch(url, { ...init, signal: ctl.signal })
  } finally {
    clearTimeout(timer)
  }
}

function isMeaningfulValue(value) {
  if (value === undefined || value === null) return false
  if (typeof value === 'string') return value.trim().length > 0
  if (Array.isArray(value)) return value.length > 0
  if (typeof value === 'object') return Object.keys(value).length > 0
  return true
}

function probeSignals(parsed) {
  const signals = []
  if (isMeaningfulValue(parsed?.output)) signals.push('output')
  if (Number(parsed?.messagesCount || 0) > 0) signals.push('messages')
  if (Number(parsed?.spawnsCount || 0) > 0) signals.push('spawns')
  if (Number(parsed?.assignmentsCount || 0) > 0) signals.push('assignments')
  return signals
}

function hasNumericAtSlot(value) {
  if (typeof value === 'number') return Number.isFinite(value)
  if (typeof value === 'string') return value.trim() !== '' && Number.isFinite(Number(value))
  return false
}

function assessRuntimeEffect(probe) {
  if (!probe) {
    return { ok: false, reason: 'missing_compute_probe', signals: [], evidence: null }
  }
  if (!probe.ok || probe.status !== 200) {
    return {
      ok: false,
      reason: 'compute_not_ok',
      signals: [],
      evidence: { status: probe.status, ok: probe.ok, bodyPreview: probe.bodyPreview || '' },
    }
  }
  const parsed = probe.parsed || {}
  const signals = probeSignals(parsed)
  const hasResults = parsed.hasResults === true || hasNumericAtSlot(parsed.atSlot)
  const hasError = parsed.hasError === true
  const ok = !hasError && (signals.length > 0 || hasResults)
  let reason = null
  if (hasError) reason = 'runtime_error'
  else if (!ok) reason = 'empty_runtime_payload'
  else reason = signals.length > 0 ? 'signal' : 'runtime_effect_observed'

  return {
    ok,
    reason,
    signals,
    evidence: {
      status: probe.status,
      ok: probe.ok,
      atSlot: parsed.atSlot ?? null,
      hasResults,
      output: parsed.output ?? null,
      messagesCount: parsed.messagesCount ?? null,
      spawnsCount: parsed.spawnsCount ?? null,
      assignmentsCount: parsed.assignmentsCount ?? null,
      hasError,
    },
  }
}

function isShellPromptOutput(value) {
  if (!value || typeof value !== 'object') return false
  const prompt = clean(value.prompt)
  const data = clean(value.data)
  if (!prompt) return false
  if (clean(value['ao-types'])) return true
  return typeof data === 'string' && data.includes('New Message From')
}

function parseJsonEnvelopeCandidate(candidate) {
  if (typeof candidate === 'string' && candidate.trim()) {
    try {
      const parsed = JSON.parse(candidate)
      if (parsed && typeof parsed === 'object') return parsed
    } catch {
      return null
    }
  }
  if (candidate && typeof candidate === 'object') return candidate
  return null
}

function extractEnvelopeFromMessages(raw) {
  const messages = Array.isArray(raw?.Messages) ? raw.Messages : []
  const envelopes = []
  for (const message of messages) {
    if (!message || typeof message !== 'object') continue
    const action =
      typeof message.Action === 'string'
        ? message.Action
        : typeof message.action === 'string'
          ? message.action
          : null
    const envelope =
      parseJsonEnvelopeCandidate(message.Data) ||
      parseJsonEnvelopeCandidate(message.data) ||
      parseJsonEnvelopeCandidate(message.Output) ||
      parseJsonEnvelopeCandidate(message.output)
    if (!envelope || typeof envelope !== 'object') continue
    envelopes.push({ action, envelope })
  }
  return envelopes
}

function pickPreferredMessageEnvelope(envelopes) {
  if (!Array.isArray(envelopes) || envelopes.length === 0) return null
  return (
    envelopes.find((entry) => entry.action === 'Resolver-Command-Result') ||
    envelopes[0] ||
    null
  )
}

function deriveOutputSummary(computeParsed) {
  const raw = computeParsed?.results?.raw || computeParsed?.raw || null
  const outputCandidate =
    raw?.Output ?? raw?.output ?? raw?.Data ?? raw?.data ?? computeParsed?.Output ?? computeParsed?.output ?? null

  let envelope = null
  let outputShape = 'empty'
  if (typeof outputCandidate === 'string') {
    outputShape = 'string'
    if (outputCandidate.trim()) {
      envelope = parseJsonEnvelopeCandidate(outputCandidate)
      if (envelope) outputShape = 'json_string'
    }
  } else if (outputCandidate && typeof outputCandidate === 'object') {
    envelope = outputCandidate
    outputShape = 'object'
  }

  const messageEnvelopes = raw ? extractEnvelopeFromMessages(raw) : []
  const preferredMessageEnvelope = pickPreferredMessageEnvelope(messageEnvelopes)
  if (!envelope && preferredMessageEnvelope) {
    envelope = preferredMessageEnvelope.envelope
    outputShape = 'message_json'
  }

  const shellOutput = isShellPromptOutput(envelope)
  const status = envelope && typeof envelope === 'object' ? clean(envelope.status) : undefined
  const code = envelope && typeof envelope === 'object' ? clean(envelope.code) : undefined
  const semanticOk = Boolean(status)

  return {
    outputShape,
    shellOutput,
    status: status || null,
    code: code || null,
    semanticOk,
    messageEnvelopeCount: messageEnvelopes.length,
    messageEnvelopeActions: messageEnvelopes.map((entry) => entry.action).filter(Boolean),
    preferredMessageEnvelopeAction: preferredMessageEnvelope?.action || null,
    outputPreview:
      outputShape === 'string'
        ? String(outputCandidate || '').slice(0, 180)
        : JSON.stringify(envelope || {}).slice(0, 180),
  }
}

async function loadArbundles() {
  const require = createRequire(import.meta.url)
  const candidates = [
    'arbundles',
    path.resolve(WORKSPACE_ROOT, 'blackcat-darkmesh-ao/node_modules/arbundles'),
    path.resolve(WORKSPACE_ROOT, 'blackcat-darkmesh-write/node_modules/arbundles'),
    path.resolve(WORKSPACE_ROOT, 'blackcat-darkmesh-gateway/workers/secrets-worker/node_modules/arbundles'),
  ]
  let lastError = null
  for (const candidate of candidates) {
    try {
      return require(candidate)
    } catch (error) {
      lastError = error
    }
  }
  throw lastError || new Error('unable_to_load_arbundles')
}

async function probeSlotCurrent(baseUrl, pid, timeoutMs) {
  const url = `${baseUrl}/${pid}~process@1.0/slot/current?accept-bundle=true`
  const res = await fetchWithTimeout(url, { method: 'GET' }, timeoutMs)
  const text = await res.text().catch(() => '')
  return { url, status: res.status, ok: res.ok, body: text.trim() }
}

async function probeCompute(baseUrl, pid, slot, timeoutMs) {
  const url = `${baseUrl}/${pid}~process@1.0/compute=${slot}?accept-bundle=true&require-codec=application/json`
  let res = null
  let text = ''
  let lastError = null
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    try {
      res = await fetchWithTimeout(url, { method: 'GET' }, timeoutMs)
      text = await res.text().catch(() => '')
      break
    } catch (error) {
      lastError = error
      if (attempt < 3) await sleep(3000)
    }
  }
  if (!res) {
    return { url, status: 'error', ok: false, error: lastError?.message || String(lastError) }
  }

  let parsed = null
  try {
    parsed = JSON.parse(text)
  } catch {
    parsed = null
  }

  const raw = parsed?.results?.raw || parsed?.raw || null
  const rawError = raw?.Error
  const hasError = (() => {
    if (rawError === null || rawError === undefined) return false
    if (typeof rawError === 'string') return rawError.trim().length > 0
    if (Array.isArray(rawError)) return rawError.length > 0
    if (typeof rawError === 'object') return Object.keys(rawError).length > 0
    return true
  })()

  const outputSummary = parsed ? deriveOutputSummary(parsed) : null
  const parsedSummary = parsed
    ? {
        atSlot: parsed['at-slot'] ?? null,
        status: parsed.status ?? null,
        hasResults: Boolean(parsed.results || parsed.raw),
        output: raw?.Output ?? null,
        messagesCount: Array.isArray(raw?.Messages) ? raw.Messages.length : null,
        spawnsCount: Array.isArray(raw?.Spawns) ? raw.Spawns.length : null,
        assignmentsCount: Array.isArray(raw?.Assignments) ? raw.Assignments.length : null,
        hasError,
      }
    : null

  return {
    url,
    status: res.status,
    ok: res.ok,
    bodyPreview: text.slice(0, 240),
    parsed: parsedSummary,
    outputSummary,
  }
}

function buildActionQuery(payload) {
  const params = new URLSearchParams()
  for (const [key, value] of Object.entries(payload || {})) {
    if (key === 'Action' || value === undefined || value === null) continue
    params.set(key, String(value))
  }
  return params.toString()
}

async function probeDirectHttp(baseUrl, pid, action, payload, timeoutMs) {
  const base = baseUrl.replace(/\/$/, '')
  const query = buildActionQuery(payload)
  const nowUrl = `${base}/${pid}~process@1.0/now?Action=${encodeURIComponent(action)}${query ? `&${query}` : ''}&accept-bundle=true`
  const actionUrl = `${base}/${pid}~process@1.0/${encodeURIComponent(action)}${query ? `?${query}&accept-bundle=true` : '?accept-bundle=true'}`

  async function fetchPreview(url) {
    const res = await fetchWithTimeout(url, { method: 'GET' }, timeoutMs)
    const text = await res.text().catch(() => '')
    return {
      url,
      status: res.status,
      ok: res.ok,
      bodyPreview: text.slice(0, 240),
    }
  }

  const now = await fetchPreview(nowUrl)
  const actionPath = await fetchPreview(actionUrl)
  return { now, actionPath }
}

function buildPayload(action, options, idx) {
  const requestId = `resolver-probe-${Date.now()}-${idx}`
  const ts = Math.floor(Date.now() / 1000).toString()
  const nonce = `nonce-${Math.random().toString(36).slice(2, 10)}`
  const payload = {
    Action: action,
    'Request-Id': requestId,
    Nonce: nonce,
    ts,
    Signature: '00',
  }
  if (action === 'ResolveHostForNode') {
    payload.Host = options.host
  } else if (action === 'ResolveRouteForHost') {
    payload.Host = options.host
    payload.Path = options.path
    payload.Method = options.method
  }
  return payload
}

async function sendSchedulerMessage({ baseUrl, pid, jwk, payload, variant, timeoutMs, replyTo }) {
  const { createData, ArweaveSigner } = await loadArbundles()
  const signer = new ArweaveSigner(jwk)
  const body = JSON.stringify(payload)
  const tags = [
    { name: 'Action', value: payload.Action },
    { name: 'Request-Id', value: payload['Request-Id'] },
    { name: 'Nonce', value: payload.Nonce },
    { name: 'ts', value: payload.ts },
    { name: 'Signature', value: payload.Signature },
    { name: 'Content-Type', value: 'application/json' },
    { name: 'Input-Encoding', value: 'JSON-1' },
    { name: 'Output-Encoding', value: 'JSON-1' },
    { name: 'Data-Protocol', value: 'ao' },
    { name: 'Type', value: 'Message' },
    { name: 'Variant', value: variant },
    { name: 'accept-bundle', value: 'true' },
    { name: 'require-codec', value: 'application/json' },
  ]
  if (replyTo) {
    tags.push({ name: 'Reply-To', value: replyTo })
  }
  const item = createData(body, signer, { target: pid, tags })
  await item.sign(signer)

  const endpoint = `${baseUrl}/~scheduler@1.0/schedule?target=${pid}`
  const sendRes = await fetchWithTimeout(
    endpoint,
    {
      method: 'POST',
      headers: {
        'content-type': 'application/ans104',
        'codec-device': 'ans104@1.0',
      },
      body: item.getRaw(),
    },
    timeoutMs,
  )
  const text = await sendRes.text().catch(() => '')
  const slot = Number(sendRes.headers.get('slot') || '')
  return {
    ok: sendRes.ok,
    status: sendRes.status,
    endpoint,
    dataItemId: item.id,
    slot: Number.isFinite(slot) ? slot : null,
    responsePreview: text.slice(0, 240),
  }
}

function summarize(results, requireSemanticOutput) {
  const total = results.length
  const transportOk = results.filter((row) => row.send.ok === true).length
  const runtimeOk = results.filter((row) => row.runtimeEffect.ok === true).length
  const semanticOk = results.filter((row) => row.compute.outputSummary?.semanticOk === true).length
  const passed = results.filter((row) => row.passed === true).length
  const failed = total - passed
  return {
    total,
    passed,
    failed,
    transportOk,
    runtimeOk,
    semanticOk,
    requireSemanticOutput,
  }
}

async function main() {
  if (hasArg('help') || hasArg('h')) {
    usage()
    process.exit(0)
  }

  const pid = must(argValue('pid'), 'pid')
  const walletPath = must(argValue('wallet'), 'wallet')
  const baseUrl = clean(argValue('base-url', DEFAULT_BASE_URL)).replace(/\/$/, '')
  const host = clean(argValue('host', 'jdwt.fun'))
  const pathValue = argValue('path', '/')
  const method = String(argValue('method', 'GET') || 'GET').toUpperCase()
  const timeoutMs = Number.parseInt(argValue('timeout-ms', '30000'), 10)
  const variant = argValue('variant', 'ao.TN.1')
  const replyTo = clean(argValue('reply-to'))
  const strictSemanticOutput = parseBool(argValue('strict-semantic-output', '0'), false)
  const actions = String(argValue('actions', DEFAULT_ACTIONS.join(',')))
    .split(',')
    .map((value) => value.trim())
    .filter(Boolean)

  if (!Number.isFinite(timeoutMs) || timeoutMs < 1000) throw new Error('invalid --timeout-ms')
  if (!fs.existsSync(walletPath)) throw new Error(`wallet not found: ${walletPath}`)

  const outputDir = clean(argValue('output-dir')) || fs.mkdtempSync(path.join(process.cwd(), 'tmp-resolver-exec-probe-'))
  fs.mkdirSync(outputDir, { recursive: true })
  const reportFile = path.join(outputDir, 'resolver-execution-probe-report.json')

  const jwk = JSON.parse(fs.readFileSync(walletPath, 'utf8'))
  const results = []

  for (const [idx, action] of actions.entries()) {
    const payload = buildPayload(action, { host, path: pathValue, method }, idx + 1)
    if (replyTo) payload['Reply-To'] = replyTo
    const send = await sendSchedulerMessage({ baseUrl, pid, jwk, payload, variant, timeoutMs, replyTo })
    const slotCurrent = await probeSlotCurrent(baseUrl, pid, timeoutMs)
    let compute = null
    if (send.slot !== null) {
      compute = await probeCompute(baseUrl, pid, send.slot, timeoutMs)
    } else {
      compute = { status: 'na', ok: false, bodyPreview: 'missing_slot' }
    }
    const directHttp = await probeDirectHttp(baseUrl, pid, action, payload, timeoutMs)
    const runtimeEffect = assessRuntimeEffect(compute)
    const semanticOk = compute.outputSummary?.semanticOk === true
    const passed = send.ok === true && runtimeEffect.ok === true && (!strictSemanticOutput || semanticOk)
    results.push({
      action,
      payload,
      send,
      slotCurrent,
      compute,
      directHttp,
      runtimeEffect,
      passed,
      failureReason: passed ? null : (!send.ok ? 'transport_failed' : (!runtimeEffect.ok ? runtimeEffect.reason : 'semantic_output_required')),
    })
  }

  const report = {
    generatedAt: new Date().toISOString(),
    pid,
    baseUrl,
    replyTo: replyTo || null,
    host,
    path: pathValue,
    method,
    strictSemanticOutput,
    results,
    summary: summarize(results, strictSemanticOutput),
  }

  fs.writeFileSync(reportFile, JSON.stringify(report, null, 2))
  console.log(JSON.stringify(report, null, 2))
  if (report.summary.failed > 0) process.exit(1)
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
