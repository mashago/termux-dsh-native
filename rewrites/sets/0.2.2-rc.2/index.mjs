// Rewrites for @deepseek-ai/dsh 0.2.2-rc.2 compiled lib output.
//
// The runner appends the marker comment after each successful transform, so
// `apply` only returns the rewritten source.

export const rewrites = [
  {
    id: 'fixed-token',
    file: 'dsh-client-connection/lib/index.js',
    marker: 'dsh-termux-native-fixed-token',
    apply(source, { at }) {
      const functionAnchor = 'function processLaunchToken(owner) {'
      const functionStart = at(functionAnchor)
      const randomAnchor = 'const created = encodeBase64Url(randomBytes(SECRET_BYTES));'
      const randomIndex = at(randomAnchor, functionStart)
      const nextFunction = source.indexOf('\nfunction ', functionStart + functionAnchor.length)
      if (nextFunction !== -1 && randomIndex > nextFunction) {
        throw new Error('random-token anchor is outside processLaunchToken()')
      }
      const replacement = [
        'const configured = process.env.DSH_WEB_TOKEN;',
        'const created = configured !== void 0 && configured !== ""',
        '\t? configured',
        '\t: encodeBase64Url(randomBytes(SECRET_BYTES));',
      ].join('\n\t')
      return source.slice(0, randomIndex) + replacement + source.slice(randomIndex + randomAnchor.length)
    },
  },
  {
    id: 'att-durability',
    file: 'dsh-attachment-local/lib/index.js',
    marker: 'dsh-termux-native-att-durability-v2',
    apply(source, { at }) {
      const functionAnchor = 'async function syncDirectory(path) {'
      const functionStart = at(functionAnchor)
      const nextFunction = source.indexOf('\nasync function ', functionStart + functionAnchor.length)
      const inFunction = (index, label) => {
        if (nextFunction !== -1 && index > nextFunction) {
          throw new Error(`${label} anchor is outside syncDirectory()`)
        }
      }
      const skip = 'error?.code === "EACCES" || error?.code === "EPERM" || error?.code === "EINVAL" || error?.code === "ENOTSUP" || error?.code === "EOPNOTSUPP" || error?.code === "ENOSYS"'
      const openAnchor = 'const handle = await open(path, constants.O_RDONLY);'
      const openBody = [
        'let handle;',
        '\ttry {',
        '\t\thandle = await open(path, constants.O_RDONLY);',
        '\t} catch (error) {',
        '\t\t/* unreadable or unsupported ancestors are the durability boundary */',
        `\t\tif (${skip}) return;`,
        '\t\tthrow error;',
        '\t}',
      ].join('\n')
      const legacyOpen = [
        '\tlet handle;',
        '\ttry {',
        '\t\thandle = await open(path, constants.O_RDONLY);',
        '\t} catch (error) {',
        '\t\t/* unreadable ancestors are the durability boundary */',
        '\t\tif (error?.code === "EACCES" || error?.code === "EPERM") return;',
        '\t\tthrow error;',
        '\t}',
      ].join('\n')
      const syncAnchor = [
        '\ttry {',
        '\t\tawait handle.sync();',
        '\t} finally {',
        '\t\tawait handle.close();',
        '\t}',
      ].join('\n')

      const syncIndex = at(syncAnchor, functionStart)
      inFunction(syncIndex, 'sync()')
      // Replace the later anchor first so the earlier open() replacement does
      // not shift this index.
      let output = source.slice(0, syncIndex) + [
        '\ttry {',
        '\t\ttry {',
        '\t\t\tawait handle.sync();',
        '\t\t} catch (error) {',
        '\t\t\t/* mounts that cannot fsync a directory have nothing to persist */',
        `\t\t\tif (${skip}) return;`,
        '\t\t\tthrow error;',
        '\t\t}',
        '\t} finally {',
        '\t\tawait handle.close();',
        '\t}',
      ].join('\n') + source.slice(syncIndex + syncAnchor.length)

      // Fresh files still have the direct open() binding; files upgraded from
      // the first rewrite carry the older guarded block instead. Upgrade both
      // to the same guarded form with the wider errno list.
      const openIndex = output.indexOf(openAnchor, functionStart)
      if (openIndex !== -1) {
        inFunction(openIndex, 'open()')
        output = output.slice(0, openIndex) + openBody + output.slice(openIndex + openAnchor.length)
      } else {
        const legacyIndex = output.indexOf(legacyOpen, functionStart)
        if (legacyIndex !== -1) {
          inFunction(legacyIndex, 'legacy open()')
          output = output.slice(0, legacyIndex) + openBody + output.slice(legacyIndex + legacyOpen.length)
        }
      }

      // Files upgraded from the first rewrite keep its trailing marker; leave a
      // single marker for the runner to append.
      return output.replace(/\n\/\* dsh-termux-native-att-durability \*\/\s*$/, '\n')
    },
  },
]