#!/data/data/com.termux/files/usr/bin/bash
# Bootstrap installer for the Termux-native dsh runtime.
#
#   curl -fsSL <release>/install.sh | bash -s -- -y
#   git clone <repo> && cd <repo> && bash install.sh -y
#
# In a checkout it runs install-core.sh from this directory. Otherwise it
# downloads the runtime payload attached to the GitHub release, verifies
# SHA256SUMS, and runs the packaged core.

set -uo pipefail

ACTION="install"
REPO="${TERMUX_DSH_REPO:-mashago/termux-dsh-native}"
TAG="${TERMUX_DSH_RELEASE:-latest}"
PASS=()

log() { printf '%s\n' "$*"; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: install.sh [options]
  -y, --yes             non-interactive
  --check               print current versions and supported dsh versions
  --uninstall           remove the runtime and service (~/.dsh is kept)
  --release <tag>       runtime release to use (default: latest)
  --repo <owner/repo>   GitHub repository (or set TERMUX_DSH_REPO)
  --dsh-version <v>     target dsh version (default: the release's tested version)
  --no-start            do not start the service after installing
  --root <path>         runtime root (default ~/.local/opt/dsh)
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --check) ACTION="check" ;;
    --uninstall) ACTION="uninstall" ;;
    --release) TAG="${2:-}"; [ -n "$TAG" ] || die "--release needs a value"; shift ;;
    --release=*) TAG="${1#*=}" ;;
    --repo) REPO="${2:-}"; [ -n "$REPO" ] || die "--repo needs a value"; shift ;;
    --repo=*) REPO="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) PASS+=("$1") ;;
  esac
  shift
done

SELF="${BASH_SOURCE[0]:-}"
case "$SELF" in
  */*) ;;
  *) SELF="" ;;
esac
if [ -n "$SELF" ] && [ -f "$(dirname "$SELF")/install-core.sh" ]; then
  DIR="$(cd "$(dirname "$SELF")" && pwd)"
  log "using local checkout: $DIR"
  exec bash "$DIR/install-core.sh" "$ACTION" ${PASS[@]+"${PASS[@]}"}
fi

[ -n "$REPO" ] || die "set TERMUX_DSH_REPO=owner/repo (or edit install.sh)"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required (pkg install coreutils)"

base="${TERMUX_DSH_BASE_URL:-}"
if [ -z "$base" ]; then
  base="https://github.com/$REPO/releases"
  if [ "$TAG" = latest ]; then
    base="$base/latest/download"
  else
    base="$base/download/$TAG"
  fi
fi

tmp_root="${TMPDIR:-${PREFIX:-/tmp}/tmp}"
mkdir -p "$tmp_root" || die "cannot create $tmp_root"
tmp="$(mktemp -d "$tmp_root/termux-dsh.XXXXXX")" || die "mktemp failed"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

log "downloading runtime payload ($TAG) from $REPO"
curl -fsSL -o "$tmp/dsh-termux-runtime.tar.gz" "$base/dsh-termux-runtime.tar.gz" \
  || die "failed to download dsh-termux-runtime.tar.gz"
curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" \
  || die "failed to download SHA256SUMS"
( cd "$tmp" && grep ' dsh-termux-runtime.tar.gz$' SHA256SUMS | sha256sum -c - >/dev/null ) \
  || die "payload checksum mismatch"

mkdir -p "$tmp/payload"
tar xzf "$tmp/dsh-termux-runtime.tar.gz" -C "$tmp/payload" || die "failed to extract payload"

bash "$tmp/payload/install-core.sh" "$ACTION" ${PASS[@]+"${PASS[@]}"}
status=$?
exit $status