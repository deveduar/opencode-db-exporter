#!/usr/bin/env bash
# menu.sh — interactive (fzf) menu for opencode-db, standalone.
#
# Level navigation: ESC goes up one level; on the main level ESC exits.
# Entry contract (array per submenu):
#   "key|label|action"
#     - key:   token (returned by choose_action)
#     - label: text shown in fzf (accepts ANSI)
#     - action: tool:<cmd>[::args] | menu:<fn> | fn:<fn> | builtin:exit | (empty = no-op)

# Colon gates (without them it can only run as a dispatcher module).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # Direct execution: enqueue the entry and call the dispatcher as source.
    exec bash "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/opencode-db.sh" menu
fi

C_GREEN=$'\033[32m'
C_CYAN=$'\033[36m'
C_RESET=$'\033[0m'

OC_DISPATCHER="${OCED_DISPATCHER:-$SCRIPT_DIR/opencode-db.sh}"

menu_require_fzf() {
    if ! command -v fzf >/dev/null 2>&1; then
        echo "ERROR: fzf missing. Install it with: opencode-db deps" >&2
        exit 1
    fi
}

# oced_out <command...> -> dispatcher stdout (to capture output).
oced_out() {
    bash "$OC_DISPATCHER" "$@"
}

# run_oced_tool <command...> -> runs the dispatcher without breaking the menu.
run_oced_tool() {
    bash "$OC_DISPATCHER" "$@" || true
    return 0
}

confirm_action() {
    local message="$1"
    local answer
    printf '%s [y/N] ' "$message"
    read -r answer
    [[ "$answer" =~ ^[yYsS]$ ]]
}

# oc_read_int <label> -> reads a positive integer. ESC cancels IMMEDIATELY
# (no Enter needed); empty or non-numeric input cancels too (rc=1).
# Prompt/feedback go to stderr so the value is clean on stdout (capture-safe).
oc_read_int() {
    local label="$1" c rest v
    printf '%s (number · ESC/empty = cancel): ' "$label" >&2
    IFS= read -r -s -n1 c >&2 || { echo >&2; return 1; }
    case "$c" in
        "" ) echo "   cancelled." >&2; return 1 ;;
        $'\e' ) echo "   cancelled." >&2; return 1 ;;
        $'\n' ) echo "   cancelled." >&2; return 1 ;;  # Enter alone = cancel (destructive)
    esac
    printf '%s' "$c" >&2
    IFS= read -r rest || true
    v="$c${rest:-}"
    echo >&2
    case "$v" in
        *[!0-9]*) echo "   (cancelled: '$v' is not a number)" >&2; return 1 ;;
    esac
    printf '%s\n' "$v"
}

# menu_pause <label> -> light pause after a REPORT action (entry marked "|pause")
# so the user can copy the output (fzf closed). Returns 0 (Enter) or 2 (ESC).
# Skipped when stdin is not a TTY (scripts/tests never hang).
menu_pause() {
    [ -t 0 ] || return 0
    printf '\n— %s · Enter: back to menu · Esc: exit this submenu — ' "$1"
    local key
    read -r -s -n1 key || return 2
    [ "$key" = $'\e' ] && return 2
    return 0
}

# choose_action <cat> <entry>... -> returns the chosen key.
# Returns 0 + key on success, 1 on EOF/no selection, 130 on ESC.
choose_action() {
    local category="$1"
    shift
    local entry key label rest selected header="Choose an action"
    [ -n "${ACTION_STATUS:-}" ] && header+=$'\n\n'"${C_CYAN}${ACTION_STATUS}${C_RESET}"
    selected=$(for entry in "$@"; do
        if [[ "$entry" == *"|"* ]]; then
            key="${entry%%|*}"
            rest="${entry#*|}"
            label="${rest%%|*}"
        else
            key="$entry"
            label="$entry"
        fi
        printf '%s\t%s\n' "$key" "$label"
    done | fzf --ansi --delimiter=$'\t' --with-nth=2.. --height=60% --reverse --border \
        --prompt="[$category] > " --header="$header")
    local fzf_rc=$?
    [ $fzf_rc -eq 130 ] && return 130  # ESC pressed
    [ -n "$selected" ] || return 1
    printf '%s\n' "${selected%%$'\t'*}"
}

# _oc_menu_call <action> -> runs an action.
#   tool:<cmd>[::args] (*)    dispatches to the opencode-db binary (OC_DISPATCHER)
#   menu:<fn> | fn:<fn>       submenu / handler of this module
#   builtin:exit              signal end (rc=2)
# Returns 0 always, except builtin:exit (2). Nested menus closing (any rc) are
# swallowed: the parent reloads its own list.
_oc_menu_call() {
    local action="$1"
    local spec fn
    local -a args=()
    case "$action" in
        tool:*)
            spec="${action#tool:}"
            if [[ "$spec" == *"::"* ]]; then
                read -r -a args <<< "${spec#*::}"
                spec="${spec%%::*}"
            fi
            run_oced_tool "$spec" "${args[@]}"
            ;;
        menu:*|fn:*)
            spec="${action#*:}"
            if [[ "$spec" == *"::"* ]]; then
                fn="${spec%%::*}"
                read -r -a args <<< "${spec#*::}"
            else
                fn="$spec"
            fi
            "$fn" "${args[@]}" || true
            return 0
            ;;
        builtin:exit)
            return 2
            ;;
        *) return 1 ;;
    esac
}

# run_menu — data-driven submenu loop. No forced pause except "|pause" (report): the
# fzf menu reloads immediately after an action; ESC on fzf climbs exactly ONE level.
run_menu() {
    local cat="menu" promptlabel="menu" entries="" refresh_cb="" empty_msg="" no_prompt=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --cat) cat="$2"; shift 2 ;;
            --prompt) promptlabel="$2"; shift 2 ;;
            --entries) entries="$2"; shift 2 ;;
            --refresh-cb) refresh_cb="$2"; shift 2 ;;
            --empty-msg) empty_msg="$2"; shift 2 ;;
            --no-prompt) no_prompt=1; shift ;;
            *) echo "run_menu: unknown flag: $1" >&2; return 0 ;;
        esac
    done

    while true; do
        MENU_FLOW=continue
        if [ -n "$refresh_cb" ]; then
            "$refresh_cb" || true
        fi
        if [ "$MENU_FLOW" = "exit" ]; then
            return 0
        fi
        if [ -z "$entries" ] || ! declare -p "$entries" >/dev/null 2>&1; then
            [ -n "$empty_msg" ] && echo "$empty_msg"
            return 0
        fi
        local -n arr="$entries"
        if [ "${#arr[@]}" -eq 0 ]; then
            [ -n "$empty_msg" ] && echo "$empty_msg"
            return 0
        fi

        local key e rest action="" pause=0
        key=$(choose_action "$cat" "${arr[@]}")
        local choose_rc=$?
        [ $choose_rc -eq 130 ] && return 2  # ESC in fzf -> climb one level
        [ $choose_rc -ne 0 ] && return 0    # other error -> close submenu
        for e in "${arr[@]}"; do
            if [ "${e%%|*}" = "$key" ]; then
                rest="${e#*|}"
                if [[ "$rest" == *"|"* ]]; then
                    action="${rest#*|}"
                fi
                break
            fi
        done
        if [ -z "$action" ]; then
            continue
        fi
        if [[ "$action" == *"|pause" ]]; then
            pause=1
            action="${action%|pause}"
        fi

        local rc=0
        _oc_menu_call "$action" || rc=$?
        if [ "$rc" -eq 2 ]; then
            return 0  # builtin:exit -> close this submenu (parent reloads)
        fi
        if [ "$pause" -eq 1 ]; then
            menu_pause "$promptlabel" || return 0
        fi
        continue  # menu reloads immediately (unless |pause)
    done
}

#-----------------------------------------------------------------------
# Selection helpers
#-----------------------------------------------------------------------
# session rows -> one per line: id title date ... (sqlite column separators excluded).
session_rows() {
    oced_out list --info 2>/dev/null | awk 'NR>2 && $1 ~ /^ses_/'
}

# session_ids -> one session id per line (all sessions, for "all sessions" loops).
session_ids() {
    session_rows | awk '{print $1}'
}

# pick_session <prompt> -> prints a session id, or empty for "all sessions".
# ESC cancels (rc=1); never selects a default.
pick_session() {
    local prompt="$1" sel
    sel=$(printf 'ALL SESSIONS (no filter)\n%s' "$(session_rows)" \
        | fzf --prompt="$prompt > " --height=60% --border --header="ESC: cancel") || return 1
    [ -n "$sel" ] || return 1
    case "$sel" in
        ALL*) printf '\n' ;;
        *) printf '%s\n' "$sel" | awk '{print $1}' ;;
    esac
}

# pick_backup_file -> prints a backup file name (or empty).
pick_backup_file() {
    local prompt="$1" opts sel
    opts=$(oced_out backups list 2>/dev/null | awk '/^[ ]*[0-9]+\./ {print $3}')
    [ -n "$opts" ] || { echo "   (no backups yet: run Backup first)"; return 1; }
    sel=$(printf '%s\n' "$opts" | fzf --prompt="$prompt > " --height=40% --border --header="ESC: cancel") || return 1
    printf '%s\n' "$sel"
}

#-----------------------------------------------------------------------
# Submenu data
#-----------------------------------------------------------------------
oc_root=(
    "db|Database and backups|menu:run_oc_menu_db"
    "sessions|Sessions (list/info/compactions)|menu:run_oc_menu_sessions"
    "export|Export sessions to Markdown (recipes, session)...|fn:oc_export_flow"
    "exports|Export runs (list/remove/prune)|menu:run_oc_menu_exports"
    "deps|Check/install dependencies...|tool:deps|pause"
    "help|Show help|tool:help|pause"
)

oc_menu_db=(
    "status|Status report (DB + last backup alignment)|tool:status|pause"
    "backup|Create backup (consistent snapshot)|tool:backup|pause"
    "list|List backups|tool:backups|pause"
    "verify|Verify a backup (sha256)...|fn:oc_pick_backup_verify"
    "prune|Prune old backups (keep N)...|fn:oc_pick_backup_prune"
)

oc_menu_sessions=(
    "list|List sessions (with info)|tool:list::--info|pause"
    "info|Session details...|fn:oc_pick_info"
    "compactions|Compactions of a session...|fn:oc_pick_compactions"
)

oc_menu_exports=(
    "list|List export runs|tool:exports::list|pause"
    "remove|Remove an export run...|fn:oc_pick_export_remove"
    "prune|Prune old export runs (keep N)...|fn:oc_pick_export_prune"
)

# Export recipes: "label|profile|arg1 arg2 ..."
oc_recipes=(
    "ALL profiles, maximal (4-in-1)|all|"
    "full (default)|full|"
    "full + full tool output|full|--tool-output full"
    "full + omit tool output|full|--tool-output omit"
    "full + omit patches|full|--patch omit"
    "full + context markers|full|--mark-compactions"
    "full + summary diffs|full|--summary-diffs"
    "full + context markers + summary diffs|full|--mark-compactions --summary-diffs"
    "full + subagents inline|full|--sub inline"
    "full + omit subagents|full|--sub omit"
    "no-calls (default)|no-calls|"
    "no-calls + summary diffs|no-calls|--summary-diffs"
    "no-calls + subagents inline|no-calls|--sub inline"
    "no-calls + omit subagents|no-calls|--sub omit"
    "text-only (default)|text-only|"
    "text-only + subagents inline|text-only|--sub inline"
    "text-only + omit subagents|text-only|--sub omit"
)

#-----------------------------------------------------------------------
# Handlers
#-----------------------------------------------------------------------
# run_for_all <cmd> <label>... -> runs the dispatcher cmd for every session.
run_for_all() {
    local cmd="$1" label="$2" sid
    echo "== $label — all sessions =="
    while IFS= read -r sid; do
        [ -n "$sid" ] || continue
        echo ""
        run_oced_tool "$cmd" "$sid"
    done <<<"$(session_ids)"
}

oc_pick_info() {
    local id
    id=$(pick_session "Session details") || return 1
    id=$(printf '%s' "$id" | tr -d '\n')
    if [ -z "$id" ]; then
        run_for_all info "Session details"
    else
        run_oced_tool info "$id"
    fi
    menu_pause "Sessions" || return 0
}

oc_pick_compactions() {
    local id
    id=$(pick_session "Compactions of session") || return 1
    id=$(printf '%s' "$id" | tr -d '\n')
    if [ -z "$id" ]; then
        run_for_all compactions "Compactions"
    else
        run_oced_tool compactions "$id"
    fi
    menu_pause "Sessions" || return 0
}

oc_pick_backup_verify() {
    local f
    f=$(pick_backup_file "Backup to verify") || return 1
    run_oced_tool backups verify "$f"
}

oc_pick_backup_prune() {
    local keep n
    keep=$(oc_read_int "How many recent backups to keep") || { echo "   cancelled."; return 0; }
    keep=$(printf '%s' "$keep" | tr -d '\n')
    n=$(jq -r '.backups | length' "$(manifest_path)" 2>/dev/null || echo 0)
    if [ "$n" -le "$keep" ]; then
        echo "   Nothing to prune (have $n, keeping $keep)."
        return 0
    fi
    confirm_action "Prune: WILL DELETE $((n - keep)) backup file(s), keeping the $keep most recent. Continue?" \
        || { echo "   cancelled."; return 0; }
    run_oced_tool backups prune "$keep"
}

oc_pick_export_remove() {
    local stamp
    stamp=$(pick_export_run "Export run to remove") || return 1
    confirm_action "Remove export run $stamp? It deletes the generated files." || { echo "   cancelled."; return 0; }
    run_oced_tool exports remove "$stamp" --yes
}

oc_pick_export_prune() {
    local keep n
    keep=$(oc_read_int "How many recent export runs to keep") || { echo "   cancelled."; return 0; }
    keep=$(printf '%s' "$keep" | tr -d '\n')
    n=$(exports_run_count)
    if [ "$n" -le "$keep" ]; then
        echo "   Nothing to prune (have $n, keeping $keep)."
        return 0
    fi
    confirm_action "Prune: WILL DELETE $((n - keep)) export run(s), keeping the $keep most recent. Continue?" \
        || { echo "   cancelled."; return 0; }
    run_oced_tool exports prune "$keep"
}

# pick_export_run <prompt> -> prints a run stamp (or empty).
pick_export_run() {
    local prompt="$1" opts sel
    opts=$(oced_out exports list 2>/dev/null | awk '/^[ ]*[0-9]+\./ {print $2}')
    [ -n "$opts" ] || { echo "   (no export runs yet)"; return 1; }
    sel=$(printf '%s\n' "$opts" | fzf --prompt="$prompt > " --height=40% --border --header="ESC: cancel") || return 1
    printf '%s\n' "$sel"
}

# exports_run_count -> number of export run dirs under OCED_OUT.
exports_run_count() {
    [ -d "$OCED_OUT" ] || { echo 0; return; }
    find "$OCED_OUT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l
}

# oc_export_flow — two screens: recipes (multi-select) -> session (or all).
# ESC always cancels; each selected recipe becomes its own export run.
oc_export_flow() {
    local picks f pick label rest profile args
    local -a idfilter=() arr=()
    f=$(printf '%s\n' "${oc_recipes[@]}" \
        | fzf --multi --prompt="Export recipes (TAB to select, Enter to export; ESC = cancel) > " \
            --height=60% --border --header="Each selected recipe produces its own export run.") || return 1
    [ -n "$f" ] || return 1

    local selid
    selid=$(pick_session "Sessions to export") || return 1
    selid=$(printf '%s' "$selid" | tr -d '\n')
    [ -n "$selid" ] && idfilter=(--filter "$selid")

    # Export plan + confirmation: heavy on large DBs, show paths & sizes first.
    local db_est=0 n_recipes
    [ -f "${OPENCODE_DB}-wal" ] && db_est=$((db_est + $(stat -c %s "${OPENCODE_DB}-wal"))) || true
    [ -f "${OPENCODE_DB}-shm" ] && db_est=$((db_est + $(stat -c %s "${OPENCODE_DB}-shm"))) || true
    db_est=$((db_est + $(stat -c %s "$OPENCODE_DB")))
    n_recipes=$(printf '%s\n' "$f" | sed '/^[[:space:]]*$/d' | wc -l)
    echo ""
    echo "-> Export plan"
    printf '   %-9s %s  %s\n' "Source:" "$OPENCODE_DB" "($(command -v o_human_size >/dev/null 2>&1 && o_human_size "$db_est" || echo "$db_est bytes") raw)"
    printf '   %-9s %s\n' "Filter:" "${selid:-ALL sessions (no filter)}"
    printf '   %-9s %s\n' "Output:" "$OCED_OUT/<timestamp>"
    printf '   %-9s %d run(s), one per selected recipe\n' "Recipes:" "$n_recipes"
    confirm_action "Start these export(s)? Heavy on a large DB." || { echo "   cancelled."; return 0; }

    while IFS= read -r pick; do
        [ -n "$pick" ] || continue
        label="${pick%%|*}"
        rest="${pick#*|}"
        profile="${rest%%|*}"
        args="${rest#*|}"
        arr=()
        [ -n "$args" ] && read -r -a arr <<<"$args"
        echo "   Exporting: $label  (${idfilter[*]:-all sessions})"
        run_oced_tool export "$profile" "${idfilter[@]}" "${arr[@]}"
        echo "   ----"
    done <<<"$f"

    menu_pause "Export runs" || return 0
}

#-----------------------------------------------------------------------
# Levels
#-----------------------------------------------------------------------
run_oc_menu_db() {
    run_menu --cat "opencode-db>db" --prompt "Database and backups" --entries oc_menu_db
}

run_oc_menu_sessions() {
    run_menu --cat "opencode-db>sessions" --prompt "Sessions" --entries oc_menu_sessions
}

run_oc_menu_exports() {
    run_menu --cat "opencode-db>exports" --prompt "Export runs" --entries oc_menu_exports
}

run_oc_menu() {
    menu_require_fzf
    run_menu --cat "opencode-db" --prompt "actions" --entries oc_root
}