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

help() {
    cat <<'EOF'
Usage: opencode-db.sh [command]
  status               DB exists/size/integrity + counts + last session + backup alignment
  list [--root|--sub|--all] [--filter PATTERN] [--info]
                       list sessions (id | title | date | agent | dir | tokens);
                       --filter: SQL LIKE pattern on id/title, e.g. 'ses_f7%'
  info <id>            full detail of one session (tokens, compactions, counts)
  compactaciones <id>  list compaction points (position + date) of a session
  backup [--no-compress]   consistent snapshot (sqlite .backup) with timestamp
                       + sha256 + stats in backups/manifest.json (gzip by default)
  backups list         list stored backups
  backups verify <file>   check sha256 of a backup against the manifest
  backups prune <N>    keep only the N most recent backups
  export [perfil] [flags]   export sessions to Markdown (see below)
  help                 this help

export profiles (default: completo):
  completo     text + reasoning + tool calls + patches + step markers + compactions
  sin-calls    text + reasoning (no tools/patches/steps)
  solo-texto   only 'text' parts of user/assistant messages

export flags:
  --filter PATTERN   SQL LIKE on session id/title, e.g. 'ses_f7%'
  --out DIR          output root (default $OCED_OUT)
  --sub separate|inline|omit   how to place subagent sessions (default separate:
                       folder per root session with subagents/ inside)
  --tool-output completo|truncado|omitir   tool output verbosity (default truncado)
  --patch completo|omitir   include patch parts (default completo)
  --marcar-compactaciones   include compaction markers in any profile
  --resumen-diffs    render user-message summary.diffs (files+additions/deletions)
EOF
}

case "${1:-help}" in
    status)        oced_status ;;
    list)          shift; oced_list "$@" ;;
    info)          oced_info "${2:-}" ;;
    compactaciones) oced_compact "${2:-}" ;;
    backup)        shift; oced_backup "$@" ;;
    backups)       shift; oced_backups "$@" ;;
    export)        shift; oced_export "$@" ;;
    help|-h)       help ;;
    *) echo "Unrecognized subcommand: $1"; help; exit 1 ;;
esac