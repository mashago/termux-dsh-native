#!/data/data/com.termux/files/usr/bin/bash
# Bootstrap updater for the Termux-native dsh runtime.
#
#   curl -fsSL <release>/update.sh | bash -s -- 0.2.2-rc.3 -y
#   git pull && bash update.sh 0.2.2-rc.3 -y
#
# It downloads the runtime payload from the GitHub release (or uses the local
# checkout), verifies it, and runs `install-core.sh update`.
# Without a dsh version it targets the release's tested version.

set -uo pipefail

ACTION="update"
REPO="${TERMUX_DSH_REPO:-mashago/termux-dsh-native}"
TAG="${TERMUX_DSH_RELEASE:-latest}"
PASS=()

log() { printf '%s\n' "$*"; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: update.sh [dsh-version] [options]
  -y, --yes             non-interactive
  --check               print current versions and supported dsh versions
  --rollback            roll back to the previous dsh version
  --release <tag>       runtime release to use (default: latest)
  --repo <owner/repo>   GitHub repository (or set TERMUX_DSH_REPO)
  --dsh-version <v>     target dsh version (same as the positional argument)
  --no-restart          do not restart the service after updating
  --force               reinstall dsh even when the version is present
  --backup-home         tar ~/.dsh (excluding cache) before updating
  --root <path>         runtime root (default ~/.local/opt/dsh)
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --check) ACTION="check" ;;
    --rollback) ACTION="rollback" ;;
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
if [ -n "$SELF" ] && [ -f "$SELF" ] && [ -f "$(dirname "$SELF")/install-core.sh" ]; then
  DIR="$(cd "$(dirname "$SELF")" && pwd)"
  log "using local checkout: $DIR"
  exec bash "$DIR/install-core.sh" "$ACTION" ${PASS[@]+"${PASS[@]}"}
fi

[ -n "$REPO" ] || die "set TERMUX_DSH_REPO=owner/repo (or edit update.sh)"
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