#!/usr/bin/env bash
# export.sh — oced_export: forwards to the Python renderer (modules/export.py).
set -uo pipefail

oced_export_one() {
    OPENCODE_DB="$(o_effective_db)" \
    OCED_OUT="$OCED_OUT" \
    OCED_BACKUP_DIR="$OCED_BACKUP_DIR" \
    OCED_PRESETS="$OCED_PRESETS" \
        python3 "$SCRIPT_DIR/export.py" "$@"
}

# oced_export [product] [flags]
# product: transcript | memory | compactions (see modules/export.py).
oced_export() {
    o_check_deps
    o_db_exists
    oced_export_one "$@"
}
