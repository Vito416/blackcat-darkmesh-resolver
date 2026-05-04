import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { basename, join } from 'node:path'

const TARGETS = {
  resolver: {
    module: 'ao.resolver.process',
    file: 'ao/resolver/process.lua',
    out: 'dist/resolver-bundle.lua'
  }
}

function parseArgs(argv) {
  const requested = new Set()
  let all = false
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i]
    if (arg === '--all') {
      all = true
      continue
    }
    if (arg === '--target') {
      const value = String(argv[i + 1] || '').trim()
      if (!value) throw new Error('--target requires value')
      i += 1
      value
        .split(',')
        .map((part) => part.trim())
        .filter(Boolean)
        .forEach((part) => requested.add(part))
      continue
    }
    if (arg === '-h' || arg === '--help') {
      printHelp()
      process.exit(0)
    }
    throw new Error(`Unknown arg: ${arg}`)
  }
  if (all || requested.size === 0) {
    return Object.keys(TARGETS)
  }
  return [...requested]
}

function printHelp() {
  console.log('Usage:')
  console.log('  node scripts/build-ao-bundles.mjs --all')
  console.log('  node scripts/build-ao-bundles.mjs --target resolver')
}

function listLuaFiles(dir) {
  return readdirSync(dir)
    .filter((name) => name.endsWith('.lua'))
    .sort()
    .map((name) => join(dir, name))
}

function read(path) {
  return readFileSync(path, 'utf8')
}

function longBracket(source) {
  for (let count = 4; count <= 12; count += 1) {
    const eq = '='.repeat(count)
    const open = `[${eq}[`
    const close = `]${eq}]`
    if (!source.includes(close)) {
      return { open, close }
    }
  }
  throw new Error('Could not find safe Lua long-bracket delimiter for source block')
}

function preloadChunk(name, source) {
  const { open, close } = longBracket(source)
  return `
package.preload["${name}"] = function()
  local loaded, err = load(${open}${source}${close}, "${name}")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end
`
}

function moduleNameForShared(path) {
  return `ao.shared.${basename(path, '.lua')}`
}

function buildTarget(targetName) {
  const target = TARGETS[targetName]
  if (!target) {
    throw new Error(`Unknown target "${targetName}". Allowed: ${Object.keys(TARGETS).join(', ')}`)
  }

  const sharedFiles = listLuaFiles('ao/shared')
  const modules = []

  if (existsSync('ao/templates.lua')) {
    modules.push({ module: 'templates', source: read('ao/templates.lua') })
  }

  for (const file of sharedFiles) {
    modules.push({ module: moduleNameForShared(file), source: read(file) })
  }

  modules.push({ module: target.module, source: read(target.file) })

  const chunks = modules.map((entry) => preloadChunk(entry.module, entry.source))
  const output = `-- bundled AO process (${targetName})\n${chunks.join('\n')}\nreturn require("${target.module}")\n`

  mkdirSync('dist', { recursive: true })
  writeFileSync(target.out, output, 'utf8')
  return { target: targetName, out: target.out, bytes: output.length, modules: modules.length }
}

function main() {
  const targets = parseArgs(process.argv)
  const built = targets.map(buildTarget)
  for (const row of built) {
    console.log(`Bundled ${row.target} -> ${row.out} bytes=${row.bytes} modules=${row.modules}`)
  }
}

main()
