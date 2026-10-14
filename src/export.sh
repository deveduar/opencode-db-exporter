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
    # Preview/discovery commands decide for themselves whether the DB is needed:
    # --list-presets/--list-products/--show/--explain never read it, and --dry-run
    # reports a missing DB gracefully instead of dying in bash first. Everything
    # else still needs it.
    local need_db=1 a
    for a in "$@"; do
        case "$a" in
            --list-presets|--list-products|--show|--explain|--dry-run) need_db=0 ;;
        esac
    done
    [ "$need_db" -eq 1 ] && o_db_exists
    oced_export_one "$@"
}

# o_export_profiles -> every name `export <name>` accepts, one per line: the
# product keywords plus the presets in $OCED_PRESETS. exportlib/plan.py is the
# SSoT for both, so a new product or preset shows up here for free (that is why
# this asks python instead of hardcoding "archive"/"memory").
o_export_profiles() {
    {
        OCED_PRESETS="$OCED_PRESETS" python3 "$SCRIPT_DIR/exportlib/plan.py" products 2>/dev/null | cut -f1
        OCED_PRESETS="$OCED_PRESETS" python3 "$SCRIPT_DIR/exportlib/plan.py" names 2>/dev/null
    } | awk 'NF' | sort -u
}

# o_export_profile_known <name> -> 0 when `export <name>` would resolve.
# grep without -q on purpose: it reads all input, so the producer never dies of
# SIGPIPE under pipefail (the AGENTS.md pitfall).
o_export_profile_known() {
    local hit
    hit=$(o_export_profiles | grep -x -- "$1" || true)
    [ -n "$hit" ]
}
