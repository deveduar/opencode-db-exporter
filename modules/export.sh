#!/usr/bin/env bash
# export.sh — oced_export: forwards to the Python renderer (modules/export.py).
set -uo pipefail

oced_export_one() {
    OPENCODE_DB="$OPENCODE_DB" \
    OCED_OUT="$OCED_OUT" \
    OCED_BACKUP_DIR="$OCED_BACKUP_DIR" \
        python3 "$SCRIPT_DIR/export.py" "$@"
}

# oced_export [profile|all] [flags]
# 'all' is a meta-profile: it writes the four profiles (full, no-calls,
# text-only, compactions) into ONE run folder, each with maximal capabilities.
oced_export() {
    o_check_deps
    o_db_exists
    if [ "${1:-}" = "all" ]; then
        shift
        local stamp base_stamp n=2 p rc=0
        base_stamp=$(date -u +%Y%m%d-%H%M%S)
        stamp="$base_stamp"
        while [ -e "$OCED_OUT/$stamp" ]; do
            stamp="$base_stamp@$n"
            n=$((n + 1))
        done
        for p in full no-calls text-only compactions; do
            echo "== export all: profile '$p' (maximal) =="
            oced_export_one "$p" --stamp "$stamp" \
                --tool-output full --patch full --mark-compactions --summary-diffs --sub separate \
                "$@" || rc=$?
        done
        return "$rc"
    fi
    oced_export_one "$@"
}
