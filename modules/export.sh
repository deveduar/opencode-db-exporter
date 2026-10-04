#!/usr/bin/env bash
# export.sh — oced_export: forwards to the Python renderer
# (exportlib/cli.py, the self-bootstrapping CLI entry — no shim needed).
set -uo pipefail

oced_export_one() {
    OPENCODE_DB="$(o_effective_db)" \
    OCED_OUT="$OCED_OUT" \
    OCED_BACKUP_DIR="$OCED_BACKUP_DIR" \
    OCED_PRESETS="$OCED_PRESETS" \
        python3 "$SCRIPT_DIR/exportlib/cli.py" "$@"
}

# oced_export [product] [flags]
# product: transcript | memory | digest (see exportlib/cli.py).
oced_export() {
    o_check_deps
    o_db_exists
    oced_export_one "$@"
}
