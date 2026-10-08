#-----------------------------------------------------------------------
# Sessions BROWSE picker: a row opens the session detail (info + its digests)
#
# A thin cfg wrapper around the generic oc_session_picker in browse mode: the
# screen reads, orders and renders sessions exactly like the export/shrink
# pickers, so there is only one session list in the menu. Nothing is selectable
# here, hence `mode: view` (no marks, no __MAKE__, no mark-all rows).
#
# The compactions toggle is a REPORT filter, so it belongs to the report command
# and not to the shell here: `info <id> --no-digest` drops the digest block. It
# is NOT implemented as a second `digest` call, because `info` already ends with
# that block and calling both printed it twice.
#-----------------------------------------------------------------------
oc_sessions_view_one() {   # $1 = session id [$2=show_compactions 0|1] [$3=hide_subs 0|1]
    local sid="${1:-}"
    local showc="${2:-1}"
    [ -n "$sid" ] || return 0
    if [ "$showc" = "1" ]; then
        run_oced_tool info "$sid"
    else
        run_oced_tool info "$sid" --no-digest
    fi
    menu_pause "Sessions" || return 0
}

# details of all sessions -> one dump of EVERY visible session, in the order
# shown, with no per-session pause (a pause per report would need a keypress per
# session). The GROUP header is printed once by the picker (view_all_header),
# which owns the iteration: a per-session callback cannot tell the first call
# from the last without state the picker already has.
oc_sessions_view_all() {   # $1 = session id [$2=show_compactions] [$3=hide_subs]
    local sid="${1:-}"
    local showc="${2:-1}"
    [ -n "$sid" ] || return 0
    if [ "$showc" = "1" ]; then
        run_oced_tool info "$sid"
    else
        run_oced_tool info "$sid" --no-digest
    fi
    echo ""
}

oc_sessions_picker() {
    local -A sess_cfg=(
        [mode]="view"
        [title]="sessions (details)"
        [header]="pick one to inspect it"
        [order]="updated-desc"
        [view_action]="oc_sessions_view_one"
        [view_action_all]="oc_sessions_view_all"
        [view_all_header]="== Details of all sessions =="
        [get_sub_count]=oc_root_sub_counts
        [get_sub_ids]="oc_export_sub_ids"
    )
    oc_session_picker sess_cfg
}
