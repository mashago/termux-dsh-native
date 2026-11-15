# Rewrite set: 0.2.2-rc.2

Verified 2026-11-13 against the compiled lib output of
`@deepseek-ai/dsh@0.2.2-rc.2` (npm install, 669 packages); the two anchored
functions are byte-identical in `0.2.2-rc.3`, so that release uses an alias set.

| rewrite | target | anchor |
|---|---|---|
| `fixed-token` | `dsh-client-connection/lib/index.js` | `function processLaunchToken(owner) {` → `const created = encodeBase64Url(randomBytes(SECRET_BYTES));` |
| `att-durability` | `dsh-attachment-local/lib/index.js` | `async function syncDirectory(path) {` → `const handle = await open(path, constants.O_RDONLY);` → the `try { await handle.sync(); … }` block |

`att-durability` v2 (verified 2026-11-15):

- `open()` skips ancestors that fail with `EACCES`, `EPERM`, `EINVAL`,
  `ENOTSUP`, `EOPNOTSUPP`, or `ENOSYS` — Android cannot open `/data/data`.
- `handle.sync()` skips the same errnos — read-only mounts can open the
  directory but reject fsync with `EINVAL` (e.g. `/` and `/system` on some
  Android kernels).
- Marker: `dsh-termux-native-att-durability-v2`. A file still carrying the
  first rewrite's `dsh-termux-native-att-durability` marker is upgraded in
  place: the transform wraps the existing `handle.sync()` and widens the open
  guard, then drops the old trailing marker.

The skip is unconditional for the errnos above; on Android the ancestors in
question are non-writable (0711), so there is no entry of ours to persist there. A
general upstream fix should additionally require that the process lacks write
access, preserving durability for writable-but-unreadable (0333) directories.

Both rewrites are idempotent via their markers. If a later dsh version moves
either anchor, create a dedicated set for that version instead of widening this
one — see `../../README.md`.