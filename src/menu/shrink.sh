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

# DISCARD_LIST_MAX -> how many discarded sessions the plan names before it
# summarises the rest. An id alone says nothing ("which chat is this?"), so the
# plan shows titles — but a 500-session discard must not flood the screen.
DISCARD_LIST_MAX=8
DISCARD_TITLE_W=60

# oc_shrink_discard_rows <roots-csv> -> one TSV line per discarded ROOT session:
# "<id>\t<title>\t<descendant-count>", read-only on the live DB, ordered like the
# picker (newest used first). The title is the reason this exists: the plan names
# what it drops. Tabs/newlines inside a title would break a TSV line, so they
# collapse to spaces (a title is one display field, not a data field).
oc_shrink_discard_rows() {
    local inlist
    inlist=$(oc_shrink_sql_ids "$1")
    [ -n "$inlist" ] || return 0
    o_q -separator $'\t' "
        WITH RECURSIVE d(id, root) AS (
            SELECT s.id, s.id FROM session s WHERE s.id IN ($inlist)
            UNION ALL
            SELECT c.id, d.root FROM session c JOIN d ON c.parent_id = d.id)
        SELECT d.root,
               CASE WHEN s.title IS NULL OR s.title = ''
                    THEN '(no title)'
                    ELSE replace(replace(replace(s.title, char(9), ' '), char(10), ' '), char(13), ' ')
               END,
               count(*) - 1
          FROM d JOIN session s ON s.id = d.root
         GROUP BY d.root
         ORDER BY s.time_updated DESC;" 2>/dev/null
}

# oc_shrink_discard_offer <roots-csv> -> offers to export what the shrink is about
# to drop: the SAFE order is backup -> export <profile> -> shrink.
#
# <roots-csv> are the roots the picker left unmarked, but the DISCARD set is
# descendant-closed while `export --sessions` matches EXACT ids. Offering the
# roots alone would export 2 of the 7 sessions about to be dropped — and it would
# look like it worked, because the export succeeds with plausible counts. So the
# offer expands to the full cascade (oc_export_expand_subs, the same helper the
# export wizard uses for its hidden-subagent mode).
# Profile: o_shrink_discard_profile ($OCED_SHRINK_DISCARD_EXPORT_PROFILE, default
# archive = transcript + memory) — a config choice, not another menu row.
oc_shrink_discard_offer() {
    local roots="$1"
    [ -n "$roots" ] || return 0
    local profile cascade rows shown=0 total
    profile=$(o_shrink_discard_profile)
    cascade=$(oc_export_expand_subs "$roots")
    [ -n "$cascade" ] || cascade="$roots"
    rows=$(oc_shrink_discard_rows "$roots")
    total=$(printf '%s' "$rows" | grep -c . || true)
    echo ""
    echo "   This shrink WILL DISCARD these session(s) (each with its subagents):"
    while IFS=$'\t' read -r id title subs; do
        [ -n "$id" ] || continue
        shown=$((shown + 1))
        [ "$shown" -gt "$DISCARD_LIST_MAX" ] && break
        if [ "${#title}" -gt "$DISCARD_TITLE_W" ]; then
            title="${title:0:$DISCARD_TITLE_W}…"
        fi
        if [ "${subs:-0}" -gt 0 ]; then
            printf '     %-38s %s (%s subagent(s))\n' "$id" "$title" "$subs"
        else
            printf '     %-38s %s\n' "$id" "$title"
        fi
    done <<< "$rows"
    if [ "$total" -gt "$DISCARD_LIST_MAX" ]; then
        printf '     … and %s more (all of them: %s)\n' "$((total - DISCARD_LIST_MAX))" "$cascade"
    fi
    if confirm_action "Export them first (opencode-db export $profile --sessions)? This is the SAFE order (backup -> export $profile -> shrink)."; then
        run_oced_tool export "$profile" --sessions "$cascade"
        echo ""
    else
        echo "   Skipping the export. You can also run: opencode-db export $profile --sessions $cascade"
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
        sel=$(oc_shrink_rows | oc_fzf_sel "shrink — recipe" \
                 "Sessions are marked. Pick what the copy should DO with the survivors · every row goes to the read-only plan · ESC: back") || return 130
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

# oc_shrink_sessions_pick -> step 1 of the create flow.
# Delegates to the generic oc_session_picker (roots_only=1).
# make_action receives the CSV of MARKED (surviving) root IDs and computes
# the discard set (all roots − marked), then calls oc_shrink_ops_pick.
oc_shrink_sessions_pick() {
    # Snapshot all root IDs now; used in make_action to compute the discard set.
    local -a _all_roots=()
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        _all_roots+=("$(awk '{print $1}' <<<"$line")")
    done < <(session_rows --root)

    _shr_make_action() {
        local marked_csv="$1" unmarked_csv="$2" selargs
        if [ -z "$unmarked_csv" ]; then
            selargs="--keep-all"
        else
            selargs="--discard-sessions $unmarked_csv"
        fi
        oc_shrink_ops_pick "$selargs"
        # rc 130 = ESC at the recipe step: bubble up so oc_session_picker loops.
        return $?
    }

    local -A _shr_cfg=(
        [roots_only]=1
        [title]="shrink — mark the ROOT sessions that survive"
        [header]="a marked session keeps its subagents"
        [order]=updated-desc
        [order_mode]="newest first"
        [make_label]="[>] continue"
        [make_action]=_shr_make_action
        [empty_guard_msg]="Nothing marked — the copy would be an EMPTY database."
        [get_sub_count]=oc_shrink_sub_counts
    )
    oc_session_picker _shr_cfg
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
    local mode="$1" order="${2:-newest}" run live_max=""
    printf '__CREATE__\t[>] create shrink copy\n'
    printf '__SWAP__\t[>] swap a copy into the LIVE DB\n'
    printf '__VERIFY__\t[?] verify\n'
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
    local -a runs=()
    local dorder="desc"
    [ "$order" = "old" ] && dorder="asc"
    mapfile -t runs < <(shrinks_runs_find "$dorder")
    [ "${#runs[@]}" -gt 0 ] || { printf '__NONE__\t(no shrink copies yet)\n'; return 0; }
    # One live DB read for every row's freshness: a list must cost one query,
    # not one per copy (shrinks_run_row queries when live_max is empty).
    live_max=$(o_q "SELECT coalesce(max(time_updated),0) FROM session" 2>/dev/null || echo 0)
    # [>] = the all-details report: every copy's shrink.json in one go, the same
    # `shrinks view` a row runs, so nothing can drift between the two. VIEW ONLY
    # (never next to [delete all]) and only when there is a copy to show.
    if [ "$mode" = "view" ]; then
        printf '__REPORT_ALL__\t[>] details of all copies\n'
    fi
    for run in "${runs[@]}"; do
        shrinks_run_row "$run" "$live_max"
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
    local rc=$?
    [ "$rc" -ne 0 ] && return $rc
    # The pause rc travels to __SWAP__ so an ESC there closes the submenu
    # instead of silently redrawing the list.
    menu_pause "Shrink Swap"
    return $?
}

oc_shrinks_picker() {
    local mode="view" order="newest" sel key
    while true; do
        local header
        header="Shrink copies — mode: $mode"
        sel=$(oc_shrinks_rows "$mode" "$order" | oc_fzf_sel "shrinks ($mode)" "$header") || return $?
        key=$(oc_sel_key "$sel")
        case "$key" in
            __CREATE__)
                    # rc 0 = a copy was built (pause, then back to this list);
                    # 130 = ESC'd out of the wizard (no pause). A pause ESC is
                    # rc 2 and leaves the submenu, like every other report.
                    oc_pick_shrink
                    [ $? -eq 0 ] || continue
                    menu_pause "Shrink copy" || return 0
                    continue
                    ;;
            __SWAP__)       oc_shrinks_swap_pick; [ $? -eq 2 ] && return 0; continue ;;
            __VERIFY__)     run_oced_tool shrinks verify; menu_pause "Shrinks Verify" || return 0; continue ;;
            __REPORT_ALL__)
                # One header, then one `shrinks view` per copy and a SINGLE pause:
                # a report, not a row that opens a flow.
                local -a stamps=() rdirs=()
                mapfile -t rdirs < <(shrinks_runs_find)
                local rd
                for rd in "${rdirs[@]}"; do
                    [ -n "$rd" ] && stamps+=( "${rd##*/}" )
                done
                oc_shrinks_view_all "${stamps[@]}"
                # rc 2 = ESC at the report pause -> close the submenu (see the
                # exports picker: a report ESC never redraws the list).
                [ $? -eq 2 ] && return 0
                continue
                ;;
            __TOGGLE__)     mode=$( [ "$mode" = view ] && printf remove || printf view ); continue ;;
            __TOGGLE_ORDER__) order=$( [ "$order" = newest ] && printf old || printf newest ); continue ;;
            __DELETE_ALL__) oc_shrinks_bulk all; continue ;;
            __KEEP_NEWEST__) oc_shrinks_bulk newest; continue ;;
            __NONE__)       continue ;;
            *)
                if [ "$mode" = view ]; then
                    run_oced_tool shrinks view "$key"
                    menu_pause "Shrinks" || return 0
                    continue
                fi
                # Remove mode: check if this shrink is stale vs live DB
                local stale
                stale=$(o_shrink_stale "$OCED_BACKUP_DIR/shrink/$key/shrink.json")
                if [ -n "$stale" ]; then
                    echo ""
                    echo "⚠️  WARNING: $stale"
                    echo "   Swapping with this copy would LOSE recent sessions (or freshness is unknown)."
                    echo "   You should create a new shrink copy before swapping."
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

