#!/data/data/com.termux/files/usr/bin/bash
# Apply the two dsh Android text rewrites using the patched glibc Node.
set -euo pipefail
ROOT="${DSH_ROOT:-$HOME/.local/opt/dsh}"
NODE="$ROOT/node/bin/node"
HERE="$(cd "$(dirname "$0")" && pwd)"
exec env -u LD_PRELOAD "$NODE" "$HERE/apply-rewrites.mjs" "$ROOT" "$@"