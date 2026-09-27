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
    local csv="$1"
    local sel key header name seldesc
    while true; do
        header=$'Export — pick a plan (preset): products + config from the presets file'$'\n'$'(ESC: back)'
        sel=$(oc_export_rows | oc_fzf_sel "export (presets)" "$header") || return $?
        key=$(oc_sel_key "$sel")
        case "$key" in
            __NONE__)   continue ;;
            __PRESET_*)
                name="${key#__PRESET_}"
                seldesc=$(oc_preset_descr "$name") || seldesc=""
                if oc_preset_run "$name" "$seldesc" "$csv"; then
                    menu_pause "Export" || return 0
                    return 0 # Exits the wizard back to main menu
                fi
                ;;
        esac
    done
}

# oc_preset_run <preset> <descr> <csv> -> confirm and run.
oc_preset_run() {
    local name="$1" descr="$2" csv="$3" purpose
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

    if [ "$marked_count" -eq "$total_sess" ]; then
        # All sessions — run as configured (no filter).
        oc_export_confirm "preset: $name" "(preset as configured)" \
            "preset '$name' (${descr:-see the presets file})" || return 1
        run_oced_tool export "$name"
    else
        oc_export_confirm "preset: $name" "sessions: $csv" \
            "preset '$name' (${descr:-see the presets file}) · sessions: $csv" || return 1
        run_oced_tool export "$name" --sessions "$csv"
    fi
    return 0
}

oc_export_sessions_pick() {
    _oc_export_make_action() {
        local csv="$1"
        oc_export_presets_picker "$csv"
        return $?
    }

    local -A _cfg=(
        [roots_only]=0
        [title]="export — sessions (marked = include)"
        [header]="Mark [x] sessions to export (subagents follow their root). Default: all marked."
        [order]=updated-desc
        [order_mode]="newest first"
        [make_label]="[>] select preset (recipe) for CURRENT selection"
        [make_action]=_oc_export_make_action
        [empty_guard_msg]="Nothing is marked — at least one session must be selected."
        [get_sub_count]=oc_export_sub_counts
    )
    oc_session_picker _cfg
}

oc_export_picker() {
    if [ -f "${OCED_PRESETS:-}" ]; then
        oc_export_sessions_pick
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

# Globals used by oc_preset_run callbacks (reset on every call).
# (No longer used, removed)

#-----------------------------------------------------------------------
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

