#!/usr/bin/env node

import fs from 'node:fs/promises'
import crypto from 'node:crypto'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'

const DEFAULT_HB_URL = 'https://write.darkmesh.fun'
const DEFAULT_SCHEDULER = '_wCF37G9t-xfJuYZqc6JXI9VrG4dzM5WUFgDfOn9LdM'
const DEFAULT_MODE = 'mainnet'
const DEFAULT_ACTIONS = [
  'GetAdmissionState',
  'ListHostsDueForDnsRefresh',
  'GetDnsRefreshState',
]
const PROTECTED_ACTIONS = new Set(['GetAdmissionState', 'ListHostsDueForDnsRefresh'])

function usage() {
  console.log(`Usage:
  fetch-ao-control-state-via-aoconnect.mjs --process <pid> [options]

Read-only AO helper that tries to fetch canonical resolver handler payloads via
\`@permaweb/aoconnect\`.

Outputs:
  - admission-state.json             (if resolved)
  - due-hosts-state.json             (if resolved)
  - dns-refresh-state.json           (if resolved)
  - ao-control-state-aoconnect-report.json

Options:
  --process <pid>                    Resolver process ID (required).
  --hb-url <url>                     AO/HB URL. Default: ${DEFAULT_HB_URL}
  --mode <name>                      AO mode. Default: ${DEFAULT_MODE}
  --scheduler <id>                   Scheduler ID. Default: ${DEFAULT_SCHEDULER}
  --wallet-jwk-file <path>           Optional Arweave JWK for signed message/result fallback.
  --actor-role <role>                Optional role for protected resolver actions.
  --auth-signature-type <type>       Optional app-level auth signature type: hmac|ed25519
  --auth-signature-secret-file <p>   Optional HMAC secret file for protected action signing.
  --auth-ed25519-private-key-file <p>
                                     Optional PEM private key for protected action signing.
  --auth-nonce <value>               Optional nonce prefix for protected action signing.
  --auth-timestamp <epoch>           Optional fixed UNIX timestamp for protected action signing.
  --scheduler-direct-base-url <url>  Optional direct scheduler ingress base URL.
                                     Default: same as --hb-url
  --compute-base-url <url>           Optional compute replay base URL.
                                     Default: same as --hb-url
  --actions <csv>                    Default: ${DEFAULT_ACTIONS.join(',')}
  --reply-to <target>                Optional explicit Reply-To target for resolver reply messages.
  --output-dir <path>                Output directory. Default: mktemp
  --timeout-ms <ms>                  Default: 20000
  -h, --help                         Show help.

Env fallbacks:
  AO_WALLET_JSON                     Optional inline JWK JSON.
  AO_ACTOR_ROLE
  AO_AUTH_SIGNATURE_TYPE
  AO_AUTH_SIGNATURE_SECRET
  AO_AUTH_SIGNATURE_SECRET_FILE
  AO_AUTH_ED25519_PRIVATE_KEY_FILE
  AO_AUTH_NONCE
  AO_AUTH_TIMESTAMP
`)
}

function parseArgs(argv) {
  const args = {
    processId: '',
    hbUrl: DEFAULT_HB_URL,
    mode: DEFAULT_MODE,
    scheduler: DEFAULT_SCHEDULER,
    walletJwkFile: '',
    actorRole: '',
    authSignatureType: '',
    authSignatureSecret: '',
    authSignatureSecretFile: '',
    authEd25519PrivateKeyFile: '',
    authNonce: '',
    authTimestamp: '',
    schedulerDirectBaseUrl: '',
    computeBaseUrl: '',
    actions: [...DEFAULT_ACTIONS],
    replyTo: '',
    outputDir: '',
    timeoutMs: 20000,
  }

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]
    switch (arg) {
      case '--process':
        args.processId = argv[++i] || ''
        break
      case '--hb-url':
        args.hbUrl = argv[++i] || ''
        break
      case '--mode':
        args.mode = argv[++i] || ''
        break
      case '--scheduler':
        args.scheduler = argv[++i] || ''
        break
      case '--wallet-jwk-file':
        args.walletJwkFile = argv[++i] || ''
        break
      case '--actor-role':
        args.actorRole = argv[++i] || ''
        break
      case '--auth-signature-type':
        args.authSignatureType = argv[++i] || ''
        break
      case '--auth-signature-secret':
        args.authSignatureSecret = argv[++i] || ''
        break
      case '--auth-signature-secret-file':
        args.authSignatureSecretFile = argv[++i] || ''
        break
      case '--auth-ed25519-private-key-file':
        args.authEd25519PrivateKeyFile = argv[++i] || ''
        break
      case '--auth-nonce':
        args.authNonce = argv[++i] || ''
        break
      case '--auth-timestamp':
        args.authTimestamp = argv[++i] || ''
        break
      case '--scheduler-direct-base-url':
        args.schedulerDirectBaseUrl = argv[++i] || ''
        break
      case '--compute-base-url':
        args.computeBaseUrl = argv[++i] || ''
        break
      case '--actions':
        args.actions = String(argv[++i] || '')
          .split(',')
          .map((value) => value.trim())
          .filter(Boolean)
        break
      case '--reply-to':
        args.replyTo = argv[++i] || ''
        break
      case '--output-dir':
        args.outputDir = argv[++i] || ''
        break
      case '--timeout-ms':
        args.timeoutMs = Number.parseInt(argv[++i] || '', 10)
        break
      case '-h':
      case '--help':
        usage()
        process.exit(0)
      default:
        throw new Error(`Unknown option: ${arg}`)
    }
  }

  if (!args.processId) throw new Error('--process required')
  if (!/^[A-Za-z0-9_-]{43}$/.test(args.processId)) throw new Error('invalid --process pid format')
  if (!args.hbUrl) throw new Error('--hb-url required')
  if (!args.mode) throw new Error('--mode required')
  if (!args.scheduler) throw new Error('--scheduler required')
  if (!Number.isFinite(args.timeoutMs) || args.timeoutMs < 1000) throw new Error('invalid --timeout-ms')
  if (!args.actions.length) throw new Error('at least one action required')
  if (
    args.authSignatureType &&
    args.authSignatureType !== 'hmac' &&
    args.authSignatureType !== 'ed25519'
  ) {
    throw new Error('invalid --auth-signature-type (expected hmac|ed25519)')
  }
  if (args.authTimestamp !== '' && !Number.isFinite(Number(args.authTimestamp))) {
    throw new Error('invalid --auth-timestamp')
  }
  if (!args.schedulerDirectBaseUrl) args.schedulerDirectBaseUrl = args.hbUrl
  if (!args.computeBaseUrl) args.computeBaseUrl = args.hbUrl

  return args
}

async function fileExists(targetPath) {
  try {
    await fs.access(targetPath)
    return true
  } catch {
    return false
  }
}

async function loadAoConnect() {
  const candidates = [
    '@permaweb/aoconnect',
    pathToFileURL(
      path.resolve(
        process.cwd(),
        '../blackcat-darkmesh-gateway/workers/secrets-worker/node_modules/@permaweb/aoconnect/dist/index.js',
      ),
    ).href,
    pathToFileURL(
      path.resolve(
        process.cwd(),
        'blackcat-darkmesh-gateway/workers/secrets-worker/node_modules/@permaweb/aoconnect/dist/index.js',
      ),
    ).href,
  ]

  let lastError = null
  for (const candidate of candidates) {
    try {
      return await import(candidate)
    } catch (error) {
      lastError = error
    }
  }
  throw lastError || new Error('unable_to_load_aoconnect')
}

async function loadArbundles() {
  const require = createRequire(import.meta.url)
  const candidates = [
    'arbundles',
    path.resolve(process.cwd(), 'blackcat-darkmesh-ao/node_modules/arbundles'),
    path.resolve(process.cwd(), 'blackcat-darkmesh-gateway/workers/secrets-worker/node_modules/arbundles'),
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

async function loadWallet(args) {
  if (args.walletJwkFile) {
    return JSON.parse(await fs.readFile(args.walletJwkFile, 'utf8'))
  }
  if (process.env.AO_WALLET_JSON) {
    return JSON.parse(process.env.AO_WALLET_JSON)
  }
  return null
}

async function loadAuthConfig(args) {
  let hmacSecret = args.authSignatureSecret || process.env.AO_AUTH_SIGNATURE_SECRET || ''
  const hmacSecretFile =
    args.authSignatureSecretFile || process.env.AO_AUTH_SIGNATURE_SECRET_FILE || ''
  if (!hmacSecret && hmacSecretFile) {
    hmacSecret = (await fs.readFile(hmacSecretFile, 'utf8')).trim()
  }

  const ed25519PrivateKeyFile =
    args.authEd25519PrivateKeyFile || process.env.AO_AUTH_ED25519_PRIVATE_KEY_FILE || ''
  const ed25519PrivateKeyPem = ed25519PrivateKeyFile
    ? await fs.readFile(ed25519PrivateKeyFile, 'utf8')
    : ''

  let signatureType = args.authSignatureType || process.env.AO_AUTH_SIGNATURE_TYPE || ''
  if (!signatureType) {
    if (ed25519PrivateKeyPem) signatureType = 'ed25519'
  }
  if (!signatureType && hmacSecret) signatureType = 'hmac'

  const rawTimestamp = args.authTimestamp || process.env.AO_AUTH_TIMESTAMP || ''
  const timestamp = rawTimestamp === '' ? null : Number.parseInt(String(rawTimestamp), 10)

  return {
    actorRole: args.actorRole || process.env.AO_ACTOR_ROLE || '',
    signatureType,
    hmacSecret,
    ed25519PrivateKeyPem,
    noncePrefix: args.authNonce || process.env.AO_AUTH_NONCE || '',
    timestamp: Number.isFinite(timestamp) ? timestamp : null,
  }
}

const SIGNATURE_EXCLUDE_KEYS = new Set(['Signature', 'signature', 'Signature-Ref'])

function canonicalValue(value) {
  if (Array.isArray(value)) {
    const parts = value.map((item, index) => `${index + 1}=${canonicalValue(item)}`)
    return `{${parts.join(',')}}`
  }
  if (value && typeof value === 'object') {
    const keys = Object.keys(value).sort((a, b) => String(a).localeCompare(String(b)))
    const parts = keys.map((key) => `${key}=${canonicalValue(value[key])}`)
    return `{${parts.join(',')}}`
  }
  if (typeof value === 'boolean') return value ? 'true' : 'false'
  if (typeof value === 'number') return String(value)
  if (typeof value === 'string') return value
  return ''
}

function canonicalPayload(message) {
  const cleaned = {}
  for (const [key, value] of Object.entries(message || {})) {
    if (!SIGNATURE_EXCLUDE_KEYS.has(key)) cleaned[key] = value
  }
  return canonicalValue(cleaned)
}

function signAppAuthMessage(message, authConfig) {
  const payload = canonicalPayload(message)
  if (authConfig.signatureType === 'hmac') {
    if (!authConfig.hmacSecret) throw new Error('missing_hmac_secret')
    return crypto.createHmac('sha256', authConfig.hmacSecret).update(payload).digest('hex')
  }
  if (authConfig.signatureType === 'ed25519') {
    if (!authConfig.ed25519PrivateKeyPem) throw new Error('missing_ed25519_private_key')
    const key = crypto.createPrivateKey(authConfig.ed25519PrivateKeyPem)
    return crypto.sign(null, Buffer.from(payload, 'utf8'), key).toString('hex')
  }
  throw new Error(`unsupported_auth_signature_type:${authConfig.signatureType || 'unset'}`)
}

function randomNonceFragment() {
  return crypto.randomBytes(8).toString('hex')
}

function buildActionMessage(action, requestId, authConfig, replyTo) {
  const message = {
    Action: action,
    'Request-Id': requestId,
  }
  if (replyTo) message['Reply-To'] = replyTo
  if (PROTECTED_ACTIONS.has(action)) {
    if (authConfig.actorRole) message['Actor-Role'] = authConfig.actorRole
    if (authConfig.signatureType) {
      const noncePrefix = authConfig.noncePrefix || 'resolver-ao-read'
      message.Nonce = `${noncePrefix}-${action.toLowerCase()}-${randomNonceFragment()}`
      message.ts = authConfig.timestamp ?? Math.floor(Date.now() / 1000)
      message.Signature = signAppAuthMessage(message, authConfig)
    }
  }
  return message
}

function withTimeout(promise, timeoutMs, label) {
  const clamped = Math.max(1000, timeoutMs)
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      setTimeout(() => reject(new Error(`timeout_${label}_${clamped}ms`)), clamped)
    }),
  ])
}

function buildTags(message) {
  const tags = [
    { name: 'Action', value: message.Action },
    { name: 'Request-Id', value: message['Request-Id'] },
    { name: 'signing-format', value: 'ans104' },
    { name: 'accept-bundle', value: 'true' },
    { name: 'require-codec', value: 'application/json' },
    { name: 'Type', value: 'Message' },
    { name: 'Variant', value: 'ao.TN.1' },
    { name: 'Data-Protocol', value: 'ao' },
    { name: 'Content-Type', value: 'application/json' },
    { name: 'Input-Encoding', value: 'JSON-1' },
    { name: 'Output-Encoding', value: 'JSON-1' },
  ]
  if (typeof message['Actor-Role'] === 'string' && message['Actor-Role'] !== '') {
    tags.push({ name: 'Actor-Role', value: message['Actor-Role'] })
  }
  if (typeof message['Reply-To'] === 'string' && message['Reply-To'] !== '') {
    tags.push({ name: 'Reply-To', value: message['Reply-To'] })
  }
  return tags
}

function buildData(message) {
  return JSON.stringify(message)
}

async function fetchComputeFallback(baseUrl, processId, slotOrMessage, timeoutMs) {
  const base = baseUrl.replace(/\/$/, '')
  const endpoint = `${base}/${processId}~process@1.0/compute=${slotOrMessage}?accept-bundle=true&require-codec=application/json`
  const response = await withTimeout(fetch(endpoint, { method: 'GET' }), timeoutMs, 'compute_fetch')
  const text = await response.text()
  if (!response.ok) {
    throw new Error(`compute_http_${response.status}:${text.slice(0, 180)}`)
  }
  return text ? JSON.parse(text) : {}
}

function extractOutputCandidate(raw) {
  const normalized = raw?.results?.raw || raw?.raw || raw || {}
  return (
    normalized?.Output ??
    normalized?.output ??
    normalized?.Data ??
    normalized?.data ??
    raw?.Output ??
    raw?.output ??
    null
  )
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
  if (candidate && typeof candidate === 'object') {
    return candidate
  }
  return null
}

function extractEnvelopeFromMessages(raw) {
  const normalized = raw?.results?.raw || raw?.raw || raw || {}
  const messages = Array.isArray(normalized?.Messages) ? normalized.Messages : []
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
    envelopes.push({
      action,
      envelope,
    })
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

function extractEnvelopeDetails(raw) {
  const normalized = raw?.results?.raw || raw?.raw || raw || {}
  const outputCandidate = extractOutputCandidate(raw)
  const outputEnvelope = parseJsonEnvelopeCandidate(outputCandidate)
  if (outputEnvelope) return { envelope: outputEnvelope, carrier: 'output', action: null }
  if (
    normalized &&
    typeof normalized === 'object' &&
    typeof normalized.status === 'string'
  ) {
    return { envelope: normalized, carrier: 'raw', action: null }
  }
  const messageEnvelopes = extractEnvelopeFromMessages(raw)
  const preferredMessageEnvelope = pickPreferredMessageEnvelope(messageEnvelopes)
  if (preferredMessageEnvelope) {
    return {
      envelope: preferredMessageEnvelope.envelope,
      carrier: 'messages',
      action: preferredMessageEnvelope.action || null,
    }
  }
  return null
}

function buildReadContract(summary, envelopeInfo) {
  if (envelopeInfo && typeof envelopeInfo.envelope === 'object') {
    return {
      state:
        envelopeInfo.carrier === 'messages'
          ? 'reply_message_payload'
          : 'semantic_payload',
      healthy: true,
      payloadAvailable: true,
      carrier: envelopeInfo.carrier,
      sourceAction: envelopeInfo.action || null,
      detail: 'ok',
    }
  }

  if (summary.runtimeEffect?.hasResults === true && summary.runtimeEffect?.hasError !== true) {
    return {
      state: 'runtime_effect_only',
      healthy: true,
      payloadAvailable: false,
      carrier: null,
      sourceAction: null,
      detail: 'runtime_effect_without_semantic_output',
    }
  }

  if (summary.runtimeEffect?.hasError === true) {
    return {
      state: 'runtime_error',
      healthy: false,
      payloadAvailable: false,
      carrier: null,
      sourceAction: null,
      detail: summary.detail || 'runtime_error',
    }
  }

  return {
    state: 'transport_unavailable',
    healthy: false,
    payloadAvailable: false,
    carrier: null,
    sourceAction: null,
    detail: summary.detail || 'transport_unavailable',
  }
}

function summarizeRawRuntimeEffect(raw) {
  const normalized = raw?.results?.raw || raw?.raw || raw || {}
  const outputCandidate = extractOutputCandidate(raw)
  const messageEnvelopes = extractEnvelopeFromMessages(raw)
  const rawError = normalized?.Error
  const hasError = (() => {
    if (rawError === null || rawError === undefined) return false
    if (typeof rawError === 'string') return rawError.trim().length > 0
    if (Array.isArray(rawError)) return rawError.length > 0
    if (typeof rawError === 'object') return Object.keys(rawError).length > 0
    return true
  })()
  const hasResults =
    normalized != null &&
    typeof normalized === 'object' &&
    (
      Object.prototype.hasOwnProperty.call(normalized, 'Output') ||
      Object.prototype.hasOwnProperty.call(normalized, 'Messages') ||
      Object.prototype.hasOwnProperty.call(normalized, 'Assignments') ||
      Object.prototype.hasOwnProperty.call(normalized, 'Spawns') ||
      Object.prototype.hasOwnProperty.call(normalized, 'Patches')
    )
  return {
    hasResults,
    hasError,
    outputShape:
      typeof outputCandidate === 'string'
        ? 'string'
        : outputCandidate && typeof outputCandidate === 'object'
          ? 'object'
          : 'empty',
    outputEmpty: typeof outputCandidate === 'string' ? outputCandidate.trim() === '' : !outputCandidate,
    messagesCount: Array.isArray(normalized?.Messages) ? normalized.Messages.length : 0,
    messageEnvelopeCount: messageEnvelopes.length,
    messageEnvelopeActions: messageEnvelopes.map((entry) => entry.action).filter(Boolean),
    assignmentsCount: Array.isArray(normalized?.Assignments) ? normalized.Assignments.length : 0,
    spawnsCount: Array.isArray(normalized?.Spawns) ? normalized.Spawns.length : 0,
  }
}

function resultBasenameForAction(action) {
  if (action === 'GetAdmissionState') return 'admission-state.json'
  if (action === 'ListHostsDueForDnsRefresh') return 'due-hosts-state.json'
  if (action === 'GetDnsRefreshState') return 'dns-refresh-state.json'
  return `${action}.json`
}

async function createOptionalSigner(root, wallet) {
  if (!wallet) return null
  const createDataItemSigner = root.createDataItemSigner
  const createSigner = root.createSigner
  if (typeof createDataItemSigner === 'function') return createDataItemSigner(wallet)
  if (typeof createSigner === 'function') return createSigner(wallet)
  throw new Error('aoconnect_create_signer_missing')
}

function buildSchedulerDirectTags(message) {
  return buildTags(message)
}

async function sendSchedulerDirect({ baseUrl, processId, wallet, message, data, timeoutMs }) {
  const { createData, ArweaveSigner } = await loadArbundles()
  const signer = new ArweaveSigner(wallet)
  const tags = buildSchedulerDirectTags(message)
  const item = createData(data, signer, { target: processId, tags })
  await item.sign(signer)
  const endpoint = `${baseUrl.replace(/\/$/, '')}/~scheduler@1.0/schedule?target=${processId}`
  const response = await withTimeout(
    fetch(endpoint, {
      method: 'POST',
      headers: {
        'content-type': 'application/ans104',
        'codec-device': 'ans104@1.0',
      },
      body: item.getRaw(),
    }),
    timeoutMs,
    'scheduler_direct_send',
  )
  const text = await response.text().catch(() => '')
  let parsed = null
  try {
    parsed = text ? JSON.parse(text) : null
  } catch {
    parsed = null
  }
  const slot = Number(response.headers.get('slot') || parsed?.slot || '')
  if (!response.ok) {
    throw new Error(`scheduler_send_failed:${response.status}:${text.slice(0, 220)}`)
  }
  if (!Number.isFinite(slot)) {
    throw new Error(`scheduler_send_no_slot:${text.slice(0, 220)}`)
  }
  return {
    slot,
    messageId: item.id,
    parsed,
    text,
  }
}

async function executeAction({
  action,
  processId,
  readClient,
  writeClient,
  wallet,
  authConfig,
  replyTo,
  hbUrl,
  schedulerDirectBaseUrl,
  computeBaseUrl,
  timeoutMs,
  outputDir,
}) {
  const requestId = `resolver-ao-${action}-${new Date().toISOString().replace(/[:.]/g, '-')}`
  const message = buildActionMessage(action, requestId, authConfig, replyTo)
  const tags = buildTags(message)
  const data = buildData(message)
  const rawPath = path.join(outputDir, `${action}.raw.json`)
  const envelopePath = path.join(outputDir, resultBasenameForAction(action))

  const summary = {
    action,
    requestId,
    available: false,
    method: null,
    protection: PROTECTED_ACTIONS.has(action) ? 'protected' : 'public',
    authEnvelope: {
      actorRole: message['Actor-Role'] || null,
      signed: typeof message.Signature === 'string' && message.Signature !== '',
      hasNonce: typeof message.Nonce === 'string' && message.Nonce !== '',
      hasTimestamp: Number.isFinite(message.ts),
      replyTo: message['Reply-To'] || null,
      signatureType:
        typeof message.Signature === 'string' && message.Signature !== ''
          ? authConfig.signatureType || null
          : null,
    },
    envelopePath: null,
    rawPath,
    detail: null,
  }

  let raw = null
  try {
    raw = await withTimeout(
      readClient.dryrun({ process: processId, tags, data }),
      timeoutMs,
      `${action}_dryrun`,
    )
    summary.method = 'dryrun'
  } catch (error) {
    summary.detail = error instanceof Error ? error.message : String(error)
  }

  if (raw == null && writeClient) {
    try {
      const slotOrMessage = await withTimeout(
        writeClient.message({ process: processId, tags, data }),
        timeoutMs,
        `${action}_message`,
      )
      try {
        raw = await withTimeout(
          writeClient.result({ process: processId, message: String(slotOrMessage) }),
          timeoutMs,
          `${action}_result`,
        )
      } catch {
        raw = await fetchComputeFallback(computeBaseUrl, processId, String(slotOrMessage), timeoutMs)
      }
      summary.method = 'message_result'
      summary.detail = null
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      summary.detail = summary.detail ? `${summary.detail}; ${message}` : message
    }
  }

  if (raw == null && wallet && schedulerDirectBaseUrl) {
    try {
      const sent = await sendSchedulerDirect({
        baseUrl: schedulerDirectBaseUrl,
        processId,
        wallet,
        message,
        data,
        timeoutMs,
      })
      raw = await fetchComputeFallback(computeBaseUrl, processId, String(sent.slot), timeoutMs)
      summary.method = 'scheduler_direct'
      summary.detail = null
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      summary.detail = summary.detail ? `${summary.detail}; ${message}` : message
    }
  }

  if (raw != null) {
    await fs.writeFile(rawPath, JSON.stringify(raw, null, 2))
    summary.runtimeEffect = summarizeRawRuntimeEffect(raw)
    const envelopeInfo = extractEnvelopeDetails(raw)
    if (envelopeInfo && typeof envelopeInfo.envelope === 'object') {
      await fs.writeFile(envelopePath, JSON.stringify(envelopeInfo.envelope, null, 2))
      summary.available = true
      summary.envelopePath = envelopePath
      summary.envelopeCarrier = envelopeInfo.carrier
      summary.envelopeSourceAction = envelopeInfo.action || null
      summary.detail = 'ok'
    } else {
      if (summary.runtimeEffect?.hasResults === true && summary.runtimeEffect?.hasError !== true) {
        summary.detail = summary.detail
          ? `${summary.detail}; runtime_effect_without_semantic_output`
          : 'runtime_effect_without_semantic_output'
      } else {
        summary.detail = summary.detail ? `${summary.detail}; invalid_envelope` : 'invalid_envelope'
      }
    }
    summary.readContract = buildReadContract(summary, envelopeInfo)
  } else {
    summary.readContract = buildReadContract(summary, null)
  }

  return summary
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  const outputDir =
    args.outputDir ||
    (await fs.mkdtemp(path.join(os.tmpdir(), 'darkmesh-ao-aoconnect-')))
  await fs.mkdir(outputDir, { recursive: true })

  const module = await loadAoConnect()
  const root = module.default || module
  const connect = root.connect
  if (typeof connect !== 'function') {
    throw new Error('aoconnect_connect_missing')
  }

  const wallet = await loadWallet(args)
  const authConfig = await loadAuthConfig(args)
  const signer = await createOptionalSigner(root, wallet)

  const readClient = connect({
    MODE: args.mode,
    URL: args.hbUrl,
    SCHEDULER: args.scheduler,
  })

  const writeClient =
    typeof signer === 'function'
      ? connect({
          MODE: args.mode,
          URL: args.hbUrl,
          SCHEDULER: args.scheduler,
          signer,
        })
      : null

  const actionResults = []
  for (const action of args.actions) {
    actionResults.push(
      await executeAction({
        action,
        processId: args.processId,
        readClient,
        writeClient,
        wallet,
        authConfig,
        replyTo: args.replyTo,
        hbUrl: args.hbUrl,
        schedulerDirectBaseUrl: args.schedulerDirectBaseUrl,
        computeBaseUrl: args.computeBaseUrl,
        timeoutMs: args.timeoutMs,
        outputDir,
      }),
    )
  }

  const report = {
    generatedAt: new Date().toISOString(),
    processId: args.processId,
    mode: args.mode,
    hbUrl: args.hbUrl,
    replyTo: args.replyTo || null,
    scheduler: args.scheduler,
    schedulerDirectBaseUrl: args.schedulerDirectBaseUrl,
    computeBaseUrl: args.computeBaseUrl,
    walletConfigured: Boolean(wallet),
    authConfigured: {
      actorRole: authConfig.actorRole || null,
      signatureType: authConfig.signatureType || null,
      signedProtectedReads:
        Boolean(authConfig.signatureType) && Boolean(authConfig.actorRole),
    },
    outputDir,
    readContractSummary: {
      healthyActions: actionResults.filter((item) => item.readContract?.healthy === true).length,
      payloadActions: actionResults.filter((item) => item.readContract?.payloadAvailable === true).length,
      runtimeEffectOnlyActions: actionResults.filter((item) => item.readContract?.state === 'runtime_effect_only').length,
      unhealthyActions: actionResults.filter((item) => item.readContract?.healthy !== true).length,
      states: actionResults.reduce((acc, item) => {
        const state = item.readContract?.state || 'unknown'
        acc[state] = (acc[state] || 0) + 1
        return acc
      }, {}),
    },
    results: actionResults,
  }
  const reportPath = path.join(outputDir, 'ao-control-state-aoconnect-report.json')
  await fs.writeFile(reportPath, JSON.stringify(report, null, 2))

  console.log('ao aoconnect control-state fetch complete')
  console.log(`  outputDir=${outputDir}`)
  console.log(`  report=${reportPath}`)
  for (const item of actionResults) {
    console.log(
      `  ${item.action}: available=${item.available} method=${item.method || 'none'} contract=${item.readContract?.state || 'unknown'} detail=${item.detail || ''}`,
    )
  }
  process.exit(0)
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error))
  process.exit(1)
})
