#!/usr/bin/env bash
# guide.sh — 'opencode-db guide': step-by-step console wizard for the safe workflow.
# It only runs read-only commands and (optionally) backup/export/shrink; it NEVER
# writes to the live DB and never swaps files itself.
set -uo pipefail

OC_GUIDE_DISPATCHER="${OCED_DISPATCHER:-$SCRIPT_DIR/opencode-db.sh}"

# oc_guide_run <cmd...> -> runs the dispatcher without breaking the wizard.
oc_guide_run() {
    bash "$OC_GUIDE_DISPATCHER" "$@" || true
    return 0
}

# oc_guide_ask <prompt> -> true on y/Y.
oc_guide_ask() {
    local ans
    printf '%s [y/N] ' "$1"
    IFS= read -r ans || return 1
    [[ "$ans" =~ ^[yY]$ ]]
}

# oced_guide [--list]
#   --list : print the plan and exit (non-interactive).
oced_guide() {
    local list_only=0
    case "${1:-}" in
        --list|-l) list_only=1 ;;
        -h|--help)
            cat <<'EOF'
Usage: opencode-db guide [--list]
  Step-by-step console wizard for the safe workflow:
  inspect -> backup -> export memory -> shrink -> swap manually.
  --list prints the plan and exits (no prompts).
EOF
            return 0 ;;
    esac

    # title <TAB> explanation <TAB> dispatcher command (or "(manual)").
    local -a steps
    mapfile -t steps <<'STEPS'
Inspect the DB	Size, tables, counts and whether the last backup is aligned; 'version' probes the schema.	status
Create a backup	Consistent snapshot (.backup) + sha256 + manifest: your safety net before anything else.	backup
Export a memory corpus	One JSON per root session with the distilled facts, so knowledge survives a shrink.	export memory
Shrink (build a copy)	Prunes old sessions + VACUUM into a smaller COPY; the live DB is never modified.	shrink lean
Swap the copy manually	Stop opencode, move the live DB aside, put the shrunk copy in place, keep the old one.	(manual)
STEPS

    echo "opencode-db guide — reclaim space without losing knowledge"
    echo "This tool never modifies the live DB; shrink only writes a copy."
    echo ""
    local line title expl cmd n=0
    for line in "${steps[@]}"; do
        n=$((n+1))
        IFS=$'\t' read -r title expl cmd <<<"$line"
        printf '  %d. %s\n     %s\n' "$n" "$title" "$expl"
    done
    echo ""

    if [ "$list_only" -eq 1 ]; then
        return 0
    fi
    if [ ! -t 0 ]; then
        echo "(non-interactive input: showing the plan only)"
        return 0
    fi

    printf 'Walk through the steps now? [y/N] '
    local go
    IFS= read -r go || return 0
    [[ "$go" =~ ^[yY]$ ]] || { echo "   cancelled."; return 0; }

    n=0
    for line in "${steps[@]}"; do
        n=$((n+1))
        IFS=$'\t' read -r title expl cmd <<<"$line"
        echo ""
        echo "── Step $n: $title ──"
        if [ "$cmd" = "(manual)" ]; then
            cat <<'EOF'
   Manual swap (this tool never does it):
     1. Quit opencode completely (replacing the DB behind a running opencode
        loses the WAL tail: the swap must happen with opencode stopped).
     2. Move the live DB aside:  mv opencode.db opencode.db.old
     3. Put the shrunk copy in place:  cp <...>/opencode.shrunk.db opencode.db
     4. Start opencode and verify. Keep opencode.db.old until you are sure.
   Safer: redo the shrink step with --swap (guard + safety copy + rollback).
EOF
            continue
        fi
        if oc_guide_ask "Run 'opencode-db $cmd'?"; then
            # shellcheck disable=SC2086  # cmd is a fixed, space-split command
            oc_guide_run $cmd
        else
            echo "   skipped."
        fi
    done
    echo ""
    echo "Done. Review the results above."
}
