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
    local warn=0
    for dep in sqlite3 python3 jq gzip; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo "   ⚠️  Missing '$dep' (needed: apt install $dep)." >&2
            warn=1
        fi
    done
    [ "$warn" -eq 0 ] && echo "   Core dependencies: OK (sqlite3, python3, jq, gzip)."
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

find "$PREFIX/modules" -type f \( -name '*.sh' \) -exec chmod +x {} +
ln -sfn "$PREFIX/modules/opencode-db.sh" "$BIN_DIR/opencode-db"

if [ -f "$CONF_DEST" ]; then
    echo "   Conf existente: $CONF_DEST (no se toca)"
else
    cp "$SOURCE_ROOT/opencode-db.conf.example" "$CONF_DEST"
    chmod 600 "$CONF_DEST"
    echo "   Conf creada desde ejemplo: $CONF_DEST (permisos 600)"
fi

echo "✅ opencode-db-exporter instalado en $PREFIX"
echo "   CLI: $BIN_DIR/opencode-db   (también: bash $SOURCE_ROOT/modules/opencode-db.sh)"
echo "   Prueba: $BIN_DIR/opencode-db status"