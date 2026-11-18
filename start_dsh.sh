#!/data/data/com.termux/files/usr/bin/bash
# start_dsh.sh — manage dsh web through termux-services (runit).
#
#   ~/start_dsh.sh              enable + start the dsh-web service (default)
#   ~/start_dsh.sh start        same as above
#   ~/start_dsh.sh stop         stop the service and disable auto-start
#   ~/start_dsh.sh status       service / auto-start / HTTP status
#   ~/start_dsh.sh restart      restart the service (keeps it enabled)
#
# Enabling = removing $SVDIR/dsh-web/down (same as `sv-enable dsh-web`).
# Disabling = creating that `down` file (same as `sv-disable dsh-web`).
# termux-services starts every enabled service when Termux's login shell
# runs `service-daemon start`.
set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
ROOT="${DSH_ROOT:-$HOME_DIR/.local/opt/dsh}"
BIN="$HOME_DIR/.local/bin/dsh"
PORT="${DSH_PORT:-3080}"
WORKSPACE="${DSH_WORKSPACE:-$HOME_DIR/workspace}"
[ -d "$WORKSPACE" ] || WORKSPACE="$HOME_DIR"

SVDIR="${SVDIR:-$PREFIX/var/service}"
LOGDIR="${LOGDIR:-$PREFIX/var/log}"
SERVICE="dsh-web"
SVC="$SVDIR/$SERVICE"
SVC_LOG="$LOGDIR/sv/$SERVICE/current"
TOKEN_FILE="$ROOT/etc/web-token"
LEGACY_PID="$ROOT/work/web.pid"

export SVDIR LOGDIR

SV="$PREFIX/bin/sv"
SV_ENABLE="$PREFIX/bin/sv-enable"
SV_DISABLE="$PREFIX/bin/sv-disable"
SERVICE_DAEMON="$PREFIX/bin/service-daemon"

[ -x "$BIN" ] || { echo "dsh: missing $BIN" >&2; exit 1; }
[ -x "$SV" ] || { echo "sv: termux-services is not installed" >&2; exit 1; }

ensure_service() {
  if [ ! -d "$SVC" ]; then
    mkdir -p "$SVC"
    # A new service directory is enabled as soon as runsvdir sees it.  Start
    # disabled, then let start() remove this after the port check.
    : > "$SVC/down"
  fi
  mkdir -p "$SVC/log" "$LOGDIR/sv/$SERVICE"
  chmod 700 "$SVC" "$SVC/log" "$LOGDIR/sv/$SERVICE" 2>/dev/null || true

  cat > "$SVC/run" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
export HOME="$HOME_DIR"
export PREFIX="$PREFIX"
export PATH="$HOME_DIR/.local/bin:$PREFIX/bin:\$PATH"
export SVDIR="$SVDIR"
export LOGDIR="$LOGDIR"
cd "$WORKSPACE" 2>/dev/null || cd "$HOME_DIR"
exec 2>&1
exec "$BIN" web --no-open --port "$PORT"
EOF

  cat > "$SVC/log/run" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
exec svlogd -tt "$LOGDIR/sv/$SERVICE"
EOF

  chmod 755 "$SVC/run" "$SVC/log/run"
}

ensure_daemon() {
  if pgrep -f "runsvdir $SVDIR" >/dev/null 2>&1; then
    return 0
  fi
  [ -x "$SERVICE_DAEMON" ] && "$SERVICE_DAEMON" start >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 25); do
    if pgrep -f "runsvdir $SVDIR" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

service_running() {
  "$SV" status "$SERVICE" 2>/dev/null | grep -q "^run: $SERVICE:"
}

service_paused() {
  "$SV" status "$SERVICE" 2>/dev/null | grep -q "^run: $SERVICE:.*paused"
}

service_enabled() {
  [ -d "$SVC" ] && [ ! -e "$SVC/down" ]
}

http_code() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 3 --connect-timeout 2 \
    "http://127.0.0.1:$PORT/" 2>/dev/null || true
}

print_url() {
  local url
  url="$(grep -m1 'dsh web: http' "$SVC_LOG" 2>/dev/null | sed 's/.*dsh web: //' || true)"
  if [ -n "$url" ]; then
    printf 'URL: %s\n' "$url"
  elif [ -s "$TOKEN_FILE" ]; then
    printf 'URL: http://127.0.0.1:%s/?token=%s\n' "$PORT" "$(cat "$TOKEN_FILE")"
  fi
}

stop_legacy_manual() {
  [ -f "$LEGACY_PID" ] || return 0
  local pid
  pid="$(cat "$LEGACY_PID" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
    && tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "dsh/lib/bin.js web"; then
    echo "stopping legacy manual dsh web (pid $pid) ..."
    kill "$pid" 2>/dev/null || true
    local i
    for i in $(seq 1 25); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.2
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$LEGACY_PID"
}

wait_for_supervise() {
  local i
  for i in $(seq 1 50); do
    [ -e "$SVC/supervise/ok" ] && return 0
    sleep 0.2
  done
  return 1
}

start() {
  stop_legacy_manual
  ensure_service

  local resumed=0
  if service_paused; then
    echo "dsh web is paused; resuming ..."
    "$SV" cont "$SERVICE" >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 25); do
      service_paused || break
      sleep 0.2
    done
    resumed=1
  fi

  if service_running && ! service_paused; then
    "$SV_ENABLE" "$SERVICE" >/dev/null 2>&1 || true
    if [ "$resumed" = 1 ]; then
      echo "dsh web resumed (service $SERVICE; auto-start enabled)"
    else
      echo "dsh web already running (service $SERVICE; auto-start enabled)"
    fi
    print_url
    return 0
  fi

  if service_paused; then
    echo "!! dsh web is still paused; try '$SV cont $SERVICE'" >&2
    return 1
  fi

  if ! ensure_daemon; then
    echo "!! runsvdir did not start; cannot manage $SERVICE" >&2
    return 1
  fi

  local code
  code="$(http_code)"
  if [ -n "$code" ] && [ "$code" != "000" ]; then
    echo "port $PORT already responds (http=$code), but service $SERVICE is not running;" >&2
    echo "refusing to start a second instance (stop the manual one first)" >&2
    return 1
  fi

  # runsvdir creates supervise/ when it first notices the service directory;
  # sv returns "unable to open supervise/ok" until then.  Do not treat that
  # transient warning as a failure.
  wait_for_supervise || true
  "$SV_ENABLE" "$SERVICE" >/dev/null 2>&1 || true

  local i
  for i in $(seq 1 60); do
    if [ -e "$SVC/supervise/ok" ] && ! service_running; then
      "$SV" up "$SERVICE" >/dev/null 2>&1 || true
    fi
    code="$(http_code)"
    if service_running && [ -n "$code" ] && [ "$code" != "000" ]; then
      echo "dsh web started (service $SERVICE; auto-start enabled)"
      print_url
      return 0
    fi
    sleep 0.5
  done

  echo "!! dsh web did not become ready" >&2
  "$SV" status "$SERVICE" >&2 || true
  tail -30 "$SVC_LOG" >&2 || true
  return 1
}

stop() {
  if [ -d "$SVC" ]; then
    if service_paused; then
      "$SV" cont "$SERVICE" >/dev/null 2>&1 || true
    fi
    if service_running; then
      echo "stopping $SERVICE ..."
    fi
    "$SV_DISABLE" "$SERVICE" >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 25); do
      service_running || break
      sleep 0.2
    done
    if service_running; then
      "$SV" down "$SERVICE" >/dev/null 2>&1 || true
    fi
    # sv-disable normally creates this; make the disabled state explicit.
    : > "$SVC/down"
    echo "dsh web stopped (service $SERVICE; auto-start disabled)"
  else
    echo "dsh web service is not installed; nothing to stop"
  fi
  stop_legacy_manual
}

status() {
  if [ -d "$SVC" ]; then
    local enabled=disabled
    [ ! -e "$SVC/down" ] && enabled=enabled
    if service_paused; then
      echo "dsh web: service=$SERVICE paused auto_start=$enabled"
      print_url
      echo "resume with: $0 start   (or: $SV cont $SERVICE)"
    elif service_running; then
      echo "dsh web: service=$SERVICE running http=$(http_code) auto_start=$enabled"
      print_url
    else
      echo "dsh web: service=$SERVICE stopped auto_start=$enabled"
    fi
  else
    echo "dsh web: service=$SERVICE not installed"
    local code
    code="$(http_code)"
    if [ -n "$code" ] && [ "$code" != "000" ]; then
      echo "port $PORT responds (http=$code); manual instance?"
      print_url
    fi
  fi
}

restart() {
  ensure_service
  if service_paused; then
    "$SV" cont "$SERVICE" >/dev/null 2>&1 || true
  fi
  if ! service_running; then
    start
    return
  fi
  "$SV_ENABLE" "$SERVICE" >/dev/null 2>&1 || true
  "$SV" restart "$SERVICE" >/dev/null 2>&1 || true
  local i code
  for i in $(seq 1 60); do
    code="$(http_code)"
    if service_running && [ -n "$code" ] && [ "$code" != "000" ]; then
      echo "dsh web restarted (service $SERVICE; auto-start enabled)"
      print_url
      return 0
    fi
    sleep 0.5
  done
  echo "!! restart did not become ready" >&2
  "$SV" status "$SERVICE" >&2 || true
  tail -30 "$SVC_LOG" >&2 || true
  return 1
}

case "${1:-start}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  restart) restart ;;
  *)
    echo "usage: $0 [start|stop|status|restart]   (no argument = start)" >&2
    exit 2
    ;;
esac