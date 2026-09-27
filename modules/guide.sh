#!/usr/bin/env bash
# guide.sh — 'opencode-db guide': interactive linear workflow for safe export+shrink.
# Steps: export (preset picker) → optional shrink (profile picker) → optional swap.
# Never writes the live DB; shrink only produces a copy. Uses fzf for navigation.
set -uo pipefail

# Source menu.sh for fzf picker helpers (oc_fzf_sel, menu_require_fzf, menu_pause, etc.)
. "$SCRIPT_DIR/menu.sh"

OC_GUIDE_DISPATCHER="${OCED_DISPATCHER:-$SCRIPT_DIR/opencode-db.sh}"

# oc_guide_run <cmd...> -> runs the dispatcher, returns 0 always (menu survives).
oc_guide_run() {
    bash "$OC_GUIDE_DISPATCHER" "$@" || true
    return 0
}

# guide_step_export -> runs export picker (preset → session/ALL → confirm → run)
guide_step_export() {
    local preset session selection_out rc

    echo ""
    echo "=== Step 1: Export sessions ==="
    echo "Choose sessions or ALL, then pick a named plan (preset)."
    echo ""

    # Run the export picker which returns the preset key selected
    if ! oc_export_picker; then
        echo "   Cancelled."
        return 1
    fi

    # oc_export_picker runs the export via oc_preset_run which handles session selection
    # and runs the actual export. We just need to capture the output to show where it went.
    # The export runs are created under OCED_OUT/<stamp>/
    # Find the latest export run to show the user
    local latest_stamp
    latest_stamp=$(find "$OCED_OUT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2)
    if [ -n "$latest_stamp" ]; then
        echo ""
        echo "   [OK] Export saved to: $OCED_OUT/$latest_stamp/"
        ls -1 "$OCED_OUT/$latest_stamp/" 2>/dev/null | sed 's/^/        /'
    else
        echo ""
        echo "   [OK] Export completed (check $OCED_OUT for the run folder)"
    fi

    menu_pause "Export" || return 0
    return 0
}

# guide_step_shrink -> runs shrink picker (profile → run) with warning
guide_step_shrink() {
    echo ""
    echo "=== Step 2: Shrink (optional) ==="
    echo "Creates a pruned + VACUUMed copy to reclaim space."
    echo ""

    if ! oc_guide_ask "Create a shrink copy now?"; then
        echo "   Skipped shrink step."
        return 0
    fi

    echo ""
    echo "⚠️  IMPORTANT: After shrink, do NOT open opencode until you decide on swap."
    echo "   If you use opencode now, the live DB will diverge from the shrink copy."
    echo "   The pre-shrink safety copy (created at swap) is your ONLY rollback."
    echo ""

    # Run shrink picker (create new or use existing)
    if ! oc_pick_shrink; then
        echo "   Cancelled."
        return 1
    fi

    # Check if a shrink was actually created (oc_pick_shrink runs it)
    # Find latest shrink run
    local latest_shrink
    latest_shrink=$(find "$OCED_BACKUP_DIR/shrink" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2)
    if [ -n "$latest_shrink" ]; then
        echo ""
        echo "   [OK] Shrink copy ready: $OCED_BACKUP_DIR/shrink/$latest_shrink/"
        echo "        Run 'opencode-db shrinks view $latest_shrink' for details."
    fi

    menu_pause "Shrink" || return 0
    return 0
}

# guide_step_swap -> runs swap with explicit "confirm" confirmation
guide_step_swap() {
    echo ""
    echo "=== Step 3: Swap (optional, DESTRUCTIVE) ==="
    echo "Replaces the LIVE opencode DB with the shrink copy."
    echo ""

    # Check if there's a shrink copy available
    local latest_shrink
    latest_shrink=$(find "$OCED_BACKUP_DIR/shrink" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2)
    if [ -z "$latest_shrink" ]; then
        echo "   No shrink copy found. Run shrink step first."
        menu_pause "Swap" || return 0
        return 1
    fi

    # Check if live DB has changed since shrink
    local stale
    stale=$(o_shrink_stale "$OCED_BACKUP_DIR/shrink/$latest_shrink/shrink.json")
    if [ -n "$stale" ]; then
        echo "⚠️  WARNING: $stale"
        echo "   Swapping NOW would LOSE recent sessions (or freshness is unknown)."
        echo "   You should re-run shrink (Step 2) before swapping."
        echo ""
        if ! oc_guide_ask "Continue anyway? (NOT RECOMMENDED)"; then
            echo "   Cancelled."
            return 1
        fi
    fi

    echo ""
    echo "⚠️  DESTRUCTIVE ACTION: This REPLACES the live database at:"
    echo "     $OPENCODE_DB"
    echo ""
    echo "   Prerequisites:"
    echo "   - opencode MUST be completely closed (TUI and server)"
    echo "   - The shrink copy was created in Step 2"
    echo "   - A safety copy (pre-shrink) will be created in $OCED_BACKUP_DIR/pre-shrink/"
    echo "   - If anything fails, the swap rolls back automatically"
    echo ""
    echo "   Type 'confirm' (exact, lowercase) to proceed:"
    if ! oc_confirm_typed "confirm"; then
        echo "   Aborted. Input must be exactly 'confirm'."
        return 1
    fi

    echo ""
    echo "   Swapping... (this may take a moment)"
    if oc_guide_run shrink --swap --yes; then
        echo ""
        echo "   [OK] Swap completed successfully."
        echo "   The live DB has been replaced with the shrunk copy."
        echo "   Safety copy is in: $OCED_BACKUP_DIR/pre-shrink/"
        echo "   Keep the safety copy until opencode opens without issues."
    else
        echo ""
        echo "   [FAIL] Swap failed. The live DB is unchanged."
    fi

    menu_pause "Swap" || return 0
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
  Interactive linear workflow for the safe export+shrink path:
  1) Export (pick preset → session/ALL → run)
  2) Shrink (optional: pick profile → create pruned copy)
  3) Swap (optional: type 'confirm' to replace live DB)
  --list prints the plan and exits (no prompts, no fzf).
EOF
            return 0 ;;
    esac

    echo "opencode-db guide — safe workflow: export → shrink → swap"
    echo "This tool never modifies the live DB directly."
    echo "  Export reads live DB (mode=ro)."
    echo "  Shrink creates a pruned copy (read-only source)."
    echo "  Swap replaces live DB (with safety copy + rollback)."
    echo ""

    if [ "$list_only" -eq 1 ]; then
        echo "Plan:"
        echo "  1. Export sessions (named plan picker)"
        echo "  2. Shrink (optional, profile picker)"
        echo "  3. Swap (optional, destructive, type 'confirm')"
        echo "     Swap the copy manually (or use shrink --swap for automated swap)."
        return 0
    fi
    if [ ! -t 0 ]; then
        echo "(non-interactive input: showing the plan only)"
        return 0
    fi

    menu_require_fzf

    if ! oc_guide_ask "Start the guided workflow?"; then
        echo "   Cancelled."
        return 0
    fi

    # Step 1: Export (required)
    if ! guide_step_export; then
        echo "Workflow stopped."
        return 0
    fi

    # Step 2: Shrink (optional)
    if ! guide_step_shrink; then
        echo "Workflow stopped."
        return 0
    fi

    # Step 3: Swap (optional)
    if ! guide_step_swap; then
        echo "Workflow stopped."
        return 0
    fi

    echo ""
    echo "=== Workflow complete ==="
    echo "Review the results above."
}