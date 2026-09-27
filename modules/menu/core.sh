# menu.sh — interactive (fzf) menu for opencode-db, standalone.
#
# Level navigation: ESC goes up one level; on the main level ESC exits.
# Root entries and pickers:
#   status    status report (DB · backups · deps · version/schema)
#   backups   level 2 = fzf picker over the backups (create / delete, bulk rows)
#   shrinks   level 2 = fzf picker to CREATE pruned copies and manage the runs
#             (view shrink.json / toggle to remove), like exports
#   sessions  level 2 = a real fzf picker over the sessions (details)
#   exports   level 2 = a real fzf picker over the export runs (view/remove)
#   export    named-plans picker (preset-first; presets file required)
# The pickers use TSV rows (key<TAB>display); fzf shows only the display column
# and the full selected line keeps the hidden key for parse-back.
# No TAB multi-select anywhere: the "switch mode" is itself a menu row, and bulk
# deletes are their own rows ([delete all] / [delete olds]).
# The root header (ACTION_STATUS) is recomputed on every loop via
# --refresh-cb oc_root_status, so it never shows stale state after an action.

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

# oc_confirm_typed <word> -> hard confirmation gate for destructive actions (swap):
# the action only continues when the user types <word> exactly (Enter alone or a
# mismatch cancels). Return 0 = accepted, 1 = cancelled.
oc_confirm_typed() {
    local word="$1" ans
    printf '   Type exactly "%s" (lowercase) to continue, anything else cancels: ' "$word"
    read -r ans || { echo "   cancelled."; return 1; }
    [ "$ans" = "$word" ] && return 0
    echo "   cancelled."
    return 1
}

# menu_pause <label> -> light pause after a REPORT action so the user can copy
# the output (fzf closed). Returns 0 (Enter) or 2 (ESC). Skipped when stdin is
# not a TTY (scripts/tests never hang).
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
# session_rows [args...] -> `list` rows (default: every session). With --root it
# returns only the ROOT sessions (no parent, or an orphan whose parent is gone):
# the shrink picker works on roots because a subagent always follows its root.
session_rows() {
    oced_out list "$@" --info 2>/dev/null | awk 'NR>2 && $1 ~ /^ses_/'
}

# session_ids -> one session id per line (all sessions, for "all sessions" loops).
session_ids() {
    session_rows | awk '{print $1}'
}

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

#-----------------------------------------------------------------------
# fzf picker plumbing (TSV: key<TAB>display; no TAB multi-select state)
#-----------------------------------------------------------------------
# oc_fzf_sel <prompt> <header> -> reads key<TAB>display rows on stdin, shows only
# the display, prints the FULL selected line (key kept for parse-back).
oc_fzf_sel() {
    local prompt="$1" header="$2"
    fzf --prompt="$prompt > " --height=60% --border --header="$header" \
        --delimiter=$'\t' --with-nth=2..
}

oc_sel_key() { printf '%s\n' "$1" | cut -f1; }

# The mode-switch row: '[*] <current>  →  <other>'. ONE symbol for every toggle
# in the menu (view/remove, sort order, subagent visibility) — the bracket token
# says what the row does, so the words only have to name the two states. `[>]` is
# reserved for rows that OPEN A FLOW (create, swap, choose preset). The caller
# passes the label it wants to see (a picker has ONE such row unless it passes an
# explicit key for a second switch, e.g. the subagent visibility row).
oc_toggle_row() {
    local mode="$1" other="$2" key="${3:-__TOGGLE__}"
    printf '%s\t[*] %s  →  %s\n' "$key" "$mode" "$other"
}

#-----------------------------------------------------------------------
# oc_session_picker <cfg_ref> — generic multi-mark session picker.
#
# cfg_ref = NAME of a local assoc array with these keys:
#   roots_only       0|1   — 1 = --root filter (shrink), 0 = all sessions (export)
#   title            str   — fzf prompt label
#   header           str   — fzf header (may have \n)
#   order            str   — initial sort key (updated-desc|updated-asc|…)
#   order_mode       str   — human label for the current order
#   make_label       str   — display text for the __MAKE__ row
#   make_action      str   — bash function called with "marked-ids-csv"
#   empty_guard_msg  str   — shown when __MAKE__ pressed with nothing marked
#   get_sub_count    str   — function that prints "id\tcount" TSV (badges)
#   get_sub_ids      str   — function that prints one REAL subagent id per line;
#                           enables the __SUBS__ visibility row (when set, a
#                           hidden subagent is not rendered and never reaches the
#                           CSV, so unmarking a session takes its subagents with
#                           it). Without it (shrink) there is no such row.
#   header           str   — optional lead-in for the one-line status bar
#                           ("<header> · N/M marked · <order> · …").
#
# Marks live in a local assoc array (1/0, never unset): new IDs default to 1
# so existing unmarks survive re-renders, order toggles and bulk ops.
# __MAKE__   -> build CSV of marked IDs -> call make_action(csv, unmarked-csv)
#              (+ hide_subs as a 3rd arg when the picker has the __SUBS__ row)
#              rc 130 from sub-action = ESC -> loop (marks intact)
#              any other rc            -> return that rc
# __TOGGLE__ -> flip order updated-desc <-> updated-asc
# __SUBS__   -> flip subagent visibility (only when get_sub_ids is set)
# __ALL__ / __NONE__ -> the only bulk rows (recency is a selection, not a
#                 marking, so it lives on the CLI as --last/--since)
# session row -> toggle 0 <-> 1
# ESC in fzf  -> return 0 (caller climbs one level)
#-----------------------------------------------------------------------
oc_session_picker() {
    local cfg_ref="$1"
    local -n cfg="$cfg_ref"

    local roots_only="${cfg[roots_only]:-0}"
    local title="${cfg[title]:-sessions}"
    local header="${cfg[header]:-}"
    local ord="${cfg[order]:-updated-desc}"
    local ord_mode="${cfg[order_mode]:-newest first}"
    local make_label="${cfg[make_label]:-[>] continue}"
    local make_action="${cfg[make_action]:-}"
    local empty_guard_msg="${cfg[empty_guard_msg]:-Nothing is marked.}"
    local get_sub_count="${cfg[get_sub_count]:-}"
    local get_sub_ids="${cfg[get_sub_ids]:-}"

    local -a ids=() top=()
    local -A marks=() local_disp=() sub_n=() is_sub=()
    local id line mark sel key n csv all_ids label order_dir
    local hide_subs=0 subs_note=""

    # Pre-load subagent counts once (static; badges don't change mid-flow).
    if [ -n "$get_sub_count" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            sub_n["${line%%$'\t'*}"]="${line##*$'\t'}"
        done < <("$get_sub_count")
    fi
    # The subagent set is static too: it decides which rows the __SUBS__ row hides.
    if [ -n "$get_sub_ids" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            is_sub["$line"]=1
        done < <("$get_sub_ids")
    fi

    while true; do
        # Re-read rows in the ACTIVE order on every render.
        ids=(); local_disp=()
        local -a row_args=("--order" "$ord")
        [ "$roots_only" = "1" ] && row_args=("--root" "--order" "$ord")
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            id=$(awk '{print $1}' <<<"$line")
            # A hidden subagent is not rendered, so it can never be marked and
            # never reaches the CSV: the selection cascades to it by construction.
            if [ "$hide_subs" = "1" ] && [ -n "${is_sub[$id]+set}" ]; then
                continue
            fi
            ids+=("$id")
            local_disp["$id"]="${line#* }"
        done < <(session_rows "${row_args[@]}")

        if [ "${#ids[@]}" -eq 0 ]; then
            echo "   (no sessions to select)"
            return 1
        fi

        # First-seen IDs default to marked=1; explicit unmarks (0) persist.
        for id in "${ids[@]}"; do [ -n "${marks[$id]+set}" ] || marks[$id]=1; done

        local toggle_other
        [ "$ord_mode" = "newest first" ] && toggle_other="old first" || toggle_other="newest first"

        # One line of essential state, recomputed every render: how many are
        # marked, in which order, and which modes are active. A caveat line only
        # when a mode has a consequence the rows do not show on their own.
        local marked_n=0 unmarked_n=0
        for id in "${ids[@]}"; do
            if [ "${marks[$id]:-0}" = 1 ]; then marked_n=$((marked_n + 1)); else unmarked_n=$((unmarked_n + 1)); fi
        done
        # The active modes, on ONE line. A caveat line follows only when a mode
        # has a consequence the rows cannot show on their own.
        subs_note="$marked_n/${#ids[@]} marked · $ord_mode"
        [ -n "$header" ] && subs_note="$header · $subs_note"
        if [ -n "$get_sub_ids" ] && [ "$hide_subs" = "1" ]; then
            subs_note+=" · subagents hidden, never exported"
        fi
        subs_note+=" · ESC: back"
        if [ -n "$get_sub_ids" ] && [ "$hide_subs" = "0" ]; then
            # The one rule a row cannot show: a shown subagent is marked on its
            # own, so un-marking its session does not take it along.
            subs_note+=$'\n'"subagents keep their own mark: un-marking a session does not remove them"
        fi

        sel=$( {
                 printf '__MAKE__\t%s\n' "$make_label"
                 oc_toggle_row "$ord_mode" "$toggle_other"
                 if [ -n "$get_sub_ids" ]; then
                     if [ "$hide_subs" = "0" ]; then
                         oc_toggle_row "subagents: shown" "hidden" "__SUBS__"
                     else
                         oc_toggle_row "subagents: hidden" "shown" "__SUBS__"
                     fi
                 fi
                 printf '__ALL__\t[mark all]\n'
                 printf '__NONE__\t[unmark all]\n'
                 for id in "${ids[@]}"; do
                     [ "${marks[$id]:-0}" = 1 ] && mark='[x]' || mark='[ ]'
                     local badge=''
                     [ -n "${sub_n[$id]:-}" ] && badge=" (${sub_n[$id]} sub)"
                     printf '%s\t%s %s%s\n' "$id" "$mark" "${local_disp[$id]:-}" "$badge"
                 done
               } | oc_fzf_sel "$title" "$subs_note") || return $?

        key=$(oc_sel_key "$sel")
        case "$key" in
            __MAKE__)
                local marked_csv="" unmarked_csv="" marked_any=0
                for id in "${ids[@]}"; do
                    if [ "${marks[$id]:-0}" = 1 ]; then
                        marked_any=1
                        marked_csv="${marked_csv:+$marked_csv,}$id"
                    else
                        unmarked_csv="${unmarked_csv:+$unmarked_csv,}$id"
                    fi
                done
                if [ "$marked_any" -eq 0 ]; then
                    echo ""
                    echo "   $empty_guard_msg"
                    continue
                fi
                [ -n "$make_action" ] || return 0
                # The 3rd arg (hide_subs) is passed ONLY when the picker has the
                # __SUBS__ row, so callbacks without it keep their old arity.
                if [ -n "$get_sub_ids" ]; then
                    "$make_action" "$marked_csv" "$unmarked_csv" "$hide_subs"
                else
                    "$make_action" "$marked_csv" "$unmarked_csv"
                fi
                local _rc=$?
                [ "$_rc" -eq 130 ] && continue   # ESC in sub-action -> loop
                return "$_rc"
                ;;
            __TOGGLE__)
                if [ "$ord_mode" = "newest first" ]; then
                    ord=updated-asc; ord_mode="old first"
                else
                    ord=updated-desc; ord_mode="newest first"
                fi
                ;;
            __SUBS__)
                if [ "$hide_subs" = "0" ]; then hide_subs=1; else hide_subs=0; fi
                ;;
            __ALL__)   for id in "${ids[@]}"; do marks[$id]=1; done ;;
            __NONE__)  for id in "${ids[@]}"; do marks[$id]=0; done ;;
            *)
                if [ -n "$key" ] && [ "$key" != "__NONE__" ]; then
                    [ "${marks[$key]:-0}" = 1 ] && marks[$key]=0 || marks[$key]=1
                fi
                ;;
        esac
    done
}

