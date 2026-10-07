#-----------------------------------------------------------------------
# Backups picker — one entry for create + manage, with a view/remove toggle
# (the same shape as the exports and shrinks pickers: actions first, then the
# mode toggle, then that mode's destructive rows, then the per-item rows).
#-----------------------------------------------------------------------
oc_backups_rows() {
    local mode="$1" order="${2:-newest}"
    local m="$OCED_BACKUP_DIR/manifest.json"
    printf '__CREATE__\t[>] create backup\n'
    oc_toggle_row "$mode" "$([ "$mode" = view ] && printf remove || printf view)"
    if [ "$order" = "newest" ]; then
        oc_toggle_row "newest first" "old first" "__TOGGLE_ORDER__"
    else
        oc_toggle_row "old first" "newest first" "__TOGGLE_ORDER__"
    fi
    if [ "$mode" = "remove" ]; then
        printf '__DELETE_ALL__\t[delete all]\n'
        printf '__KEEP_NEWEST__\t[delete olds]\n'
    fi
    [ -f "$m" ] || { printf '__NONE__\t(no backups yet)\n'; return 0; }
    local file dt sz szh ss ms sha orderjq
    # Same sort the human list uses; `old` flips it. Bulk rows keep newest-first.
    orderjq='.backups | sort_by(.date)'
    [ "$order" = "newest" ] && orderjq="$orderjq | reverse"
    jq -r "$orderjq"' | .[] | [.file, (.date|sub("T";" ")|sub("Z$";"")), (.size|tostring), (.sessions|tostring), ((.messages//0)|tostring), ((.sha256//"-")[:8])] | @tsv' "$m" \
    | while IFS=$'\t' read -r file dt sz ss ms sha; do
        szh=$(o_human_size "$sz")
        printf '%s\t%s\n' "$file" "$(printf '%s  %-9s  %5s sess  %6s msg  sha:%s' "$dt" "$szh" "$ss" "$ms" "$sha")"
    done
}

# Bulk deletions from the backup picker (all / keep newest only).
oc_backups_bulk() {
    local what="$1" m="$OCED_BACKUP_DIR/manifest.json"
    [ -f "$m" ] || { echo "   (no backups yet)"; return 1; }
    local total
    total=$(jq -r '.backups | length' "$m" 2>/dev/null || echo 0)
    [ "$total" -gt 0 ] || { echo "   (no backups yet)"; return 1; }
    local -a files=()
    if [ "$what" = "all" ]; then
        confirm_action "DELETE ALL $total backups? This cannot be undone." || { echo "   cancelled."; return 0; }
        mapfile -t files < <(jq -r '.backups[].file' "$m")
    else
        [ "$total" -le 1 ] && { echo "   Already only 1 backup."; return 0; }
        confirm_action "DELETE $((total - 1)) older backups, keeping only the newest?" || { echo "   cancelled."; return 0; }
        mapfile -t files < <(jq -r '.backups | sort_by(.date) | reverse | .[1:][] | .file' "$m")
    fi
    local f
    for f in "${files[@]}"; do
        run_oced_tool backups remove "$f" --yes
    done
}

oc_backups_picker() {
    local mode="view" order="newest" sel key
    while true; do
        local header
        header="Backups — mode: $mode"
        sel=$(oc_backups_rows "$mode" "$order" | oc_fzf_sel "backups ($mode)" "$header") || return $?
        key=$(oc_sel_key "$sel")
        case "$key" in
            # Plan first, then OUR gate, then run non-interactively — the same
            # shape as the shrink wizard (read-only plan -> y/N -> run). The command
            # used to ask its own [y/N] on stdin from inside a captured call: the
            # prompt never reached the screen and the menu looked frozen until a
            # keypress arrived, which (being an empty line) cancelled the backup.
            __CREATE__)
                run_oced_tool backup --dry-run
                confirm_action "Create this backup now?" || { echo "   cancelled."; continue; }
                run_oced_tool backup --yes
                menu_pause "New backup" || return 0
                continue
                ;;
            __TOGGLE__)     mode=$( [ "$mode" = view ] && printf remove || printf view ); continue ;;
            __TOGGLE_ORDER__) order=$( [ "$order" = newest ] && printf old || printf newest ); continue ;;
            __DELETE_ALL__) oc_backups_bulk all; continue ;;
            __KEEP_NEWEST__) oc_backups_bulk newest; continue ;;
            __NONE__)       continue ;;
            *)
                if [ "$mode" = view ]; then
                    # The details carry the sha256 check too, so viewing a
                    # backup can never look "fine" without validating it.
                    run_oced_tool backups view "$key"
                    menu_pause "Backups" || return 0
                    continue
                fi
                confirm_action "DELETE backup $key?" || continue
                run_oced_tool backups remove "$key" --yes
                continue
                ;;
        esac
    done
}
