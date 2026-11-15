#!/data/data/com.termux/files/usr/bin/bash
# termux-dsh-native: pnpm shim for dsh profiles.
#
# - Pins the pnpm version dsh 0.2.2-rc.3 expects. Corepack's default is
#   pnpm 9.15.0, which rejects `pnpm add` in dsh's profile workspace with
#   ERR_PNPM_ADDING_TO_ROOT. Override with DSH_PNPM_VERSION.
# - Runs the bundled glibc Node with the link shim. The shim's constructor
#   clears LD_PRELOAD, so bionic children start clean.
# - Puts $DSH_ROOT/bin first so pnpm's npm pass-through finds the working npm
#   shim instead of Node's /usr/bin/env shebang.
# - If corepack has to download pnpm, it uses npm's default registry; set
#   COREPACK_NPM_REGISTRY (e.g. https://registry.npmmirror.com) to override.
# Installed as ~/.local/bin/pnpm.
set -euo pipefail
DSH_ROOT="${DSH_ROOT:-$HOME/.local/opt/dsh}"
NODE_BIN="$DSH_ROOT/node/bin/node"
SHIM="$DSH_ROOT/lib/libdsh-termux-native-link.so"
PNPM_VERSION="${DSH_PNPM_VERSION:-11.28.5}"
TMPDIR="${DSH_TMPDIR:-${DSH_HOME:-$HOME/.dsh}/cache/tmp}"
mkdir -p "$TMPDIR"
unset LD_PRELOAD
export PATH="$DSH_ROOT/bin:$DSH_ROOT/node/bin:$PATH"
export COREPACK_ENABLE_DOWNLOAD_PROMPT="${COREPACK_ENABLE_DOWNLOAD_PROMPT:-0}"
exec env LD_PRELOAD="$SHIM" TMPDIR="$TMPDIR" \
  "$NODE_BIN" \
  "$DSH_ROOT/node/lib/node_modules/corepack/dist/corepack.js" "pnpm@$PNPM_VERSION" "$@"
