#!/usr/bin/env bash
# Build a GitHub release payload for the Termux-native dsh runtime.
#
#   ./make-release.sh --project v0.3.0 --tested-dsh 0.2.2-rc.3
#
# Output in release/:
#   install.sh
#   update.sh
#   dsh-termux-runtime.tar.gz
#   SHA256SUMS
#
# The payload carries every rewrite set, the prebuilt link shim, and the
# installer core. Run this on a Mac/Linux host, not on the phone.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT=""
TESTED=""
NODE_VERSION="24.19.0"
SO="$HERE/dist/libdsh-termux-native-link.so"
OUT="$HERE/release"

die() { printf '!! %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift ;;
    --tested-dsh) TESTED="${2:-}"; shift ;;
    --node) NODE_VERSION="${2:-}"; shift ;;
    --so) SO="${2:-}"; shift ;;
    --out) OUT="${2:-}"; shift ;;
    -h|--help)
      sed -n '2,12p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

[ -n "$PROJECT" ] || die "--project is required (e.g. v0.3.0)"
[ -n "$TESTED" ] || die "--tested-dsh is required (the dsh version verified for this release)"
[ -f "$SO" ] || die "link shim not found: $SO (build it on the phone and copy it to dist/)"

SETS="$HERE/rewrites/sets"
[ -d "$SETS" ] || die "missing rewrite sets: $SETS"

chain_check() {
  node - "$SETS" <<'NODE'
const fs = require('node:fs')
const path = require('node:path')
const setsDir = process.argv[2]
const sets = new Map()
for (const name of fs.readdirSync(setsDir)) {
  const file = path.join(setsDir, name, 'manifest.json')
  if (!fs.existsSync(file)) continue
  const manifest = JSON.parse(fs.readFileSync(file, 'utf8'))
  if (!Array.isArray(manifest.versions) || manifest.versions.length === 0) {
    throw new Error(`set ${name}: manifest.versions must be a non-empty array`)
  }
  sets.set(name, manifest)
}
if (sets.size === 0) throw new Error('no rewrite sets found')
for (const [name, manifest] of sets) {
  let current = name
  const seen = new Set([name])
  while (sets.get(current).extends !== undefined) {
    const next = sets.get(current).extends
    if (!sets.has(next)) throw new Error(`set ${name}: extends unknown set ${next}`)
    if (seen.has(next)) throw new Error(`set ${name}: extends cycle at ${next}`)
    seen.add(next)
    current = next
  }
  if (!fs.existsSync(path.join(setsDir, current, 'index.mjs'))) {
    throw new Error(`set ${name}: resolved set ${current} has no index.mjs`)
  }
}
const versions = [...new Set([...sets.values()].flatMap(manifest => manifest.versions))].sort()
console.log(versions.join(' '))
NODE
}

SUPPORTED="$(chain_check)" || die "rewrite set validation failed"
printf '%s\n' $SUPPORTED | grep -qxF "$TESTED" \
  || die "tested dsh $TESTED is not covered by any set (supported: $SUPPORTED)"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/dsh-release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/bin" "$STAGE/rewrites" "$STAGE/dist"
cp "$HERE/install-core.sh" "$STAGE/install-core.sh"
cp "$HERE/bin/dsh-wrapper.sh" "$STAGE/bin/dsh-wrapper.sh"
cp "$HERE/bin/dsh-open.sh" "$STAGE/bin/dsh-open.sh"
cp "$HERE/rewrites/apply-rewrites.sh" "$STAGE/rewrites/apply-rewrites.sh"
cp "$HERE/rewrites/apply-rewrites.mjs" "$STAGE/rewrites/apply-rewrites.mjs"
cp -R "$HERE/rewrites/lib" "$STAGE/rewrites/lib"
cp -R "$HERE/rewrites/sets" "$STAGE/rewrites/sets"
cp "$HERE/start_dsh.sh" "$STAGE/start_dsh.sh"
cp "$HERE/start_sshd.sh" "$STAGE/start_sshd.sh"
cp "$HERE/verify-install.sh" "$STAGE/verify-install.sh"
[ -f "$HERE/smoke-web.sh" ] && cp "$HERE/smoke-web.sh" "$STAGE/smoke-web.sh"
cp "$SO" "$STAGE/dist/libdsh-termux-native-link.so"

cat > "$STAGE/release-manifest.sh" <<EOF
PROJECT_VERSION="$PROJECT"
TESTED_DSH="$TESTED"
SUPPORTED_DSH="$SUPPORTED"
NODE_VERSION="$NODE_VERSION"
EOF

chmod 755 "$STAGE/install-core.sh" "$STAGE/start_dsh.sh" "$STAGE/start_sshd.sh" \
  "$STAGE/verify-install.sh" "$STAGE/rewrites/apply-rewrites.sh" \
  "$STAGE/bin/dsh-wrapper.sh" "$STAGE/bin/dsh-open.sh"
chmod 644 "$STAGE/rewrites/apply-rewrites.mjs" "$STAGE/dist/libdsh-termux-native-link.so"
[ -f "$STAGE/smoke-web.sh" ] && chmod 755 "$STAGE/smoke-web.sh"

mkdir -p "$OUT"
tar -C "$STAGE" -czf "$OUT/dsh-termux-runtime.tar.gz" .
cp "$HERE/install.sh" "$OUT/install.sh"
cp "$HERE/update.sh" "$OUT/update.sh"
chmod 755 "$OUT/install.sh" "$OUT/update.sh"

if command -v sha256sum >/dev/null 2>&1; then
  ( cd "$OUT" && sha256sum install.sh update.sh dsh-termux-runtime.tar.gz > SHA256SUMS )
else
  ( cd "$OUT" && shasum -a 256 install.sh update.sh dsh-termux-runtime.tar.gz > SHA256SUMS )
fi

printf 'release:   %s\n' "$PROJECT"
printf 'dsh:       tested=%s supported=%s\n' "$TESTED" "$SUPPORTED"
printf 'node:      %s\n' "$NODE_VERSION"
printf 'payload:   %s/dsh-termux-runtime.tar.gz\n' "$OUT"
printf 'checksums: %s/SHA256SUMS\n' "$OUT"
printf '\npublish with:\n'
printf '  gh release create %s --title "%s" %s/*\n' "$PROJECT" "$PROJECT" "$OUT"