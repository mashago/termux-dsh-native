// Shared mechanics for the versioned Termux/Android text rewrites.
//
// A rewrite set (sets/<id>/index.mjs) exports `rewrites`, an array of
//   { id, file, marker, apply(source, { at }) }
// where `file` is relative to work/node_modules/@deepseek-ai. Sets carry only
// anchors and transforms; marker idempotency, backups, atomic writes, and
// syntax checks live here so every version behaves the same.

import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'

/** Print a loud failure and exit non-zero. */
export function fail(message) {
  console.error(`!! ${message}`)
  process.exit(1)
}

/** Read and parse one JSON file. */
export function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'))
}

/** Index of `needle` at or after `from`, throwing when the anchor drifted. */
export function anchorIndex(source, needle, from = 0) {
  const index = source.indexOf(needle, from)
  if (index === -1) throw new Error(`anchor not found: ${needle}`)
  return index
}

/** Verify that a rewritten file is still valid JavaScript. */
export function checkSyntax(file) {
  try {
    execFileSync(process.execPath, ['--check', file], { stdio: 'pipe' })
  } catch (error) {
    throw new Error(`rewritten file is not valid JS: ${file}\n${error.stderr?.toString() ?? error}`)
  }
}

/** Per-run backup writer under backups/rewrites/<version>/<stamp>/. */
function backupFactory(root, modules, version) {
  const stamp = new Date().toISOString().replace(/[:.]/g, '-')
  const backupRoot = path.join(root, 'backups', 'rewrites', version, stamp)
  return (file) => {
    const relative = path.relative(modules, file)
    const target = path.join(backupRoot, relative)
    fs.mkdirSync(path.dirname(target), { recursive: true })
    fs.copyFileSync(file, target)
    return target
  }
}

/**
 * Run one rewrite set.
 * @param options.mode - 'apply' | 'dry-run' | 'check'
 * @returns for 'check', true when every marker is present; true otherwise.
 */
export function runRewrites({ root, version, rewrites, mode }) {
  const modules = path.join(root, 'work', 'node_modules', '@deepseek-ai')
  const backup = backupFactory(root, modules, version)
  let checkOk = true

  for (const rewrite of rewrites) {
    const file = path.join(modules, rewrite.file)
    if (!fs.existsSync(file)) fail(`missing target file: ${file}`)
    const source = fs.readFileSync(file, 'utf8')
    const relative = path.relative(root, file)
    const hasMarker = source.includes(rewrite.marker)

    if (mode === 'check') {
      if (!hasMarker) checkOk = false
      console.log(`${hasMarker ? 'PASS' : 'FAIL'} ${rewrite.id} marker (${relative})`)
      continue
    }

    if (hasMarker) {
      console.log(`skip ${relative} (${rewrite.marker})`)
      continue
    }

    let output
    try {
      output = rewrite.apply(source, { at: (needle, from) => anchorIndex(source, needle, from) })
    } catch (error) {
      fail(`${rewrite.id}: ${error.message} (${relative})`)
    }
    if (output === source) fail(`${rewrite.id}: rewrite produced no change (${relative})`)

    if (mode === 'dry-run') {
      console.log(`would rewrite ${relative} (${rewrite.id})`)
      continue
    }

    const saved = backup(file)
    const temporary = `${file}.dsh-termux-native.tmp`
    fs.writeFileSync(temporary, `${output}\n/* ${rewrite.marker} */\n`)
    fs.renameSync(temporary, file)
    try {
      checkSyntax(file)
    } catch (error) {
      fs.copyFileSync(saved, file)
      fail(`${error.message}\nrestored backup: ${path.relative(root, saved)}`)
    }
    console.log(`rewrote ${relative} (${rewrite.id}; backup: ${path.relative(root, saved)})`)
  }

  return checkOk
}