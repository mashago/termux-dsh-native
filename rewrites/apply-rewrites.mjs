// Versioned rewrite dispatcher for the Termux/Android dsh install.
//
// Usage: node apply-rewrites.mjs <dsh-runtime-root> [--dry-run|--check-only|--show-set] [--set <id>]
//
// The installed dsh version selects a set under sets/: a manifest's `versions`
// entry must match exactly. A set whose manifest declares `extends` resolves to
// another set's implementation (alias sets carry no code of their own). When no
// set matches, the run fails and lists the available sets; DSH_REWRITE_FALLBACK=1
// trials the set marked `default: true` and warns loudly.
//
// DSH_EXPECTED_VERSION remains an optional assertion for scripts. A successful
// apply records rewrites-state.json at the runtime root; --check-only warns when
// the state was written for another version or set.

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { fail, readJson, runRewrites } from './lib/common.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const args = process.argv.slice(2)

let root
let mode = 'apply'
let forcedSet
for (let index = 0; index < args.length; index += 1) {
  const arg = args[index]
  if (arg === '--dry-run') mode = 'dry-run'
  else if (arg === '--check-only') mode = 'check'
  else if (arg === '--show-set') mode = 'show-set'
  else if (arg === '--set') {
    forcedSet = args[index += 1]
    if (!forcedSet) fail('--set requires a set id')
  } else if (arg.startsWith('--')) fail(`unknown argument: ${arg}`)
  else if (root === undefined) root = arg
  else fail(`unexpected argument: ${arg}`)
}
root ??= process.env.DSH_ROOT
if (!root) {
  fail('usage: node apply-rewrites.mjs <dsh-runtime-root> [--dry-run|--check-only|--show-set] [--set <id>]')
}

const installed = readJson(path.join(root, 'work', 'node_modules', '@deepseek-ai', 'dsh', 'package.json')).version
const expected = process.env.DSH_EXPECTED_VERSION
if (expected !== undefined && expected !== '' && expected !== installed && process.env.DSH_ALLOW_VERSION !== '1') {
  fail(`dsh version is ${installed}, expected ${expected}; ` +
    'set DSH_ALLOW_VERSION=1 only after re-checking the rewrite anchors')
}

const setsDir = path.join(here, 'sets')
const sets = fs.readdirSync(setsDir, { withFileTypes: true })
  .filter(entry => entry.isDirectory())
  .map((entry) => {
    const dir = path.join(setsDir, entry.name)
    const manifestFile = path.join(dir, 'manifest.json')
    if (!fs.existsSync(manifestFile)) fail(`set ${entry.name} has no manifest.json`)
    const manifest = readJson(manifestFile)
    if (!Array.isArray(manifest.versions)) fail(`set ${entry.name}: manifest.versions must be an array`)
    return { id: entry.name, dir, manifest }
  })

function describe(sets) {
  return sets.map(set => `  ${set.id}${set.manifest.default === true ? ' (default)' : ''} ` +
    `[${set.manifest.versions.join(', ')}]`).join('\n')
}

let entry
if (forcedSet !== undefined) {
  entry = sets.find(set => set.id === forcedSet)
  if (entry === undefined) fail(`unknown set ${forcedSet}\navailable sets:\n${describe(sets)}`)
} else {
  entry = sets.find(set => set.manifest.versions.includes(installed))
  if (entry === undefined && process.env.DSH_REWRITE_FALLBACK === '1') {
    entry = sets.find(set => set.manifest.default === true)
    if (entry !== undefined) {
      console.error(`!! no exact rewrite set for dsh ${installed}; using default set ${entry.id}`)
    }
  }
  if (entry === undefined) {
    fail(`no rewrite set for dsh ${installed}\navailable sets:\n${describe(sets)}\n` +
      `add sets/${installed}/manifest.json (copy sets/0.2.2-rc.2/manifest.json as a template),\n` +
      'or set DSH_REWRITE_FALLBACK=1 to trial the default set')
  }
}

const chain = [entry.id]
let impl = entry
const seen = new Set(chain)
while (impl.manifest.extends !== undefined) {
  const next = sets.find(set => set.id === impl.manifest.extends)
  if (next === undefined) fail(`set ${impl.id} extends unknown set ${impl.manifest.extends}`)
  if (seen.has(next.id)) fail(`set extends cycle: ${[...chain, next.id].join(' -> ')}`)
  seen.add(next.id)
  chain.push(next.id)
  impl = next
}

const chainLabel = chain.join(' -> ')
console.log(`rewrite set: ${chainLabel} (dsh ${installed})`)
if (mode === 'show-set') process.exit(0)

const moduleFile = path.join(impl.dir, 'index.mjs')
if (!fs.existsSync(moduleFile)) fail(`set ${impl.id} has no index.mjs (an alias-only set must extend a set with one)`)
const { rewrites } = await import(pathToFileURL(moduleFile).href)
if (!Array.isArray(rewrites) || rewrites.length === 0) fail(`set ${impl.id} exports no rewrites`)

const ok = runRewrites({ root, version: installed, rewrites, mode })

if (mode === 'check') {
  const stateFile = path.join(root, 'rewrites-state.json')
  if (!fs.existsSync(stateFile)) {
    console.error('!! no rewrites-state.json (expected after a successful apply)')
  } else {
    const state = readJson(stateFile)
    if (state.version !== installed) {
      console.error(`!! rewrites-state.json was written for dsh ${state.version}; installed is ${installed}`)
    } else if (state.set !== entry.id) {
      console.error(`!! rewrites-state.json set is ${state.set}; resolved set is ${entry.id}`)
    }
  }
  process.exit(ok ? 0 : 1)
}

if (mode === 'apply') {
  fs.writeFileSync(path.join(root, 'rewrites-state.json'), `${JSON.stringify({
    version: installed,
    set: entry.id,
    extends: chain.slice(1),
    appliedAt: new Date().toISOString(),
  }, null, 2)}\n`)
}

console.log('rewrites complete')