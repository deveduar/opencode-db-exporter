#!/usr/bin/env bash
# menu.sh — interactive (fzf) menu for opencode-db, standalone.
#
# Level navigation: ESC goes up one level; on the main level ESC exits.
# Root entries and pickers:
#   status    status report (DB · backups · deps · version/schema)
#   backups   level 2 = a real fzf picker over the backups (mode toggle verify/delete)
#   sessions  level 2 = a real fzf picker over the sessions (mode toggle details/export)
#   exports   level 2 = a real fzf picker over the export runs (mode toggle view/remove)
# The pickers use TSV rows (key<TAB>display); fzf shows only the display column
# and the full selected line keeps the hidden key for parse-back.
# No TAB multi-select anywhere: the "switch mode" is itself a menu row, and bulk
# deletes are their own rows ([delete all] / [delete olds]).

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
session_rows() {
    oced_out list --info 2>/dev/null | awk 'NR>2 && $1 ~ /^ses_/'
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

# The mode-switch row. Selecting it flips the picker mode and reloads the list.
oc_toggle_row() {
    local mode="$1" other="$2"
    printf '__TOGGLE__\t[mode: %s]  switch to %s\n' "$mode" "$other"
}

#-----------------------------------------------------------------------
# Backups picker
#-----------------------------------------------------------------------
oc_backups_rows() {
    local m="$OCED_BACKUP_DIR/manifest.json"
    printf '__CREATE__\t[create backup (consistent snapshot)]\n'
    printf '__SHRINK__\t[shrink (lighter copy from the LIVE DB)...]\n'
    printf '__DELETE_ALL__\t[delete ALL backups]\n'
    printf '__KEEP_NEWEST__\t[delete olds (keep only the newest)]\n'
    [ -f "$m" ] || { printf '__NONE__\t(no backups recorded yet)\n'; return 0; }
    local file dt sz szh ss ms sha
    jq -r '.backups | sort_by(.date) | reverse | .[] | [.file, (.date|sub("T";" ")|sub("Z$";"")), (.size|tostring), (.sessions|tostring), ((.messages//0)|tostring), ((.sha256//"-")[:8])] | @tsv' "$m" \
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
    local sel key
    while true; do
        local header
        header="Database and backups — select a backup to delete, or use the actions above"
        sel=$(oc_backups_rows | oc_fzf_sel "backups (delete)" "$header") || return $?
        key=$(oc_sel_key "$sel")
        case "$key" in
            __CREATE__)     run_oced_tool backup; continue ;;
            __SHRINK__)     oc_pick_shrink; continue ;;
            __DELETE_ALL__) oc_backups_bulk all; continue ;;
            __KEEP_NEWEST__) oc_backups_bulk newest; continue ;;
            __NONE__)       continue ;;
            *)
                confirm_action "DELETE backup $key?" || continue
                run_oced_tool backups remove "$key" --yes
                continue
                ;;
        esac
    done
}

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

#-----------------------------------------------------------------------
# Export picker (session or ALL -> export wizard)
#-----------------------------------------------------------------------
oc_export_rows() {
    printf '__ALL__\tALL SESSIONS (no filter)\n'
    oc_sessions_rows
}

oc_export_picker() {
    local sel key
    while true; do
        local header
        header=$'Sessions to export — pick one session, or ALL SESSIONS'$'\n'$'(then choose a profile and its variant; ESC: back)'
        sel=$(oc_export_rows | oc_fzf_sel "sessions (export)" "$header") || return $?
        key=$(oc_sel_key "$sel")
        case "$key" in
            __ALL__)    oc_export_flow ""  || continue ;;
            __NONE__)   continue ;;
            *)          oc_export_flow "$key" || continue ;;
        esac
    done
}

#-----------------------------------------------------------------------
# Manage exports picker (view / remove)
#-----------------------------------------------------------------------
oc_exports_rows() {
    local mode="$1"
    oc_toggle_row "$mode" "$([ "$mode" = view ] && printf remove || printf view)"
    if [ "$mode" = "remove" ]; then
        printf '__DELETE_ALL__\t[delete ALL export runs]\n'
        printf '__KEEP_NEWEST__\t[delete all except the newest]\n'
    fi
    [ -d "$OCED_OUT" ] || { printf '__NONE__\t(no export runs yet)\n'; return 0; }
    local run
    exports_runs_find | while IFS= read -r run; do
        [ -d "$run" ] || continue
        oc_exports_run_row "${run##*/}"
    done
}

# exports_run_count -> number of export run dirs under OCED_OUT.
exports_run_count() {
    [ -d "$OCED_OUT" ] || { echo 0; return; }
    find "$OCED_OUT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l
}

# oc_stamp_human <stamp> -> human readable date of an export run stamp.
oc_stamp_human() {
    local s="$1"
    case "$s" in
        [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]_[0-2][0-9]-[0-5][0-9])
            printf '%s %s UTC' "${s:0:10}" "${s:11:2}:${s:14:2}" ;;
        *) printf '%s' "$s" ;;
    esac
}

# oc_exports_run_row <stamp> -> one TSV row aggregating a run's metadatos.
oc_exports_run_row() {
    local stamp="$1"
    local run="$OCED_OUT/$stamp"
    local meta profiles="" roots=0 subs=0 msgs=0 found=0 m p r s
    local -a metas
    mapfile -t metas < <(find "$run" -name metadatos.json -type f 2>/dev/null | sort)
    for m in "${metas[@]}"; do
        [ -f "$m" ] || continue
        found=1
        p=$(jq -r '.profile // "?"' "$m")
        profiles="${profiles:+$profiles+}$p"
        r=$(jq -r '.sessions.roots // 0' "$m")
        s=$(jq -r '.sessions.subagents // 0' "$m")
        [ "$r" -gt "$roots" ] && roots="$r"
        [ "$s" -gt "$subs" ] && subs="$s"
        msgs=$((msgs + $(jq -r '.messages // 0' "$m")))
    done
    [ "$found" -eq 1 ] || profiles="?"
    local size
    size=$(du -sb "$run" 2>/dev/null | cut -f1); size=${size:-0}
    printf '%s\t%s\n' "$stamp" "$(printf '%-16s  %-30s  %s root · %s msg · %s' \
        "$(oc_stamp_human "$stamp")" "$profiles" "$roots" "$msgs" "$(o_human_size "$size")")"
}

# Bulk removals from the exports picker (all / keep newest only).
oc_exports_bulk() {
    local what="$1"
    local -a runs
    mapfile -t runs < <(exports_runs_find | xargs -n1 basename 2>/dev/null | sort -r)
    local total=${#runs[@]}
    [ "$total" -gt 0 ] || { echo "   (no export runs yet)"; return 1; }
    local -a targets=()
    if [ "$what" = "all" ]; then
        confirm_action "DELETE ALL $total export runs? This cannot be undone." || { echo "   cancelled."; return 0; }
        targets=("${runs[@]}")
    else
        [ "$total" -le 1 ] && { echo "   Already only 1 export run."; return 0; }
        confirm_action "DELETE $((total - 1)) older export runs, keeping only the newest?" || { echo "   cancelled."; return 0; }
        targets=("${runs[@]:1}")
    fi
    local s
    for s in "${targets[@]}"; do
        run_oced_tool exports remove "$s" --yes
    done
}

oc_exports_picker() {
    local mode="view" sel key
    while true; do
        local header
        header="Manage exports — mode: $mode"$'\n'"$(
            if [ "$mode" = view ]; then printf 'view: show the report of an export run';
            else printf 'remove: delete a run (with confirmation)'; fi
        )"
        sel=$(oc_exports_rows "$mode" | oc_fzf_sel "exports ($mode)" "$header") || return $?
        key=$(oc_sel_key "$sel")
        case "$key" in
            __TOGGLE__)     mode=$( [ "$mode" = view ] && printf remove || printf view ); continue ;;
            __DELETE_ALL__) oc_exports_bulk all; continue ;;
            __KEEP_NEWEST__) oc_exports_bulk newest; continue ;;
            __NONE__)       continue ;;
            *)
                if [ "$mode" = view ]; then
                    run_oced_tool exports view "$key"
                    menu_pause "Manage exports" || return 0
                    return 0
                fi
                confirm_action "Remove export run $key? It deletes the generated files." || continue
                run_oced_tool exports remove "$key" --yes
                continue
                ;;
        esac
    done
}

#-----------------------------------------------------------------------
# Export flow: session (done by the picker) -> product -> variant/custom
#-----------------------------------------------------------------------
# oc_pick_product -> selects one export product (key<TAB>label).
# product = the document to produce (transcript | memory | compactions).
oc_pick_product() {
    printf '%s\n' \
        $'transcript\ttranscript: the conversation in markdown (text + reasoning + tools + patches) + optional faithful JSON' \
        $'memory\tmemory: RAG corpus (corpus.jsonl, one entry per root session)' \
        $'compactions\tcompactions: only the compacted-context digests' \
        | oc_fzf_sel "export product" "Product = the document you want to produce. Next step: choose how it is configured (variant)."
}

# oc_recipes_for <product> -> TSV rows (args<TAB>label) for that product.
# variant = how the product is configured; bundle = several products in one run.
oc_recipes_for() {
    case "$1" in
        transcript) printf '%s\n' \
            $'transcript\tdefault' \
            $'transcript --tool-output full\ttool output: full' \
            $'transcript --tool-output omit\tomit tool output' \
            $'transcript --patch omit\tomit patches' \
            $'transcript --no-reasoning\tno reasoning' \
            $'transcript --summary-diffs\t+ summary diffs' \
            $'transcript --mark-compactions\t+ compaction markers' \
            $'transcript --mark-compactions --summary-diffs\t+ markers + diffs' \
            $'transcript --sub inline\tsubagents: inline' \
            $'transcript --sub omit\tsubagents: omit' \
            $'transcript --json\t+ faithful JSON archive' \
            $'transcript --json --sanitize\t+ JSON archive, secrets redacted' \
            $'__FULLMEM__\tbundle: transcript + memory corpus (one run)' \
            $'__CUSTOM__\tcustom… (choose my own options)' ;;
        compactions) printf '%s\n' \
            $'compactions\tdefault' \
            $'compactions --sub inline\tsubagents: inline' \
            $'compactions --sub omit\tsubagents: omit' \
            $'compactions --json\t+ faithful JSON archive' \
            $'__CUSTOM__\tcustom… (choose my own options)' ;;
        memory) printf '%s\n' \
            $'memory\tdefault' \
            $'memory --files\t+ touched files' \
            $'__CUSTOM__\tcustom… (cap / files)' ;;
        *) return 1 ;;
    esac
}

# oc_export_confirm <profile-label> <filter-or-empty> <spec> -> print the plan + ask.
oc_export_confirm() {
    local profile="$1" selid="$2" spec="$3"
    local db_est=0
    [ -f "$OPENCODE_DB-wal" ] && db_est=$((db_est + $(stat -c %s "$OPENCODE_DB-wal"))) || true
    [ -f "$OPENCODE_DB-shm" ] && db_est=$((db_est + $(stat -c %s "$OPENCODE_DB-shm"))) || true
    db_est=$((db_est + $(stat -c %s "$OPENCODE_DB")))
    echo ""
    echo "-> Export plan"
    printf '   %-9s %s\n' "Source:" "$OPENCODE_DB"
    printf '   %-9s %s\n' "Filter:" "${selid:-ALL sessions (no filter)}"
    printf '   %-9s %s\n' "Profile:" "$profile"
    printf '   %-9s %s\n' "Spec:" "$spec"
    printf '   %-9s %s\n' "Output:" "$OCED_OUT/<timestamp>"
    if [ "$db_est" -ge 1073741824 ]; then
        confirm_action "Start this export? The DB is ~$(o_human_size "$db_est") — may take a while." || { echo "   cancelled."; return 1; }
    else
        confirm_action "Start this export?" || { echo "   cancelled."; return 1; }
    fi
    return 0
}

# oc_export_flow [session-id|"") -> product-first export wizard. Empty = ALL sessions.
oc_export_flow() {
    local selid="${1:-}"
    local -a idfilter=()
    [ -n "$selid" ] && idfilter=(--filter "$selid")

    local prod prodkey
    prod=$(oc_pick_product) || return 1
    prodkey=$(oc_sel_key "$prod")

    local rec reckey
    rec=$(oc_recipes_for "$prodkey" | oc_fzf_sel "variant ($prodkey)" \
        "Choose the '$prodkey' variant — product = the document to produce · variant = how it is configured · bundle = several products in one run · custom… = my own options") || return 1
    reckey=$(oc_sel_key "$rec")

    case "$reckey" in
        __FULLMEM__)
            oc_export_confirm "transcript + memory" "$selid" "transcript + RAG corpus (one run)" || return 0
            local stamp
            stamp=$(date -u +%Y%m%d-%H%M%S)
            run_oced_tool export transcript --stamp "$stamp" "${idfilter[@]}"
            run_oced_tool export memory --stamp "$stamp" --files "${idfilter[@]}"
            menu_pause "Export" || return 0
            return 0
            ;;
        __CUSTOM__)
            local cmdline args
            if [ "$prodkey" = memory ]; then
                args=$(oc_memory_custom) || return 1
                cmdline="memory ${args:-}"
            else
                args=$(oc_custom_run "$prodkey") || return 1
                cmdline="$prodkey ${args:-}"
            fi
            cmdline=${cmdline% }
            oc_export_confirm "$prodkey" "$selid" "custom: $cmdline" || return 0
            # shellcheck disable=SC2086  # cmdline must split ("--sub inline --role user")
            run_oced_tool export $cmdline "${idfilter[@]}"
            menu_pause "Export" || return 0
            return 0
            ;;
        *)
            oc_export_confirm "$prodkey" "$selid" "$reckey" || return 0
            local -a parts
            read -r -a parts <<<"$reckey"
            local profile_only="${parts[0]}"
            local -a extra=("${parts[@]:1}")
            run_oced_tool export "$profile_only" "${extra[@]}" "${idfilter[@]}"
            menu_pause "Export" || return 0
            return 0
            ;;
    esac
}

#-----------------------------------------------------------------------
# Custom (checkbox checklist, "sistema asus" style: toggled one row per Enter)
#-----------------------------------------------------------------------
# oc_custom_set <product> -> initializes the global ingredient arrays.
#   OC_CK_KEY/OC_CK_LABEL/OC_CK_TYPE(bool|cycle)/OC_CK_VAL
oc_custom_set() {
    local p="$1"
    OC_CK_KEY=(); OC_CK_LABEL=(); OC_CK_TYPE=(); OC_CK_VAL=()
    case "$p" in
        transcript)
            OC_CK_KEY=(tools outfull patches markers diffs sub role reasoning json sanitize)
            OC_CK_LABEL=("tool calls + inputs" "tool output (full)" "patches" "compaction markers" "summary diffs" "subagents" "role" "reasoning" "faithful JSON archive" "sanitize (redact secrets)")
            OC_CK_TYPE=(bool bool bool bool bool cycle cycle bool bool bool)
            OC_CK_VAL=(on off on off off separate all on off off) ;;
        compactions)
            OC_CK_KEY=(sub role json sanitize)
            OC_CK_LABEL=("subagents" "role" "faithful JSON archive" "sanitize (redact secrets)")
            OC_CK_TYPE=(cycle cycle bool bool)
            OC_CK_VAL=(separate all off off) ;;
    esac
}

# oc_custom_args <product> -> builds the command-line ingredients from the arrays.
oc_custom_args() {
    local p="$1" args=""
    case "$p" in
        transcript)
            if [ "${OC_CK_VAL[0]}" = off ]; then
                args+=" --tool-output omit"
            elif [ "${OC_CK_VAL[1]}" = on ]; then
                args+=" --tool-output full"
            fi
            [ "${OC_CK_VAL[2]}" = off ] && args+=" --patch omit"
            [ "${OC_CK_VAL[3]}" = on ] && args+=" --mark-compactions"
            [ "${OC_CK_VAL[4]}" = on ] && args+=" --summary-diffs"
            args+=" --sub ${OC_CK_VAL[5]} --role ${OC_CK_VAL[6]}"
            [ "${OC_CK_VAL[7]}" = off ] && args+=" --no-reasoning"
            [ "${OC_CK_VAL[8]}" = on ] && args+=" --json"
            [ "${OC_CK_VAL[9]}" = on ] && args+=" --sanitize" ;;
        compactions)
            args+=" --sub ${OC_CK_VAL[0]} --role ${OC_CK_VAL[1]}"
            [ "${OC_CK_VAL[2]}" = on ] && args+=" --json"
            [ "${OC_CK_VAL[3]}" = on ] && args+=" --sanitize" ;;
    esac
    printf '%s\n' "$args"
}

# oc_custom_run <profile> -> interactive checklist; prints the args on stdout.
oc_custom_run() {
    local profile="$1" i rows sel key
    oc_custom_set "$profile"
    while true; do
        rows=""
        for i in "${!OC_CK_KEY[@]}"; do
            case "${OC_CK_TYPE[$i]}" in
                bool)
                    rows+=$(printf '%s\t%s\n' "${OC_CK_KEY[$i]}" "- [${OC_CK_VAL[$i]}] ${OC_CK_LABEL[$i]}") ;;
                cycle)
                    rows+=$(printf '%s\t%s\n' "${OC_CK_KEY[$i]}" "- ${OC_CK_LABEL[$i]}: ${OC_CK_VAL[$i]}") ;;
            esac
            rows+=$'\n'
        done
        rows+=$(printf '%s\t%s\n' "__RUN__" "[run this custom export]"); rows+=$'\n'
        rows+=$(printf '%s\t%s\n' "__ABORT__" "[cancel]"); rows+=$'\n'
        sel=$(printf '%b' "$rows" | oc_fzf_sel "custom ($profile)" "Checklist: Enter toggles a row · '[run]' executes") || return 1
        key=$(oc_sel_key "$sel")
        case "$key" in
            __RUN__)  break ;;
            __ABORT__) echo "   cancelled."; return 1 ;;
            *)
                for i in "${!OC_CK_KEY[@]}"; do
                    [ "${OC_CK_KEY[$i]}" = "$key" ] || continue
                    if [ "${OC_CK_TYPE[$i]}" = bool ]; then
                        [ "${OC_CK_VAL[$i]}" = on ] && OC_CK_VAL[$i]=off || OC_CK_VAL[$i]=on
                    else
                        case "${OC_CK_VAL[$i]}" in
                            separate) OC_CK_VAL[$i]=inline ;;
                            inline)   OC_CK_VAL[$i]=omit ;;
                            omit)     OC_CK_VAL[$i]=separate ;;
                            all)      OC_CK_VAL[$i]=user ;;
                            user)     OC_CK_VAL[$i]=assistant ;;
                            assistant) OC_CK_VAL[$i]=all ;;
                        esac
                    fi
                done
                ;;
        esac
    done
    printf '%s\n' "$(oc_custom_args "$profile")"
}

# oc_memory_custom -> checklist for the memory profile (files / cap); prints args.
oc_memory_custom() {
    local files=off cap="0" rows sel key n
    while true; do
        rows=$(printf '%s\t%s\n' "files" "- [${files}] touched files per session"; printf '%s\t%s\n' "cap" "- cap N chars per text (now: $cap)"; printf '%s\t%s\n' "__RUN__" "[run this memory export]"; printf '%s\t%s\n' "__ABORT__" "[cancel]")
        sel=$(printf '%b\n' "$rows" | oc_fzf_sel "custom (memory)" "Checklist: Enter toggles · '[run]' executes") || return 1
        key=$(oc_sel_key "$sel")
        case "$key" in
            __RUN__) break ;;
            __ABORT__) echo "   cancelled."; return 1 ;;
            files) [ "$files" = on ] && files=off || files=on ;;
            cap)
                n=$(oc_read_int "Cap per text in chars (0 = unlimited)") || continue
                cap=$(printf '%s' "$n" | tr -d '\n') ;;
        esac
    done
    local args=""
    [ "$files" = on ] && args+=" --files"
    [ "$cap" != "0" ] && args+=" --cap $cap"
    printf '%s\n' "$args"
}

#-----------------------------------------------------------------------
# shrink in the menu: named recipes (like the export recipes), custom N/days/date
# and dry-run. shrink only WRITES a copy (never modifies the live DB); the
# swap is manual.
#-----------------------------------------------------------------------
pick_shrink_profile() {
    local sel
    sel=$(printf 'lean: keep 10 most recent + strip reasoning|shrink|lean\nrecent: sessions updated in the last 90 days|shrink|recent\nfull: keep ALL sessions, strip reasoning only|shrink|full\nbare: keep 10 most recent, keep reasoning|shrink|bare\ndry-run (no file)|shrink|lean --dry-run\ncustom (choose exactly what to keep)...|shrink|custom\n' \
        | fzf --prompt="shrink recipe > " --height=50% --border --header="Shrink works on the LIVE DB (own snapshot), not on a backup. ESC: cancel") || return 1
    [ -n "$sel" ] || return 1
    printf '%s\n' "$sel"
}

oc_pick_shrink_custom() {
    local sel n
    sel=$(printf 'keep N most recent sessions\nkeep sessions from the last N days\nkeep sessions since a date (real range)\n' \
        | fzf --prompt="custom shrink criteria > " --height=35% --border --header="ESC: cancel") || return 1
    [ -n "$sel" ] || return 1
    case "$sel" in
        *"N most recent"*)
            n=$(oc_read_int "Number of most recent sessions to keep") || return 1
            printf 'shrink --keep %s\n' "$(printf '%s' "$n" | tr -d '\n')" ;;
        *"N days"*)
            n=$(oc_read_int "Days to keep (updated within the last N days)") || return 1
            printf 'shrink --older-than %s\n' "$(printf '%s' "$n" | tr -d '\n')" ;;
        *"since a date"*)
            local min_ts max_ts min_dt max_dt d
            min_ts=$(sqlite3 "$(o_db_uri)" "SELECT coalesce(min(time_updated),0) FROM session;")
            max_ts=$(sqlite3 "$(o_db_uri)" "SELECT coalesce(max(time_updated),0) FROM session;")
            if [ "$min_ts" -gt 0 ] && [ "$max_ts" -gt 0 ]; then
                min_dt=$(date -u -d "@$((min_ts/1000))" +%Y-%m-%d 2>/dev/null || date -u -r $((min_ts/1000)) +%Y-%m-%d 2>/dev/null)
                max_dt=$(date -u -d "@$((max_ts/1000))" +%Y-%m-%d 2>/dev/null || date -u -r $((max_ts/1000)) +%Y-%m-%d 2>/dev/null)
                echo "   Available range: $min_dt .. $max_dt" >&2
            fi
            d=$(oc_read_int "Since date (YYYYMMDD, e.g. 20260115)") || return 1
            # Convert YYYYMMDD to YYYY-MM-DD
            d=$(printf '%s' "$d" | tr -d '\n')
            if [ ${#d} -eq 8 ]; then
                d="${d:0:4}-${d:4:2}-${d:6:2}"
            fi
            printf 'shrink --since %s\n' "$d" ;;
    esac
}

oc_pick_shrink() {
    local presel runargs
    presel=$(pick_shrink_profile) || return 1
    runargs="${presel##*|}"
    if [ "$runargs" = "custom" ]; then
        runargs=$(oc_pick_shrink_custom) || { echo "   cancelled."; return 0; }
        runargs="${runargs#shrink }"
    fi
    if [[ "$runargs" != *"--dry-run"* ]]; then
        echo ""
        echo "-> shrink plan (workflow: backup -> export memory -> shrink)"
        printf '   %-9s %s\n' "Action:" "write a pruned + VACUUMed COPY ($runargs)"
        printf '   %-9s %s\n' "Source:" "$OPENCODE_DB (LIVE DB, own snapshot)"
        printf '   %-9s %s\n' "Output:" "$OCED_BACKUP_DIR/shrink/<timestamp>/ (swap manually)"
        confirm_action "Continue? The live DB is never modified; export memory first to keep its knowledge." \
            || { echo "   cancelled."; return 0; }
    fi
    # shellcheck disable=SC2086  # runargs must split ("--keep 30")
    run_oced_tool shrink $runargs
    menu_pause "Backups" || return 0
}

#-----------------------------------------------------------------------
# Root
#-----------------------------------------------------------------------
oc_root=(
    "status|Status report (DB · backups · deps · version/schema)|fn:oc_show_status"
    "backups|Database and backups (picker)|fn:oc_backups_picker"
    "sessions|Sessions (details picker)|fn:oc_sessions_picker"
    "export|Export sessions (wizard picker)|fn:oc_export_picker"
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
    run_menu --cat "opencode-db" --prompt "actions" --entries oc_root
}