#!/data/data/com.termux/files/usr/bin/bash
# Install / update / roll back the Termux-native dsh runtime.
#
# This file is the single implementation behind both bootstraps:
#   install.sh  -> install-core.sh install [options]
#   update.sh   -> install-core.sh update  [dsh-version] [options]
#
# It runs under Termux's bionic bash. glibc commands are always invoked with
# `env -u LD_PRELOAD`; the link shim is only loaded for the Node process.

set -uo pipefail

PAYLOAD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${DSH_ROOT:-$HOME/.local/opt/dsh}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

FORCE=0
NO_START=0
NO_RESTART=0
BACKUP_HOME=0
PURGE_HOME=0
TARGET=""

ACTION="${1:-install}"
[ $# -gt 0 ] && shift

log() { printf '%s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
step() { printf '\n== %s\n' "$*"; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  install-core.sh install [dsh-version] [options]
  install-core.sh update  [dsh-version] [options]
  install-core.sh rollback [options]
  install-core.sh check
  install-core.sh uninstall [--purge-home]

Options:
  -y, --yes             accepted for scripts; the installer never prompts
  --dsh-version <v>     target dsh version (same as the positional argument)
  --root <path>         runtime root (default ~/.local/opt/dsh)
  --no-start            do not start the service after a fresh install
  --no-restart          do not restart the service after an update
  --force               reinstall dsh even when the target version is present
  --backup-home         tar ~/.dsh (excluding cache) before changing versions
  --purge-home          uninstall: also delete ~/.dsh
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) ;;   # accepted for scripts; the installer never prompts
    --dsh-version) TARGET="${2:-}"; [ -n "$TARGET" ] || die "--dsh-version needs a value"; shift ;;
    --root) ROOT="${2:-}"; [ -n "$ROOT" ] || die "--root needs a value"; shift ;;
    --no-start) NO_START=1 ;;
    --no-restart) NO_RESTART=1 ;;
    --force) FORCE=1 ;;
    --backup-home) BACKUP_HOME=1 ;;
    --purge-home) PURGE_HOME=1 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; [ $# -gt 0 ] && TARGET="$1" ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$TARGET" ] || die "unexpected argument: $1"; TARGET="$1" ;;
  esac
  shift
done

case "$ACTION" in
  install|update|rollback|check|uninstall) ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; die "unknown action: $ACTION" ;;
esac

# ── release manifest ───────────────────────────────────────────────────────

if [ -f "$PAYLOAD_DIR/release-manifest.sh" ]; then
  # shellcheck disable=SC1091
  . "$PAYLOAD_DIR/release-manifest.sh"
fi
PROJECT_VERSION="${PROJECT_VERSION:-dev}"
NODE_VERSION="${NODE_VERSION:-24.19.0}"
TESTED_DSH="${TESTED_DSH:-}"
SUPPORTED_DSH="${SUPPORTED_DSH:-}"

sets_dir() { printf '%s' "$PAYLOAD_DIR/rewrites/sets"; }

derive_supported() {
  local manifest
  for manifest in "$(sets_dir)"/*/manifest.json; do
    [ -f "$manifest" ] || continue
    sed -n 's/.*"versions"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' "$manifest" \
      | tr -d ' "' | tr ',' '\n'
  done | awk 'NF' | sort -u
}

default_set_version() {
  local manifest
  for manifest in "$(sets_dir)"/*/manifest.json; do
    [ -f "$manifest" ] || continue
    if grep -q '"default"[[:space:]]*:[[:space:]]*true' "$manifest"; then
      sed -n 's/.*"versions"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' "$manifest" \
        | tr -d ' "' | tr ',' '\n' | awk 'NF' | head -1
      return 0
    fi
  done
}

if [ -z "$SUPPORTED_DSH" ]; then
  SUPPORTED_DSH="$(derive_supported | tr '\n' ' ' | sed 's/ *$//')"
fi
if [ -z "$TESTED_DSH" ]; then
  TESTED_DSH="$(default_set_version)"
  [ -n "$TESTED_DSH" ] || TESTED_DSH="$(printf '%s' "$SUPPORTED_DSH" | awk '{print $1}')"
fi

supported_has() {
  printf '%s\n' $SUPPORTED_DSH | grep -qxF "$1"
}

list_supported() {
  printf '  %s\n' $SUPPORTED_DSH
}

# ── helpers ────────────────────────────────────────────────────────────────

node_bin() { printf '%s' "$ROOT/node/bin/node"; }
npm_cli() { printf '%s' "$ROOT/node/lib/node_modules/npm/bin/npm-cli.js"; }

node_version() {
  [ -x "$(node_bin)" ] || return 0
  env -u LD_PRELOAD "$(node_bin)" --version 2>/dev/null | sed 's/^v//'
}

dsh_version() {
  local file="$ROOT/work/node_modules/@deepseek-ai/dsh/package.json"
  [ -f "$file" ] || return 0
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -1
}

version_ge() {
  [ "$1" = "$2" ] && return 0
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

free_kb() { df -Pk "$HOME" | awk 'NR==2 {print $4}'; }

check_disk() {
  local need_kb="$1" free
  free="$(free_kb)"
  [ -n "$free" ] || return 0
  if [ "$free" -lt "$need_kb" ]; then
    die "not enough free space in \$HOME: ${free} KiB available, ${need_kb} KiB needed"
  fi
}

check_termux() {
  [ -d "$PREFIX" ] || die "Termux prefix not found: $PREFIX"
  case "$(uname -m)" in
    aarch64|arm64) ;;
    *) die "unsupported architecture: $(uname -m) (only aarch64 is supported)" ;;
  esac
}

ensure_packages() {
  local missing=() pkg_name command_name
  for pkg_name in glibc-repo glibc glibc-runner termux-services coreutils; do
    dpkg -s "$pkg_name" >/dev/null 2>&1 || missing+=("$pkg_name")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    warn "missing Termux packages: ${missing[*]}"
    die "install them first: pkg install -y ${missing[*]}"
  fi
  for command_name in curl tar xz sha256sum sort awk; do
    command -v "$command_name" >/dev/null 2>&1 \
      || die "missing command: $command_name (pkg install -y curl tar xz-utils coreutils)"
  done
}

ensure_node_for() {
  local target_dsh="$1" desired="$NODE_VERSION" current engines_min
  current="$(node_version)"
  if [ -z "$current" ]; then
    step "Install Node $desired"
    install_node "$desired"
  elif ! version_ge "$current" "$desired"; then
    step "Upgrade Node $current -> $desired"
    install_node "$desired"
  fi
  current="$(node_version)"
  engines_min="$(npm_engines_min "$target_dsh" || true)"
  if [ -n "$engines_min" ] && ! version_ge "$current" "$engines_min"; then
    step "Install Node $engines_min (required by dsh $target_dsh)"
    install_node "$engines_min"
  fi
  [ -n "$(node_version)" ] || die "Node is not installed at $ROOT/node"
}

install_node() {
  local version="$1" archive="$ROOT/tmp/node-v$version-linux-arm64.tar.xz"
  local shasums="$ROOT/tmp/SHASUMS256-v$version.txt" staging="$ROOT/node.new.$$" old="$ROOT/node.old.$$"
  mkdir -p "$ROOT/tmp"
  step "Download Node v$version"
  curl -fsSL -o "$archive" "https://nodejs.org/dist/v$version/node-v$version-linux-arm64.tar.xz" \
    || die "failed to download Node v$version"
  curl -fsSL -o "$shasums" "https://nodejs.org/dist/v$version/SHASUMS256.txt" \
    || die "failed to download Node SHASUMS256.txt"
  ( cd "$ROOT/tmp" && grep " node-v$version-linux-arm64.tar.xz\$" "$shasums" | sha256sum -c - >/dev/null ) \
    || die "Node v$version checksum mismatch"
  rm -rf "$staging"; mkdir -p "$staging"
  tar xJf "$archive" --strip-components=1 -C "$staging" || die "failed to extract Node"
  env -u LD_PRELOAD "$PREFIX/glibc/bin/patchelf" \
    --set-interpreter "$PREFIX/glibc/lib/ld-linux-aarch64.so.1" "$staging/bin/node" \
    || die "patchelf failed"
  env -u LD_PRELOAD "$staging/bin/node" --version >/dev/null \
    || die "patched Node does not run"
  if [ -d "$ROOT/node" ]; then mv "$ROOT/node" "$old"; fi
  mv "$staging" "$ROOT/node"
  rm -rf "$old"
  rm -f "$archive" "$shasums"
}

npm_engines_min() {
  local version="$1" engines
  engines="$(env -u LD_PRELOAD TMPDIR="$ROOT/tmp" "$(node_bin)" "$(npm_cli)" \
    view "@deepseek-ai/dsh@$version" engines.node --json 2>/dev/null | sed 's/[{}"]//g')"
  [ -n "$engines" ] || return 0
  printf '%s' "$engines" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -V | head -1
}

npm_install_dsh() {
  local version="$1"
  mkdir -p "$ROOT/work" "$ROOT/tmp"
  if [ ! -f "$ROOT/work/package.json" ]; then
    ( cd "$ROOT/work" && env -u LD_PRELOAD TMPDIR="$ROOT/tmp" \
        "$(node_bin)" "$(npm_cli)" init -y >/dev/null ) || die "npm init failed"
  fi
  step "Install @deepseek-ai/dsh@$version"
  ( cd "$ROOT/work" && env -u LD_PRELOAD \
      TMPDIR="$ROOT/tmp" \
      PATH="$PREFIX/glibc/bin:$PATH" \
      NODE_OPTIONS="--max-old-space-size=4096" \
      "$(node_bin)" "$(npm_cli)" install \
        --ignore-scripts --no-audit --no-fund "@deepseek-ai/dsh@$version" ) \
    || die "npm install failed for dsh $version"
}

npm_version_exists() {
  env -u LD_PRELOAD TMPDIR="$ROOT/tmp" "$(node_bin)" "$(npm_cli)" \
    view "@deepseek-ai/dsh@$1" version >/dev/null 2>&1
}

# ── service helpers ────────────────────────────────────────────────────────

service_running() {
  SVDIR="$PREFIX/var/service" sv status dsh-web 2>/dev/null | grep -q '^run:'
}

service_autostart() {
  [ -d "$PREFIX/var/service/dsh-web" ] && [ ! -e "$PREFIX/var/service/dsh-web/down" ]
}

service_stop() {
  [ -x "$HOME/start_dsh.sh" ] || return 0
  bash "$HOME/start_dsh.sh" stop >/dev/null 2>&1 || true
}

service_start() {
  [ -x "$HOME/start_dsh.sh" ] || return 0
  bash "$HOME/start_dsh.sh" start
}

# ── runtime deployment ─────────────────────────────────────────────────────

list_local_helpers() {
  local list="$ROOT/tools/helpers.list"
  if [ -f "$list" ]; then
    while IFS='|' read -r src scope dest; do
      case "$src" in ''|\#*) continue ;; esac
      if [ "$scope" = local-bin ]; then
        printf '%s\n' "$dest"
      fi
    done < "$list"
  else
    printf '%s\n' pnpm
  fi
}

backup_runtime() {
  local stamp dir
  stamp="$(date +%Y%m%d-%H%M%S)"
  dir="$ROOT/backups/runtime/$stamp"
  mkdir -p "$dir" || die "cannot create runtime backup: $dir"
  if [ -d "$ROOT/tools" ]; then
    cp -R "$ROOT/tools" "$dir/tools" || die "runtime backup failed: tools"
  fi
  if [ -d "$ROOT/bin" ]; then
    cp -R "$ROOT/bin" "$dir/bin" || die "runtime backup failed: bin"
  fi
  if [ -d "$ROOT/lib" ]; then
    cp -R "$ROOT/lib" "$dir/lib" || die "runtime backup failed: lib"
  else
    warn "runtime backup: $ROOT/lib is missing"
  fi
  mkdir -p "$dir/local-bin" || die "cannot create runtime backup: local-bin"
  for f in $(list_local_helpers); do
    if [ -f "$HOME/.local/bin/$f" ]; then
      cp -p "$HOME/.local/bin/$f" "$dir/local-bin/$f" || die "runtime backup failed: $f"
    fi
  done
  for f in start_dsh.sh start_sshd.sh; do
    if [ -f "$HOME/$f" ]; then
      cp -p "$HOME/$f" "$dir/$f" || die "runtime backup failed: $f"
    fi
  done
  printf '%s' "$dir"
}

restore_runtime() {
  local dir="$1"
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  rm -rf "$ROOT/tools" "$ROOT/bin"
  cp -R "$dir/tools" "$ROOT/tools" || warn "runtime restore failed: tools"
  cp -R "$dir/bin" "$ROOT/bin" || warn "runtime restore failed: bin"
  if [ -d "$dir/lib" ]; then
    rm -rf "$ROOT/lib"
    cp -R "$dir/lib" "$ROOT/lib" || warn "runtime restore failed: lib"
  else
    mkdir -p "$ROOT/lib"
    warn "runtime backup has no lib; keeping the current link shim"
  fi
  rm -f "$ROOT/lib/unset-ld-preload.cjs"
  mkdir -p "$HOME/.local/bin"
  for f in $(list_local_helpers); do
    if [ -f "$dir/local-bin/$f" ]; then
      cp -p "$dir/local-bin/$f" "$HOME/.local/bin/$f" || warn "runtime restore failed: $f"
    else
      rm -f "$HOME/.local/bin/$f"
    fi
  done
  rm -f "$HOME/.local/bin/dsh-install"
  for f in start_dsh.sh start_sshd.sh; do
    if [ -f "$dir/$f" ]; then
      cp -p "$dir/$f" "$HOME/$f" || warn "runtime restore failed: $f"
    fi
  done
}

deploy_runtime() (
  set -e
  mkdir -p "$ROOT"/{bin,lib,tools,etc} "$HOME/.local/bin"
  chmod 700 "$ROOT/etc"
  cp "$PAYLOAD_DIR/bin/dsh-wrapper.sh" "$ROOT/bin/dsh"
  cp "$PAYLOAD_DIR/bin/dsh-open.sh" "$ROOT/bin/dsh-open"
  cp "$PAYLOAD_DIR/helpers.list" "$ROOT/tools/helpers.list"
  while IFS='|' read -r src scope dest; do
    case "$src" in ''|\#*) continue ;; esac
    case "$scope" in
      root-bin) target="$ROOT/bin/$dest" ;;
      local-bin) target="$HOME/.local/bin/$dest" ;;
      *) echo "!! helpers.list: unknown scope $scope for $src" >&2; exit 1 ;;
    esac
    cp "$PAYLOAD_DIR/$src" "$target"
    chmod 755 "$target"
  done < "$PAYLOAD_DIR/helpers.list"
  rm -f "$HOME/.local/bin/dsh-install"
  cp "$PAYLOAD_DIR/start_dsh.sh" "$HOME/start_dsh.sh"
  cp "$PAYLOAD_DIR/start_sshd.sh" "$HOME/start_sshd.sh"
  cp "$PAYLOAD_DIR/verify-install.sh" "$ROOT/tools/verify-install.sh"
  if [ -f "$PAYLOAD_DIR/smoke-web.sh" ]; then
    cp "$PAYLOAD_DIR/smoke-web.sh" "$ROOT/tools/smoke-web.sh"
  fi
  cp "$PAYLOAD_DIR/rewrites/apply-rewrites.sh" "$ROOT/tools/apply-rewrites.sh"
  cp "$PAYLOAD_DIR/rewrites/apply-rewrites.mjs" "$ROOT/tools/apply-rewrites.mjs"
  rm -rf "$ROOT/tools/lib" "$ROOT/tools/sets"
  cp -R "$PAYLOAD_DIR/rewrites/lib" "$ROOT/tools/lib"
  cp -R "$PAYLOAD_DIR/rewrites/sets" "$ROOT/tools/sets"
  cp "$PAYLOAD_DIR/dist/libdsh-termux-native-link.so" "$ROOT/lib/libdsh-termux-native-link.so"
  rm -f "$ROOT/lib/unset-ld-preload.cjs"
  chmod 755 "$ROOT/bin/dsh" "$ROOT/bin/dsh-open" \
    "$HOME/start_dsh.sh" "$HOME/start_sshd.sh" \
    "$ROOT/tools/apply-rewrites.sh" "$ROOT/tools/verify-install.sh"
  if [ -f "$ROOT/tools/smoke-web.sh" ]; then
    chmod 755 "$ROOT/tools/smoke-web.sh"
  fi
  chmod 644 "$ROOT/tools/apply-rewrites.mjs" "$ROOT/tools/helpers.list" \
    "$ROOT/lib/libdsh-termux-native-link.so"
  if [ ! -s "$ROOT/etc/web-token" ]; then
    head -c 9 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n' > "$ROOT/etc/web-token"
  fi
  chmod 600 "$ROOT/etc/web-token"
  ln -sfn "$ROOT/bin/dsh" "$HOME/.local/bin/dsh"
  if ! printf '%s' ":$PATH:" | grep -q ":$HOME/.local/bin:"; then
    grep -q '# dsh-termux-native' "$HOME/.bashrc" 2>/dev/null \
      || printf '\nexport PATH="$HOME/.local/bin:$PATH"   # dsh-termux-native\n' >> "$HOME/.bashrc"
  fi
)

probe_shim() {
  step "Probe link shim"
  env -u LD_PRELOAD LD_PRELOAD="$ROOT/lib/libdsh-termux-native-link.so" \
    "$(node_bin)" -e 'process.exit(0)' \
    || die "link shim failed to load"
}

apply_rewrites() {
  step "Apply version-matched text rewrites"
  bash "$ROOT/tools/apply-rewrites.sh" || return 1
}

verify_install() {
  step "Verify installation"
  bash "$ROOT/tools/verify-install.sh" || return 1
}

rewrite_set_label() {
  local file="$ROOT/rewrites-state.json"
  [ -f "$file" ] || return 0
  sed -n 's/.*"set"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -1
}

write_state() {
  local previous="$1"
  env -u LD_PRELOAD "$(node_bin)" -e '
    const fs = require("fs");
    const [file, project, dsh, nodeVersion, setLabel, previous] = process.argv.slice(1);
    let prior = null;
    try {
      const old = JSON.parse(fs.readFileSync(file, "utf8"));
      prior = { dshVersion: old.dshVersion, projectVersion: old.projectVersion, installedAt: old.installedAt };
    } catch {}
    const previousBlock = previous
      ? { dshVersion: previous, projectVersion: prior?.projectVersion ?? null }
      : prior ? { dshVersion: prior.dshVersion, projectVersion: prior.projectVersion } : null;
    const now = new Date().toISOString();
    fs.writeFileSync(file, JSON.stringify({
      projectVersion: project,
      dshVersion: dsh,
      nodeVersion: nodeVersion,
      rewriteSet: setLabel || null,
      installedAt: prior?.installedAt ?? now,
      updatedAt: now,
      previous: previousBlock,
    }, null, 2) + "\n");
  ' "$ROOT/install-state.json" "$PROJECT_VERSION" "$TARGET" "$(node_version)" "$(rewrite_set_label)" "$previous"
}

backup_home() {
  [ "$BACKUP_HOME" = 1 ] || return 0
  [ -d "$HOME/.dsh" ] || return 0
  mkdir -p "$ROOT/backups/home"
  local archive="$ROOT/backups/home/dsh-home-$(date +%Y%m%d-%H%M%S).tgz"
  step "Back up ~/.dsh (cache excluded)"
  tar czf "$archive" -C "$HOME" --exclude='.dsh/cache' .dsh || warn "~/.dsh backup failed"
  log "backup: $archive"
}

previous_dsh_version() {
  local file="$ROOT/install-state.json"
  [ -f "$file" ] || return 0
  [ -x "$(node_bin)" ] || return 0
  env -u LD_PRELOAD "$(node_bin)" -e '
    const fs = require("fs");
    try {
      const state = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      process.stdout.write(state.previous?.dshVersion ?? "");
    } catch {}
  ' "$file"
}

# ── actions ────────────────────────────────────────────────────────────────

print_check() {
  log "project:        $PROJECT_VERSION"
  log "dsh installed:  $(dsh_version)"
  log "tested dsh:     $TESTED_DSH"
  log "supported dsh:  $(printf '%s' "$SUPPORTED_DSH")"
  log "node:           $(node_version)"
  log "root:           $ROOT"
  if [ -r "$ROOT/lib/libdsh-termux-native-link.so" ]; then
    log "link shim:      present"
  else
    log "link shim:      missing"
  fi
  if [ -x "$ROOT/bin/npm" ] && [ -x "$HOME/.local/bin/pnpm" ]; then
    log "plugin helpers: present"
  else
    log "plugin helpers: missing"
  fi
  if service_running; then
    log "service:        running"
  else
    log "service:        stopped"
  fi
  if service_autostart; then log "auto-start:     enabled"; else log "auto-start:     disabled"; fi
  if [ -f "$ROOT/rewrites-state.json" ]; then
    log "rewrites state: $(tr -d '\n' < "$ROOT/rewrites-state.json" | sed 's/  */ /g')"
  fi
}

do_uninstall() {
  step "Stop and remove the dsh-web service"
  service_stop
  rm -rf "$PREFIX/var/service/dsh-web" "$PREFIX/var/log/sv/dsh-web"
  rm -f "$HOME/.local/bin/dsh"
  # dsh-install is removed from current releases; keep cleaning it for old installs.
  for f in pnpm dsh-install; do
    if grep -q 'termux-dsh-native' "$HOME/.local/bin/$f" 2>/dev/null; then
      rm -f "$HOME/.local/bin/$f"
    fi
  done
  rm -f "$HOME/start_dsh.sh" "$HOME/start_sshd.sh"
  step "Remove runtime root $ROOT"
  rm -rf "$ROOT"
  if [ "$PURGE_HOME" = 1 ]; then
    step "Remove ~/.dsh (purge)"
    rm -rf "$HOME/.dsh"
  else
    log "kept ~/.dsh (pass --purge-home to delete credentials, sessions and config)"
  fi
  log "uninstall complete"
}

do_install_or_update() {
  local mode="$1"

  step "Preflight"
  check_termux
  check_disk $([ "$mode" = install ] && echo 3000000 || echo 1500000)
  ensure_packages
  mkdir -p "$ROOT/tmp" "$ROOT/work"

  [ -n "$TARGET" ] || TARGET="$TESTED_DSH"
  [ -n "$TARGET" ] || die "no target dsh version (payload declares no supported versions)"
  supported_has "$TARGET" || {
    warn "dsh $TARGET is not covered by this payload"
    list_supported
    die "upgrade the runtime release, or pick a supported version"
  }

  if [ "$mode" = update ]; then
    [ -n "$(dsh_version)" ] || die "dsh is not installed under $ROOT; run install first"
  fi

  local previous_version
  previous_version="$(dsh_version)"

  ensure_node_for "$TARGET"

  if ! npm_version_exists "$TARGET"; then
    if [ "$previous_version" = "$TARGET" ]; then
      warn "cannot reach the npm registry; continuing with the local dsh $TARGET"
    else
      die "cannot reach the npm registry and dsh $TARGET is not installed locally"
    fi
  fi

  local was_running=0 was_autostart=0
  service_running && was_running=1
  service_autostart && was_autostart=1

  backup_home
  local backup_dir
  backup_dir="$(backup_runtime)" || die "runtime backup failed"
  [ -n "$backup_dir" ] || die "runtime backup failed"
  log "runtime backup: $backup_dir"

  if [ "$was_running" = 1 ]; then
    step "Stop dsh-web"
    service_stop
  fi

  if [ "$previous_version" = "$TARGET" ] && [ "$FORCE" = 0 ]; then
    log "dsh $TARGET already installed; skipping npm install"
  else
    if ! npm_install_dsh "$TARGET"; then
      warn "npm install failed"
      if [ -n "$previous_version" ]; then
        warn "reinstalling dsh $previous_version"
        npm_install_dsh "$previous_version" || warn "reinstall of $previous_version also failed"
      fi
      [ "$was_running" = 1 ] && service_start
      die "update aborted before any runtime files changed"
    fi
  fi

  step "Deploy runtime files"
  deploy_runtime
  local deploy_status=$?
  if [ "$deploy_status" -ne 0 ]; then
    warn "deploy step failed; rolling back"
    restore_runtime "$backup_dir"
    if [ -n "$previous_version" ] && [ "$previous_version" != "$TARGET" ]; then
      npm_install_dsh "$previous_version" || warn "rollback install failed"
    fi
    [ "$was_running" = 1 ] && service_start
    die "deploy failed; previous runtime restored"
  fi

  if ! probe_shim; then
    restore_runtime "$backup_dir"
    [ -n "$previous_version" ] && npm_install_dsh "$previous_version"
    [ "$was_running" = 1 ] && service_start
    die "link shim probe failed; restored the previous runtime"
  fi

  if ! apply_rewrites; then
    warn "rewrite step failed; rolling back"
    restore_runtime "$backup_dir"
    if [ -n "$previous_version" ] && [ "$previous_version" != "$TARGET" ]; then
      npm_install_dsh "$previous_version" || warn "rollback install failed"
    fi
    apply_rewrites || warn "rollback rewrites failed"
    [ "$was_running" = 1 ] && service_start
    die "update failed during rewrites; previous version restored"
  fi

  if ! verify_install; then
    warn "verify step failed; rolling back"
    restore_runtime "$backup_dir"
    if [ -n "$previous_version" ] && [ "$previous_version" != "$TARGET" ]; then
      npm_install_dsh "$previous_version" || warn "rollback install failed"
    fi
    apply_rewrites || warn "rollback rewrites failed"
    [ "$was_running" = 1 ] && service_start
    die "update failed verification; previous version restored"
  fi

  write_state "$previous_version"

  if [ "$was_running" = 1 ] || [ "$was_autostart" = 1 ]; then
    if [ "$NO_RESTART" = 1 ]; then
      warn "service left stopped (--no-restart)"
    else
      step "Restart dsh-web"
      service_start
    fi
  elif [ "$mode" = install ] && [ "$NO_START" = 0 ]; then
    step "Start dsh-web"
    service_start
  fi

  log ""
  log "dsh:     ${previous_version:-none} -> $TARGET"
  log "rewrite: $(rewrite_set_label)"
  log "done"
}

do_rollback() {
  local previous
  previous="$(previous_dsh_version)"
  [ -n "$previous" ] || die "no previous dsh version recorded in $ROOT/install-state.json"
  supported_has "$previous" || die "previous version $previous is not covered by this payload"
  warn "rolling back dsh to $previous (sessions written by a newer dsh may be unreadable)"
  TARGET="$previous"
  do_install_or_update update
}

case "$ACTION" in
  check) print_check ;;
  uninstall) do_uninstall ;;
  install) do_install_or_update install ;;
  update) do_install_or_update update ;;
  rollback) do_rollback ;;
esac
