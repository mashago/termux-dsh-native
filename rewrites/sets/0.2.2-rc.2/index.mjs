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
    marker: 'dsh-termux-native-att-durability',
    apply(source, { at }) {
      const functionAnchor = 'async function syncDirectory(path) {'
      const functionStart = at(functionAnchor)
      const openAnchor = 'const handle = await open(path, constants.O_RDONLY);'
      const openIndex = at(openAnchor, functionStart)
      const nextFunction = source.indexOf('\nasync function ', functionStart + functionAnchor.length)
      if (nextFunction !== -1 && openIndex > nextFunction) {
        throw new Error('open() anchor is outside syncDirectory()')
      }
      const replacement = [
        '\tlet handle;',
        '\ttry {',
        '\t\thandle = await open(path, constants.O_RDONLY);',
        '\t} catch (error) {',
        '\t\t/* unreadable ancestors are the durability boundary */',
        '\t\tif (error?.code === "EACCES" || error?.code === "EPERM") return;',
        '\t\tthrow error;',
        '\t}',
      ].join('\n')
      return source.slice(0, openIndex) + replacement + source.slice(openIndex + openAnchor.length)
    },
  },
]