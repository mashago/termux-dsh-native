#!/data/data/com.termux/files/usr/bin/bash
# $BROWSER dispatcher for dsh on Android.
#   dsh web passes an http(s) URL  -> termux-open-url (am start -a VIEW -d URL)
#   host.openPath passes a file    -> termux-open (FileProvider content URI)
set -euo pipefail
case "${1:-}" in
  http://*|https://*) exec termux-open-url "$1" ;;
  *)                  exec termux-open "$1" ;;
esac