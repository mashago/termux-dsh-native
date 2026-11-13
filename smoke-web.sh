#!/data/data/com.termux/files/usr/bin/bash
# Start dsh web in the background, wait for its tokenized URL, verify HTTP,
# then stop it (unless KEEP=1).
set -euo pipefail

ROOT="${DSH_ROOT:-$HOME/.local/opt/dsh}"
PORT="${PORT:-3080}"
LOG="${LOG:-$ROOT/work/web-smoke.log}"
WORKSPACE="${WORKSPACE:-$HOME}"
COOKIES="$LOG.cookies"

cd "$WORKSPACE"
: > "$LOG"
: > "$COOKIES"

nohup "$HOME/.local/bin/dsh" web --no-open --port "$PORT" >"$LOG" 2>&1 &
PID=$!
echo "started pid=$PID log=$LOG"

URL=""
for _ in $(seq 1 90); do
  if grep -q '^dsh web: ' "$LOG"; then
    URL=$(grep -m1 '^dsh web: ' "$LOG" | sed 's/^dsh web: //')
    break
  fi
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "!! server exited before printing its URL"
    cat "$LOG"
    exit 1
  fi
  sleep 1
done

if [ -z "$URL" ]; then
  echo "!! timed out waiting for the dsh web URL"
  tail -40 "$LOG"
  kill "$PID" 2>/dev/null || true
  exit 1
fi

echo "url=$URL"
echo -n "token_url_status="
curl -s -o /dev/null -w '%{http_code}\n' "$URL"
echo -n "follow_status="
curl -s -o /dev/null -b "$COOKIES" -c "$COOKIES" -L "$URL" -w '%{http_code}\n'
echo -n "root_status="
curl -s -o /dev/null -b "$COOKIES" "http://127.0.0.1:$PORT/" -w '%{http_code}\n'

if [ "${KEEP:-0}" != "1" ]; then
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  echo "stopped pid=$PID"
else
  echo "kept running pid=$PID"
fi