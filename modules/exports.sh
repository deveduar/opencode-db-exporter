#!/usr/bin/env bash
# exports.sh — oced_exports: list/remove/prune of past export runs (OCED_OUT).
set -uo pipefail

# exports_runs_find -> run dirs under OCED_OUT, newest first.
exports_runs_find() {
    [ -d "$OCED_OUT" ] || return 0
    find "$OCED_OUT" -mindepth 1 -maxdepth 1 -type d | sort -r
}

oced_exports() {
    local cmd="${1:-list}"
    case "$cmd" in
        list)   oced_exports_list ;;
        remove) shift; oced_exports_remove "$@" ;;
        prune)  shift; oced_exports_prune "$@" ;;
        view)   shift; oced_exports_view "$@" ;;
        *) echo "Usage: opencode-db exports [list|remove <stamp> [--yes]|prune <keep> [--yes]|view <stamp> [--files] [--json]]"; return 1 ;;
    esac
}

oced_exports_list() {
    local -a runs metas rows=()
    local run meta profiles roots subs msgs comp size m found p r s stamp human_date
    mapfile -t runs < <(exports_runs_find)
    for run in "${runs[@]}"; do
        stamp="${run##*/}"
        # Format stamp YYYY-MM-DD_HH-MM -> YYYY-MM-DD HH:MM UTC
        human_date="$stamp"
        case "$stamp" in
            [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]_[0-2][0-9]-[0-5][0-9])
                human_date="${stamp:0:10} ${stamp:11:2}:${stamp:14:2} UTC" ;;
        esac
        mapfile -t metas < <(find "$run" -type f \( -name metadata.json -o -name metadatos.json \) 2>/dev/null | sort)
        profiles="" roots=0 subs=0 msgs=0 comp=0 found=0
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
        done
        [ "$found" -eq 1 ] || profiles="?"
        size=$(du -sb "$run" 2>/dev/null | cut -f1)
        size=${size:-0}
        rows+=("$(printf '  %d.  %-16s  %-34s  %s roots (%s subagent) · %s msgs · %s comp · %s' \
            "$((${#rows[@]} + 1))" "$human_date" "$profiles" "$roots" "$subs" "$msgs" "$comp" "$(o_human_size "$size")")")
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
          pair("JSON archive";        (.json // false)),
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
    mapfile -t metas < <(find "$target" -type f \( -name metadata.json -o -name metadatos.json \) 2>/dev/null | sort)
    [ "${#metas[@]}" -gt 0 ] || { echo "No metadata.json found in $target"; return 1; }

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
        printf '  %-11s %s\n' "date:" "$(jq -r '.date // "-"' "$first_meta")"
        printf '  %-11s %s\n' "db:" "$(jq -r '.db // "-"' "$first_meta")"
        printf '  %-11s %s\n' "sha256:" "$(jq -r '.db_sha256 // "-"' "$first_meta")"
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
    # Any product of the run can carry the records, so look for the FIRST one
    # that has them instead of assuming the first file found: in a bundle the
    # products are sorted, and `memory` sorts before `transcript`.
    local rec_meta=""
    for meta in "${metas[@]}"; do
        [ -f "$meta" ] || continue
        if [ "$(jq -r '(.session_records // []) | length' "$meta" 2>/dev/null || echo 0)" != "0" ]; then
            rec_meta="$meta"
            break
        fi
    done
    if [ -n "$rec_meta" ]; then
        echo ""
        echo "== Sessions =="
        # The free-text title goes LAST and is never padded: bash printf counts
        # BYTES in %-Ns, so a padded title column desynchronises the layout as
        # soon as a title carries an accent or a CJK glyph.
        local sid skind stitle screated supdated when
        while IFS=$'\t' read -r sid skind stitle screated supdated; do
            [ -n "$sid" ] || continue
            if [ "$screated" = "$supdated" ]; then
                when="${supdated:0:10}"
            else
                when="${screated:0:16} -> ${supdated:0:16}"
            fi
            printf '  %-22s %-8s  %-25s %s\n' "$sid" "$skind" "$when" "$stitle"
        done < <(oced_export_session_rows "$rec_meta")
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
