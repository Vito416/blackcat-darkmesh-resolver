#!/usr/bin/env node
import fs from 'node:fs'
import path from 'node:path'
import { spawnSync } from 'node:child_process'

const repoRoot = process.cwd()

const requiredFiles = [
  'ops/live-vps/runtime/hb/addons/darkmesh-resolver@1.0.lua',
  'ops/live-vps/runtime/hb/addons/README.md',
  'ops/live-vps/runtime/hb/addons/fixtures/resolver-fixtures.v1.lua',
  'ops/live-vps/local-tools/build-resolver-policy-bundle.mjs',
  'ops/live-vps/local-tools/resolver-bundle-input.example.json',
  'ops/migrations/DARKMESH_RESOLVER_V1_IMPLEMENTATION_PACK_2026-04-24.md',
  'ops/migrations/DARKMESH_AUTONOMOUS_DNS_TXT_RESOLVER_AUDIT_2026-04-24.md',
  'ops/migrations/DARKMESH_RESOLVER_AO_NATIVE_REFRESH_PLAN_2026-04-24.md',
  'ops/migrations/schemas/dm1-config.schema.json',
  'ops/migrations/schemas/dm1-dns-txt.schema.json',
  'ops/migrations/schemas/dm-resolver-policy-bundle.schema.json',
  'ops/migrations/schemas/dm-resolver-decision.schema.json',
  'scripts/run-resolver-fixtures.lua',
]

function fail(message) {
  console.error(`FAIL ${message}`)
  process.exit(1)
}

for (const file of requiredFiles) {
  const abs = path.join(repoRoot, file)
  if (!fs.existsSync(abs)) {
    fail(`missing required file: ${file}`)
  }
  if (file.endsWith('.json')) {
    try {
      JSON.parse(fs.readFileSync(abs, 'utf8'))
    } catch (error) {
      fail(`invalid JSON in ${file}: ${error instanceof Error ? error.message : String(error)}`)
    }
  }
}

const resolverSource = fs.readFileSync(
  path.join(repoRoot, 'ops/live-vps/runtime/hb/addons/darkmesh-resolver@1.0.lua'),
  'utf8',
)
const allowedActionsMatch = resolverSource.match(/local allowed_actions = \{([\s\S]*?)\n\}/)
if (!allowedActionsMatch) {
  fail('cannot parse allowed_actions from resolver source')
}
const allowedActions = new Set(
  [...allowedActionsMatch[1].matchAll(/"([A-Za-z0-9]+)"/g)].map((match) => match[1]),
)
if (allowedActions.size === 0) {
  fail('resolver allowed_actions is empty')
}

const fixturesSource = fs.readFileSync(
  path.join(repoRoot, 'ops/live-vps/runtime/hb/addons/fixtures/resolver-fixtures.v1.lua'),
  'utf8',
)
const fixtureActions = new Set([...fixturesSource.matchAll(/Action\s*=\s*"([A-Za-z0-9]+)"/g)].map((match) => match[1]))
const missingFixtureActions = [...allowedActions].filter((action) => !fixtureActions.has(action))
if (missingFixtureActions.length > 0) {
  fail(`fixture matrix missing resolver actions: ${missingFixtureActions.join(', ')}`)
}

const tmpDir = path.join(repoRoot, 'tmp')
fs.mkdirSync(tmpDir, { recursive: true })
const generatedPath = path.join(tmpDir, 'resolver-policy-bundle.generated.json')

const scriptPath = path.join(repoRoot, 'ops/live-vps/local-tools/build-resolver-policy-bundle.mjs')
const inputPath = path.join(repoRoot, 'ops/live-vps/local-tools/resolver-bundle-input.example.json')
const run = spawnSync(
  process.execPath,
  [scriptPath, '--input', inputPath, '--output', generatedPath, '--mode', 'off', '--fail-open', 'true'],
  { stdio: 'pipe', encoding: 'utf8' },
)

if (run.status !== 0) {
  const stderr = run.stderr?.trim() || run.stdout?.trim() || 'unknown error'
  fail(`bundle generator failed: ${stderr}`)
}

let generated
try {
  generated = JSON.parse(fs.readFileSync(generatedPath, 'utf8'))
} catch (error) {
  fail(`generated bundle is not valid JSON: ${error instanceof Error ? error.message : String(error)}`)
}

const requiredBundleKeys = [
  'schemaVersion',
  'snapshotId',
  'version',
  'generatedAt',
  'policyMode',
  'failOpen',
  'hostPolicies',
  'sitePolicies',
  'dnsProofState',
  'cacheHints',
]
for (const key of requiredBundleKeys) {
  if (!(key in generated)) {
    fail(`generated bundle missing key: ${key}`)
  }
}

if (generated.schemaVersion !== '1.0') fail('generated schemaVersion must be 1.0')
if (generated.version !== 'dm-resolver-bundle/1') fail('generated version must be dm-resolver-bundle/1')
if (generated.policyMode !== 'off') fail('generated policyMode must be off for baseline run')
if (generated.failOpen !== true) fail('generated failOpen must be true for baseline run')

const hostsCount = Object.keys(generated.hostPolicies || {}).length
if (hostsCount < 1) fail('generated hostPolicies is empty')

const fixtureRunnerPath = path.join(repoRoot, 'scripts/run-resolver-fixtures.lua')
const fixtureRun = spawnSync('lua', [fixtureRunnerPath], {
  stdio: 'pipe',
  encoding: 'utf8',
})
if (fixtureRun.error) {
  fail(`resolver fixture runner failed to start: ${fixtureRun.error.message}`)
}
if (fixtureRun.status !== 0) {
  const stderr = fixtureRun.stderr?.trim() || fixtureRun.stdout?.trim() || 'unknown error'
  fail(`resolver fixture checks failed: ${stderr}`)
}

console.log('PASS resolver pack sanity checks')
