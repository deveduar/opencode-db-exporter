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
#
# IT STREAMS, IT NEVER CAPTURES. Capturing the output (`out=$(… 2>&1)`) makes the
# dispatcher talk to a PIPE, so anything it writes — including a question it
# asks on stdin — stays invisible until the process exits: `backup` printed its
# plan and then "Create this backup? [y/N]", blocked on `read`, and the menu
# looked FROZEN; the keypress that eventually arrived was an empty line, so the
# plan appeared and the backup was cancelled. Same failure class as the removed
# guide wizard (a stdin prompt inside the menu). `tee` keeps the output on the
# terminal AND in a log, which is all the stamp extraction below needs.
#
# A successful `export` / `shrink` publishes its run stamp in
# OCED_LAST_EXPORT_STAMP / OCED_LAST_SHRINK_STAMP: the dispatcher already prints
# the folder it wrote ("[OK] Exported … to: <dir>", "Copy ready: <dir>/<stamp>
# /opencode.shrunk.db"), so we read the stamp from THAT line instead of guessing
# "the newest folder by mtime" afterwards — a second run, a concurrent run or a
# pre-existing newer run would all make the guess name the wrong one.
run_oced_tool() {
    local log d out
    log=$(mktemp "${TMPDIR:-/tmp}/oced-tool.XXXXXX" 2>/dev/null) || log=""
    if [ -z "$log" ]; then
        # No log available: run it plainly rather than hide the output. The stamp
        # helpers are best-effort (a missing OCED_LAST_* only costs a hint).
        bash "$OC_DISPATCHER" "$@" 2>&1 || true
        return 0
    fi
    bash "$OC_DISPATCHER" "$@" 2>&1 | tee "$log" || true
    out=$(<"$log")
    rm -f "$log"
    case "${1:-}" in
        export)
            d=$(sed -n 's/.*\[OK\] Exported.*to: //p' <<<"$out" | tail -1)
            [ -n "$d" ] && { OCED_LAST_EXPORT_STAMP="$(basename "$d")"; export OCED_LAST_EXPORT_STAMP; }
            ;;
        shrink)
            # Only the copy-building path prints "Copy ready:"; --swap returns early.
            d=$(sed -n 's/.*Copy ready: //p' <<<"$out" | tail -1)
            [ -n "$d" ] && { OCED_LAST_SHRINK_STAMP="$(basename "$(dirname "$d")")"; export OCED_LAST_SHRINK_STAMP; }
            ;;
    esac
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

# menu_pause <label> -> light pause after a REPORT/ACTION so the user can read
# the output (fzf closed). Returns 0 (Enter) or 2 (ESC). Skipped when stdin is
# not a TTY (scripts/tests never hang).
#
# THE navigation contract every picker follows:
#   menu_pause "$x" || return 0   # ESC  -> leave the submenu (main menu)
#   continue                       # Enter -> redraw THIS picker's list
# run_menu has no back-stack: a picker function that RETURNS hands control back
# to the root menu (core.sh), so "go back to the list I came from" can only be
# expressed by `continue` inside the picker's own while-loop. Reports used to
# `return 0` after the pause, which is why Enter jumped to the root while the
# remove paths (confirm_action || continue) correctly stayed put.
menu_pause() {
    [ -t 0 ] || return 0
    printf '\n— %s · Enter: back to the list · Esc: main menu — ' "$1"
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
# session_rows [args...] -> one TAB-separated row per session: id, title,
# created, updated, agent, parent_id, parent_title, directory (default: every
# session). With --root it returns only the ROOT sessions (no parent, or an
# orphan whose parent is gone): the shrink picker works on roots because a
# subagent always follows its root. The rows come from `list --tsv` (clean
# fields, no sqlite -column padding, no token/cost columns): the picker builds
# its own label from them.
session_rows() {
    oced_out list --tsv "$@" 2>/dev/null | awk -F'\t' '$1 ~ /^ses_/'
}

# oc_short_id <id> -> the id as it appears in a menu LABEL: the `ses_` prefix
# dropped and the rest cut to ID_LABEL_W chars with a `_` truncation marker, so
# the id column is a fixed ID_LABEL_W-wide field and the title/date columns stay
# aligned (a real id is `ses_` + 32 hex, which was unreadable in every row).
# DISPLAY ONLY: the row KEY keeps the full id, so marks, CSVs and every command
# still use the real id. `f72115a_` for `ses_f72115a...`.
ID_LABEL_W=8
oc_short_id() {
    local rest="${1#ses_}"
    printf '%s_' "${rest:0:$((ID_LABEL_W - 1))}"
}

# TITLE_COL_W — width of the label's SECOND column (the title), the 3rd column
# (agent/date/badge/ref) starts right after it, so the columns line up across
# rows. Padding only: the title is NEVER cut (a title longer than the column
# pushes the metadata to the right; fzf truncates the row's end anyway).
TITLE_COL_W=36

# PARENT_WORD_W -> how much of the parent's title the `→ <parent>` token carries
# after the parent's short id. A cap keeps the token readable when the first word
# is long or hyphenated (opencode-db, portability...); truncation adds a `_`
# (the same "the word continues" marker as the short id). The row's own title is
# NEVER capped — it is rendered in full, joined to the id.
PARENT_WORD_W=9
oc_parent_token() {   # <parent_id> <parent_title> -> "f4fecb3_mejoras"
    local pid="${1:-}" ptitle="${2:-}" word
    [ -n "$ptitle" ] || { printf ''; return 0; }
    word=$(printf '%s' "$ptitle" | awk '{print $1}')
    if [ "${#word}" -gt "$PARENT_WORD_W" ]; then
        word="${word:0:PARENT_WORD_W}_"
    fi
    printf '%s%s' "$(oc_short_id "$pid")" "$word"
}

# oc_title_display <title> -> the title with opencode's generated subagent
# suffix ` (@<agent> subagent)` stripped (DISPLAY ONLY). A subagent row already
# carries the `@<agent>` token and the `→ <parent>` reference, so the suffix
# only repeats the agent on every subagent row. Never touches the data path:
# `list --tsv`, reports, exports and the `info` banner keep the real title.
oc_title_display() {
    local t="${1:-}"
    [[ "$t" =~ ^(.*)\ \(@[^\)]*\ subagent\)$ ]] && [ -n "${BASH_REMATCH[1]}" ] && t="${BASH_REMATCH[1]}"
    printf '%s' "$t"
}

# ROW_COL_GAP — the spaces guaranteed between the title column and the metadata
# column. Padding alone cannot do this: `printf %-37s` adds NOTHING once the
# title is already 37+ chars, so an overlong title ran straight into `@agent`
# (the reported bug). The gap is added ONLY in that overflow case, so rows whose
# title fits keep their existing alignment (and their pinned tests) untouched.
ROW_COL_GAP=2

# oc_row_label <id> <title> <agent> <updated> <sub_count> <parent_id> <parent_title>
# -> the menu's compact THREE-column label (`id | title | metadata`). A helper so
# the overflow rule is unit-testable without a fake DB: a title longer than the
# column is followed by ROW_COL_GAP spaces, never glued to `@agent`.
oc_row_label() {
    local rid="$1" rtitle="$2" ragent="$3" rupdated="$4" rsub="$5" rpid="$6" rptitle="$7"
    local tw=$((TITLE_COL_W + 1)) tt field disp
    tt="$(oc_title_display "$rtitle")"
    if [ "${#tt}" -ge "$tw" ]; then
        field="$tt$(printf '%*s' "$ROW_COL_GAP" '')"
    else
        field="$(printf "%-${tw}s" "$tt")"
    fi
    disp="$(printf "%-$((ID_LABEL_W + 1))s" "$(oc_short_id "$rid")")"
    disp+="$field"
    [ -n "$ragent" ] && disp+="@$ragent  "
    disp+="${rupdated:0:16}"
    [ -n "$rsub" ] && disp+="  (${rsub} sub)"
    [ -n "$rpid" ] && disp+="  → $(oc_parent_token "$rpid" "$rptitle")"
    printf '%s' "$disp"
}

# oc_root_sub_counts -> "root-id\tN_sub" for ROOT sessions that have subagents
# (recursive: nested subagents included). ONE helper for every session picker
# (browse/export/shrink) so the `(N sub)` badge means the same everywhere.
# Read-only, live DB. A session whose parent row is gone is itself a root.
oc_root_sub_counts() {
    o_q -separator $'\t' "WITH RECURSIVE d(id, root) AS (
            SELECT s.id, s.id FROM session s
             WHERE s.parent_id IS NULL OR s.parent_id = ''
                OR NOT EXISTS (SELECT 1 FROM session p WHERE p.id = s.parent_id)
            UNION ALL
            SELECT c.id, d.root FROM session c JOIN d ON c.parent_id = d.id)
         SELECT root, count(*) - 1 FROM d GROUP BY root HAVING count(*) > 1;" 2>/dev/null
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
# reserved for rows that OPEN A FLOW (create, swap, choose preset) plus the
# all-details report `__REPORT_ALL__`, the one row that prints EVERY entry of the
# list at once — it opens the same screens a per-row report opens, just all of
# them, which is why it shares the token instead of inventing one. The caller
# passes the label it wants to see (a picker has ONE such row unless it passes an
# explicit key for a second switch, e.g. the subagent visibility row).
oc_toggle_row() {
    local mode="$1" other="$2" key="${3:-__TOGGLE__}"
    printf '%s\t[*] %s  →  %s\n' "$key" "$mode" "$other"
}

#-----------------------------------------------------------------------
# oc_view_all <header> <pause-label> <manager> <stamp>...
#
# The "details of all" report of the artifact pickers (exports, shrinks): ONE
# global header, then the SAME view command the per-row branch runs, once per
# stamp, with NO pause in between, then the picker's usual report pause. It is
# the counterpart of the sessions screen's __REPORT_ALL__ iterator, for the
# screens that are not driven by oc_session_picker.
#
# <manager> is the subcommand namespace whose verb is `view` (`exports`,
# `shrinks`), because that is the only shape both screens need: spelling the
# command here would mean every call site composing "run_oced_tool … view".
#
# The header belongs to the ITERATION, exactly like view_all_header in
# oc_session_picker: a callback cannot tell "first call" from "last call"
# without state the picker owns, and one header per stamp would be noise.
#-----------------------------------------------------------------------
oc_view_all() {
    local header="$1" label="$2" mgr="$3"; shift 3
    local -a keys=( "$@" )
    printf '%s\n' "$header"
    if [ "${#keys[@]}" -eq 0 ]; then
        echo "   (none)"
        return 0
    fi
    local k
    for k in "${keys[@]}"; do
        run_oced_tool "$mgr" view "$k"
        echo ""
    done
    # Same labels the per-row reports use, so an all-report pause can never be
    # read as a create/swap pause ("Export" / "Shrink copy"). The pause rc is
    # RETURNED, not swallowed: ESC (2) has to travel to the caller's __REPORT_ALL__
    # branch so it closes the submenu instead of silently redrawing the list —
    # the same rule as __SWAP__.
    menu_pause "$label"
}

oc_exports_view_all() { oc_view_all "== Details of all export runs ==" "Manage exports" exports "$@"; }
oc_shrinks_view_all() { oc_view_all "== Details of all shrink copies ==" "Shrinks" shrinks "$@"; }

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
    # `mode`: `select` (the default, unchanged) marks rows to build a selection;
    # `view` is a BROWSE screen: nothing is selectable, so it renders no marks,
    # no __MAKE__ and no mark-all/unmark-all rows, and a row just runs
    # `view_action <id>`. It reuses this picker so both screens read, order and
    # render sessions identically instead of growing a second implementation.
    local view_mode=0
    [ "${cfg[mode]:-select}" = "view" ] && view_mode=1
    local view_action="${cfg[view_action]:-}"
    local view_action_all="${cfg[view_action_all]:-}"
    local view_all_header="${cfg[view_all_header]:-}"
    [ "$view_mode" -eq 1 ] || view_action=""
    local show_compactions=1

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
            local rid rtitle rcreated rupdated ragent rpid rptitle rdir disp
            # bash `read` collapses runs of IFS whitespace, so three empty
            # fields in a row would eat the path: split on \x1f instead (a
            # non-whitespace IFS keeps every empty field, verbatim).
            IFS=$'\x1f' read -r rid rtitle rcreated rupdated ragent rpid rptitle rdir <<<"${line//$'\t'/$'\x1f'}"
            # A hidden subagent is not rendered, so it can never be marked and
            # never reaches the CSV: the selection cascades to it by construction.
            if [ "$hide_subs" = "1" ] && [ -n "${is_sub[$rid]+set}" ]; then
                continue
            fi
            ids+=("$rid")
            # The compact label as THREE columns: `id | title | metadata`. The
            # FIRST COLUMN is the short id on a fixed width (oc_short_id drops
            # `ses_`, cuts to ID_LABEL_W-1 and always ends in `_`, so the
            # underscore terminates the id — it is NOT glued to the title any
            # more). The SECOND COLUMN is the FULL title, padded to TITLE_COL_W
            # (padding only, never truncated; a longer one pushes the metadata
            # right but is ALWAYS followed by ROW_COL_GAP spaces, so it never
            # glues to the metadata; fzf truncates the row's end), passed through
            # oc_title_display which sheds opencode's generated ` (@<agent>
            # subagent)` suffix (the `@<agent>` token and the `→ <parent>`
            # reference already say it). The THIRD COLUMN is the metadata: the
            # agent token, ONE full-ish date (the updated YYYY-MM-DD HH:MM), the
            # `(N sub)` badge and the `→ <parent>` token on subagent rows (a
            # parent id present). The session's own path is deliberately NOT
            # rendered (it bloated every row; it stays in `list` and `info`).
            disp="$(oc_row_label "$rid" "$rtitle" "$ragent" "$rupdated" "${sub_n[$rid]:-}" "$rpid" "$rptitle")"
            local_disp["$rid"]="$disp"
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
        subs_note=""
        if [ "$view_mode" -eq 1 ]; then
            subs_note="${#ids[@]} session(s) · $ord_mode · ESC: back"
        else
            subs_note="$marked_n/${#ids[@]} marked · $ord_mode"
            [ -n "$header" ] && subs_note="$header · $subs_note"
            if [ -n "$get_sub_ids" ] && [ "$hide_subs" = "1" ]; then
                subs_note+=" · subagents hidden, never exported"
            fi
            subs_note+=" · ESC: back"
        fi
        if [ "$view_mode" -eq 0 ] && [ -n "$get_sub_ids" ] && [ "$hide_subs" = "0" ]; then
            # The one rule a row cannot show: a shown subagent is marked on its
            # own, so un-marking its session does not take it along.
            subs_note+=$'\n'"subagents keep their own mark: un-marking a session does not remove them"
        fi

        sel=$( {
                 if [ "$view_mode" -eq 0 ]; then
                     printf '__MAKE__\t%s\n' "$make_label"
                 fi
                 oc_toggle_row "$ord_mode" "$toggle_other"
                 # Compactions and report-count are REPORT concepts: a select
                 # screen has nothing to report, so the rows only exist in view
                 # mode. Rendering them everywhere put dead keys in the export
                 # and shrink pickers, where selecting one exited the loop.
                  if [ "$view_mode" -eq 1 ]; then
                     if [ "$show_compactions" -eq 1 ]; then
                         oc_toggle_row "compactions in reports: shown" "hidden" "__TOGGLE_COMP__"
                     else
                         oc_toggle_row "compactions in reports: hidden" "shown" "__TOGGLE_COMP__"
                     fi
                 fi
                  if [ -n "$get_sub_ids" ]; then
                     if [ "$hide_subs" -eq 0 ]; then
                         oc_toggle_row "subagents: shown" "hidden" "__SUBS__"
                     else
                         oc_toggle_row "subagents: hidden" "shown" "__SUBS__"
                     fi
                  fi
                  if [ "$view_mode" -eq 1 ]; then
                      printf '%s\t%s\n' "__REPORT_ALL__" "[>] details of all sessions"
                  fi

                 if [ "$view_mode" -eq 0 ]; then
                     printf '__ALL__\t[mark all]\n'
                     printf '__NONE__\t[unmark all]\n'
                 fi
                 for id in "${ids[@]}"; do
                     if [ "$view_mode" -eq 1 ]; then
                         # [>] = opens a FLOW (the session detail). A browse row
                         # is not selectable, so it must not wear a [x]/[ ] mark:
                         # a mark there would promise a selection that is never
                         # built. The label is already complete (id+title+date+
                         # suffixes), so it is printed as-is.
                         printf '%s\t%s\n' "$id" "${local_disp[$id]:-}"
                         continue
                     fi
                     [ "${marks[$id]:-0}" = 1 ] && mark='[x]' || mark='[ ]'
                     printf '%s\t%s %s\n' "$id" "$mark" "${local_disp[$id]:-}"
                 done
               } | oc_fzf_sel "$title" "$subs_note") || return $?

        key=$(oc_sel_key "$sel")
        if [ "$view_mode" -eq 1 ]; then
            case "$key" in
                __TOGGLE__)
                    if [ "$ord_mode" = "newest first" ]; then
                        ord=updated-asc; ord_mode="old first"
                    else
                        ord=updated-desc; ord_mode="newest first"
                    fi
                    ;;
                __TOGGLE_COMP__)
                    show_compactions=$((1 - show_compactions))
                    ;;
                 __SUBS__)
                     if [ "$hide_subs" = "0" ]; then hide_subs=1; else hide_subs=0; fi
                     ;;
                 __REPORT_ALL__)
                     # The group header belongs to the ITERATION, not to the
                     # per-session callback: a callback cannot tell "first call"
                     # from "last call" without state the picker already owns.
                     if [ -n "${view_all_header:-}" ]; then
                         printf '%s\n' "$view_all_header"
                     fi
                     if [ -n "$view_action_all" ]; then
                         for idv in "${ids[@]}"; do
                             "$view_action_all" "$idv" "$show_compactions" "$hide_subs"
                         done
                     elif [ -n "$view_action" ]; then
                         for idv in "${ids[@]}"; do
                             "$view_action" "$idv" "$show_compactions" "$hide_subs"
                         done
                     fi
                     menu_pause "Sessions" || return 0
                     ;;
                 __NONE__|__ALL__|__MAKE__) continue ;;
                "")
                    return 0 ;;
                *)  # A session row is a REPORT: view_action prints it and pauses
                    # (that is the caller's contract, as in sessions.sh).
                    [ -n "$view_action" ] && "$view_action" "$key" "$show_compactions" "$hide_subs"
                    ;;
            esac
            continue
        fi
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

