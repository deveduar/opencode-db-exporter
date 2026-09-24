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
. "$SCRIPT_DIR/shrink.sh"

help() {
    cat <<'EOF'
Usage: opencode-db.sh [command]
  menu                 interactive menu (fzf, standalone)
  status               DB exists/size/integrity + counts + last session + backup alignment
                       + version/schema probe + dependency check
  version              tool version (opencode-db) + opencode CLI version + schema compatibility probe
  list [--root|--sub|--all] [--filter PATTERN] [--info]
                       list sessions (id | title | date | agent | dir | tokens);
                       --filter: SQL LIKE pattern on id/title, e.g. 'ses_f7%'
  info <id>            full detail of one session (tokens, compactions, counts)
  compactions <id> [show [last|N|all]]
                       list compaction points (date + new queue) of a session;
                       'show' also prints the compacted-context digest stored in
                       the following "mode=compaction" message (last / N / all)
  backup [--no-compress] [--yes]   consistent snapshot (sqlite .backup) with timestamp
                       + sha256 + stats in backups/manifest.json (gzip by default);
                       shows the plan (source/target/estimated size) and asks to
                       confirm before starting (--yes skips the confirmation)
  backups list         list stored backups
  backups verify <file>   check sha256 of a backup against the manifest
  backups remove <file> [--yes]   delete a backup file
  backups prune <N>    keep only the N most recent backups
shrink [recipe] [--keep N|--older-than DAYS|--since DATE] [--strip-reasoning] [--dry-run] [--swap] [--yes]
                         build a PRUNED + VACUUMed COPY of the DB to reclaim space
                         (a big DB only grows: deleting sessions does NOT shrink
                         the file). The copy replaces the live DB manually; this
                         tool never writes it. --swap automates the replacement
                         safely: aborts if opencode is running, snapshots a
                         .pre-shrink safety copy (WAL-safe) and rolls back if the
                         new DB does not open. recipes: lean (keep 10 + strip
                         reasoning, recommended) | recent (last 90 days) | full
                         (keep all, strip reasoning) | bare (keep 10, no strip)
  export [product] [flags]   export sessions to Markdown (see below)
exports list         list past export runs (date/profile/counts/size);
                        a run with several profiles shows them joined with '+'
  exports remove <stamp> [--yes]   delete one export run (all its profiles)
  exports prune <N> [--yes]   keep only the N most recent export runs
  exports view <stamp> [--files]   show details of an export run (index, sessions, files)
  guide [--list]       step-by-step console wizard (inspect -> backup -> export memory
                       -> shrink -> swap manually); --list prints the plan only
  deps [--check]       check/install the dependencies (apt/pacman/dnf, idempotent, needs sudo)
  help                 this help

export products (default: transcript):
  transcript   the conversation in markdown: text + reasoning + tool calls +
               patches + step markers (tool output is truncated by default:
               use --tool-output full for the complete output). Optional
               --json writes a faithful archive per session (native shape.)
  memory       RAG/memory corpus: corpus.jsonl with one JSON per root session
               (metadata + first user text + last assistant text + all
               compaction digests) - ready for embeddings, not a transcript
  compactions  only the compacted-context digests (mode=compaction messages)

export flags:
  --filter PATTERN   SQL LIKE on session id/title, e.g. 'ses_f7%'
  --sessions ID[,ID]   exact session id(s) to export (repeatable);
                     overrides --filter / the preset selection
  --out DIR          output root (default $OCED_OUT)
  --sub separate|inline|omit   how to place subagent sessions (default separate:
                       folder per root session with subagents/ inside)
  --tool-output full|truncated|omit   tool output verbosity (default truncated;
                       applies to transcripts/compactions)
  --patch full|omit   include patch parts (default full; transcripts only)
  --mark-compactions   include compaction marker paragraphs (transcripts only)
  --no-reasoning       omit the reasoning parts (transcripts only)
  --summary-diffs    render user-message summary.diffs (files+additions/deletions)
  --role all|user|assistant   transcripts/compactions: render only one role's
                       messages (--role user = prompts only, --role assistant =
                       answers only; memory ignores it)
  --json             also write a faithful JSON archive per session (transcripts
                     and compactions)
  --sanitize         redact secret-looking values (API keys, bearer tokens,
                     private keys, key=... pairs) in the exported output
  --cap N  --files   memory tuning: truncate each text value to N chars
                     (0 = unlimited, default) and/or include touched files

Named presets (presets file, source of truth for the menu and the CLI):
  export <name>      run a named preset from $OCED_PRESETS (JSON):
                     {"presets":{"clean":{"product":"transcript","json":true,
                     "sanitize":true,"no_reasoning":true,"filter":"Project Beta"}}}
                     The preset pins the product, its config flags and optionally
                     the selection ('filter' or exact 'sessions' ids, not both;
                     none = ALL). Explicit CLI flags (--filter/--sessions/--cap...)
                     override the preset. 'export transcript'/'memory'/'compactions'
                     always mean the product (its aliases and flags are unchanged).

Configuration (env > conf file > built-in default):
  OPENCODE_DB       SQLite database (default ~/.local/share/opencode/opencode.db;
                    WSL with native-Windows opencode: /mnt/c/Users/<user>/.../opencode.db)
  OCED_OUT          export output root (default ~/.local/share/opencode-db-exporter/exports)
  OCED_BACKUP_DIR   backup folder (default ~/.local/share/opencode-db-exporter/backups)
  OCED_COMPRESS     1 gzip backups (default) / 0 raw
  OCED_LOG         1 appends an activity log (backup/prune/shrink) to OCED_ACTIVITY_LOG
  OCED_CONF         config file (default ~/.config/opencode-db/opencode-db.conf)
  OCED_PRESETS      export presets file (default ~/.config/opencode-db/presets.json)

Global flag (must precede subcommand):
  --from-backup <file>   use a stored backup as the DB source (read-only).
                         <file> can be a filename (under $OCED_BACKUP_DIR) or absolute path.
                         WARNING: operations reflect the backup state, not the live DB.
                         Use 'status' to check alignment before running.
EOF
}

# Global flag: --from-backup <file> (must appear before subcommand)
if [ "${1:-}" = "--from-backup" ]; then
    [ "$#" -ge 3 ] || { echo "Usage: opencode-db --from-backup <file> <subcommand> [args...]"; exit 1; }
    export OCED_FROM_BACKUP="$2"
    shift 2
fi

# Resolve the DB source once (memoized) for the commands that read it, and clean
# up the decompressed temp backup on exit. Meta/write-only commands skip this.
case "${1:-help}" in
    deps|help|-h|menu|guide|backups) ;;
    *) o_resolve_db ;;
esac
trap 'o_cleanup_tmp' EXIT

case "${1:-help}" in
    menu)          . "$SCRIPT_DIR/menu.sh"; run_oc_menu ;;
    status)        oced_status ;;
    version|--version|-V)  oced_version ;;
    list)          shift; oced_list "$@" ;;
    info)          shift; oced_info "$@" ;;
    compactions)   shift; oced_compactions "$@" ;;
    backup)        shift; oced_backup "$@" ;;
    backups)       shift; oced_backups "$@" ;;
    shrink)          shift; oced_shrink "$@" ;;
    export)        shift; oced_export "$@" ;;
    exports)       shift; oced_exports "$@" ;;
    guide)         shift; . "$SCRIPT_DIR/guide.sh"; oced_guide "$@" ;;
    deps)          shift; oced_deps "$@" ;;
    help|-h)       help ;;
    *) echo "Unrecognized subcommand: $1"; help; exit 1 ;;
esac