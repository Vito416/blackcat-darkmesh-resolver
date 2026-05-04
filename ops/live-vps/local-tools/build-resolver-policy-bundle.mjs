#!/usr/bin/env node
import fs from 'node:fs'
import path from 'node:path'

const VALID_POLICY_MODES = new Set(['off', 'observe', 'soft', 'enforce'])
const VALID_PROOF_STATES = new Set(['valid', 'expired', 'missing', 'unchecked'])
const VALID_ROUTE_METHODS = new Set(['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'])

function usage() {
  console.log(`Usage:
  node ops/live-vps/local-tools/build-resolver-policy-bundle.mjs \
    --input <json> [--output <json>] [--mode <off|observe|soft|enforce>] [--fail-open <true|false>] [--snapshot-id <id>]

Input format (minimal):
{
  "autoDns": {
    "enabled": true,
    "refreshOnStale": true,
    "refreshIntervalSec": 300,
    "staleRefreshMinIntervalSec": 30,
    "maxHostsPerRun": 100,
    "staleGraceSec": 900,
    "relayPath": "/~relay@1.0",
    "cachePath": "/~cache@1.0",
    "cronPath": "/~cron@1.0",
    "dohEndpoint": "https://cloudflare-dns.com/dns-query",
    "arweaveBase": "https://arweave.net"
  },
  "hosts": [
    {
      "host": "site-a.example",
      "siteId": "site-a",
      "processId": "<43-char-pid>",
      "moduleId": "<43-char-module>",
      "scheduler": "<43-char-scheduler>",
      "routePrefix": "/",
      "proof": {
        "state": "valid",
        "checkedAt": "2026-04-24T08:00:00Z",
        "validUntil": "2026-04-24T09:00:00Z",
        "source": "dns_txt"
      },
      "route": {
        "defaultActionHint": "read",
        "rules": [
          { "pathPrefix": "/api", "methods": ["GET", "HEAD"], "actionHint": "read" }
        ]
      }
    }
  ]
}
`)
}

function fail(message) {
  throw new Error(message)
}

function readArgValue(args, index, flag) {
  const value = args[index + 1]
  if (!value || value.startsWith('--')) fail(`Missing value for ${flag}`)
  return value
}

function parseBooleanLike(raw, flagName) {
  const value = String(raw).trim().toLowerCase()
  if (value === 'true' || value === '1' || value === 'yes' || value === 'on') return true
  if (value === 'false' || value === '0' || value === 'no' || value === 'off') return false
  fail(`Invalid ${flagName}: ${raw}`)
}

function canonicalHost(raw, fieldName = 'host') {
  if (typeof raw !== 'string') fail(`Invalid ${fieldName}: must be string`)
  let host = raw.trim().toLowerCase()
  if (!host) fail(`Invalid ${fieldName}: empty`)
  if (host.includes('://') || host.includes('/') || host.includes('?') || host.includes('#')) {
    fail(`Invalid ${fieldName}: must be hostname only`)
  }
  host = host.replace(/\.+$/, '')
  if (!host) fail(`Invalid ${fieldName}: empty after trim`)

  let parsed
  try {
    parsed = new URL(`http://${host}`).hostname.toLowerCase()
  } catch {
    fail(`Invalid ${fieldName}: not parseable hostname`)
  }

  if (!parsed.includes('.')) fail(`Invalid ${fieldName}: FQDN required`)
  if (parsed.length > 253) fail(`Invalid ${fieldName}: too long`)

  for (const label of parsed.split('.')) {
    if (!label || label.length > 63) fail(`Invalid ${fieldName}: bad label length`)
    if (!/^[a-z0-9-]+$/.test(label) || label.startsWith('-') || label.endsWith('-')) {
      fail(`Invalid ${fieldName}: bad label characters`)
    }
  }

  return parsed
}

function readOptionalString(value, fieldName, maxLen = 256) {
  if (value == null) return undefined
  if (typeof value !== 'string') fail(`Invalid ${fieldName}: must be string when provided`)
  const trimmed = value.trim()
  if (!trimmed) fail(`Invalid ${fieldName}: empty`)
  if (trimmed.length > maxLen) fail(`Invalid ${fieldName}: too long`)
  return trimmed
}

function readRequiredString(value, fieldName, maxLen = 256) {
  const normalized = readOptionalString(value, fieldName, maxLen)
  if (!normalized) fail(`Missing ${fieldName}`)
  return normalized
}

function readOptionalBoolean(value, fieldName) {
  if (value == null) return undefined
  if (typeof value !== 'boolean') fail(`Invalid ${fieldName}: must be boolean when provided`)
  return value
}

function readOptionalProcessLike(value, fieldName) {
  const normalized = readOptionalString(value, fieldName, 128)
  if (!normalized) return undefined
  if (!/^[A-Za-z0-9_-]{20,128}$/.test(normalized)) fail(`Invalid ${fieldName}: expected AO id format`)
  return normalized
}

function readRoutePrefix(value, fieldName) {
  const normalized = readOptionalString(value, fieldName, 1024)
  if (!normalized) return undefined
  if (!normalized.startsWith('/')) fail(`Invalid ${fieldName}: must start with /`)
  return normalized
}

function normalizeIsoOrUndefined(value, fieldName) {
  if (value == null) return undefined
  if (typeof value !== 'string') fail(`Invalid ${fieldName}: must be ISO string`)
  const trimmed = value.trim()
  if (!trimmed) return undefined
  const timestamp = Date.parse(trimmed)
  if (!Number.isFinite(timestamp)) fail(`Invalid ${fieldName}: not parseable ISO date`)
  return new Date(timestamp).toISOString().replace('.000Z', 'Z')
}

function normalizeMethods(rawMethods, fieldName) {
  if (rawMethods == null) return undefined
  if (!Array.isArray(rawMethods)) fail(`Invalid ${fieldName}: must be array`)
  const out = []
  const seen = new Set()
  for (const methodRaw of rawMethods) {
    if (typeof methodRaw !== 'string') fail(`Invalid ${fieldName}: method must be string`)
    const method = methodRaw.trim().toUpperCase()
    if (!VALID_ROUTE_METHODS.has(method)) fail(`Invalid ${fieldName}: unsupported method ${methodRaw}`)
    if (!seen.has(method)) {
      seen.add(method)
      out.push(method)
    }
  }
  return out.length > 0 ? out : undefined
}

function normalizeDevicePath(value, fieldName) {
  const normalized = readOptionalString(value, fieldName, 256)
  if (!normalized) return undefined
  if (!/^\/~[a-z0-9-]+@[0-9.]+$/.test(normalized)) {
    fail(`Invalid ${fieldName}: expected /~device@version format`)
  }
  return normalized
}

function normalizeAutoDns(rawAutoDns) {
  if (rawAutoDns == null) return undefined
  if (typeof rawAutoDns !== 'object' || Array.isArray(rawAutoDns)) {
    fail('Invalid autoDns: must be object')
  }

  const out = {}
  const enabled = readOptionalBoolean(rawAutoDns.enabled, 'autoDns.enabled')
  if (enabled != null) out.enabled = enabled
  const refreshOnStale = readOptionalBoolean(rawAutoDns.refreshOnStale, 'autoDns.refreshOnStale')
  if (refreshOnStale != null) out.refreshOnStale = refreshOnStale
  const requireChallenge = readOptionalBoolean(rawAutoDns.requireChallenge, 'autoDns.requireChallenge')
  if (requireChallenge != null) out.requireChallenge = requireChallenge

  if (rawAutoDns.refreshIntervalSec != null) {
    out.refreshIntervalSec = parseNumberArg(rawAutoDns.refreshIntervalSec, 'autoDns.refreshIntervalSec', 30, 86400)
  }
  if (rawAutoDns.staleRefreshMinIntervalSec != null) {
    out.staleRefreshMinIntervalSec = parseNumberArg(
      rawAutoDns.staleRefreshMinIntervalSec,
      'autoDns.staleRefreshMinIntervalSec',
      0,
      86400,
    )
  }
  if (rawAutoDns.maxHostsPerRun != null) {
    out.maxHostsPerRun = parseNumberArg(rawAutoDns.maxHostsPerRun, 'autoDns.maxHostsPerRun', 1, 500)
  }
  if (rawAutoDns.staleGraceSec != null) {
    out.staleGraceSec = parseNumberArg(rawAutoDns.staleGraceSec, 'autoDns.staleGraceSec', 0, 172800)
  }
  if (rawAutoDns.challengeTtlSec != null) {
    out.challengeTtlSec = parseNumberArg(rawAutoDns.challengeTtlSec, 'autoDns.challengeTtlSec', 30, 7200)
  }

  const relayPath = normalizeDevicePath(rawAutoDns.relayPath, 'autoDns.relayPath')
  if (relayPath) out.relayPath = relayPath
  const cachePath = normalizeDevicePath(rawAutoDns.cachePath, 'autoDns.cachePath')
  if (cachePath) out.cachePath = cachePath
  const cronPath = normalizeDevicePath(rawAutoDns.cronPath, 'autoDns.cronPath')
  if (cronPath) out.cronPath = cronPath
  const dohEndpoint = readOptionalString(rawAutoDns.dohEndpoint, 'autoDns.dohEndpoint', 512)
  if (dohEndpoint) {
    if (!/^https:\/\/.+/.test(dohEndpoint)) fail('Invalid autoDns.dohEndpoint: expected https:// URL')
    out.dohEndpoint = dohEndpoint
  }
  const arweaveBase = readOptionalString(rawAutoDns.arweaveBase, 'autoDns.arweaveBase', 512)
  if (arweaveBase) {
    if (!/^https:\/\/.+/.test(arweaveBase)) fail('Invalid autoDns.arweaveBase: expected https:// URL')
    out.arweaveBase = arweaveBase
  }

  return Object.keys(out).length > 0 ? out : undefined
}

function normalizeRoute(rawRoute, host) {
  if (rawRoute == null) return undefined
  if (typeof rawRoute !== 'object' || Array.isArray(rawRoute)) fail(`Invalid route for ${host}: must be object`)

  const route = {}
  const defaultActionHint = readOptionalString(rawRoute.defaultActionHint, `route.defaultActionHint (${host})`, 128)
  if (defaultActionHint) route.defaultActionHint = defaultActionHint

  if (rawRoute.rules != null) {
    if (!Array.isArray(rawRoute.rules)) fail(`Invalid route.rules for ${host}: must be array`)
    const rules = []
    for (const [index, rawRule] of rawRoute.rules.entries()) {
      if (typeof rawRule !== 'object' || rawRule == null || Array.isArray(rawRule)) {
        fail(`Invalid route.rules[${index}] for ${host}: must be object`)
      }
      const pathPrefix = readRoutePrefix(
        rawRule.pathPrefix ?? rawRule.path,
        `route.rules[${index}].pathPrefix (${host})`,
      )
      if (!pathPrefix) fail(`Missing route.rules[${index}].pathPrefix for ${host}`)
      const actionHint = readOptionalString(rawRule.actionHint, `route.rules[${index}].actionHint (${host})`, 128)
      const methods = normalizeMethods(rawRule.methods, `route.rules[${index}].methods (${host})`)
      const normalizedRule = { pathPrefix }
      if (methods) normalizedRule.methods = methods
      if (actionHint) normalizedRule.actionHint = actionHint
      rules.push(normalizedRule)
    }
    if (rules.length > 0) route.rules = rules
  }

  return Object.keys(route).length > 0 ? route : undefined
}

function normalizeProof(rawProof, host, defaultProofState) {
  if (rawProof == null) {
    return {
      state: defaultProofState,
      source: 'bundle-generator',
      checkedAt: new Date().toISOString().replace('.000Z', 'Z'),
    }
  }

  if (typeof rawProof !== 'object' || Array.isArray(rawProof)) {
    fail(`Invalid proof for ${host}: must be object`)
  }

  const stateRaw = readOptionalString(rawProof.state, `proof.state (${host})`, 32) || defaultProofState
  const state = stateRaw.toLowerCase()
  if (!VALID_PROOF_STATES.has(state)) fail(`Invalid proof.state (${host}): ${stateRaw}`)

  let sequence
  if (rawProof.sequence != null || rawProof.dnsProofSeq != null) {
    sequence = parseNumberArg(rawProof.sequence ?? rawProof.dnsProofSeq, `proof.sequence (${host})`, 0, 2147483647)
  }

  return {
    state,
    checkedAt:
      normalizeIsoOrUndefined(rawProof.checkedAt ?? rawProof.dnsProofCheckedAt, `proof.checkedAt (${host})`) ||
      new Date().toISOString().replace('.000Z', 'Z'),
    validUntil: normalizeIsoOrUndefined(rawProof.validUntil ?? rawProof.dnsProofValidUntil, `proof.validUntil (${host})`),
    source: readOptionalString(rawProof.source, `proof.source (${host})`, 128) || 'bundle-generator',
    challengeRef: readOptionalString(rawProof.challengeRef, `proof.challengeRef (${host})`, 256),
    ...(sequence != null ? { sequence } : {}),
  }
}

function deepEqual(a, b) {
  return JSON.stringify(a) === JSON.stringify(b)
}

function buildBundle(input, options) {
  if (typeof input !== 'object' || input == null || Array.isArray(input)) fail('Input root must be object')
  if (!Array.isArray(input.hosts) || input.hosts.length === 0) fail('Input must contain non-empty hosts[]')

  const hostPolicies = {}
  const sitePolicies = {}
  const dnsProofState = {}
  const routePolicies = {}
  const autoDns = normalizeAutoDns(input.autoDns)

  for (const [index, rawEntry] of input.hosts.entries()) {
    if (typeof rawEntry !== 'object' || rawEntry == null || Array.isArray(rawEntry)) {
      fail(`hosts[${index}] must be object`)
    }

    const host = canonicalHost(rawEntry.host, `hosts[${index}].host`)
    const siteId = readRequiredString(rawEntry.siteId, `hosts[${index}].siteId`, 128)
    const processId = readOptionalProcessLike(rawEntry.processId, `hosts[${index}].processId`)
    const moduleId = readOptionalProcessLike(rawEntry.moduleId, `hosts[${index}].moduleId`)
    const scheduler = readOptionalProcessLike(rawEntry.scheduler, `hosts[${index}].scheduler`)
    const routePrefix = readRoutePrefix(rawEntry.routePrefix, `hosts[${index}].routePrefix`)
    const status = readOptionalString(rawEntry.status, `hosts[${index}].status`, 64)

    hostPolicies[host] = {
      siteId,
      ...(processId ? { processId } : {}),
      ...(moduleId ? { moduleId } : {}),
      ...(scheduler ? { scheduler } : {}),
      ...(routePrefix ? { routePrefix } : {}),
      ...(status ? { status } : {}),
    }

    const sitePolicyEntry = {
      ...(processId ? { processId } : {}),
      ...(moduleId ? { moduleId } : {}),
      ...(scheduler ? { scheduler } : {}),
      ...(routePrefix ? { routePrefix } : {}),
      ...(status ? { status } : {}),
    }

    if (sitePolicies[siteId] && !deepEqual(sitePolicies[siteId], sitePolicyEntry)) {
      fail(
        `Conflicting site policy for siteId=${siteId}. ` +
          `Use a single canonical runtime tuple (process/module/scheduler/routePrefix).`,
      )
    }
    sitePolicies[siteId] = sitePolicies[siteId] || sitePolicyEntry

    dnsProofState[host] = normalizeProof(rawEntry.proof, host, options.defaultProofState)

    const normalizedRoute = normalizeRoute(rawEntry.route, host)
    if (normalizedRoute) {
      routePolicies[host] = normalizedRoute
    }
  }

  const generatedAt = new Date().toISOString().replace('.000Z', 'Z')
  const snapshotId =
    options.snapshotId ||
    `dm-resolver-${generatedAt.replace(/[-:]/g, '').replace(/\.\d{3}/, '').replace('T', 'T').replace('Z', 'Z')}`

  const bundle = {
    schemaVersion: '1.0',
    snapshotId,
    version: 'dm-resolver-bundle/1',
    generatedAt,
    policyMode: options.mode,
    failOpen: options.failOpen,
    hostPolicies,
    sitePolicies,
    dnsProofState,
    ...(Object.keys(routePolicies).length > 0 ? { routePolicies } : {}),
    cacheHints: {
      positiveTtlSec: options.cachePositiveSec,
      negativeTtlSec: options.cacheNegativeSec,
      staleWhileRevalidateSec: options.cacheSwrSec,
      hardMaxStaleSec: options.cacheHardMaxStaleSec,
    },
    ...(autoDns ? { autoDns } : {}),
  }

  return bundle
}

function parseNumberArg(value, flagName, min, max) {
  const parsed = Number.parseInt(String(value), 10)
  if (!Number.isFinite(parsed) || parsed < min || parsed > max) {
    fail(`Invalid ${flagName}: expected integer in range ${min}-${max}`)
  }
  return parsed
}

function main() {
  const args = process.argv.slice(2)
  if (args.includes('-h') || args.includes('--help')) {
    usage()
    process.exit(0)
  }

  let inputPath = ''
  let outputPath = ''
  let mode = 'off'
  let failOpen = true
  let snapshotId = ''
  let defaultProofState = 'unchecked'
  let cachePositiveSec = 300
  let cacheNegativeSec = 60
  let cacheSwrSec = 900
  let cacheHardMaxStaleSec = 3600

  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i]
    switch (arg) {
      case '--input':
        inputPath = readArgValue(args, i, '--input')
        i += 1
        break
      case '--output':
        outputPath = readArgValue(args, i, '--output')
        i += 1
        break
      case '--mode':
        mode = readArgValue(args, i, '--mode').trim().toLowerCase()
        i += 1
        break
      case '--fail-open':
        failOpen = parseBooleanLike(readArgValue(args, i, '--fail-open'), '--fail-open')
        i += 1
        break
      case '--snapshot-id':
        snapshotId = readArgValue(args, i, '--snapshot-id').trim()
        i += 1
        break
      case '--default-proof-state':
        defaultProofState = readArgValue(args, i, '--default-proof-state').trim().toLowerCase()
        i += 1
        break
      case '--cache-positive-sec':
        cachePositiveSec = parseNumberArg(readArgValue(args, i, '--cache-positive-sec'), '--cache-positive-sec', 1, 86400)
        i += 1
        break
      case '--cache-negative-sec':
        cacheNegativeSec = parseNumberArg(readArgValue(args, i, '--cache-negative-sec'), '--cache-negative-sec', 1, 86400)
        i += 1
        break
      case '--cache-swr-sec':
        cacheSwrSec = parseNumberArg(readArgValue(args, i, '--cache-swr-sec'), '--cache-swr-sec', 0, 86400)
        i += 1
        break
      case '--cache-hard-max-stale-sec':
        cacheHardMaxStaleSec = parseNumberArg(
          readArgValue(args, i, '--cache-hard-max-stale-sec'),
          '--cache-hard-max-stale-sec',
          0,
          172800,
        )
        i += 1
        break
      default:
        fail(`Unknown argument: ${arg}`)
    }
  }

  if (!inputPath) fail('Missing --input')
  if (!VALID_POLICY_MODES.has(mode)) fail(`Invalid --mode: ${mode}`)
  if (!VALID_PROOF_STATES.has(defaultProofState)) fail(`Invalid --default-proof-state: ${defaultProofState}`)

  const resolvedInput = path.resolve(inputPath)
  if (!fs.existsSync(resolvedInput)) fail(`Input file not found: ${resolvedInput}`)

  const rawText = fs.readFileSync(resolvedInput, 'utf8')
  let parsedInput
  try {
    parsedInput = JSON.parse(rawText)
  } catch (error) {
    fail(`Input is not valid JSON: ${error instanceof Error ? error.message : String(error)}`)
  }

  const bundle = buildBundle(parsedInput, {
    mode,
    failOpen,
    snapshotId,
    defaultProofState,
    cachePositiveSec,
    cacheNegativeSec,
    cacheSwrSec,
    cacheHardMaxStaleSec,
  })

  const outputJson = `${JSON.stringify(bundle, null, 2)}\n`

  if (outputPath) {
    const resolvedOutput = path.resolve(outputPath)
    fs.mkdirSync(path.dirname(resolvedOutput), { recursive: true })
    fs.writeFileSync(resolvedOutput, outputJson, 'utf8')
    console.log(`Wrote resolver bundle: ${resolvedOutput}`)
  } else {
    process.stdout.write(outputJson)
  }
}

main()
