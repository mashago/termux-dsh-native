#!/data/data/com.termux/files/usr/bin/bash
# dsh wrapper for Termux. Installed as ~/.local/bin/dsh.
set -euo pipefail

DSH_ROOT="${DSH_ROOT:-$HOME/.local/opt/dsh}"
NODE_BIN="$DSH_ROOT/node/bin/node"
DSH_BIN="$DSH_ROOT/work/node_modules/@deepseek-ai/dsh/lib/bin.js"
SHIM="$DSH_ROOT/lib/libdsh-termux-native-link.so"

[ -x "$NODE_BIN" ] || { echo "dsh: missing $NODE_BIN" >&2; exit 1; }
[ -r "$DSH_BIN" ] || { echo "dsh: missing $DSH_BIN" >&2; exit 1; }
[ -r "$SHIM" ] || { echo "dsh: missing $SHIM" >&2; exit 1; }

# Termux's bionic libtermux-exec preload must be cleared before any glibc
# binary starts.  Create the temp directory BEFORE exporting our glibc shim:
# mkdir is a bionic Termux binary, and a glibc .so in LD_PRELOAD would make
# the bionic loader fail to start it.  After the export, the only child this
# script starts is the glibc Node process itself.
export TMPDIR="${DSH_TMPDIR:-${DSH_HOME:-$HOME/.dsh}/cache/tmp}"
mkdir -p "$TMPDIR"

# Optional fixed web launch token.  Read it before the glibc shim export: cat
# is a bionic Termux binary and must not inherit the glibc LD_PRELOAD.
if [ -r "$DSH_ROOT/etc/web-token" ]; then
  DSH_WEB_TOKEN="$(cat "$DSH_ROOT/etc/web-token")"
  export DSH_WEB_TOKEN
fi

unset LD_PRELOAD
export LD_PRELOAD="$SHIM"

# Runtime temp is shared under the dsh home's cache tree, next to the other
# derived data dsh keeps there.  This deployment runs with danger-full-access,
# so no sandbox grant has to cover TMPDIR.

# URL vs local-file handoff is dispatched by dsh-open.
export BROWSER="$DSH_ROOT/bin/dsh-open"

# This kernel has no Landlock; dsh's workspace-write fails closed.  The user
# explicitly chose danger-full-access for this device.
export DSH_PERMISSION_MODE="${DSH_PERMISSION_MODE:-danger-full-access}"

exec "$NODE_BIN" "$DSH_BIN" "$@"