#!/data/data/com.termux/files/usr/bin/bash
# Post-install checks for the termux-dsh-native runtime.
set -uo pipefail

ROOT="${DSH_ROOT:-$HOME/.local/opt/dsh}"
NODE="$ROOT/node/bin/node"
DSH="$ROOT/work/node_modules/@deepseek-ai/dsh"
SHIM="$ROOT/lib/libdsh-termux-native-link.so"
FAIL=0

check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS $name"
  else
    echo "FAIL $name"
    FAIL=$((FAIL + 1))
  fi
}

check "node binary" test -x "$NODE"
check "dsh package" test -f "$DSH/package.json"
check "dsh web frontend dist" test -f "$ROOT/work/node_modules/@deepseek-ai/dsh-web-frontend/dist/index.html"
check "node-pty prebuild" test -f "$ROOT/work/node_modules/node-pty/prebuilds/linux-arm64/pty.node"
check "flock addon" test -f "$ROOT/work/node_modules/@deepseek-ai/node-addon-system-linux-arm64/bin/glibc/system.node"
check "ripgrep prebuild" test -x "$ROOT/work/node_modules/@vscode/ripgrep-linux-arm64/bin/rg"
check "sharp prebuild" test -f "$ROOT/work/node_modules/@img/sharp-linux-arm64/lib/sharp-linux-arm64-0.35.5.node"
check "link shim" test -r "$SHIM"
check "wrapper" test -x "$HOME/.local/bin/dsh"
check "browser opener" test -x "$ROOT/bin/dsh-open"
check "npm shim" test -x "$ROOT/bin/npm"
check "pnpm wrapper" test -x "$HOME/.local/bin/pnpm"
check "dsh-install wrapper" test -x "$HOME/.local/bin/dsh-install"
check "unset-ld-preload preload" test -f "$ROOT/lib/unset-ld-preload.cjs"

if [ -x "$NODE" ]; then
  echo "INFO node: $(env -u LD_PRELOAD "$NODE" --version 2>&1)"
  echo "INFO glibc: $(env -u LD_PRELOAD "$NODE" -e 'console.log(process.report.getReport().header.glibcVersionRuntime)' 2>&1)"
fi

if [ -x "$ROOT/bin/npm" ]; then
  check "npm shim --version" env -u LD_PRELOAD "$ROOT/bin/npm" --version
fi

if [ -f "$DSH/package.json" ]; then
  echo "INFO dsh: $(env -u LD_PRELOAD "$NODE" -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).version)' "$DSH/package.json" 2>&1)"
  echo "INFO $(env -u LD_PRELOAD "$NODE" "$ROOT/tools/apply-rewrites.mjs" "$ROOT" --show-set 2>&1 | head -1)"
fi

check "rewrite markers" env -u LD_PRELOAD "$NODE" "$ROOT/tools/apply-rewrites.mjs" "$ROOT" --check-only
check "web token file" test -s "$ROOT/etc/web-token"

if [ -x "$NODE" ] && [ -f "$DSH/lib/bin.js" ]; then
  check "dsh --version (direct)" env -u LD_PRELOAD "$NODE" "$DSH/lib/bin.js" --version
fi

if [ -x "$HOME/.local/bin/dsh" ]; then
  check "dsh --version (wrapper)" "$HOME/.local/bin/dsh" --version
fi

echo "SUMMARY failures=$FAIL"
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"