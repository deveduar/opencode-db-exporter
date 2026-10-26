#!/usr/bin/env bash
# exports.sh — oced_exports: list/remove/prune of past export runs (OCED_OUT).
set -uo pipefail

# exports_runs_find [asc|desc] -> run dirs under OCED_OUT, `desc` = newest first
# (the default every caller wants; `asc` = oldest first, for the backlog picker).
exports_runs_find() {
    [ -d "$OCED_OUT" ] || return 0
    local cmp="-r"
    [ "${1:-desc}" = "asc" ] && cmp=""
    find "$OCED_OUT" -mindepth 1 -maxdepth 1 -type d \
        ! -name '.*' ! -name '*~*' | sort $cmp
}

# oced_export_rec_meta <metadata.json...> -> the FIRST file that actually carries
# `.session_records` (a bundle sorts its products, and `memory` sorts before
# `transcript`, so assuming the first file found is not safe). Empty when the run
# has none (a legacy run written before `.session_records` existed).
oced_export_rec_meta() {
    local m
    for m in "$@"; do
        [ -f "$m" ] || continue
        if jq -e '(.session_records // []) | length > 0' "$m" >/dev/null 2>&1; then
            printf '%s' "$m"; return 0
        fi
    done
}

# o_export_stale <metadata.json> [--tag] -> uses Python's shared per-session
# freshness rule; bash only formats the reason/tag and return code.
o_export_stale() {
    local meta="$1" tag=0
    [ "${2:-}" = "--tag" ] && tag=1
    [ -f "$meta" ] || { [ "$tag" -eq 1 ] && printf 'unverifiable' || echo "metadata.json missing: $meta"; return 1; }
    local result state reason
    result=$(OPENCODE_DB="$(o_effective_db)" python3 "$SCRIPT_DIR/exportlib/stale.py" --meta "$meta" --summary 2>/dev/null) || return 1
    state=$(printf '%s' "$result" | jq -r '.tag // empty')
    reason=$(printf '%s' "$result" | jq -r '.reason // empty')
    if [ -z "$state" ]; then
        [ "$tag" -eq 1 ] || printf ''
        return 0
    fi
    if [ "$tag" -eq 1 ]; then printf '%s' "$state"; else printf '%s\n' "$reason"; fi
    return 1
}

oced_exports() {
    local cmd="${1:-list}"
    case "$cmd" in
        list)   oced_exports_list ;;
        remove) shift; oced_exports_remove "$@" ;;
        prune)  shift; oced_exports_prune "$@" ;;
        view)   shift; oced_exports_view "$@" ;;
        stale)  shift; oced_exports_stale "$@" ;;
        verify) shift; oced_exports_verify "$@" ;;
        update) shift; oced_exports_update "$@" ;;
        *) echo "Usage: opencode-db exports [list|remove <stamp> [--yes]|prune <keep> [--yes]|view <stamp> [--files] [--json]|stale <stamp> [--tsv|--json]|verify [--tsv]|update <stamp> [--mode delta|accumulative] [--sticky stale|always|never] [--include-excluded ID,ID] [--keep-history] [--dry-run] [--json] [--yes]]"; return 1 ;;
    esac
}

# oced_exports_update <stamp> [flags] -> the run-refresh engine
# (exportlib/update.py is the SSoT: it reads the run's own metadata + the live DB,
# decides the target set, re-renders it into a temp dir and swaps it in; bash only
# pins the config vars, exactly like oced_export_one does for the export CLI).
oced_exports_update() {
    OPENCODE_DB="$(o_effective_db)" \
    OCED_OUT="$OCED_OUT" \
    OCED_BACKUP_DIR="$OCED_BACKUP_DIR" \
    OCED_PRESETS="$OCED_PRESETS" \
        python3 "$SCRIPT_DIR/exportlib/update.py" "$@"
}

# oced_exports_stale <stamp> [--tsv|--json] -> per-session freshness of ONE run.
# `exportlib/stale.py` is the SSoT (the same rule `exports view` renders and
# `exports update` uses to decide what changed); bash only pins the effective DB.
oced_exports_stale() {
    OPENCODE_DB="$(o_effective_db)" \
    OCED_OUT="$OCED_OUT" \
        python3 "$SCRIPT_DIR/exportlib/stale.py" "$@"
}

oced_exports_stale_batch() {
    [ "$#" -gt 0 ] || { printf '{}\n'; return 0; }
    OPENCODE_DB="$(o_effective_db)" \
        python3 "$SCRIPT_DIR/exportlib/stale.py" --summary-batch "$@"
}

oced_exports_list() {
    local -a runs metas rows=()
    local run meta profiles roots subs msgs comp size m found p r s stamp human_date lrmeta lrtag lrmode lrdate lrrefresh lrsess lrpreset lrn_rec lrn_ex lrkept
    mapfile -t runs < <(exports_runs_find)
    local -a freshness_metas=()
    local -a run_metas=()
    local freshness_json
    for run in "${runs[@]}"; do
        stamp="${run##*/}"
        mapfile -t run_metas < <(find "$run" -type f -name metadata.json 2>/dev/null | sort)
        lrmeta=$(oced_export_rec_meta "${run_metas[@]}")
        [ -n "$lrmeta" ] && freshness_metas+=("$lrmeta")
    done
    freshness_json=$(oced_exports_stale_batch "${freshness_metas[@]}" 2>/dev/null) || freshness_json='{}'
    for run in "${runs[@]}"; do
        stamp="${run##*/}"
        # Format stamp YYYY-MM-DD_HH-MM -> YYYY-MM-DD HH:MM UTC
        human_date="$stamp"
        case "$stamp" in
            [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]_[0-2][0-9]-[0-5][0-9])
                human_date="${stamp:0:10} ${stamp:11:2}:${stamp:14:2} UTC" ;;
        esac
        mapfile -t metas < <(find "$run" -type f -name metadata.json 2>/dev/null | sort)
        profiles="" roots=0 subs=0 msgs=0 comp=0 found=0
        lrsess=""
        lrpreset=""
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
            comp=$((comp + $(jq -r '.compactions // 0' "$m")))
            # The preset the run came from (the refresh replays it) rides LAST on
            # the row, so the recipe is visible next to the product it produced.
            [ -z "$lrpreset" ] && lrpreset=$(jq -r '.preset // empty' "$m" 2>/dev/null)
            # The `roots (subagent)` cell alone hides the run's SIZE: 3 roots can be
            # 3 sessions or 22. `K/N kept` is the fact that says whether this run is a
            # subset — the `total` is `session_records` plus the `.excluded` it left
            # out (the difference carries the excluded count). A full run shows just
            # `N`. The short root/sub breakdown (`3 root 19 sub`) always rides along,
            # so a narrowed run never looks full and a full run still shows its shape.
            lrn_rec=$(jq -r '(.session_records // []) | length' "$m" 2>/dev/null || echo 0)
            lrn_ex=$(jq -r '(.excluded // []) | length' "$m" 2>/dev/null || echo 0)
            lrkept=$(( lrn_rec > 0 ? lrn_rec : (r + s) ))
            if [ "${lrn_ex:-0}" -gt 0 ]; then
                lrsess=$(printf '%s/%s kept · %s root %s sub' "$lrkept" "$((lrkept + lrn_ex))" "$r" "$s")
            else
                lrsess=$(printf '%s · %s root %s sub' "$lrkept" "$r" "$s")
            fi
        done
        [ "$found" -eq 1 ] || profiles="?"
        size=$(du -sb "$run" 2>/dev/null | cut -f1)
        size=${size:-0}
        lrmeta=$(oced_export_rec_meta "${metas[@]}")
        lrtag=""
        lrrefresh=""
        if [ -n "$lrmeta" ]; then
            lrtag=$(printf '%s' "$freshness_json" | jq -r --arg path "$lrmeta" '.[$path].tag // empty')
            # A run refreshed in place keeps its stamp (its place in this list),
            # so the ONLY visible proof it moved is the `.update_mode`/`date`
            # pair the engine records. Without it a successful refresh reads as
            # "nothing happened". Rendering the refresh time NEXT TO the stamp
            # makes the two facts distinguishable.
            lrmode=$(jq -r '.update_mode // empty' "$lrmeta" 2>/dev/null)
            lrdate=$(jq -r '.date // empty' "$lrmeta" 2>/dev/null)
            [ -n "$lrmode" ] && [ -n "$lrdate" ] && lrrefresh=" $(printf 'refreshed %s (%s)' "${lrdate%Z}" "$lrmode")"
        elif [ "$found" -eq 1 ]; then
            # Legacy run: metadata exists but records WHICH sessions it holds do
            # not, so freshness is undecidable — the same verdict `verify` gives.
            lrtag="unverifiable"
        fi
        [ -n "$lrtag" ] && lrtag=" ($lrtag)"
        local lrsess_cell="${lrsess:-$roots roots ($subs subagent)}"
        rows+=("$(printf '  %d.  %-16s  %-34s  %-38s  %s msgs · %s comp · %s  %s%s%s' \
            "$((${#rows[@]} + 1))" "$human_date" "$profiles" "$lrsess_cell" "$msgs" "$comp" "$(o_human_size "$size")" "$lrpreset" "$lrtag" "$lrrefresh")")
    done
    echo "== Exports (${#runs[@]}) =="
    if [ "${#rows[@]}" -eq 0 ]; then
        echo "   (no export runs yet; run: opencode-db export)"
    else
        for row in "${rows[@]}"; do echo "$row"; done
        echo ""
        echo "  remove <stamp>  ·  prune <N>"
    fi
}

oced_exports_remove() {
    local stamp="${1:-}" yes=0 target
    [ -n "$stamp" ] || { echo "Usage: opencode-db exports remove <stamp> [--yes]"; return 1; }
    [ "${2:-}" = "--yes" ] && yes=1
    target="$OCED_OUT/$stamp"
    [ -d "$target" ] || { echo "Not found: $target"; echo "Try: opencode-db exports list"; return 1; }
    if [ "$yes" -eq 0 ]; then
        local ans
        printf 'Remove export run %s? This deletes the generated files. [y/N] ' "$stamp"
        read -r ans || return 1
        [[ "$ans" =~ ^[yYsS]$ ]] || { echo "   cancelled."; return 0; }
    fi
    rm -rf -- "$target"
    o_log "exports remove stamp=$stamp"
    echo "Removed: $target"
}

oced_exports_prune() {
    local keep="${1:-}" yes=0
    [ "${2:-}" = "--yes" ] && yes=1
    case "$keep" in
        ''|*[!0-9]*) echo "Usage: opencode-db exports prune <N>  (N = how many to keep)"; return 1 ;;
    esac
    [ "$keep" -ge 1 ] || { echo "N must be >= 1"; return 1; }
    local -a runs
    local total n i target
    mapfile -t runs < <(exports_runs_find)
    total=${#runs[@]}
    if [ "$total" -le "$keep" ]; then
        echo "Nothing to prune (have $total, keeping $keep)."
        return 0
    fi
    n=0
    for ((i = keep; i < total; i++)); do
        target="${runs[$i]}"
        rm -rf -- "$target"
        n=$((n + 1))
    done
    o_log "exports prune keep=$keep removed=$n"
    echo "Prune: removed $n run(s); keeping $keep."
}

# oced_exports_verify [--tsv] -> audit EVERY run's freshness vs the effective DB
# (one `o_export_stale` per run, not only the newest), the sibling of
# `shrinks verify`. A stale/missing run is not broken — it is history — but the
# tool must be able to say which runs no longer describe the live DB, and
# `exports update` is the fix. `--tsv` emits `stamp<TAB>tag<TAB>reason` rows.
oced_exports_verify() {
    local tsv=0
    for a in "$@"; do [ "$a" = "--tsv" ] && tsv=1; done
    local -a runs
    mapfile -t runs < <(exports_runs_find)
    local n=${#runs[@]}
    local -a flagged=()   # each entry: stamp<TAB>tag<TAB>reason
    local run stamp mtag mreason rmeta summary
    local -a mlist freshness_metas=()
    local -A run_meta=()
    for run in "${runs[@]}"; do
        stamp="${run##*/}"
        mapfile -t mlist < <(find "$run" -type f -name metadata.json 2>/dev/null | sort)
        rmeta=$(oced_export_rec_meta "${mlist[@]}")
        run_meta["$stamp"]="$rmeta"
        [ -n "$rmeta" ] && freshness_metas+=("$rmeta")
    done
    local freshness_json
    freshness_json=$(oced_exports_stale_batch "${freshness_metas[@]}" 2>/dev/null) || freshness_json='{}'
    for run in "${runs[@]}"; do
        stamp="${run##*/}"
        rmeta="${run_meta[$stamp]:-}"
        if [ -z "$rmeta" ]; then
            flagged+=("$stamp"$'\t'"unverifiable"$'\t'"no metadata.json with session_records")
            continue
        fi
        summary=$(printf '%s' "$freshness_json" | jq -c --arg path "$rmeta" '.[$path] // {}')
        if [ "$(printf '%s' "$summary" | jq -r '.clean // false')" = true ]; then
            continue
        fi
        mtag=$(printf '%s' "$summary" | jq -r '.tag // "unverifiable"')
        mreason=$(printf '%s' "$summary" | jq -r '.reason // "cannot verify freshness"')
        flagged+=("$stamp"$'\t'"$mtag"$'\t'"$mreason")
    done
    if [ "$tsv" -eq 1 ]; then
        local f
        for f in "${flagged[@]}"; do
            printf '%s\t%s\t%s\n' "${f%%$'\t'*}" "$(printf '%s' "$f" | cut -f2)" "$(printf '%s' "$f" | cut -f3)"
        done
        return 0
    fi
    echo "== Export runs verification =="
    echo ""
    if [ "$n" -eq 0 ]; then
        echo "   (no export runs yet)"
        return 0
    fi
    if [ ${#flagged[@]} -eq 0 ]; then
        echo "All clean ($n run(s) match the live DB)."
        return 0
    fi
    echo "⚠️  Runs that no longer match the live DB (${#flagged[@]} of $n):"
    local f
    for f in "${flagged[@]}"; do
        printf '  %-18s [%s]  %s\n' "${f%%$'\t'*}" "$(printf '%s' "$f" | cut -f2)" "$(printf '%s' "$f" | cut -f3)"
    done
    echo ""
    echo "   Refresh one in place with: opencode-db exports update <stamp>"
    echo "   (or re-export it; these runs are history, not errors)."
}
# The human phrase for a stored run's selection. It asks PYTHON, because the
# rules live in util.selection_phrase() (the inverse of selection_meta()) and
# bash must not grow a second copy: reading `.filter`/`.sessions_selected` here
# reported a `--last 3`/`--since` run as "sessions: all", which is exactly the
# lie this screen must not tell.
oced_export_selection_phrase() {   # $1 = metadata.json
    local meta="${1:-}" phrase=""
    if [ -f "$meta" ]; then
        phrase=$(python3 "$SCRIPT_DIR/exportlib/plan.py" selection-meta "$meta" 2>/dev/null) || phrase=""
    fi
    printf '%s' "${phrase:--}"
}

# oced_export_scope_phrase <metadata.json> -> the human phrase of `.scope`, the
# WIDER set the run was drawn from (identical to `.selection` for a plain run,
# different exactly when the run was narrowed). Same `selection_phrase` source,
# so `scope` and `selection` can never be described by two different rules.
oced_export_scope_phrase() {   # $1 = metadata.json
    local meta="${1:-}" phrase=""
    if [ -f "$meta" ]; then
        phrase=$(jq -c '{selection: .scope}' "$meta" 2>/dev/null \
                 | python3 "$SCRIPT_DIR/exportlib/plan.py" selection-phrase 2>/dev/null) || phrase=""
    fi
    printf '%s' "${phrase:--}"
}

# One product's metadata as `label<TAB>value` pairs. The ORDER is fixed here (so
# the screen never reorders between runs) and a field is only emitted when the
# key actually exists, because a missing key used to be rendered as a value:
# `Cap: 0 (unlimited)` and `Touched files: false` were printed for every
# transcript even though `cap`/`touched_files` are memory-only keys.
# Alignment is done by the caller (jq 1.7 has no ljust).
oced_export_meta_pairs() {   # $1 = metadata.json
    jq -r '
        def pair($l; $v): ($l + "\t" + ($v | tostring));
        [
          pair("Product";             (.profile // "-")),
          pair("Preset";              (.preset // "-")),
          pair("Sub";                 (.sub // "-")),
          (if ((.role // "all") != "all") then pair("Role"; .role) else empty end),
          pair("Sanitize";            (.sanitize // false)),
          pair("Reasoning";           (.reasoning // false)),
          pair("Summary diffs";       (.summary_diffs // false)),
          pair("Tokens backfilled";   (.tokens_backfilled // 0)),
          pair("No subagents";        (.no_subagents // false)),
          pair("No orphan subagents"; (.no_orphan_subagents // false)),
          (if (.subagents_hidden // 0) > 0
             then pair("Subagents hidden"; .subagents_hidden) else empty end),
          (if has("cap") then
             pair("Cap"; ((.cap | tostring) + (if .cap == 0 then " (unlimited)" else "" end)))
             else empty end),
          (if has("touched_files") then pair("Touched files"; .touched_files) else empty end),
          pair("Files"; ((.files // []) | length))
        ] | .[]
    ' "$1"
}

# The sessions a run really contains. Printed ONCE per run (not once per
# product): a bundle shares the selection, so the same list would otherwise be
# repeated verbatim for every product. Falls back to `.sessions_selected` for a
# legacy run written before `.session_records` existed.
oced_export_session_rows() {   # $1 = metadata.json
    if jq -e '(.session_records // []) | length > 0' "$1" >/dev/null 2>&1; then
        jq -r '.session_records[]
               | [ (.id // "-"), (.kind // "-"),
                   ((.title // "") | if . == "" then "(no title)" else .[0:60] end),
                   (.created // "-"), (.updated // "-") ]
               | @tsv' "$1"
        return 0
    fi
    local ids
    ids=$(jq -r '(.sessions_selected // []) | if length == 0 then ["ALL (not recorded)"] else .[] end | @tsv' "$1")
    [ -n "$ids" ] || return 0
    local one
    while IFS= read -r one; do
        [ -n "$one" ] && printf '%s\t%s\t%s\t%s\t%s\n' "$one" "-" "(legacy record)" "-" "-"
    done <<< "$ids"
}

oced_exports_view() {
    local stamp="${1:-}" show_files=0 json_mode=0
    [ -n "$stamp" ] || { echo "Usage: opencode-db exports view <stamp> [--files] [--json]"; return 1; }
    for arg in "${@:2}"; do
        case "$arg" in
            --files) show_files=1 ;;
            --json)  json_mode=1 ;;
            *) echo "Unknown option: $arg"; return 1 ;;
        esac
    done
    local target="$OCED_OUT/$stamp"
    [ -d "$target" ] || { echo "Not found: $target"; echo "Try: opencode-db exports list"; return 1; }

    local -a metas
    mapfile -t metas < <(find "$target" -type f -name metadata.json 2>/dev/null | sort)
    [ "${#metas[@]}" -gt 0 ] || { echo "No metadata.json found in $target"; return 1; }
    # The metadata file that carries `.session_records` (see oced_export_rec_meta).
    local rec_meta
    rec_meta=$(oced_export_rec_meta "${metas[@]}")

    if [ "$json_mode" -eq 1 ]; then
        printf '['
        local first=1
        for meta in "${metas[@]}"; do
            [ -f "$meta" ] || continue
            [ "$first" -eq 1 ] || printf ','
            cat "$meta"
            first=0
        done
        printf ']\n'
        return 0
    fi

    echo "== Export run: $stamp =="
    echo ""
    # roots/subagents are a MAX (a bundle copies the same sessions per product)
    # but messages/compactions/digests/files are a SUM.
    local tot_roots=0 tot_subs=0 tot_msgs=0 tot_comp=0 tot_dig=0 tot_files=0
    local first_meta="" prod r s m c d f
    for meta in "${metas[@]}"; do
        [ -f "$meta" ] || continue
        [ -n "$first_meta" ] || first_meta="$meta"
        prod=$(jq -r '.profile // "?"' "$meta")
        r=$(jq -r '.sessions.roots // 0' "$meta")
        s=$(jq -r '.sessions.subagents // 0' "$meta")
        m=$(jq -r '.messages // 0' "$meta")
        c=$(jq -r '.compactions // 0' "$meta")
        d=$(jq -r '.digests // 0' "$meta")
        f=$(jq -r '.files // [] | length' "$meta")
        [ "$r" -gt "$tot_roots" ] && tot_roots="$r"
        [ "$s" -gt "$tot_subs" ] && tot_subs="$s"
        tot_msgs=$((tot_msgs + m))
        tot_comp=$((tot_comp + c))
        tot_dig=$((tot_dig + d))
        tot_files=$((tot_files + f))
        printf '  %-12s %s roots (%s subagent) · %s msgs · %s comp · %s digests · %s files\n' \
            "$prod" "$r" "$s" "$m" "$c" "$d" "$f"
    done
    echo ""
    local size
    size=$(du -sb "$target" 2>/dev/null | cut -f1); size=${size:-0}
    printf '  %-11s %s roots (%s subagent) · %s msgs · %s comp · %s digests · %s\n' \
        "totals:" "$tot_roots" "$tot_subs" "$tot_msgs" "$tot_comp" "$tot_dig" "$(o_human_size "$size")"
    if [ -n "$first_meta" ]; then
        # The selection is a RUN-level fact (shared by a bundle), so it is
        # printed once here and not repeated in every product block.
        printf '  %-11s %s\n' "selection:" "$(oced_export_selection_phrase "$first_meta")"
        # The scope is the WIDER set the run was drawn from; it differs from
        # `selection` exactly when the run was narrowed, so the gap between the
        # two is the whole point of printing it. Legacy runs have none (`-`).
        local scope_phrase
        scope_phrase=$(oced_export_scope_phrase "$first_meta")
        [ "$scope_phrase" != "-" ] && printf '  %-11s %s\n' "scope:" "$scope_phrase"
        printf '  %-11s %s\n' "date:" "$(jq -r '.date // "-"' "$first_meta")"
        # A refresh keeps the stamp, so name it explicitly: the `date` above IS
        # the refresh time, and without this line the reader has no way to tell
        # a refreshed run from one never touched. Absent on a fresh run.
        local upmode
        upmode=$(jq -r '.update_mode // empty' "$first_meta" 2>/dev/null)
        [ -n "$upmode" ] && printf '  %-11s %s mode (refreshed in place)\n' "updated:" "$upmode"
        printf '  %-11s %s\n' "db:" "$(jq -r '.db // "-"' "$first_meta")"
        printf '  %-11s %s\n' "sha256:" "$(jq -r '.db_sha256 // "-"' "$first_meta")"
        if [ -n "$rec_meta" ]; then
            local freason
            if freason=$(o_export_stale "$rec_meta"); then
                printf '  %-11s %s\n' "freshness:" "fresh (the live DB has no newer content for these sessions)"
            else
                printf '  %-11s %s\n' "freshness:" "STALE — $freason"
            fi
        else
            printf '  %-11s %s\n' "freshness:" "unverifiable (no session_records recorded)"
        fi
    fi

    echo ""
    echo "== Details per product =="
    local n=0 k v
    for meta in "${metas[@]}"; do
        [ -f "$meta" ] || continue
        [ "$n" -eq 0 ] || echo ""
        n=$((n + 1))
        while IFS=$'\t' read -r k v; do
            [ -n "$k" ] || continue
            printf '  %-21s %s\n' "$k:" "$v"
        done < <(oced_export_meta_pairs "$meta")
    done

    # WHICH sessions the run contains (identity only, straight from metadata).
    # `rec_meta` (the product that carries `.session_records`) was resolved once
    # above.
    if [ -n "$rec_meta" ]; then
        echo ""
        echo "== Sessions =="
        # The per-session staleness marks resolved once from the SAME rule the
        # run-level `freshness:` line uses, so the dedicated section can never
        # contradict the verdict above.
        local -A ses_state=()
        local -A ses_live_updated=()
        local -a stale_ids=() missing_ids=() unverifiable_ids=()
        local _mk _st _mk_kind _mk_upd _live_upd _mk_title
        # `exportlib/stale.py` is the ONE freshness rule (shared with
        # `exports stale` and `exports update`); its order is already stale first,
        # then missing, each by updated desc, so the arrays keep it verbatim.
        while IFS=$'\t' read -r _mk _st _mk_kind _mk_upd _live_upd _mk_title; do
            [ -n "$_mk" ] || continue
            ses_state["$_mk"]="$_st"
            ses_live_updated["$_mk"]="$_live_upd"
            case "$_st" in
                stale)   stale_ids+=("$_mk") ;;
                missing) missing_ids+=("$_mk") ;;
                unverifiable) unverifiable_ids+=("$_mk") ;;
            esac
        done < <(oced_exports_stale --meta "$rec_meta" --tsv 2>/dev/null)
        local -A ses_info=()
        local sid skind stitle screated supdated when
        # Collect all session rows first so we can order by last use (updated desc),
        # matching the menu's updated-desc order. Stale/missing are NOT pulled to
        # the top here; they are listed explicitly in == Changed since export ==.
        local -a all_rows=()
        while IFS=$'\t' read -r sid skind stitle screated supdated; do
            [ -n "$sid" ] || continue
            if [ "$screated" = "$supdated" ]; then
                when="${supdated:0:10}"
            else
                when="${screated:0:16} -> ${supdated:0:16}"
            fi
            ses_info["$sid"]="$skind"$'\t'"$when"$'\t'"$stitle"$'\t'"${ses_state[$sid]:-}"
            # Sort key = updated desc (ISO8601 sorts correctly lexicographically)
            all_rows+=("$supdated"$'\t'"$sid"$'\t'"$skind"$'\t'"$when"$'\t'"$stitle")
        done < <(oced_export_session_rows "$rec_meta")
        local pr _updsid updsid upskind upwhen upstitle
        mapfile -t all_rows < <(printf '%s\n' "${all_rows[@]}" | sort -r)
        for pr in "${all_rows[@]}"; do
            [ -n "$pr" ] || continue
            IFS=$'\t' read -r _updsid updsid upskind upwhen upstitle <<< "$pr"
            printf '  %-22s %-8s  %-25s %s\n' "$updsid" "$upskind" "$upwhen" "$upstitle"
        done
        # Summary counts (the arrays are already in display order)
        local n_stale=${#stale_ids[@]} n_missing=${#missing_ids[@]} n_unverifiable=${#unverifiable_ids[@]}
        if [ "$n_stale" -gt 0 ] || [ "$n_missing" -gt 0 ] || [ "$n_unverifiable" -gt 0 ]; then
            local parts=""
            [ "$n_stale" -gt 0 ] && parts="$n_stale stale"
            [ "$n_missing" -gt 0 ] && parts="${parts:+$parts, }$n_missing missing"
            [ "$n_unverifiable" -gt 0 ] && parts="${parts:+$parts, }$n_unverifiable unverifiable"
            printf '\n  %s session(s) changed since export: %s\n' \
                "$((n_stale + n_missing + n_unverifiable))" "$parts"
            echo ""
            echo "== Changed since export =="
            local asid askind aswhen astitle astat
            # print stale first, then missing, then unverifiable
            local al
            for al in "${stale_ids[@]}"; do
                IFS=$'\t' read -r askind aswhen astitle astat <<< "${ses_info[$al]}"
                printf '  %-22s %-8s  %-25s  stale  live %s  %s\n' "$al" "$askind" "$aswhen" "${ses_live_updated[$al]:--}" "$astitle"
            done
            for al in "${missing_ids[@]}"; do
                IFS=$'\t' read -r askind aswhen astitle astat <<< "${ses_info[$al]}"
                printf '  %-22s %-8s  %-25s  missing  live -  %s\n' "$al" "$askind" "$aswhen" "$astitle"
            done
            for al in "${unverifiable_ids[@]}"; do
                IFS=$'\t' read -r askind aswhen astitle astat <<< "${ses_info[$al]}"
                printf '  %-22s %-8s  %-25s  unverifiable  live %s  %s\n' "$al" "$askind" "$aswhen" "${ses_live_updated[$al]:--}" "$astitle"
            done
        fi
    fi

    # WHICH sessions the run LEFT OUT (`.excluded`: in scope but deliberately not
    # exported). Without this block a narrowed run is indistinguishable from a
    # full one. Capped like `shrinks view`: past the cap the title alone would
    # push the screen off, and the count is what the reader needs.
    if [ -n "$rec_meta" ]; then
        local n_ex
        n_ex=$(jq -r '(.excluded // []) | length' "$rec_meta" 2>/dev/null || echo 0)
        if [ "${n_ex:-0}" -gt 0 ]; then
            echo ""
            echo "== Excluded ($n_ex kept out of scope) =="
            local esid etitle en=0
            local EX_CAP=8
            while IFS=$'\t' read -r esid etitle; do
                [ -n "$esid" ] || continue
                en=$((en + 1))
                [ "$en" -le "$EX_CAP" ] || continue
                printf '  %-22s  %s\n' "$esid" "$etitle"
            done < <(jq -r '.excluded[] | [ (.id // "-"),
                        ((.title // "") | if . == "" then "(no title)" else .[0:60] end) ] | @tsv' "$rec_meta")
            [ "$en" -gt "$EX_CAP" ] && printf '  … %s more\n' "$((en - EX_CAP))"
        fi
    fi

    if [ "$show_files" -eq 1 ]; then
        echo ""
        echo "== Files =="
        local rel sz
        while IFS= read -r f; do
            rel="${f#$target/}"
            sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
            printf '  %-60s %s\n' "$rel" "$(o_human_size "$sz")"
        done < <(find "$target" -type f \( -name '*.md' -o -name '*.json' -o -name '*.jsonl' \) | sort)
    fi
}
