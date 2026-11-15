#!/data/data/com.termux/files/usr/bin/bash
# Deploy the dsh runtime pieces after Node + npm install (plan Steps 1-3).
# Run from the termux-dsh-native project directory on the phone.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${DSH_ROOT:-$HOME/.local/opt/dsh}"
BIN="$HOME/.local/bin"

[ -x "$ROOT/node/bin/node" ] || { echo "!! missing Node at $ROOT/node/bin/node" >&2; exit 1; }
[ -f "$ROOT/work/node_modules/@deepseek-ai/dsh/package.json" ] || {
  echo "!! dsh is not installed in $ROOT/work" >&2
  exit 1
}

mkdir -p "$ROOT/bin" "$ROOT/lib" "$ROOT/tools" "$ROOT/etc" "$BIN"
chmod 700 "$ROOT/etc"

# Optional fixed web launch token.  Default: 12 random base64url characters.
# Set DSH_WEB_TOKEN explicitly to choose one (e.g. DSH_WEB_TOKEN=0123456789abcdef).
if [ ! -s "$ROOT/etc/web-token" ]; then
  TOKEN="${DSH_WEB_TOKEN:-$(head -c 9 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')}"
  printf '%s\n' "$TOKEN" > "$ROOT/etc/web-token"
  echo "created $ROOT/etc/web-token"
fi
chmod 600 "$ROOT/etc/web-token"

cp "$HERE/bin/dsh-wrapper.sh" "$ROOT/bin/dsh"
cp "$HERE/bin/dsh-open.sh" "$ROOT/bin/dsh-open"
cp "$HERE/bin/npm-wrapper.sh" "$ROOT/bin/npm"
cp "$HERE/bin/pnpm-wrapper.sh" "$BIN/pnpm"
cp "$HERE/bin/dsh-install.sh" "$BIN/dsh-install"
rm -f "$ROOT/lib/unset-ld-preload.cjs"
cp "$HERE/rewrites/apply-rewrites.sh" "$ROOT/tools/apply-rewrites.sh"
cp "$HERE/rewrites/apply-rewrites.mjs" "$ROOT/tools/apply-rewrites.mjs"
rm -rf "$ROOT/tools/lib" "$ROOT/tools/sets"
cp -R "$HERE/rewrites/lib" "$ROOT/tools/lib"
cp -R "$HERE/rewrites/sets" "$ROOT/tools/sets"
cp "$HERE/verify-install.sh" "$ROOT/tools/verify-install.sh"
cp "$HERE/start_dsh.sh" "$HOME/start_dsh.sh"
cp "$HERE/start_sshd.sh" "$HOME/start_sshd.sh"
chmod 755 "$ROOT/bin/dsh" "$ROOT/bin/dsh-open" "$ROOT/bin/npm" \
  "$BIN/pnpm" "$BIN/dsh-install" \
  "$ROOT/tools/apply-rewrites.sh" "$ROOT/tools/verify-install.sh" \
  "$HOME/start_dsh.sh" "$HOME/start_sshd.sh"
chmod 644 "$ROOT/tools/apply-rewrites.mjs"

ln -sfn "$ROOT/bin/dsh" "$BIN/dsh"

if ! printf '%s' ":$PATH:" | grep -q ":$BIN:"; then
  if ! grep -q '# dsh-termux-native' "$HOME/.bashrc" 2>/dev/null; then
    printf '\nexport PATH="$HOME/.local/bin:$PATH"   # dsh-termux-native\n' >> "$HOME/.bashrc"
    echo "added $BIN to PATH in ~/.bashrc"
  fi
fi

bash "$ROOT/tools/apply-rewrites.sh"
bash "$ROOT/tools/verify-install.sh"