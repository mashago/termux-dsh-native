#!/data/data/com.termux/files/usr/bin/bash
# termux-dsh-native: run the dsh CLI directly under the bundled glibc Node.
#
# The normal ~/.local/bin/dsh wrapper is fine for booting profiles. This helper
# runs dsh's bin.js with the link shim loaded, for one-shot CLI work such as
# `dsh-install plugin ...`. The shim constructor clears LD_PRELOAD for children.
# Installed as ~/.local/bin/dsh-install.
set -euo pipefail
DSH_ROOT="${DSH_ROOT:-$HOME/.local/opt/dsh}"
NODE_BIN="$DSH_ROOT/node/bin/node"
DSH_BIN="$DSH_ROOT/work/node_modules/@deepseek-ai/dsh/lib/bin.js"
SHIM="$DSH_ROOT/lib/libdsh-termux-native-link.so"
TMPDIR="${DSH_TMPDIR:-${DSH_HOME:-$HOME/.dsh}/cache/tmp}"
mkdir -p "$TMPDIR"
unset LD_PRELOAD
export PATH="$HOME/.local/bin:$DSH_ROOT/bin:$DSH_ROOT/node/bin:$PATH"
exec env LD_PRELOAD="$SHIM" TMPDIR="$TMPDIR" "$NODE_BIN" "$DSH_BIN" "$@"
