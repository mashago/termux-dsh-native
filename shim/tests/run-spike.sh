#!/data/data/com.termux/files/usr/bin/bash
# Step 0 spike runner. Runs entirely under a dedicated temporary directory.
# Expects libdsh-termux-native-link.so and spike.mjs beside this script.
set -euo pipefail

D="${SPIKE_DIR:-$HOME/.dsh-termux-native-spike-2026-11-13}"
NODE_VERSION="${NODE_VERSION:-24.19.0}"
NODE_TARBALL="node-v${NODE_VERSION}-linux-arm64"
LOADER="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
for candidate in "${PATCHELF:-}" "$PREFIX/bin/patchelf" "$PREFIX/glibc/bin/patchelf"; do
  [ -n "$candidate" ] || continue
  if [ -x "$candidate" ]; then PATCHELF="$candidate"; break; fi
done
[ -x "${PATCHELF:-}" ] || { echo "!! missing patchelf (pkg install -y patchelf)" >&2; exit 1; }
SHIM="$D/libdsh-termux-native-link.so"
SPIKE="$D/spike.mjs"

mkdir -p "$D"
cd "$D"

echo "== spike directory: $D"
echo "== PREFIX=$PREFIX"
echo "== initial LD_PRELOAD=${LD_PRELOAD:-<unset>}"

if [ ! -x "$D/$NODE_TARBALL/bin/node" ]; then
  echo "== downloading Node $NODE_VERSION (linux-arm64)"
  curl -fsSL -o "$D/node.tar.xz" \
    "https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TARBALL}.tar.xz"
  tar xJf "$D/node.tar.xz" -C "$D"
  rm -f "$D/node.tar.xz"
fi

NODE_BIN="$D/$NODE_TARBALL/bin/node"
if [ ! -x "$D/node-patched" ]; then
  cp "$NODE_BIN" "$D/node-patched"
  chmod +x "$D/node-patched"
  env -u LD_PRELOAD "$PATCHELF" --set-interpreter "$LOADER" "$D/node-patched"
fi

echo "== node: $(env -u LD_PRELOAD "$D/node-patched" --version)"
echo "== glibc: $(env -u LD_PRELOAD "$D/node-patched" -e 'console.log(process.report.getReport().header.glibcVersionRuntime)')"

test -f "$SHIM" || { echo "!! missing $SHIM" >&2; exit 1; }
test -f "$SPIKE" || { echo "!! missing $SPIKE" >&2; exit 1; }

set +e
echo "== control run (no shim; expects EACCES)"
env -u LD_PRELOAD SPIKE_EXPECT=fail "$D/node-patched" "$SPIKE" >"$D/control.log" 2>&1
CONTROL_STATUS=$?

echo "== shim run"
env -u LD_PRELOAD \
  LD_PRELOAD="$SHIM" \
  DSH_LINK_SHIM_DEBUG=1 \
  SPIKE_LARGE_MB="${SPIKE_LARGE_MB:-50}" \
  "$D/node-patched" "$SPIKE" >"$D/shim.log" 2>&1
SHIM_STATUS=$?
set -e

echo
echo "== control.log =="
cat "$D/control.log"
echo
echo "== shim.log =="
cat "$D/shim.log"
echo
echo "== status: control=$CONTROL_STATUS shim=$SHIM_STATUS"
if [ "$CONTROL_STATUS" -eq 0 ] && [ "$SHIM_STATUS" -eq 0 ]; then
  echo "== SPIKE PASS"
else
  echo "== SPIKE FAIL"
fi
echo "== logs kept in $D (delete after inspection)"