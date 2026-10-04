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
    local csv="$1" hide="${2:-0}"
    local sel key header name seldesc
    while true; do
        header=$'Export — pick a plan (preset): products + config from the presets file'
        [ "$hide" = "1" ] && header+=$'\n'"(subagents hidden: roots only)"
        header+=$'\n'"(ESC: back)"
        sel=$(oc_export_rows | oc_fzf_sel "export (presets)" "$header") || return $?
        key=$(oc_sel_key "$sel")
        case "$key" in
            __NONE__)   continue ;;
            __PRESET_*)
                name="${key#__PRESET_}"
                seldesc=$(oc_preset_descr "$name") || seldesc=""
                if oc_preset_run "$name" "$seldesc" "$csv" "$hide"; then
                    # The run is done: hand control back up (make_action ->
                    # the session picker -> oc_export_picker -> __CREATE__ of the
                    # exports picker), which owns the pause and decides whether
                    # to redraw the exports list or close the submenu.
                    return 0
                fi
                ;;
        esac
    done
}

# oc_preset_run <preset> <descr> <csv> [hide_subs] -> confirm and run.
# hide_subs=1 means the picker had subagents hidden, so the CSV holds roots only:
# the run pins --no-subagents so the guarantee does not depend on the selection
# being passed at all (e.g. a preset that would run the whole DB).
oc_preset_run() {
    local name="$1" descr="$2" csv="$3" hide="${4:-0}" purpose
    purpose=$(oc_preset_purpose "$name" 2>/dev/null) || purpose="see the presets file for its products/config"

    # snapshot: fresh — offer a backup when not aligned.
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

    local total_sess marked_count
    total_sess=$(o_q "SELECT count(*) FROM session;" 2>/dev/null) || total_sess=0
    local -a _arr
    IFS=',' read -r -a _arr <<< "$csv"
    marked_count="${#_arr[@]}"
    local all_marked=0
    [ "$marked_count" -eq "$total_sess" ] && all_marked=1

    # What the PRESET pins, straight from plan.py (python is the SSoT for preset
    # text). Empty = it pins no selection, which is the case where "everything
    # marked" really does mean everything.
    local psel psub
    psel=$(oc_plan_py selection "$name" 2>/dev/null) || psel=""
    psub=$(oc_plan_py subagents "$name" 2>/dev/null) || psub=""

    # ONE line saying what will actually be selected, and — when the preset pins
    # a selection that the marks cannot express — who wins and what is ignored.
    local sess_line
    if [ "$all_marked" = 1 ]; then
        if [ -n "$psel" ]; then
            sess_line="$psel (from the preset) — your $marked_count marks are not used"
        else
            sess_line="all $total_sess sessions in the DB"
        fi
    else
        sess_line="the $marked_count sessions you marked"
        [ -n "$psel" ] && sess_line+=" (the menu overrides the preset: $psel)"
    fi

    # Only what the MENU adds beyond the preset, so it is never mistaken for the
    # preset's own config.
    local menu_adds="nothing"
    local -a extra=()
    local run_csv="$csv"
    if [ "$hide" = "1" ]; then
        # Hidden mode: picker only showed roots. Expand to full cascade so all
        # subagents of selected roots are exported. No --no-subagents flag.
        run_csv=$(oc_export_expand_subs "$csv")
        menu_adds="subagents cascaded from selected roots"
    fi

    # Consequences the two lines above do not show. In "shown" mode a subagent is
    # an ordinary row with its own mark, so un-marking its session leaves it
    # selected and the engine exports it standalone, as a root.
    local note=""
    if [ "$hide" != "1" ]; then
        local n_stand
        n_stand=$(oc_export_standalone_subs "$csv")
        if [ "$n_stand" -gt 0 ]; then
            if [ "$psub" = "no_orphan_subagents" ] || [ "$psub" = "both" ]; then
                note="$n_stand subagent(s) are marked but their session is not: the preset's"
                note+=" --no-orphan-subagents WILL DROP them"
            else
                note="$n_stand subagent(s) will be exported standalone"
                note+=" (their session is not selected; --no-orphan-subagents would drop them)"
            fi
        fi
        # Explicitly unmarked subagents in shown mode (user clicked [ ] on them).
        local n_unmarked
        n_unmarked=$(oc_export_unmarked_subs "$csv")
        if [ "$n_unmarked" -gt 0 ]; then
            if [ -n "$note" ]; then note+=$'\n'; fi
            note+="$n_unmarked subagent(s) explicitly unmarked will be dropped"
        fi
    fi
    # A preset that already drops subagents cannot be widened by the switch.
    if [ -n "$psub" ] && [ "$hide" = "0" ] && [ -z "$note" ]; then
        case "$psub" in
            no_subagents|both) note="the preset drops every subagent; the subagents switch cannot bring them back" ;;
            no_orphan_subagents) note="the preset keeps only subagents whose parent is exported" ;;
        esac
    fi

    if [ "$all_marked" = 1 ]; then
        oc_export_confirm "$name" "$sess_line" "$menu_adds" "$note" || return 1
        run_oced_tool export "$name" "${extra[@]}"
    else
        oc_export_confirm "$name" "$sess_line" "$menu_adds" "$note" || return 1
        run_oced_tool export "$name" --sessions "$run_csv" "${extra[@]}"
    fi
    return 0
}

oc_export_sessions_pick() {
    _oc_export_make_action() {
        local csv="$1" hide="${3:-0}"
        oc_export_presets_picker "$csv" "$hide"
        return $?
    }

    local -A _cfg=(
        [roots_only]=0
        [title]="export — mark the sessions to include"
        [header]=""
        [order]=updated-desc
        [order_mode]="newest first"
        [make_label]="[>] choose the preset"
        [make_action]=_oc_export_make_action
        [empty_guard_msg]="Nothing marked — an export needs at least one session."
        [get_sub_count]=oc_export_sub_counts
        [get_sub_ids]=oc_export_sub_ids
    )
    oc_session_picker _cfg
}

oc_export_picker() {
    if [ -f "${OCED_PRESETS:-}" ]; then
        oc_export_sessions_pick
        return $?   # 0 = ran, 130 = ESC'd out; the caller pauses
    fi
    # No presets file: the menu wizard is preset-only. The CLI still accepts
    # raw product keywords and flags. rc 0 so __CREATE__ pauses and lets the
    # user read this before redrawing the list.
    echo "Export from the menu needs a presets file (named plans = the source of truth)."
    echo "   missing: $OCED_PRESETS"
    echo "   create it from the shipped example:"
    echo "     cp \"$SCRIPT_DIR/../presets.json.example\" \"$OCED_PRESETS\""
    echo "   meanwhile: opencode-db export transcript|memory|digest [flags]"
    return 0
}

#-----------------------------------------------------------------------
# oc_export_sub_ids -> one id per line: every REAL subagent, i.e. a session with
# a non-empty parent_id whose parent row still exists. Drives the picker's
# "subagents" visibility row. A session whose parent is gone (an orphan) is a
# ROOT for every purpose, so it is never hidden.
oc_export_sub_ids() {
    o_q "SELECT s.id FROM session s
          WHERE s.parent_id IS NOT NULL AND s.parent_id <> ''
            AND EXISTS (SELECT 1 FROM session p WHERE p.id = s.parent_id);" 2>/dev/null
}

# oc_export_sub_counts -> "id\tN_sub" for ROOT sessions that have subagents.
# Mirror of oc_shrink_sub_counts but used by the export session picker to
# display a badge for all-sessions mode (roots_only=0).
oc_export_sub_counts() {
    o_q -separator $'\t' "WITH RECURSIVE d(id, root) AS (
            SELECT s.id, s.id FROM session s
             WHERE s.parent_id IS NULL OR s.parent_id = ''
                OR NOT EXISTS (SELECT 1 FROM session p WHERE p.id = s.parent_id)
            UNION ALL
            SELECT c.id, d.root FROM session c JOIN d ON c.parent_id = d.id)
         SELECT root, count(*) - 1 FROM d GROUP BY root HAVING count(*) > 1;" 2>/dev/null
}

# oc_export_sql_ids <csv> -> sanitized SQL IN-list ('id1','id2') for export queries.
oc_export_sql_ids() {
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

# oc_export_expand_subs <csv> -> csv with all subagents (recursive) of the
# given roots. Used in hidden mode: the picker only shows roots, so we expand
# to the full cascade before passing to the export tool.
oc_export_expand_subs() {
    local inlist
    inlist=$(oc_export_sql_ids "$1")
    [ -n "$inlist" ] || { printf ''; return 0; }
    o_q "WITH RECURSIVE subs(id) AS (
              SELECT id FROM session WHERE id IN ($inlist)
              UNION ALL
              SELECT s.id FROM session s JOIN subs ON s.parent_id = subs.id
          )
          SELECT id FROM subs;" 2>/dev/null | paste -sd, -
}

# oc_export_unmarked_subs <csv> -> how many REAL subagents of the marked roots
# are NOT in the CSV (i.e. explicitly unmarked by the user in shown mode).
# Only counts subagents whose parent root IS in the CSV.
oc_export_unmarked_subs() {
    local inlist
    inlist=$(oc_export_sql_ids "$1")
    [ -n "$inlist" ] || { printf '0'; return 0; }
    local n
    n=$(o_q "WITH RECURSIVE subs(id) AS (
                  SELECT id FROM session WHERE id IN ($inlist)
                  UNION ALL
                  SELECT s.id FROM session s JOIN subs ON s.parent_id = subs.id
              )
              SELECT count(*) FROM subs WHERE id NOT IN ($inlist);" 2>/dev/null) || n=""
    case "${n:-0}" in
        '' | *[!0-9]*) printf '0' ;;
        *)             printf '%s' "$n" ;;
    esac
}

# oc_export_standalone_subs <csv> -> how many REAL subagents of <csv> have their
# parent session OUTSIDE <csv>. Those are the ones the engine promotes to roots
# and exports standalone, so the confirm step can say so before the gate. The
# EXISTS guard is the same rule as oc_export_sub_ids: a session whose parent row
# is GONE is an orphan, i.e. a root, never a "standalone subagent". Prints 0 on
# an empty CSV or a failed query.
oc_export_standalone_subs() {
    local inlist
    inlist=$(oc_export_sql_ids "$1")
    [ -n "$inlist" ] || { printf '0'; return 0; }
    local n
    n=$(o_q "SELECT count(*) FROM session s
              WHERE s.parent_id IS NOT NULL AND s.parent_id <> ''
                AND s.id IN ($inlist)
                AND s.parent_id NOT IN ($inlist)
                AND EXISTS (SELECT 1 FROM session p WHERE p.id = s.parent_id);" 2>/dev/null) || n=""
    case "${n:-0}" in
        '' | *[!0-9]*) printf '0' ;;
        *)             printf '%s' "$n" ;;
    esac
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

# oc_annotate_flags <csv> -> human phrases, ONE PER LINE: "faithful JSON, raw and
# unfiltered", "full tool outputs", etc. (no separator, no marker: a joined
# string read as an expression rather than a list).
# Hints are defined in exportlib/flags.py (ANNOTATE_HINTS) — the single source of truth.
oc_annotate_flags() {
    local csv="$1"
    [ -n "$csv" ] || return 0
    python3 "$SCRIPT_DIR/exportlib/flags.py" --annotate "$csv" 2>/dev/null
}

# oc_export_plan <profile> -> the confirm's product block.
# profile = preset name OR product keyword (transcript|memory|digest).
# FLAT, no label and no leading indentation: the caller owns the layout. Wrapped
# at a FIXED width (not `tput cols`) so the screen is deterministic across
# terminals and the smoke suite can assert the exact column count.
OCED_PLAN_WIDTH=72
oc_export_plan() {
    oc_plan_py plan "$1" --width "$OCED_PLAN_WIDTH"
}

# oc_export_notes <profile> -> the caveats of that plan, "" when it has none.
# A note is an annotation OF the recipe, never a recipe itself: `has_json` /
# `has_sanitize` come from the preset's own flags.
oc_export_notes() {
    oc_plan_py notes "$1" --width "$OCED_PLAN_WIDTH"
}

# oc_export_confirm <preset> <sessions-line> [menu-adds] [note]
# One honest block: what will be selected, what the menu adds on top of the
# preset, and the consequences the rows cannot show.
#
# Layout is FLAT and flush left: no indentation, no bullets, no levels. The
# `%-10s` key column is what aligns the values ("Menu adds:" is exactly 10
# chars, so `%-9s` used to push its value one column right of every other).
# Below the rows come the products (name, then its description and effective
# flags BELOW it) and, when the plan has any, an annotated "-> Notes" block.
oc_export_confirm() {
    local name="$1" sess="$2" menu_adds="${3:-nothing}" note="${4:-}"
    local db_est=0
    [ -f "$OPENCODE_DB-wal" ] && db_est=$((db_est + $(stat -c %s "$OPENCODE_DB-wal"))) || true
    [ -f "$OPENCODE_DB-shm" ] && db_est=$((db_est + $(stat -c %s "$OPENCODE_DB-shm"))) || true
    db_est=$((db_est + $(stat -c %s "$OPENCODE_DB")))
    echo ""
    echo "-> Export plan"
    printf '%-10s %s\n' "Source:" "$OPENCODE_DB"
    printf '%-10s %s\n' "Preset:" "$name"
    printf '%-10s %s\n' "Sessions:" "$sess"
    printf '%-10s %s\n' "Menu adds:" "$menu_adds"
    [ -n "$note" ] && printf '%-10s %s\n' "Note:" "$note"
    printf '%-10s %s\n' "Output:" "$OCED_OUT/<timestamp>"
    echo ""
    oc_export_plan "$name"
    local notes
    notes=$(oc_export_notes "$name")
    if [ -n "$notes" ]; then
        echo ""
        echo "-> Notes"
        printf '%s\n' "$notes"
    fi
    echo ""
    if [ "$db_est" -ge 1073741824 ]; then
        confirm_action "Start this export? The DB is ~$(o_human_size "$db_est") — may take a while." || { echo "   cancelled."; return 1; }
    else
        confirm_action "Start this export?" || { echo "   cancelled."; return 1; }
    fi
    return 0
}
