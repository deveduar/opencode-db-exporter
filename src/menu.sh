#!/usr/bin/env bash
# menu.sh — fzf TUI for opencode-db. Split into src/menu/.

for _m in core backups sessions export exports shrink; do
    . "$SCRIPT_DIR/menu/${_m}.sh"
done

#-----------------------------------------------------------------------
# Root
#-----------------------------------------------------------------------
oc_root=(
    "exports|Exports|fn:oc_exports_picker"
    "backups|Backups|fn:oc_backups_picker"
    "shrinks|Shrinks|fn:oc_shrinks_picker"
    "sessions|Sessions|fn:oc_sessions_picker"
    "status|Status|fn:oc_show_status"
    "help|Help|tool:help|pause"
)

# Roots extra rows: INSTALL when the tool is not installed yet (and the running
# checkout ships install.sh); UNINSTALL once it is installed (and the running
# tree ships uninstall.sh). The two are mutually exclusive: an installed tool
# offers Uninstall only, a portable checkout not yet installed offers Install
# only. "Installed" is the shim install.sh creates (oc_is_installed).
oc_root_extra_rows() {
    if oc_is_installed; then
        [ -f "$OCED_REPO_ROOT/uninstall.sh" ] && printf 'uninstall|Uninstall|fn:oc_menu_uninstall\n'
    else
        [ -f "$OCED_REPO_ROOT/install.sh" ] && printf 'install|Install|fn:oc_menu_install\n'
    fi
    return 0
}

# oc_repo_script <label> <script> — run a repo script (install/uninstall) with
# the menu's streaming contract (direct tty, never captured) and pause after.
oc_repo_script() {
    local label="$1" script="$2"
    [ -f "$script" ] || { echo "   not found: $script"; return 1; }
    bash "$script"
    menu_pause "$label" || return 0
}
oc_menu_install()   { oc_repo_script "Install"   "$OCED_REPO_ROOT/install.sh"; }
oc_menu_uninstall() { oc_repo_script "Uninstall" "$OCED_REPO_ROOT/uninstall.sh"; }

# oc_root_status -> builds ACTION_STATUS for the root menu header
# Shows: DB path/size, sessions count, WAL state, last backup alignment, export runs count
oc_root_status() {
    ACTION_STATUS=""
    o_db_exists 2>/dev/null || { ACTION_STATUS="DB not found: $OPENCODE_DB"; return 0; }
    local bytes sessions wal_size backup_align export_count
    bytes=$(stat -c %s "$OPENCODE_DB" 2>/dev/null || echo 0)
    sessions=$(o_q "SELECT count(*) FROM session" 2>/dev/null || echo 0)
    if [ -f "$OPENCODE_DB-wal" ]; then
        wal_size=$(stat -c %s "$OPENCODE_DB-wal" 2>/dev/null || echo 0)
    else
        wal_size=0
    fi
    local manifest="$OCED_BACKUP_DIR/manifest.json"
    if [ -f "$manifest" ]; then
        local last_idx msess mmess mu tsess tmess tu
        last_idx=$(jq -r '.backups | length - 1' "$manifest" 2>/dev/null || echo -1)
        if [ "$last_idx" -ge 0 ]; then
            msess=$(jq -r --argjson i "$last_idx" '.backups[$i].sessions' "$manifest" 2>/dev/null || echo 0)
            mmess=$(jq -r --argjson i "$last_idx" '.backups[$i].messages' "$manifest" 2>/dev/null || echo 0)
            mu=$(jq -r --argjson i "$last_idx" '.backups[$i].max_updated' "$manifest" 2>/dev/null || echo 0)
            tsess=$(o_q "SELECT count(*) FROM session" 2>/dev/null || echo 0)
            tmess=$(o_q "SELECT count(*) FROM message" 2>/dev/null || echo 0)
            tu=$(o_q "SELECT max(time_updated) FROM session" 2>/dev/null || echo 0)
            if [ "$msess" = "$tsess" ] && [ "$mmess" = "$tmess" ] && [ "$mu" = "$tu" ]; then
                backup_align="[OK] aligned"
            else
                backup_align="[!] out of sync"
            fi
        else
            backup_align="no backups"
        fi
    else
        backup_align="no backups"
    fi
    export_count=$(exports_run_count 2>/dev/null || echo 0)
    ACTION_STATUS="DB: $(o_human_size "$bytes") | Sessions: $sessions | WAL: $(o_human_size "$wal_size") | Backup: $backup_align | Exports: $export_count"
}

oc_show_status() {
    run_oced_tool status
    menu_pause "Status" || return 0
}

run_oc_menu() {
    menu_require_fzf
    o_check_deps
    oc_root_status
    # Build the entry list per run (never mutate the global oc_root): the
    # install/uninstall row is appended only when the state calls for it. The name
    # must differ from run_menu's own `entries` local or the nameref would bind to
    # the wrong variable (run_menu stores the NAME in a local called `entries`).
    local -a oc_root_entries=( "${oc_root[@]}" )
    local _r
    while IFS= read -r _r; do
        [ -n "$_r" ] && oc_root_entries+=("$_r")
    done < <(oc_root_extra_rows)
    # --refresh-cb recomputes ACTION_STATUS at the top of every root loop so the
    # header never shows stale info after an action (backup, shrink, export…).
    run_menu --cat "opencode-db" --prompt "actions" --entries oc_root_entries --refresh-cb oc_root_status
}