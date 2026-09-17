#!/usr/bin/env bash
set -euo pipefail

# install.sh — installs opencode-db-exporter to a local prefix and creates the opencode-db symlink.
# Usage: ./install.sh
#   default prefix: ~/.local/share/opencode-db-exporter
#   shim: ~/.local/bin/opencode-db

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="$HOME/.local/share/opencode-db-exporter"
BIN_DIR="${HOME}/.local/bin"
CONF_DIR="$HOME/.config/opencode-db"
CONF_DEST="$CONF_DIR/opencode-db.conf"

check_deps() {
    local missing=""
    for dep in sqlite3 python3 jq gzip; do
        command -v "$dep" >/dev/null 2>&1 || missing+=" $dep"
    done
    [ -n "$missing" ] && echo "   ⚠️  Missing:$missing  (fix with: ~/.local/bin/opencode-db deps)"
    command -v fzf >/dev/null 2>&1 || echo "   ⚠️  Missing fzf (only needed for the interactive menu)."
}

if [ "$SOURCE_ROOT" = "$PREFIX" ]; then
    echo "The local copy is already the current source; nothing to sync."
    exit 0
fi

mkdir -p "$PREFIX" "$BIN_DIR" "$CONF_DIR"
echo "-> Dependencies..."
check_deps

sync_dir() {
    local path="$1"
    mkdir -p "$PREFIX/$path"
    if ! command -v rsync >/dev/null 2>&1; then
        rm -rf "$PREFIX/$path"
        mkdir -p "$PREFIX/$path"
        cp -a "$SOURCE_ROOT/$path/." "$PREFIX/$path/"
    else
        local rc=0
        rsync -a --delete "$SOURCE_ROOT/$path/" "$PREFIX/$path/" || rc=$?
        if [ "$rc" -ne 0 ] && [ "$rc" -ne 23 ] && [ "$rc" -ne 24 ]; then
            return "$rc"
        fi
    fi
}

for path in modules tests; do
    sync_dir "$path"
done

find "$PREFIX/modules" -type f -name '*.sh' -exec chmod +x {} +
ln -sfn "$PREFIX/modules/opencode-db.sh" "$BIN_DIR/opencode-db"

if [ -f "$CONF_DEST" ]; then
    echo "   Existing config: $CONF_DEST (not modified)"
else
    cp "$SOURCE_ROOT/opencode-db.conf.example" "$CONF_DEST"
    chmod 600 "$CONF_DEST"
    echo "   Config created from example: $CONF_DEST (permissions 600)"
fi

echo "✅ opencode-db-exporter installed in $PREFIX"
echo "   CLI: $BIN_DIR/opencode-db   (also: bash $SOURCE_ROOT/modules/opencode-db.sh)"
echo "   Try: $BIN_DIR/opencode-db status"