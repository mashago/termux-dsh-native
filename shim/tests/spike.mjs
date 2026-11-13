// Spike: verify the Termux/Android link() shim's observable semantics.
// Runs on-device under the glibc Node built for the dsh runtime.
// SPIKE_EXPECT=fail runs only the "real link is denied" control case.

import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'

const root = fs.mkdtempSync(path.join(process.env.HOME, '.dsh-termux-native-spike-'))
const expectFail = process.env.SPIKE_EXPECT === 'fail'
let failures = 0
let checks = 0

function assert(condition, message) {
  if (!condition) throw new Error(message)
}

function errnoOf(fn) {
  try {
    fn()
    return null
  } catch (error) {
    return error?.code ?? String(error)
  }
}

function check(name, fn) {
  checks += 1
  try {
    fn()
    console.log(`PASS ${name}`)
  } catch (error) {
    failures += 1
    console.log(`FAIL ${name}: ${error?.stack ?? error}`)
  }
}

function sourceFile(name, contents, mode = 0o640) {
  const file = path.join(root, name)
  fs.writeFileSync(file, contents)
  fs.chmodSync(file, mode)
  return file
}

function sample(file, offset, length) {
  const fd = fs.openSync(file, 'r')
  try {
    const buffer = Buffer.alloc(length)
    const read = fs.readSync(fd, buffer, 0, length, offset)
    return buffer.subarray(0, read)
  } finally {
    fs.closeSync(fd)
  }
}

function cleanup() {
  try {
    fs.rmSync(root, { recursive: true, force: true })
  } catch (error) {
    console.log(`WARN cleanup failed: ${error?.message ?? error}`)
  }
}

async function main() {
  console.log(`root=${root}`)
  console.log(`expect=${expectFail ? 'fail' : 'ok'}`)
  console.log(`ld_preload=${JSON.stringify(process.env.LD_PRELOAD ?? null)}`)

  const src = sourceFile('source', 'hello shim')
  const dst = path.join(root, 'target')

  if (expectFail) {
    check('plain link is denied without the shim', () => {
      const code = errnoOf(() => fs.linkSync(src, dst))
      assert(code === 'EACCES', `expected EACCES, got ${code}`)
      assert(!fs.existsSync(dst), 'target must not exist after denied link')
    })
    console.log(`SUMMARY checks=${checks} failures=${failures}`)
    cleanup()
    process.exitCode = failures === 0 ? 0 : 1
    return
  }

  check('link succeeds with the shim', () => {
    fs.linkSync(src, dst)
    assert(fs.existsSync(src), 'source must remain')
    assert(fs.existsSync(dst), 'target must exist')
  })

  check('target is a copy, not a hard link', () => {
    const a = fs.statSync(src)
    const b = fs.statSync(dst)
    assert(a.ino !== b.ino, `inode must differ (source=${a.ino}, target=${b.ino})`)
    assert(a.dev === b.dev, 'device must match')
  })

  check('content and mode are preserved', () => {
    assert(fs.readFileSync(dst, 'utf8') === 'hello shim', 'content mismatch')
    const mode = fs.statSync(dst).mode & 0o777
    assert(mode === 0o640, `mode mismatch: 0o${mode.toString(8)}`)
  })

  check('existing target yields EEXIST', () => {
    const code = errnoOf(() => fs.linkSync(src, dst))
    assert(code === 'EEXIST', `expected EEXIST, got ${code}`)
  })

  check('directory source yields EPERM', () => {
    const dir = path.join(root, 'a-directory')
    fs.mkdirSync(dir)
    const code = errnoOf(() => fs.linkSync(dir, path.join(root, 'dir-link')))
    assert(code === 'EPERM', `expected EPERM, got ${code}`)
  })

  check('symlink source remains a symlink', () => {
    const sym = path.join(root, 'sym-source')
    const symDst = path.join(root, 'sym-target')
    fs.symlinkSync('hello shim', sym)
    fs.linkSync(sym, symDst)
    assert(fs.lstatSync(symDst).isSymbolicLink(), 'target must be a symlink')
    assert(fs.readlinkSync(symDst) === 'hello shim', 'symlink target text mismatch')
  })

  check('concurrent link yields one success and one EEXIST', async () => {
    const race = path.join(root, 'race-target')
    const results = await Promise.allSettled([
      fs.promises.link(src, race),
      fs.promises.link(src, race),
    ])
    const ok = results.filter(result => result.status === 'fulfilled').length
    const eexist = results.filter(
      result => result.status === 'rejected' && result.reason?.code === 'EEXIST',
    ).length
    assert(ok === 1, `expected one success, got ${ok}`)
    assert(eexist === 1, `expected one EEXIST, got ${eexist}`)
  })

  check('large file copy', () => {
    const mb = Number(process.env.SPIKE_LARGE_MB ?? '50')
    const size = mb * 1024 * 1024
    const big = sourceFile('big-source', Buffer.alloc(0), 0o600)
    const fd = fs.openSync(big, 'w')
    try {
      const chunk = Buffer.alloc(1024 * 1024, 0x61)
      for (let i = 0; i < mb; i += 1) fs.writeSync(fd, chunk)
      fs.fsyncSync(fd)
    } finally {
      fs.closeSync(fd)
    }
    const bigDst = path.join(root, 'big-target')
    const started = process.hrtime.bigint()
    fs.linkSync(big, bigDst)
    const elapsedMs = Number(process.hrtime.bigint() - started) / 1e6
    assert(fs.statSync(bigDst).size === size, 'large target size mismatch')
    assert(sample(bigDst, 0, 16).equals(sample(big, 0, 16)), 'large head mismatch')
    assert(
      sample(bigDst, size - 16, 16).equals(sample(big, size - 16, 16)),
      'large tail mismatch',
    )
    console.log(`INFO large=${mb}MB elapsed_ms=${elapsedMs.toFixed(1)}`)
  })

  check('bionic child starts without LD_PRELOAD', () => {
    const shell = path.join(process.env.PREFIX ?? '/data/data/com.termux/files/usr', 'bin', 'bash')
    const output = execFileSync(shell, [
      '-c',
      'echo CHILD_OK; printf "child_LD_PRELOAD=%s\\n" "${LD_PRELOAD-unset}"',
    ], { encoding: 'utf8' })
    assert(output.includes('CHILD_OK'), `bash did not start: ${output}`)
    assert(
      output.includes('child_LD_PRELOAD=unset') || output.includes('child_LD_PRELOAD=\n'),
      `child inherited LD_PRELOAD: ${output}`,
    )
  })

  console.log(`SUMMARY checks=${checks} failures=${failures}`)
  cleanup()
  process.exitCode = failures === 0 ? 0 : 1
}

main().catch((error) => {
  console.log(`FATAL ${error?.stack ?? error}`)
  cleanup()
  process.exitCode = 1
})