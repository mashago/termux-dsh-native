#!/data/data/com.termux/files/usr/bin/bash
# termux-dsh-native: npm shim for the bundled dsh runtime.
#
# Node's official tarball ships bin/npm as a symlink to npm-cli.js, whose
# shebang is "#!/usr/bin/env node". Android has no /usr/bin/env, so pnpm's
# `view` pass-through (spawnSync npm) fails with ENOENT. Invoke the bundled
# node explicitly instead. Installed as $DSH_ROOT/bin/npm.
set -euo pipefail
DSH_ROOT="${DSH_ROOT:-$HOME/.local/opt/dsh}"
exec "$DSH_ROOT/node/bin/node" "$DSH_ROOT/node/lib/node_modules/npm/bin/npm-cli.js" "$@"
