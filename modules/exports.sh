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
        *) echo "Usage: opencode-db exports [list|remove <stamp> [--yes]|prune <keep> [--yes]]"; return 1 ;;
    esac
}

oced_exports_list() {
    local -a runs metas rows=()
    local run meta profiles roots subs msgs comp size m found p r s
    mapfile -t runs < <(exports_runs_find)
    for run in "${runs[@]}"; do
        mapfile -t metas < <(find "$run" -name metadatos.json -type f 2>/dev/null | sort)
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
        rows+=("$(printf '  %d.  %-19s  %-34s  %s roots (%s subagent) · %s msgs · %s comp · %s' \
            "$((${#rows[@]} + 1))" "${run##*/}" "$profiles" "$roots" "$subs" "$msgs" "$comp" "$(o_human_size "$size")")")
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
    echo "Prune: removed $n run(s); keeping $keep."
}