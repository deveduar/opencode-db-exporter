#!/usr/bin/env bash
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
# Export picker: named presets (the ONLY menu path). A presets file
# (OCED_PRESETS, JSON) is the source of truth: each named preset = product(s)
# + config + its own selection (filter/sessions). Without a presets file the
# export entry prints guidance (the CLI still accepts raw product keywords and
# flags). There is NO manual session/or-ALL + product flow in the menu anymore
# — the shipped plans (notes/rag/digest + user presets) cover it.
# All preset plan logic lives in exportlib/plan.py (resolve() + CLI bridge);
# these shell shims pin OCED_PRESETS for the python process (common.sh only
# sets it as a shell variable when using the built-in default).
#-----------------------------------------------------------------------
oc_plan_py() {
    OCED_PRESETS="$OCED_PRESETS" python3 "$SCRIPT_DIR/exportlib/plan.py" "$@" 2>/dev/null
}

oc_preset_rows() {
    [ -f "${OCED_PRESETS:-}" ] || return 1
    oc_plan_py rows
}

oc_preset_descr() { # $1=preset-name -> one-line selection summary (plan line)
    [ -f "${OCED_PRESETS:-}" ] || return 1
    oc_plan_py descr "$1" || return 1
}

oc_export_rows() {
    oc_preset_rows
}

# oc_selection_rows -> session/ALL selection rows for a chosen preset.
oc_selection_rows() {
    printf '__ALL__\tALL SESSIONS (no filter)\n'
    oc_sessions_rows
}

oc_export_presets_picker() {
    local sel key header name seldesc
    while true; do
        header=$'Export — pick a plan (preset): products + config from the presets file'$'\n'$'(then choose a session or ALL SESSIONS; ESC: back)'
        sel=$(oc_export_rows | oc_fzf_sel "export (presets)" "$header") || return $?
        key=$(oc_sel_key "$sel")
        case "$key" in
            __NONE__)   continue ;;
            __PRESET_*)
                name="${key#__PRESET_}"
                seldesc=$(oc_preset_descr "$name") || seldesc=""
                oc_preset_run "$name" "$seldesc" || continue
                menu_pause "Export" || return 0
                ;;
        esac
    done
}

# oc_preset_run <preset> <descr> -> pick a session/ALL for a preset, confirm, run.
# ALL runs the preset as configured; a session overrides its embedded selection
# via --filter (CLI wins over the preset; a bundle shares the override).
oc_preset_run() {
    local name="$1" descr="$2" sel key purpose
    purpose=$(oc_preset_purpose "$name" 2>/dev/null) || purpose="see the presets file for its products/config"
    sel=$(oc_selection_rows | oc_fzf_sel "sessions (preset)" \
        $'Preset '"$name"$' — '"$purpose"$''$'\n'$'(pick a session, or ALL SESSIONS; ALL = as configured, a session = override; ESC: back)') || return 1
    key=$(oc_sel_key "$sel")
    case "$key" in
        __NONE__) return 1 ;;
        __ALL__)
            # snapshot: fresh presets coordinate with the reference archive: offer a
            # fresh backup when the live DB diverged from the last one.
            if [ "$(oc_plan_py snapshot "$name" 2>/dev/null)" = "fresh" ]; then
                local align
                align=$(o_backup_aligned)
                if [ "$align" != "aligned" ]; then
                    echo ""
                    echo "   Preset '$name' pins 'snapshot: fresh' — the export doubles as a reference"
                    echo "   archive, so the last backup should match the live DB (currently: $align)."
                    if confirm_action "Create a fresh backup first? (recommended)"; then
                        run_oced_tool backup
                    fi
                fi
            fi
            oc_export_confirm "preset: $name" "(preset as configured)" "preset '$name' (${descr:-see the presets file})" || return 0
            run_oced_tool export "$name"
            ;;
        *)
            oc_export_confirm "preset: $name" "filter: $key (override)" "preset '$name' (${descr:-see the presets file}) · override: $key" || return 0
            run_oced_tool export "$name" --filter "$key"
            ;;
    esac
    return 0
}

oc_export_picker() {
    if [ -f "${OCED_PRESETS:-}" ]; then
        oc_export_presets_picker
        return 0
    fi
    # No presets file: the menu wizard is preset-only. The CLI still accepts
    # raw product keywords and flags.
    echo "Export from the menu needs a presets file (named plans = the source of truth)."
    echo "   missing: $OCED_PRESETS"
    echo "   create it from the shipped example:"
    echo "     cp \"$SCRIPT_DIR/../presets.json.example\" \"$OCED_PRESETS\""
    echo "   meanwhile: opencode-db export transcript|memory|compactions [flags]"
    return 0
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

# oc_exports_run_row <stamp> -> one TSV row aggregating a run's metadata.
oc_exports_run_row() {
    local stamp="$1"
    local run="$OCED_OUT/$stamp"
    local meta profiles="" roots=0 subs=0 msgs=0 found=0 m p r s
    local -a metas
    mapfile -t metas < <(find "$run" -type f \( -name metadata.json -o -name metadatos.json \) 2>/dev/null | sort)
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
# Export confirm: print the plan (presets only — there is no product-only flow)
#-----------------------------------------------------------------------
# oc_pick_product is gone (no manual flow): the menu exports through named
# presets; product rows are still served by exportlib/plan.py `products` for
# the CLI/tests (product-keyword exports work on the CLI without presets).

# oc_preset_purpose <name> -> one-line purpose for the shipped plans (unknown -> 1).
# The purpose map lives in exportlib/plan.py (PLAN_PURPOSE) — the single source.
oc_preset_purpose() {
    oc_plan_py purpose "$1"
}

# oc_preset_names -> preset names present in OCED_PRESETS (one per line).
oc_preset_names() {
    [ -f "${OCED_PRESETS:-}" ] || return 1
    oc_plan_py names
}

# oc_preset_legend -> header lines explaining each shipped plan that exists in the
# file (keeps the picker rows short: purpose never overflows a row).
oc_preset_legend() {
    [ -f "${OCED_PRESETS:-}" ] || return 0
    oc_plan_py legend
}

# oc_annotate_flags <csv> -> human bits: "+ faithful JSON (raw)", "full tool outputs", etc.
# Hints are defined in exportlib/flags.py (ANNOTATE_HINTS) — the single source of truth.
oc_annotate_flags() {
    local csv="$1"
    [ -n "$csv" ] || return 0
    python3 "$SCRIPT_DIR/exportlib/flags.py" --annotate "$csv" 2>/dev/null
}

# oc_export_plan <profile> -> multi-line "Will produce:" block for the confirm.
# profile = preset name OR product keyword (transcript|memory|compactions).
# Output has NO leading indentation; caller adds uniform indentation.
# Fully computed in exportlib/plan.py (resolve()) — the single source of truth
# for product intros, per-product flags/bits, Notes and the sanitize warning.
oc_export_plan() {
    oc_plan_py plan "$1"
}

# oc_export_confirm <profile-label> <filter-or-empty> <spec> -> print the plan + ask.
# profile-label can be "preset: <name>" or a product keyword (transcript|memory|compactions).
oc_export_confirm() {
    local profile="$1" selid="$2" spec="$3"
    local db_est=0 plan_name="$profile"
    [ -f "$OPENCODE_DB-wal" ] && db_est=$((db_est + $(stat -c %s "$OPENCODE_DB-wal"))) || true
    [ -f "$OPENCODE_DB-shm" ] && db_est=$((db_est + $(stat -c %s "$OPENCODE_DB-shm"))) || true
    db_est=$((db_est + $(stat -c %s "$OPENCODE_DB")))
    case "$profile" in
        preset:\ *) plan_name="${profile#preset: }" ;;
    esac
    echo ""
    echo "-> Export plan"
    printf '   %-9s %s\n' "Source:" "$OPENCODE_DB"
    printf '   %-9s %s\n' "Filter:" "${selid:-ALL sessions (no filter)}"
    printf '   %-9s %s\n' "Profile:" "$profile"
    printf '   %-9s %s\n' "Spec:" "$spec"
    printf '   %-9s %s\n' "Output:" "$OCED_OUT/<timestamp>"
    # Dynamic "Will produce:" block with uniform 2-space indent
    printf '   Will produce:\n'
    oc_export_plan "$plan_name" | sed 's/^/  /'
    echo ""
    if [ "$db_est" -ge 1073741824 ]; then
        confirm_action "Start this export? The DB is ~$(o_human_size "$db_est") — may take a while." || { echo "   cancelled."; return 1; }
    else
        confirm_action "Start this export?" || { echo "   cancelled."; return 1; }
    fi
    return 0
}

#-----------------------------------------------------------------------
# shrink in the menu: SESSIONS first, then a RECIPE, then a read-only plan.
# shrink only WRITES a copy (never modifies the live DB); the swap is manual
# and lives in the shrinks picker.
#
#   1. sessions picker — ROOT sessions only, [x] = survive in the copy
#      (subagents follow their root, so they are never listed separately)
#   2. recipe        — a named ops-only recipe (lean/quiet); every row goes
#                      straight to the read-only plan (y/N)
#   3. plan           — exact read-only counts + y/N, then the shrink runs
#
# Recipe rows, descriptions and baked flags come from shrinklib/plan.py
# (single source of truth, the mirror of exportlib/plan.py); the LIVE numbers
# of the plan are counted here with read-only queries.
#-----------------------------------------------------------------------
oc_shrink_py() {
    OCED_SHRINK_PRESETS="${OCED_SHRINK_PRESETS:-}" python3 "$SCRIPT_DIR/shrinklib/plan.py" "$@" 2>/dev/null
}

oc_shrink_rows() {
    oc_shrink_py rows
}

oc_shrink_plan() { # <recipe> -> multi-line block of what the recipe does
    oc_shrink_py plan "$1" || return 1
}

oc_shrink_desc() { # <recipe> -> one-line summary of its operations
    oc_shrink_py descr "$1" || return 1
}

# oc_shrink_sub_counts -> "<root-id>\t<descendant-count>" for roots WITH
# subagents (recursive: nested subagents included). Read-only, live DB.
oc_shrink_sub_counts() {
    o_q -separator $'\t' "WITH RECURSIVE d(id, root) AS (
            SELECT s.id, s.id FROM session s
             WHERE s.parent_id IS NULL OR s.parent_id = ''
                OR NOT EXISTS (SELECT 1 FROM session p WHERE p.id = s.parent_id)
            UNION ALL
            SELECT c.id, d.root FROM session c JOIN d ON c.parent_id = d.id)
         SELECT root, count(*) - 1 FROM d GROUP BY root HAVING count(*) > 1;" 2>/dev/null
}

# oc_shrink_sql_ids <id-csv> -> a SQL id-list ('a','b') ready to be pasted into
# an IN (...) — the picker passes the unmarked roots (the engine then closes the
# set over their descendants) or the full root list. Ids are sanitized to
# [A-Za-z0-9_]. Empty input -> empty output (= no filter).
oc_shrink_sql_ids() {
    local csv="$1" id out=""
    [ -n "$csv" ] || return 0
    local IFS=','
    for id in $csv; do
        id="${id//[^A-Za-z0-9_]/}"
        [ -n "$id" ] || continue
        [ -n "$out" ] && out="$out,"
        out="$out'$id'"
    done
    printf '%s' "$out"
}

# oc_shrink_discard_offer <ids-csv> -> offers to export the ids to be discarded
# BEFORE the shrink drops them: the SAFE order is backup -> export <profile> -> shrink.
# Profile is $OCED_SHRINK_DISCARD_EXPORT_PROFILE (default: archive = transcript+memory;
# set to "memory" for corpus-only, or any valid export product/profile).
oc_shrink_discard_offer() {
    local ids="$1"
    [ -n "$ids" ] || return 0
    local profile="${OCED_SHRINK_DISCARD_EXPORT_PROFILE:-archive}"
    echo ""
    echo "   This shrink WILL DISCARD the listed session(s) (and their subagents):"
    echo "     $ids"
    if confirm_action "Export them first (opencode-db export $profile --sessions)? This is the SAFE order (backup -> export $profile -> shrink)."; then
        run_oced_tool export "$profile" --sessions "$ids"
        echo ""
    else
        echo "   Skipping the export. You can also run: opencode-db export $profile --sessions $ids"
    fi
}

# oc_shrink_confirm_run <runargs> <strip 0|1> <sel-args> [recipe] -> step 3 of
# the create flow: the DETAILED read-only plan (exact counts, computed on the
# LIVE DB with the same predicates shrink.sh uses) + the y/N gate. Nothing is
# written here; the live DB is never modified. `recipe` (the name picked in step
# 2) is printed with its purpose, so the plan is self-explanatory.
# Returns: 2 = declined at the gate (the caller goes BACK to the recipe list),
# 0 = the shrink ran, other = the run's own rc.
oc_shrink_confirm_run() {
    local runargs="$1" strip="$2" selargs="$3" recipe="${4:-}" recipe_purpose
    local disc_sql keep_sql n t db_sz total=0
    local keep_n disc_n keep_roots disc_roots keep_subs disc_subs
    # the discard set = the unmarked roots + every descendant (what the engine
    # prunes); keep = everything else.
    disc_sql=$(oc_shrink_sql_ids "$(printf '%s' "$selargs" | sed -n 's/^--discard-sessions //p')")
    if [ -n "$disc_sql" ]; then
        keep_sql="SELECT count(*) FROM session WHERE id NOT IN (WITH RECURSIVE d(id) AS (SELECT id FROM session WHERE id IN ($disc_sql) UNION SELECT s.id FROM session s JOIN d ON s.parent_id = d.id) SELECT id FROM d);"
        disc_n=$(o_q "WITH RECURSIVE d(id) AS (SELECT id FROM session WHERE id IN ($disc_sql) UNION SELECT s.id FROM session s JOIN d ON s.parent_id = d.id) SELECT count(*) FROM d;" 2>/dev/null) || disc_n=0
        keep_n=$(o_q "$keep_sql" 2>/dev/null) || keep_n=0
        disc_roots=$(o_q "WITH RECURSIVE d(id) AS (SELECT id FROM session WHERE id IN ($disc_sql) UNION SELECT s.id FROM session s JOIN d ON s.parent_id = d.id) SELECT count(*) FROM d WHERE d.id IN ($disc_sql);" 2>/dev/null) || disc_roots=0
        keep_roots=$(o_q "SELECT count(*) FROM session WHERE (parent_id IS NULL OR parent_id='' OR NOT EXISTS (SELECT 1 FROM session p WHERE p.id=session.parent_id)) AND id NOT IN ($disc_sql);" 2>/dev/null) || keep_roots=0
        disc_subs=$((disc_n - disc_roots))
        keep_subs=$(o_q "SELECT count(*) FROM session WHERE NOT (parent_id IS NULL OR parent_id='' OR NOT EXISTS (SELECT 1 FROM session p WHERE p.id=session.parent_id)) AND id NOT IN (WITH RECURSIVE d(id) AS (SELECT id FROM session WHERE id IN ($disc_sql) UNION SELECT s.id FROM session s JOIN d ON s.parent_id = d.id) SELECT id FROM d);" 2>/dev/null) || keep_subs=0
    else
        keep_n=$(o_q "SELECT count(*) FROM session;" 2>/dev/null) || keep_n=0
        disc_n=0; disc_roots=0; disc_subs=0
        keep_roots=$(o_q "SELECT count(*) FROM session WHERE parent_id IS NULL OR parent_id='' OR NOT EXISTS (SELECT 1 FROM session p WHERE p.id=session.parent_id);" 2>/dev/null) || keep_roots=0
        keep_subs=$((keep_n - keep_roots))
    fi

    echo ""
    echo "-> shrink plan (read-only counts — nothing is written yet)"
    printf '   %-11s %s\n' "Source:" "$OPENCODE_DB (LIVE DB, own snapshot)"
    printf '   %-11s %s\n' "Output:" "$OCED_BACKUP_DIR/shrink/<timestamp>/ (swap manually)"
    if [ -n "$recipe" ]; then
        recipe_purpose=$(oc_shrink_py purpose "$recipe" 2>/dev/null)
        printf '   %-11s %s\n' "Recipe:" "$recipe${recipe_purpose:+ - $recipe_purpose}"
    fi
    printf '   %-11s shrink %s\n' "Command:" "$runargs"
    if [ "$disc_n" -gt 0 ]; then
        printf '   %-11s %s root(s) + %s subagent(s) = %s session(s)\n' "Keep:" "$keep_roots" "$keep_subs" "$keep_n"
        printf '   %-11s %s root(s) + %s subagent(s) = %s session(s) (cascade)\n' "Discard:" "$disc_roots" "$disc_subs" "$disc_n"
    else
        printf '   %-11s ALL %s session(s) (%s root(s) + %s subagent(s))\n' "Keep:" "$keep_n" "$keep_roots" "$keep_subs"
    fi

    echo "   Rows to remove:"
    if [ "$disc_n" -gt 0 ]; then
        for t in part message todo session_message session_share session_context_epoch session_input; do
            n=$(o_q "SELECT count(*) FROM $t WHERE session_id NOT IN (WITH RECURSIVE d(id) AS (SELECT id FROM session WHERE id IN ($disc_sql) UNION SELECT s.id FROM session s JOIN d ON s.parent_id = d.id) SELECT id FROM d);" 2>/dev/null) || n=""
            [ -n "$n" ] || continue
            [ "$n" -eq 0 ] && continue
            printf '     %-24s %s\n' "$t" "$n"
            total=$((total + n))
        done
        for t in event event_sequence; do
            n=$(o_q "SELECT count(*) FROM $t WHERE aggregate_id LIKE 'ses_%' AND aggregate_id NOT IN (WITH RECURSIVE d(id) AS (SELECT id FROM session WHERE id IN ($disc_sql) UNION SELECT s.id FROM session s JOIN d ON s.parent_id = d.id) SELECT id FROM d);" 2>/dev/null) || n=""
            [ -n "$n" ] || continue
            [ "$n" -eq 0 ] && continue
            printf '     %-24s %s (discarded sessions)\n' "$t" "$n"
            total=$((total + n))
        done
        printf '     %-24s %s\n' "session" "$disc_n"
        total=$((total + disc_n))
    fi
    if [ "$strip" -eq 1 ]; then
        if [ "$disc_n" -gt 0 ]; then
            n=$(o_q "SELECT count(*) FROM part WHERE json_extract(data,'\$.type')='reasoning' AND session_id NOT IN (WITH RECURSIVE d(id) AS (SELECT id FROM session WHERE id IN ($disc_sql) UNION SELECT s.id FROM session s JOIN d ON s.parent_id = d.id) SELECT id FROM d);" 2>/dev/null) || n=0
        else
            n=$(o_q "SELECT count(*) FROM part WHERE json_extract(data,'\$.type')='reasoning';" 2>/dev/null) || n=0
        fi
        printf '     %-24s %s (in the sessions that survive)\n' "part (reasoning)" "$n"
        total=$((total + n))
    fi
    [ "$total" -eq 0 ] && printf '     (nothing to remove — the copy is a VACUUMed duplicate)\n'

    db_sz=0
    [ -f "$OPENCODE_DB" ] && db_sz=$(stat -c %s "$OPENCODE_DB" 2>/dev/null || echo 0)
    [ -f "$OPENCODE_DB-wal" ] && db_sz=$((db_sz + $(stat -c %s "$OPENCODE_DB-wal" 2>/dev/null || echo 0)))
    if [ "${db_sz:-0}" -gt 0 ]; then
        printf '   %-11s %s (the size after VACUUM is reported when it finishes)\n' "Size now:" "$(o_human_size "$db_sz")"
    fi
    echo ""
    [ "$disc_n" -gt 0 ] && oc_shrink_discard_offer "$(printf '%s' "$selargs" | sed -n 's/^--discard-sessions //p')"
    confirm_action "Build this shrink copy? The live DB is never modified; export memory first to keep its knowledge." \
        || { echo "   declined — back to the recipe step (ESC there cancels the flow)."; return 2; }
    # shellcheck disable=SC2086  # runargs must split ("--discard-sessions a,b")
    run_oced_tool shrink $runargs
    return $?
}

# oc_shrink_ops_pick <sel-args> -> step 2 of the create flow: the RECIPE, i.e.
# what happens to the sessions that SURVIVE (ops-only: the selection is already
# done in step 1, so a recipe never picks sessions). Rows = the recipe rows only
# (shrinklib/plan.py rows: built-ins lean/quiet + $OCED_SHRINK_PRESETS). No
# toggles and no "continue": picking a recipe IS the answer and goes straight to
# the plan, which is where the user already sees everything and confirms with
# y/N. Declining the plan (rc 2) re-renders this list to pick another recipe;
# ESC (rc 130) climbs to the sessions picker.
oc_shrink_ops_pick() {
    local selargs="$1" sel key line name runargs strip rc
    while true; do
        sel=$(oc_shrink_rows | oc_fzf_sel "shrink — recipe (what to do with the survivors)" \
                 $'The sessions are already selected. Pick what the copy should DO with the ones that survive.'$'\n'$'Every row goes straight to the read-only plan (y/N). ESC: back to sessions') || return 130
        key=$(oc_sel_key "$sel")
        case "$key" in
            __PRESET_*) ;;
            *) return 130 ;;
        esac
        name="${key#__PRESET_}"
        line=$(oc_shrink_py bake "$name") || { echo "   unknown recipe: $name"; continue; }
        strip=0
        case "$line" in *--strip-reasoning*) strip=1 ;; esac
        runargs="$selargs"
        [ "$strip" -eq 1 ] && runargs="$runargs --strip-reasoning"
        oc_shrink_confirm_run "$runargs" "$strip" "$selargs" "$name"
        rc=$?
        # 2 = declined at the gate: come back here to pick another recipe
        [ "$rc" -eq 2 ] && continue
        return $rc
    done
}

# oc_shrink_sessions_pick -> step 1 of the create flow: ROOT sessions on/off
# ([x] = survive in the copy; subagents follow their root, so they are never
# listed separately). Default: ALL marked. Order: newest first (time_updated)
# with a mode-toggle row to flip it; the rows are re-read on every render and
# the marks live in an assoc array keyed by id, so re-sorting loses nothing.
# Bulk rows: ALL / NONE / LAST N / OLDEST N / DAYS N (the age-based ones
# RESTART the selection: unmark everything, then mark only the roots that
# match). __MAKE__ continues to the recipe step with the current selection
# (all marked = --keep-all; unmarked roots = --discard-sessions, whose
# subagents cascade). Zero marked is refused.
oc_shrink_sessions_pick() {
    local -a ids=() unmarked=() top=()
    local -A marks=() local_disp=() sub_n=()
    local id line mark sel key n csv selargs label order all_ids
    local ord=updated-desc ord_mode="newest first"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        sub_n["${line%%$'\t'*}"]="${line##*$'\t'}"
    done < <(oc_shrink_sub_counts)

    while true; do
        # (re)read the session rows in the ACTIVE order on every render
        ids=(); local_disp=()
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            id=$(awk '{print $1}' <<<"$line")
            ids+=("$id")
            local_disp["$id"]="${line#* }"
        done < <(session_rows --root --order "$ord")
        if [ "${#ids[@]}" -eq 0 ]; then
            echo "   (no root sessions to select)"
            return 1
        fi
        # default ALL marked, but only for the sessions we have NOT seen yet.
        # marks[] holds 1/0 and is never unset, so an explicit 0 (a session the
        # user unmarked) survives every re-render (bulk rows, order toggle, ...).
        for id in "${ids[@]}"; do [ -n "${marks[$id]+set}" ] || marks[$id]=1; done
        sel=$( { printf '__MAKE__\t[>] continue with the CURRENT selection -> recipe\n'
                 oc_toggle_row "shrink — order: $ord_mode" \
                     "$([ "$ord_mode" = "newest first" ] && printf "oldest first" || printf "newest first")"
                 printf '__ALL__\t[mark ALL sessions (keep everything)]\n'
                 printf '__NONE__\t[unmark ALL — surgical mode: mark only what should survive]\n'
                 printf '__LAST__\t[keep only the N most recent sessions]\n'
                 printf '__OLDEST__\t[keep only the N oldest sessions]\n'
                 printf '__DAYS__\t[keep only the sessions updated in the last N days]\n'
                 for id in "${ids[@]}"; do
                     if [ "${marks[$id]:-0}" = 1 ]; then mark='[x]'; else mark='[ ]'; fi
                     local badge=''
                     [ -n "${sub_n[$id]:-}" ] && badge=" (${sub_n[$id]} sub)"
                     printf '%s\t%s %s%s\n' "$id" "$mark" "${local_disp[$id]:-}" "$badge"
                 done
               } | oc_fzf_sel "shrink — sessions (marked = survive)" \
                 $'Marked [x] ROOT sessions survive in the copy (their subagents follow).'$'\n'$"Default: all marked. Sorted: $ord_mode. [>] continue = pick the recipe. ESC: back") || return 0
        key=$(oc_sel_key "$sel")
        case "$key" in
            __MAKE__)
                unmarked=()
                local marked_any=0
                for id in "${ids[@]}"; do
                    if [ "${marks[$id]:-0}" = 1 ]; then marked_any=1; else unmarked+=("$id"); fi
                done
                if [ "$marked_any" -eq 0 ]; then
                    echo ""
                    echo "   Nothing is selected — the copy would be an EMPTY database."
                    echo "   Mark at least one session (or [mark ALL]) before continuing."
                    continue
                fi
                if [ "${#unmarked[@]}" -eq 0 ]; then
                    selargs="--keep-all"
                else
                    csv=$(IFS=','; echo "${unmarked[*]}")
                    selargs="--discard-sessions $csv"
                fi
                oc_shrink_ops_pick "$selargs"
                # 130 = ESC at the recipe step: climb back here with the
                # marks intact. Any other rc (a failed run) ends the flow.
                [ "$?" -eq 130 ] && continue
                return 0
                ;;
            __TOGGLE__)
                if [ "$ord_mode" = "newest first" ]; then
                    ord=updated-asc; ord_mode="oldest first"
                else
                    ord=updated-desc; ord_mode="newest first"
                fi
                ;;
            __ALL__)   for id in "${ids[@]}"; do marks[$id]=1; done ;;
            __NONE__)  for id in "${ids[@]}"; do marks[$id]=0; done ;;
            __LAST__ | __OLDEST__ | __DAYS__)
                case "$key" in
                    __LAST__)   label="Keep only the N most recent sessions — N"; order="DESC" ;;
                    __OLDEST__) label="Keep only the N oldest sessions — N"; order="ASC" ;;
                    __DAYS__)   label="Keep only the sessions updated in the last N days — N"; order="DAYS" ;;
                esac
                n=$(oc_read_int "$label") || continue
                for id in "${ids[@]}"; do marks[$id]=0; done
                all_ids=$(oc_shrink_sql_ids "$(IFS=','; echo "${ids[*]}")")
                if [ "$order" = "DAYS" ]; then
                    mapfile -t top < <(o_q "SELECT s.id FROM session s WHERE s.id IN ($all_ids) AND s.time_updated >= (strftime('%s','now') - $n * 86400) * 1000 ORDER BY s.time_updated DESC, s.time_created DESC;" 2>/dev/null)
                    [ "${#top[@]}" -eq 0 ] && echo "   (no session was updated in the last $n day(s) — everything is now unmarked)"
                else
                    mapfile -t top < <(o_q "SELECT s.id FROM session s WHERE s.id IN ($all_ids) ORDER BY s.time_updated $order, s.time_created $order LIMIT $n;" 2>/dev/null)
                    [ "${#top[@]}" -eq 0 ] && echo "   (nothing to mark)"
                fi
                for id in "${top[@]}"; do marks[$id]=1; done ;;
            *)
                if [ -n "$key" ] && [ "$key" != "__NONE__" ]; then
                    if [ "${marks[$key]:-0}" = 1 ]; then marks[$key]=0; else marks[$key]=1; fi
                fi
                ;;
        esac
    done
}

# __CREATE__ of the shrinks picker: sessions -> recipe -> plan.
oc_pick_shrink() {
    oc_shrink_sessions_pick
}

# --------------------------------------------------------------------
# Shrinks picker: CREATE a pruned copy AND manage the produced runs
# (view shrink.json / toggle to remove), like exports. Rows come from the
# shrink.sh helpers (shrinks_runs_find/shrinks_run_row — the same source as
# `shrinks list --tsv`), so there is no duplicated aggregation in the menu.
# --------------------------------------------------------------------
oc_shrinks_rows() {
    local mode="$1" run
    printf '__CREATE__\t[create shrink copy (pruned + VACUUMed from the LIVE DB)...]\n'
    printf '__SWAP__\t[>] swap a copy into the LIVE DB (destructive — type "confirm")\n'
    printf '__VERIFY__\t[verify: check for orphan dirs, old pre-shrinks, stale shrinks]\n'
    oc_toggle_row "$mode" "$([ "$mode" = view ] && printf remove || printf view)"
    if [ "$mode" = "remove" ]; then
        printf '__DELETE_ALL__\t[delete ALL shrink copies]\n'
        printf '__KEEP_NEWEST__\t[delete all except the newest]\n'
    fi
    local -a runs=()
    mapfile -t runs < <(shrinks_runs_find)
    [ "${#runs[@]}" -gt 0 ] || { printf '__NONE__\t(no shrink copies yet)\n'; return 0; }
    for run in "${runs[@]}"; do
        shrinks_run_row "$run"
    done
}

# Bulk deletions from the shrinks picker (all / keep newest only).
oc_shrinks_bulk() {
    local what="$1"
    local -a runs=()
    mapfile -t runs < <(shrinks_runs_find)
    local total=${#runs[@]}
    [ "$total" -gt 0 ] || { echo "   (no shrink copies yet)"; return 1; }
    local -a targets=()
    if [ "$what" = "all" ]; then
        confirm_action "DELETE ALL $total shrink copies? This cannot be undone." || { echo "   cancelled."; return 0; }
        targets=("${runs[@]}")
    else
        [ "$total" -le 1 ] && { echo "   Already only 1 shrink copy."; return 0; }
        confirm_action "DELETE $((total - 1)) older shrink copies, keeping only the newest?" || { echo "   cancelled."; return 0; }
        targets=("${runs[@]:1}")
    fi
    local s
    for s in "${targets[@]}"; do
        run_oced_tool shrinks remove "${s##*/}" --yes
    done
}

# oc_shrinks_swap_pick -> pick an existing copy, gate with a typed 'confirm' and
# swap it into the LIVE DB safely (pre-shrink WAL-safe snapshot + rollback come
# from oced_shrink_swap; stale freshness is flagged first).
oc_shrinks_swap_pick() {
    local -a runs=()
    local run sel key snap stale
    mapfile -t runs < <(shrinks_runs_find)
    [ "${#runs[@]}" -gt 0 ] || { echo "   (no shrink copies yet — create one first)."; return 0; }
    sel=$(for run in "${runs[@]}"; do shrinks_run_row "$run"; done | oc_fzf_sel "swap (pick a copy)" \
        $'Pick the copy to SWAP into the LIVE DB (DESTRUCTIVE).'$'\n'$'opencode MUST be closed first; a pre-shrink safety copy is auto-created. ESC: back') || return $?
    key=$(oc_sel_key "$sel")
    [ -n "$key" ] || return 0
    snap="$OCED_BACKUP_DIR/shrink/$key/opencode.shrunk.db"
    if [ ! -f "$snap" ]; then
        echo "   copy not found: $snap"
        return 0
    fi
    stale=$(o_shrink_stale "$OCED_BACKUP_DIR/shrink/$key/shrink.json")
    if [ -n "$stale" ]; then
        echo ""
        echo "⚠️  WARNING: $stale"
        echo "   Swapping with this copy would LOSE recent sessions (or freshness is unknown)."
        echo "   You should create a new shrink before swapping."
        echo ""
    fi
    echo ""
    echo "⚠️  DESTRUCTIVE ACTION: this REPLACES the live database at:"
    echo "     $OPENCODE_DB"
    echo ""
    echo "   Prerequisites:"
    echo "   - opencode MUST be completely closed (TUI and server)"
    echo "   - a pre-shrink safety copy is created automatically in $OCED_BACKUP_DIR/pre-shrink/"
    echo "   - if anything fails, the swap rolls back automatically"
    echo ""
    oc_confirm_typed "confirm" || return 0
    echo ""
    echo "   Swapping... (this may take a moment)"
    oced_shrink_swap "$snap" 1
    [ $? -eq 0 ] && menu_pause "Shrink Swap" || :
}

oc_shrinks_picker() {
    local mode="view" sel key
    while true; do
        local header
        header="Shrink copies — mode: $mode"$'\n'"$(
            if [ "$mode" = view ]; then printf 'view: show the shrink.json of a run — create new copies via the first row';
            else printf 'remove: delete a run (with confirmation)'; fi
        )"
        sel=$(oc_shrinks_rows "$mode" | oc_fzf_sel "shrinks ($mode)" "$header") || return $?
        key=$(oc_sel_key "$sel")
        case "$key" in
            __CREATE__)     oc_pick_shrink; continue ;;
            __SWAP__)       oc_shrinks_swap_pick; continue ;;
            __VERIFY__)     run_oced_tool shrinks verify; menu_pause "Shrinks Verify" || return 0; continue ;;
            __TOGGLE__)     mode=$( [ "$mode" = view ] && printf remove || printf view ); continue ;;
            __DELETE_ALL__) oc_shrinks_bulk all; continue ;;
            __KEEP_NEWEST__) oc_shrinks_bulk newest; continue ;;
            __NONE__)       continue ;;
            *)
                if [ "$mode" = view ]; then
                    run_oced_tool shrinks view "$key"
                    menu_pause "Shrinks" || return 0
                    return 0
                fi
                # Remove mode: check if this shrink is stale vs live DB
                local stale
                stale=$(o_shrink_stale "$OCED_BACKUP_DIR/shrink/$key/shrink.json")
                if [ -n "$stale" ]; then
                    echo ""
                    echo "⚠️  WARNING: $stale"
                    echo "   Swapping with this copy would LOSE recent sessions (or freshness is unknown)."
                    echo "   You should create a new shrink (Step 2 in guide) before swapping."
                    echo ""
                    if ! confirm_action "Continue with stale shrink anyway? (NOT RECOMMENDED)"; then
                        continue
                    fi
                fi
                confirm_action "Remove shrink run $key? It deletes the generated copy." || continue
                run_oced_tool shrinks remove "$key" --yes
                continue
                ;;
        esac
    done
}

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