# Rewrite set: 0.2.2-rc.2

Verified 2026-11-13 against the compiled lib output of
`@deepseek-ai/dsh@0.2.2-rc.2` (npm install, 669 packages).

| rewrite | target | anchor |
|---|---|---|
| `fixed-token` | `dsh-client-connection/lib/index.js` | `function processLaunchToken(owner) {` → `const created = encodeBase64Url(randomBytes(SECRET_BYTES));` |
| `att-durability` | `dsh-attachment-local/lib/index.js` | `async function syncDirectory(path) {` → `const handle = await open(path, constants.O_RDONLY);` |

Both rewrites are idempotent via their markers. If a later dsh version moves
either anchor, create a dedicated set for that version instead of widening this
one — see `../../README.md`.