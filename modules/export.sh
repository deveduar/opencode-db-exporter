#!/usr/bin/env bash
# export.sh — oced_export: forwards to the Python renderer (modules/export.py).
set -uo pipefail

oced_export() {
    o_check_deps
    o_db_exists
    OPENCODE_DB="$OPENCODE_DB" \
    OCED_OUT="$OCED_OUT" \
    OCED_BACKUP_DIR="$OCED_BACKUP_DIR" \
        python3 "$SCRIPT_DIR/export.py" "$@"
}