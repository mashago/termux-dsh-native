#!/data/data/com.termux/files/usr/bin/bash
# start_sshd.sh — start Termux sshd if it is not already running.
# Start-only: there is deliberately no stop/restart command.
#
# Uses termux-services (runit) when available:
#   service-daemon start  -> runsvdir
#   sv up sshd            -> starts the sshd service
# Falls back to a direct `sshd` only when the runit service directory is absent.
set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
export PATH="$PREFIX/bin:$PATH"
SVDIR="${SVDIR:-$PREFIX/var/service}"
export SVDIR

SV="$PREFIX/bin/sv"
SSHD="$PREFIX/bin/sshd"
SERVICE_DAEMON="$PREFIX/bin/service-daemon"
RUNSVDIR="$PREFIX/bin/runsvdir"
SSHD_LOG_DIR="$PREFIX/var/log/sv/sshd"

if [ "$#" -gt 0 ]; then
  echo "usage: $0   (no arguments; starts sshd if needed)" >&2
  exit 2
fi

is_running() {
  [ -x "$SV" ] || return 1
  "$SV" status sshd 2>/dev/null | grep -q '^run: sshd:'
}

show_status() {
  if [ -x "$SV" ] && [ -d "$SVDIR/sshd" ]; then
    "$SV" status sshd 2>&1 || true
  else
    pgrep -af "sshd" 2>/dev/null | head -5 || true
  fi
}

if is_running; then
  echo "sshd already running"
  show_status
  exit 0
fi

if [ -d "$SVDIR/sshd" ] && [ -x "$SV" ]; then
  # termux-services path: make sure runsvdir is running, then bring the service up.
  if ! pgrep -f "runsvdir $SVDIR" >/dev/null 2>&1; then
    if [ -x "$SERVICE_DAEMON" ]; then
      "$SERVICE_DAEMON" start >/dev/null 2>&1 || true
    elif [ -x "$RUNSVDIR" ]; then
      nohup "$RUNSVDIR" "$SVDIR" >/dev/null 2>&1 &
    else
      echo "!! neither service-daemon nor runsvdir is available" >&2
      exit 1
    fi
  fi

  "$SV" up sshd >/dev/null 2>&1 || true

  for _ in $(seq 1 20); do
    # service-daemon may still be bringing runsvdir up on the first pass.
    "$SV" up sshd >/dev/null 2>&1 || true
    if is_running; then
      echo "sshd started"
      show_status
      exit 0
    fi
    sleep 0.5
  done

  echo "!! sshd did not reach run state" >&2
  show_status >&2
  if [ -f "$SSHD_LOG_DIR/current" ]; then
    echo "== sshd log tail ==" >&2
    tail -20 "$SSHD_LOG_DIR/current" >&2 || true
  fi
  exit 1
fi

# No termux-services sshd service: use the daemon directly.
if pgrep -f "(^|/)sshd( |$)" >/dev/null 2>&1; then
  echo "sshd already running (direct)"
  exit 0
fi

"$SSHD"
echo "sshd started (direct)"
pgrep -af "sshd" 2>/dev/null | head -5 || true