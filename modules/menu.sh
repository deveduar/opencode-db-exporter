#!/usr/bin/env bash
# menu.sh — fzf TUI for opencode-db. Split into modules/menu/.

for _m in core backups sessions export exports shrink; do
    . "$SCRIPT_DIR/menu/${_m}.sh"
done

#-----------------------------------------------------------------------
# Root
#-----------------------------------------------------------------------
oc_root=(
    "status|Status report (DB · backups · deps · version/schema)|fn:oc_show_status"
    "backups|Backups (snapshots picker)|fn:oc_backups_picker"
    "shrinks|Shrink copies (create + manage picker)|fn:oc_shrinks_picker"
    "sessions|Sessions (details picker)|fn:oc_sessions_picker"
    "export|Export sessions (named plans picker)|fn:oc_export_picker"
    "exports|Manage exports (view / remove picker)|fn:oc_exports_picker"
    "guide|Guided workflow (inspect -> backup -> export memory -> shrink)|tool:guide|pause"
    "help|Show help|tool:help|pause"
)

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
    oc_root_status
    # --refresh-cb recomputes ACTION_STATUS at the top of every root loop so the
    # header never shows stale info after an action (backup, shrink, export…).
    run_menu --cat "opencode-db" --prompt "actions" --entries oc_root --refresh-cb oc_root_status
}