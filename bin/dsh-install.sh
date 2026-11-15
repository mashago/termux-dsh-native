#!/data/data/com.termux/files/usr/bin/bash
# termux-dsh-native: deprecated alias for the dsh CLI.
#
# The dsh wrapper now puts ~/.local/bin on PATH itself, so `dsh plugin` works
# from non-interactive shells. This file remains only for existing scripts.
# Installed as ~/.local/bin/dsh-install.
set -euo pipefail
DSH_ROOT="${DSH_ROOT:-$HOME/.local/opt/dsh}"
exec "$DSH_ROOT/bin/dsh" "$@"
