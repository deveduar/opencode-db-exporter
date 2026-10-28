#-----------------------------------------------------------------------
# Manage exports picker (view / remove)
#-----------------------------------------------------------------------
oc_exports_rows() {
    local mode="$1" order="${2:-newest}"
    # [>] = opens a FLOW, and creating a run IS one (sessions -> preset). It is
    # the first row so "make an export" is the primary action of the screen.
    printf '__CREATE__\t[>] create export\n'
    oc_toggle_row "$mode" "$([ "$mode" = view ] && printf remove || printf view)"
    if [ "$order" = "newest" ]; then
        oc_toggle_row "newest first" "old first" "__TOGGLE_ORDER__"
    else
        oc_toggle_row "old first" "newest first" "__TOGGLE_ORDER__"
    fi
    # [>] = the all-details report: every run's detail screen in one go, the same
    # `exports view` a row runs, so nothing can drift between the two. VIEW ONLY
    # and only when there is something to show: a report row next to [delete all]
    # is a mistake waiting to happen, and an empty list already says it has none.
    # [>] = opens the refresh flow (LEVEL 2: pick which run to update). It is
    # only meaningful on a run whose scope is still alive, so a stale/missing run
    # still gets it (that is exactly what refreshing is for) — the run list row
    # already says whether it is behind. `update all runs` is NOT here: it lives
    # in the update list (LEVEL 2), next to the runs it refreshes.
    if [ "$mode" = "view" ] && [ "$(exports_run_count)" -gt 0 ]; then
        printf '__UPDATE__\t[>] update\n'
        printf '__REPORT_ALL__\t[>] details of all runs\n'
    fi
    if [ "$mode" = "remove" ]; then
        printf '__DELETE_ALL__\t[delete all]\n'
        printf '__KEEP_NEWEST__\t[delete olds]\n'
    fi
    [ -d "$OCED_OUT" ] || return 0
    local run stamp recmeta freshness_json
    local dorder="desc"
    [ "$order" = "old" ] && dorder="asc"
    local -a runs=() metas=() stale_metas=()
    mapfile -t runs < <(exports_runs_find "$dorder")
    for run in "${runs[@]}"; do
        mapfile -t metas < <(find "$run" -type f -name metadata.json 2>/dev/null | sort)
        [ "${#metas[@]}" -gt 0 ] || { echo "error: $run has no metadata.json; re-export this run" >&2; return 1; }
        local m
        for m in "${metas[@]}"; do
            oced_export_require_meta "$m" || return 1
        done
        recmeta=$(oced_export_rec_meta "${metas[@]}")
        [ -n "$recmeta" ] || return 1
        stale_metas+=("$recmeta")
    done
    freshness_json=$(oced_exports_freshness_batch "${stale_metas[@]}" 2>/dev/null) || freshness_json='{}'
    for run in "${runs[@]}"; do
        [ -d "$run" ] || continue
        oc_exports_run_row "${run##*/}" "$freshness_json"
    done
}

# exports_run_count -> number of export run dirs under OCED_OUT.
exports_run_count() {
    [ -d "$OCED_OUT" ] || { echo 0; return; }
    find "$OCED_OUT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l
}

# oc_stamp_human <stamp> -> human readable date of an export run stamp, in LOCAL
# time (MENU ONLY: the stamp is UTC; `exports list` keeps rendering UTC itself).
oc_stamp_human() {
    local s="$1"
    case "$s" in
        [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]_[0-2][0-9]-[0-5][0-9])
            o_local_ts "${s:0:10} ${s:11:2}:${s:14:2}:00" '+%Y-%m-%d %H:%M %Z' ;;
        *) printf '%s' "$s" ;;
    esac
}

# oc_exports_run_row <stamp> -> one TSV row aggregating a run's metadata.
oc_exports_run_row() {
    local stamp="$1"
    local freshness_json="${2:-}"
    local run="$OCED_OUT/$stamp"
    local meta profiles="" roots=0 subs=0 msgs=0 found=0 m p r s refresh="" tag="" shown_date="" sess_cell="" preset=""
    local kept total nex
    local -a metas
    mapfile -t metas < <(find "$run" -type f -name metadata.json 2>/dev/null | sort)
    [ "${#metas[@]}" -gt 0 ] || { echo "error: $run has no metadata.json; re-export this run" >&2; return 1; }
    for m in "${metas[@]}"; do
        oced_export_require_meta "$m" || return 1
    done
    for m in "${metas[@]}"; do
        [ -f "$m" ] || continue
        found=1
        p=$(jq -r '.profile // "?"' "$m")
        profiles="${profiles:+$profiles+}$p"
        r=$(jq -r '[.session_records[] | select(.kind == "root")] | length' "$m")
        s=$(jq -r '[.session_records[] | select(.kind == "subagent")] | length' "$m")
        [ "$r" -gt "$roots" ] && roots="$r"
        [ "$s" -gt "$subs" ] && subs="$s"
        msgs=$((msgs + $(jq -r '.messages // 0' "$m")))
        # The preset the run was produced by: the recipe is what the refresh
        # replays, so the row names it (bundle metadata carries it too). A run
        # with no preset (a bare product keyword) leaves the column empty.
        [ -z "$preset" ] && preset=$(jq -r '.preset // empty' "$m" 2>/dev/null)
        # Size of the run, not just its roots: `K/N kept` when the run is a subset
        # (the `.excluded` it left out is the difference), else just `N`. The root/sub
        # breakdown always rides along, short (`3 root 19 sub`), so a narrowed run
        # never looks full.
        nex=$(jq -r '.excluded | length' "$m")
        kept=$(jq -r '.session_records | length' "$m")
        if [ "${nex:-0}" -gt 0 ]; then
            sess_cell="$kept/$((kept + nex)) kept · ${r} root ${s} sub"
        else
            sess_cell="$kept · ${r} root ${s} sub"
        fi
    done
    [ "$found" -eq 1 ] || profiles="?"
    # THE DATE the row must show is the LAST time this run moved. A refresh keeps
    # its stamp (its place in the list), so the stamp date would keep saying the
    # old creation time after an update — the metadata `.date` is the honest one.
    shown_date=$(oc_stamp_human "$stamp")
    local rm rdate recmeta
    if [ -n "${metas[0]:-}" ]; then
        rm=$(jq -r '.update_mode // empty' "${metas[0]}" 2>/dev/null)
        rdate=$(jq -r '.date // empty' "${metas[0]}" 2>/dev/null)
        if [ -n "$rm" ] && [ -n "$rdate" ]; then
            # `.date` is ISO UTC ("2026-10-19T18:19:30Z") -> the menu's local human form.
            shown_date=$(o_local_ts "${rdate%Z}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || printf '%s' "$stamp")
            # A refreshed run wears a mark, not a sentence: the mode (`delta`/
            # `accumulative`) still lives in `exports view`, so the row stays a row.
            refresh=" ⟳"
        fi
    fi
    # The freshness tag: the same `o_export_freshness` verdict `exports list`/`verify`
    # use, so the menu can never disagree with the CLI about a run being behind.
    recmeta=$(oced_export_rec_meta "${metas[@]}")
    if [ -n "$recmeta" ]; then
        if [ -n "$freshness_json" ]; then
            tag=$(printf '%s' "$freshness_json" | jq -r --arg path "$recmeta" '.[$path].tag // empty')
        else
            tag=$(o_export_freshness "$recmeta" --tag 2>/dev/null || true)
        fi
    fi
    [ -n "$tag" ] && tag=" ($tag)"
    local size
    size=$(du -sb "$run" 2>/dev/null | cut -f1); size=${size:-0}
    printf '%s\t%s\n' "$stamp" "$(printf '%-16s  %-30s  %-34s  %s msg · %s  %s%s%s' \
        "$shown_date" "$profiles" "${sess_cell:-$roots root}" "$msgs" "$(o_human_size "$size")" "$preset" "$tag" "$refresh")"
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
    local mode="view" order="newest" sel key
    while true; do
        local header
        header="Export runs — [>] create export, or inspect a run · mode: $mode"
        sel=$(oc_exports_rows "$mode" "$order" | oc_fzf_sel "exports ($mode)" "$header") || return $?
        key=$(oc_sel_key "$sel")
        case "$key" in
            __CREATE__)
                # The create flow owns the screen until it finishes. rc 0 = it
                # ran (pause here, then back to this list); rc 130 = the user
                # ESC'd out of the wizard (no pause: they asked to move on).
                # A pause ESC (rc 2) is swallowed by `menu_pause || return 0`
                # and leaves the submenu, like every other report.
                oc_export_picker
                [ $? -eq 0 ] || continue
                menu_pause "Export" || return 0
                continue
                ;;
            __TOGGLE__)     mode=$( [ "$mode" = view ] && printf remove || printf view ); continue ;;
            __TOGGLE_ORDER__) order=$( [ "$order" = newest ] && printf old || printf newest ); continue ;;
            __UPDATE__)
                # LEVEL 2 (the run list, in update mode): it owns the screen and
                # loops on its own runs until the user ESC's. When it returns
                # (ESC -> rc 130) we redraw THIS list; completing/cancelling an
                # update never reaches here (it redraws the update list instead),
                # so the user stays where they were.
                oc_exports_update_runs
                continue
                ;;
            __REPORT_ALL__)
                # One header, then one `exports view` per run and a SINGLE pause:
                # this is a report, not a row that opens a flow, so it must not
                # drop the user into a nested picker per run.
                local -a stamps=() rd
                while IFS= read -r rd; do
                    [ -n "$rd" ] && stamps+=( "${rd##*/}" )
                done < <(exports_runs_find)
                oc_exports_view_all "${stamps[@]}"
                # rc 2 = ESC at the report pause -> close the submenu, exactly
                # like every other report. `continue` alone would redraw the list.
                [ $? -eq 2 ] && return 0
                continue
                ;;
            __DELETE_ALL__) oc_exports_bulk all; continue ;;
            __KEEP_NEWEST__) oc_exports_bulk newest; continue ;;
            __NONE__)       continue ;;
            *)
                if [ "$mode" = view ]; then
                    run_oced_tool exports view "$key"
                    menu_pause "Manage exports" || return 0
                    continue
                fi
                confirm_action "Remove export run $key? It deletes the generated files." || continue
                run_oced_tool exports remove "$key" --yes
                continue
                ;;
        esac
    done
}

# oc_exports_update_runs -> LEVEL 2 of the refresh flow: the run list IN UPDATE
# MODE. `[>] update all runs` is its FIRST row (whole-shelf refresh), then one row
# per run (the same `oc_exports_run_row` the view/remove list uses). Picking a run
# opens LEVEL 3 (`oc_exports_update_modes`); when it returns — after running,
# declining or ESC'ing — this list REDRAWS, so the user stays in update mode and
# can refresh another run instead of landing back in the view/remove list. Only
# ESC here (rc 130) leaves to LEVEL 1.
oc_exports_update_runs() {
    local -a runs=()
    mapfile -t runs < <(exports_runs_find)
    [ "${#runs[@]}" -gt 0 ] || { echo "   (no export runs yet; create one first)"; return 1; }
    local sel key
    while true; do
        local -a rows=()
        if [ "${#runs[@]}" -gt 1 ]; then
            rows+=( "$(printf '__UPDATE_ALL__\t[>] update all runs')" )
        fi
        local r
        for r in "${runs[@]}"; do
            rows+=( "$(oc_exports_run_row "${r##*/}")" )
        done
        sel=$(printf '%s\n' "${rows[@]}" \
              | oc_fzf_sel "exports (update)" "Refresh a run in place — pick the run (ESC: back)") || return $?
        key=$(oc_sel_key "$sel")
        case "$key" in
            __UPDATE_ALL__) _oc_exports_update_all "${runs[@]}"; continue ;;
            __NONE__|"")    continue ;;
            *)              oc_exports_update_modes "$key"; continue ;;
        esac
    done
}

# oc_exports_update_modes <stamp> -> LEVEL 3: the concrete updates for ONE run.
#
# NOT a toggle screen: each ROW is a concrete update you can run (its own mode
# and excluded policy), because "change a modifier, re-run, re-read a plan that
# fzf then covers" is exactly the flow that left the user unable to read what was
# about to happen. Picking a row prints the engine's OWN `--dry-run` plan to the
# terminal (fzf is gone by then, so it scrolls) and THEN asks the y/N gate — the
# plan is on screen, uncovered, at the moment of the decision.
#
# It ALWAYS returns to LEVEL 2 (the caller `continue`s): running, declining or
# ESC'ing an update all redraw the run list, so the user never drops back to the
# view/remove list mid-refresh. The rc is therefore not a navigation signal
# (LEVEL 2 ignores it) — a run that is genuinely up to date just says so.
#
# A row is rendered only when its plan really MOVES something, so a no-op mode
# is never offered (picking it would print a plan and do nothing). When exactly
# ONE action remains — a full run with no gap (delta alone), or a narrowed run
# whose only useful move is bringing the scope back — the picker is SKIPPED and
# the action runs straight into its plan+gate: a one-row fzf screen is a step
# whose only job is to make the user press Enter.
oc_exports_update_modes() {
    local stamp="$1"
    [ -n "$stamp" ] || return 0

    # One `--dry-run --json` probe per policy that can differ. delta is the
    # baseline; `never` needs its OWN probe because its target differs from delta
    # exactly when delta revives an edited excluded session — reusing delta's
    # target for the `never` row printed the wrong leap. `accumulative` needs its
    # own because it can widen the set to the whole scope.
    #
    # `--include-excluded all` is deliberately NOT probed: it lands on the SAME
    # set as `--mode accumulative` (mathematically `in_scope == still ∪ new ∪
    # ex_live`), so the two are one action here — the single "bring the whole
    # scope back" row runs accumulative. The `all`/ids forms stay on the CLI.
    local p_delta p_never p_scope
    p_delta=$(run_oced_tool_json exports update "$stamp" --dry-run --json)
    p_never=$(run_oced_tool_json exports update "$stamp" --dry-run --json --sticky never)
    p_scope=$(run_oced_tool_json exports update "$stamp" --dry-run --json --mode accumulative)
    [ -n "$p_delta" ] || return 0
    local n_before n_excluded n_new n_changed n_revived
    n_before=$(printf '%s' "$p_delta" | jq -r '.counts.before // 0')
    n_excluded=$(printf '%s' "$p_delta" | jq -r '.counts.excluded_total // 0')
    n_new=$(printf '%s' "$p_delta" | jq -r '.counts.new // 0')
    n_changed=$(printf '%s' "$p_delta" | jq -r '.counts.changed // 0')
    # delta's default sticky=stale revives exactly the excluded sessions the DB
    # edited — that count is what tells us whether `keep excluded out` (never)
    # would differ from delta at all. It is the ONLY case where it differs.
    n_revived=$(printf '%s' "$p_delta" | jq -r '.counts.revived // 0')
    # Each policy's own target and its own "does it move anything" verdict. A
    # row whose plan is a no-op (`up_to_date`) must NOT be offered: picking it
    # would print a plan and then do nothing. delta can be a no-op while the
    # scope still has a gap (then only the scope row is useful, or nothing).
    local t_delta t_never t_scope t_rev
    t_delta=$(printf '%s' "$p_delta" | jq -r '.counts.target // 0')
    t_never=$(printf '%s' "$p_never" | jq -r '.counts.target // 0')
    t_scope=$(printf '%s' "$p_scope" | jq -r '.counts.target // 0')
    t_rev=$(printf '%s' "$p_scope" | jq -r '.counts.revived // 0')
    local d_move n_move s_move
    d_move=$(printf '%s' "$p_delta" | jq -r 'if .up_to_date then 0 else 1 end')
    n_move=$(printf '%s' "$p_never" | jq -r 'if .up_to_date then 0 else 1 end')
    s_move=$(printf '%s' "$p_scope" | jq -r 'if .up_to_date then 0 else 1 end')

    # Build the rows as `key<TAB>label`. A row is rendered only when its plan
    # really moves something (`*_move`), so a no-op never appears:
    #   delta  : offered when it moves.
    #   never  : offered only when delta would revive an edited excluded (the one
    #            case where it differs from delta) AND it actually moves.
    #   scope  : offered when the run has a gap AND bringing it back moves —
    #            this is the ONE reopen row (accumulative ≡ include-excluded all).
    # A run whose delta is a no-op but still has a gap gets ONLY the scope row (or
    # nothing when even that would not move) — never a delta row that does nothing.
    local delta_what=""
    [ "$n_changed" -gt 0 ] && delta_what+="re-render $n_changed"
    [ "$n_new" -gt 0 ] && delta_what+="${delta_what:+ · }+$n_new new"
    [ "$n_revived" -gt 0 ] && delta_what+="${delta_what:+ · }revive $n_revived edited"
    [ -n "$delta_what" ] || delta_what="no content change"
    local -a rows=()
    if [ "$d_move" -eq 1 ]; then
        rows+=( "$(printf '%s\t[>] sticky stale (default) — %s → %s' "__UPD_DELTA__" "$delta_what" "$t_delta")" )
    fi
    if [ "$n_excluded" -gt 0 ] && [ "$n_revived" -gt 0 ] && [ "$n_move" -eq 1 ]; then
        rows+=( "$(printf '%s\t[>] sticky never — 0 revived, %s excluded stay out → %s' "__UPD_NEVER__" "$n_excluded" "$t_never")" )
    fi
    if [ "$n_excluded" -gt 0 ] && [ "$s_move" -eq 1 ]; then
        rows+=( "$(printf '%s\t[>] bring the whole scope back — revive %s → %s' "__UPD_SCOPE__" "$t_rev" "$t_scope")" )
    fi

    # Nothing to offer (every row would be a no-op): say so and stop; LEVEL 2
    # redraws the run list. Same when the only row equals the run's own state.
    if [ "${#rows[@]}" -eq 0 ]; then
        echo ""
        echo "   Nothing has moved for $stamp — it already matches the live DB."
        return 0
    fi

    # ONE concrete action: skip the picker. There is no choice to make, so a
    # one-row fzf screen is a step that only asks the user to press Enter; the
    # action runs the same plan+gate path a picked row would.
    local key
    if [ "${#rows[@]}" -eq 1 ]; then
        key=$(oc_sel_key "${rows[0]}")
        case "$key" in
            __UPD_DELTA__)  _oc_exports_update_one "$stamp" ;;
            __UPD_NEVER__)  _oc_exports_update_one "$stamp" --sticky never ;;
            __UPD_SCOPE__)  _oc_exports_update_one "$stamp" --mode accumulative ;;
        esac
        return 0
    fi

    local hdr sel
    hdr="$stamp — now $n_before session(s), $n_excluded excluded"
    hdr="$hdr"$'\n'"sticky stale=revive an excluded only if edited · never=keep all excluded out"
    hdr="$hdr"$'\n'"bring the whole scope back reopens every excluded (the whole scope)"
    sel=$(printf '%s\n' "${rows[@]}" | oc_fzf_sel "exports (update)" "$hdr") || return 0
    key=$(oc_sel_key "$sel")
    case "$key" in
        __UPD_DELTA__)  _oc_exports_update_one "$stamp" ;;
        __UPD_NEVER__)  _oc_exports_update_one "$stamp" --sticky never ;;
        __UPD_SCOPE__)  _oc_exports_update_one "$stamp" --mode accumulative ;;
    esac
    return 0
}

# _oc_exports_update_one <stamp> [flag…] -> print the plan UNCOVERED, gate, run.
# The plan is the engine's (`--dry-run`), so what the user reads is literally
# what runs; printing it here (fzf already closed) is the whole point of the
# fila-run model. Declining the gate returns 1 (nothing written, no pause).
_oc_exports_update_one() {
    local stamp="$1"; shift
    run_oced_tool exports update "$stamp" --dry-run "$@"
    confirm_action "Apply this update to $stamp now?" || return 1
    run_oced_tool_spin "Refreshing" exports update "$stamp" --yes "$@"
    return 0
}

# _oc_exports_update_all <run…> -> refresh every run with the same mode, ONE
# global gate (never a confirm per run), each run refreshed in place. It is the
# FIRST row of the update list (LEVEL 2), next to the runs it refreshes.
_oc_exports_update_all() {
    local -a runs=("$@")
    local r stamp
    echo ""
    echo "   This will refresh ALL ${#runs[@]} export run(s) (delta)."
    echo "   A run already up to date is skipped."
    confirm_action "Refresh all ${#runs[@]} runs now?" || return 1
    for r in "${runs[@]}"; do
        stamp="${r##*/}"
        echo ""
        echo "--- $stamp ---"
        run_oced_tool_spin "Refreshing" exports update "$stamp" --yes
    done
    return 0
}

