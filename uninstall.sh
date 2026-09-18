#!/usr/bin/env bash
# uninstall.sh — removes the installed opencode-db-exporter copy and the shim.
# Usage: ./uninstall.sh [--all] [--yes]
#   default: removes the installed code + ~/.local/bin/opencode-db symlink,
#            and KEEPS config, backups and exports.
#   --all:   also removes the config dir and the backups/exports data.
#   --yes:   do not ask for confirmation.
set -euo pipefail

PREFIX="$HOME/.local/share/opencode-db-exporter"
BIN_DIR="$HOME/.local/bin"
SHIM="$BIN_DIR/opencode-db"
CONF_DIR="$HOME/.config/opencode-db"
BACKUP_DIR="$PREFIX/backups"
OUT_DIR="$PREFIX/exports"

all=0
yes=0
for arg in "$@"; do
    case "$arg" in
        --all) all=1 ;;
        --yes|-y) yes=1 ;;
        -h|--help)
            sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

echo "This will remove:"
printf '  - %s (installed code)\n' "$PREFIX"
printf '  - %s (symlink)\n' "$SHIM"
if [ "$all" -eq 1 ]; then
    printf '  - %s (config)\n' "$CONF_DIR"
    printf '  - %s and %s (backups and exports data)\n' "$BACKUP_DIR" "$OUT_DIR"
else
    echo "  (keeping config, backups and exports; use --all to remove them too)"
fi

if [ "$yes" -eq 0 ]; then
    printf 'Continue? [y/N] '
    read -r ans || ans=""
    [[ "$ans" =~ ^[yYsS]$ ]] || { echo "cancelled."; exit 0; }
fi

rm -f -- "$SHIM"
if [ "$all" -eq 1 ]; then
    rm -rf -- "$PREFIX" "$CONF_DIR"
else
    rm -rf -- "$PREFIX/modules" "$PREFIX/tests" "$PREFIX/uninstall.sh" "$PREFIX/LICENSE"
    rmdir -- "$PREFIX" 2>/dev/null || true
fi

echo "✅ opencode-db-exporter uninstalled."
[ "$all" -eq 1 ] || echo "   Kept: $CONF_DIR, $BACKUP_DIR, $OUT_DIR"
echo "   Note: system packages installed by 'opencode-db deps' (sqlite3, python3,"
echo "         jq, gzip; optional fzf) are NOT removed. To drop them:"
echo "         sudo apt remove sqlite3 python3 jq gzip fzf && sudo apt autoremove"