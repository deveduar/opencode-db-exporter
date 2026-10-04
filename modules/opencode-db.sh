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
                       [--order created-asc|created-desc|updated-asc|updated-desc]
                       list sessions (id | title | date | agent | dir | tokens);
                       --filter: SQL LIKE pattern on id/title, e.g. 'ses_f7%'
                       --order: sort axis + direction (default created-asc = oldest
                       first); ties always fall back to time_created
  info <id>            full detail of one session (tokens, digests, counts)
  digest <id> [show [last|N|all]]
                       a compaction MARKER is the event opencode records (date +
                       new queue); a DIGEST is the summary it wrote for it, in the
                       following "mode=compaction" message (last / N / all).
                       'compactions' still works: deprecated alias of 'digest'
  backup [--no-compress] [--yes]   consistent snapshot (sqlite .backup) with timestamp
                       + sha256 + stats in backups/manifest.json (gzip by default);
                       shows the plan (source/target/estimated size) and asks to
                       confirm before starting (--yes skips the confirmation)
  backups list         list stored backups
  backups view <file>  a backup's details + its sha256 check vs the live DB
  backups verify <file>   check sha256 of a backup against the manifest
  backups remove <file> [--yes]   delete a backup file
  backups prune <N>    keep only the N most recent backups
shrink [preset] [--keep N | --older-than DAYS | --since DATE | --keep-all |
          --keep-sessions ID[,ID] | --discard-sessions ID[,ID]]
          [--strip-reasoning] [--dry-run] [--swap] [--yes] [--list-presets]
                      build a PRUNED + VACUUMed COPY of the DB to reclaim space
                      (a big DB only grows: deleting sessions does NOT shrink
                      the file). The copy replaces the live DB manually; this
                      tool never writes it. --swap automates the replacement
                      safely: aborts if opencode is running, snapshots a
                      safety copy to $OCED_BACKUP_DIR/pre-shrink/ (WAL-safe)
                       and rolls back if the new DB does not open. Exactly ONE
                       keep rule applies (last one wins); a recipe is a named
                       combination of OPERATIONS only (lean/quiet, see below) —
                       the session selection is the keep rule above, or the menu
                       picker. The kept set is closed (parents/subagents of a
                       kept session stay).
  export [product] [flags]   export sessions to Markdown (see below)
exports list         list past export runs (date/profile/counts/size);
                        a run with several profiles shows them joined with '+'
  exports remove <stamp> [--yes]   delete one export run (all its profiles)
  exports prune <N> [--yes]   keep only the N most recent export runs
  exports view <stamp> [--files] [--json]   show details of an export run (config, sessions, files; --json = raw)
  shrinks list [--tsv]   list the produced shrink copies (criteria/counts/size)
  shrinks view <stamp> [--json]   show the shrink.json of a run (--json = raw)
  shrinks verify [--yes] [--tsv]   check for orphan run dirs, old pre-shrink
                       copies and a shrink that is stale vs the live DB; --yes
                       auto-removes orphan dirs + old pre-shrinks
  shrinks remove <stamp> [--yes]   delete a shrink run (the pruned + VACUUMed copy)
  shrinks prune <N> [--yes]   keep only the N most recent shrink runs
  deps [--check]       check/install the dependencies (apt/pacman/dnf, idempotent, needs sudo)
  help                 this help

EOF
    # Export products + flags come from the python SSoT (flags.py --help-exports)
    if ! python3 "$SCRIPT_DIR/exportlib/flags.py" --help-exports 2>/dev/null; then
        cat <<'EOF'
export products (default: transcript):
  transcript | memory | digest        (see 'opencode-db export --help' for the flags)

EOF
    fi
    # Shrink recipes + flags come from the python SSoT (shrinklib/flags.py --help-shrinks)
    if ! python3 "$SCRIPT_DIR/shrinklib/flags.py" --help-shrinks 2>/dev/null; then
        cat <<'EOF'
shrink presets (default: keep the 10 most recent sessions):
  lean      keep the 10 most recent sessions + strip reasoning (recommended)
  recent    keep sessions updated in the last 90 days
  full      keep ALL sessions, strip reasoning + vacuum (just reclaims space)
  bare      keep the 10 most recent sessions, keep reasoning

EOF
    fi
    cat <<'EOF'

Named presets (presets file, source of truth for the menu and the CLI):
  export <name>      run a named preset from $OCED_PRESETS (JSON):
                     {"presets":{"clean":{"product":"transcript","json":true,
                     "sanitize":true,"no_reasoning":true,"filter":"Project Beta"}}}
                     The preset pins the product, its config flags and optionally
                     the selection ('filter' or exact 'sessions' ids, not both;
                     none = ALL). Explicit CLI flags (--filter/--sessions/--cap...)
                     override the preset. 'export transcript'/'memory'/'digest'
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
  OCED_SHRINK_PRESETS shrink presets file (default ~/.config/opencode-db/shrink-presets.json)

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
    deps|help|-h|menu|backups|shrinks) ;;
    shrink) [ "${2:-}" = "--list-presets" ] || o_resolve_db ;;
    *) o_resolve_db ;;
esac
trap 'o_cleanup_tmp' EXIT

case "${1:-help}" in
    menu)          . "$SCRIPT_DIR/menu.sh"; run_oc_menu ;;
    status)        oced_status ;;
    version|--version|-V)  oced_version ;;
    list)          shift; oced_list "$@" ;;
    info)          shift; oced_info "$@" ;;
    digest)        shift; oced_digest "$@" ;;
    # Deprecated alias: the old name of `digest`, kept so old scripts work.
    compactions)   shift; oced_digest "$@" ;;
    backup)        shift; oced_backup "$@" ;;
    backups)       shift; oced_backups "$@" ;;
    shrink)          shift; oced_shrink "$@" ;;
    shrinks)       shift; oced_shrinks "$@" ;;
    export)        shift; oced_export "$@" ;;
    exports)       shift; oced_exports "$@" ;;
    deps)          shift; oced_deps "$@" ;;
    help|-h)       help ;;
    *) echo "Unrecognized subcommand: $1"; help; exit 1 ;;
esac