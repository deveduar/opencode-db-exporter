#-----------------------------------------------------------------------
# Sessions details picker (info + compactions)
#-----------------------------------------------------------------------
oc_sessions_rows() {
    session_rows | while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '%s\t%s\n' "$(awk '{print $1}' <<<"$line")" "$line"
    done
}

oc_sessions_picker() {
    local sel key
    while true; do
        local header
        header=$'Sessions — select one to inspect (full info + compaction digests)'
        sel=$(oc_sessions_rows | oc_fzf_sel "sessions (details)" "$header") || return $?
        key=$(oc_sel_key "$sel")
        case "$key" in
            __NONE__) continue ;;
            *)
                run_oced_tool info "$key"
                menu_pause "Sessions" || return 0
                ;;
        esac
    done
}

