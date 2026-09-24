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
        *) echo "Usage: opencode-db exports [list|remove <stamp> [--yes]|prune <keep> [--yes]|view <stamp> [--files]]"; return 1 ;;
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

oced_exports_view() {
    local stamp="${1:-}" show_files=0
    [ -n "$stamp" ] || { echo "Usage: opencode-db exports view <stamp> [--files]"; return 1; }
    [ "${2:-}" = "--files" ] && show_files=1
    local target="$OCED_OUT/$stamp"
    [ -d "$target" ] || { echo "Not found: $target"; echo "Try: opencode-db exports list"; return 1; }

    # Summary covers every product in the run (the old head -1 hid all but the
    # first alphabetically, e.g. the memory/RAG corpus of a multi-product run).
    local -a metas
    local meta prod r s m c first_meta="" profiles=""
    local tot_roots=0 tot_subs=0 tot_msgs=0 tot_comp=0
    mapfile -t metas < <(find "$target" -type f \( -name metadata.json -o -name metadatos.json \) 2>/dev/null | sort)
    [ "${#metas[@]}" -gt 0 ] || { echo "No metadata.json found in $target"; return 1; }

    echo "== Export run: $stamp =="
    for meta in "${metas[@]}"; do
        [ -f "$meta" ] || continue
        [ -n "$first_meta" ] || first_meta="$meta"
        prod=$(jq -r '.profile // "?"' "$meta")
        profiles="${profiles:+$profiles+}$prod"
        r=$(jq -r '.sessions.roots // 0' "$meta")
        s=$(jq -r '.sessions.subagents // 0' "$meta")
        m=$(jq -r '.messages // 0' "$meta")
        c=$(jq -r '.compactions // 0' "$meta")
        [ "$r" -gt "$tot_roots" ] && tot_roots="$r"
        [ "$s" -gt "$tot_subs" ] && tot_subs="$s"
        tot_msgs=$((tot_msgs + m))
        tot_comp=$((tot_comp + c))
        printf '  %-14s %s roots (%s subagent) · %s msgs · %s comp\n' \
            "$prod" "$r" "$s" "$m" "$c"
        if [ -f "$(dirname "$meta")/corpus.jsonl" ]; then
            local cl nlines
            cl="$(dirname "$meta")/corpus.jsonl"
            nlines=$(wc -l < "$cl" | tr -d ' ')
            printf '  %-14s %s\n' "" "corpus: $nlines entries · $(o_human_size "$(stat -c %s "$cl")")"
        fi
    done
    echo ""
    local size
    size=$(du -sb "$target" 2>/dev/null | cut -f1); size=${size:-0}
    echo "  totals: $profiles · $tot_roots roots ($tot_subs subagent) · $tot_msgs msgs · $tot_comp comp · $(o_human_size "$size")"
    if [ -n "$first_meta" ]; then
        echo "  date:   $(jq -r '.date // "-"' "$first_meta")"
        echo "  db:     $(jq -r '.db // "-"' "$first_meta")"
        echo "  sha256: $(jq -r '.db_sha256 // "-"' "$first_meta")"
    fi

    echo ""
    echo "== Indexes =="
    local index_file
    for index_file in "$target"/*/index.md; do
        [ -f "$index_file" ] || continue
        local rel_path="${index_file#$target/}"
        rel_path="${rel_path%/index.md}"
        echo "  $rel_path"
        sed -n '/^## Sessions$/,/^---$/p' "$index_file" | head -20 | grep -E '^[0-9]+\.|^\s+- ' | sed 's/^/    /'
    done

    if [ "$show_files" -eq 1 ]; then
        echo ""
        echo "== Files =="
        find "$target" -type f \( -name '*.md' -o -name '*.json' -o -name '*.jsonl' \) | while IFS= read -r f; do
            local rel="${f#$target/}"
            local sz
            sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
            printf '  %-60s %s\n' "$rel" "$(o_human_size "$sz")"
        done
    fi
}