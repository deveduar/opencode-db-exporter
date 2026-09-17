#!/usr/bin/env bash
# opencode-db.sh — dispatcher: wires the subcommands to the modules in this folder.
# A standalone tool to inspect, back up and export the local opencode database,
# useful also when opencode itself fails or sessions disappear.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/view.sh"
. "$SCRIPT_DIR/backup.sh"
. "$SCRIPT_DIR/export.sh"
. "$SCRIPT_DIR/exports.sh"
. "$SCRIPT_DIR/deps.sh"

help() {
    cat <<'EOF'
Usage: opencode-db.sh [command]
  menu                 interactive menu (fzf, standalone)
  status               DB exists/size/integrity + counts + last session + backup alignment
  list [--root|--sub|--all] [--filter PATTERN] [--info]
                       list sessions (id | title | date | agent | dir | tokens);
                       --filter: SQL LIKE pattern on id/title, e.g. 'ses_f7%'
  info <id>            full detail of one session (tokens, compactions, counts)
  compactions <id> [show [last|N|all]]
                       list compaction points (date + new queue) of a session;
                       'show' also prints the compacted-context digest stored in
                       the following "mode=compaction" message (last / N / all)
  backup [--no-compress]   consistent snapshot (sqlite .backup) with timestamp
                       + sha256 + stats in backups/manifest.json (gzip by default)
  backups list         list stored backups
  backups verify <file>   check sha256 of a backup against the manifest
  backups prune <N>    keep only the N most recent backups
  export [profile] [flags]   export sessions to Markdown (see below)
  exports list         list past export runs (date/profile/counts/size);
                       a run with several profiles shows them joined with '+'
  exports remove <stamp> [--yes]   delete one export run (all its profiles)
  exports prune <N> [--yes]   keep only the N most recent export runs
  deps [--check]       check/install the dependencies (apt, idempotent, needs sudo)
  help                 this help

export profiles (default: full):
  full         text + reasoning + tool calls + patches + step markers
               (tool output is truncated by default: use --tool-output full for
               the complete output; 'full' is ONE export, not one per option)
  no-calls     text + reasoning (no tools/patches/steps)
  text-only    only 'text' parts of user/assistant messages
  compactions  only the compacted-context digests (mode=compaction messages)
  all          meta-profile: writes the four profiles above into ONE run folder,
               each with maximal capabilities (--tool-output full --patch full
               --mark-compactions --summary-diffs --sub separate). Overrides may
               be appended after 'all'.

export flags:
  --filter PATTERN   SQL LIKE on session id/title, e.g. 'ses_f7%'
  --out DIR          output root (default $OCED_OUT)
  --sub separate|inline|omit   how to place subagent sessions (default separate:
                       folder per root session with subagents/ inside)
  --tool-output full|truncated|omit   tool output verbosity (default truncated)
  --patch full|omit   include patch parts (default full)
  --mark-compactions   include compaction markers in any profile
  --summary-diffs    render user-message summary.diffs (files+additions/deletions)
EOF
}

case "${1:-help}" in
    menu)          . "$SCRIPT_DIR/menu.sh"; run_oc_menu ;;
    status)        oced_status ;;
    list)          shift; oced_list "$@" ;;
    info)          shift; oced_info "$@" ;;
    compactions)   shift; oced_compactions "$@" ;;
    backup)        shift; oced_backup "$@" ;;
    backups)       shift; oced_backups "$@" ;;
    export)        shift; oced_export "$@" ;;
    exports)       shift; oced_exports "$@" ;;
    deps)          shift; oced_deps "$@" ;;
    help|-h)       help ;;
    *) echo "Unrecognized subcommand: $1"; help; exit 1 ;;
esac