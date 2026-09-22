#!/usr/bin/env bash
# common.sh — config, paths and helpers shared by the opencode-db modules.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Config precedence: environment > conf file > built-in default.
OCED_CONF="${OCED_CONF:-$HOME/.config/opencode-db/opencode-db.conf}"

# Optional path config (no secrets): $OCED_CONF (permissions 600).
# Variables: OPENCODE_DB, OCED_OUT, OCED_BACKUP_DIR, OCED_COMPRESS, OCED_LOG.
load_conf() {
    [ -f "$OCED_CONF" ] || return 0
    chmod 600 "$OCED_CONF" 2>/dev/null || true

    # Snapshot variables already present in the environment so the conf file
    # cannot clobber them (env wins over conf).
    local v
    local -A conf_env_set=() conf_env_val=()
    for v in OPENCODE_DB OCED_OUT OCED_BACKUP_DIR OCED_COMPRESS OCED_LOG OCED_ACTIVITY_LOG OCED_FROM_BACKUP; do
        if [ "${!v+x}" = x ]; then
            conf_env_set[$v]=1
            conf_env_val[$v]="${!v}"
        fi
    done
    set -a; . "$OCED_CONF"; set +a
    for v in "${!conf_env_set[@]}"; do
        printf -v "$v" '%s' "${conf_env_val[$v]}"
    done
}
load_conf

# Built-in defaults for whatever neither the environment nor the conf defined.
: "${OPENCODE_DB:=$HOME/.local/share/opencode/opencode.db}"
: "${OCED_OUT:=$HOME/.local/share/opencode-db-exporter/exports}"
: "${OCED_BACKUP_DIR:=$HOME/.local/share/opencode-db-exporter/backups}"
: "${OCED_COMPRESS:=1}"

# Tool version (shown by 'opencode-db version' and the schema probe).
OCED_VERSION="1.0.0"

# Expected opencode DB schema (compatibility probe). Space-separated tables and
# "table:col,col,..." entries; the tool warns if any are missing.
OCED_EXPECTED_TABLES="session message part todo session_share session_context_epoch session_input session_message event event_sequence project project_directory workspace migration data_migration"
OCED_EXPECTED_COLUMNS="
session:id,parent_id,agent,model,directory,title,version,time_created,time_updated,cost,tokens_input,tokens_output
message:id,session_id,data
part:id,message_id,session_id,data
todo:session_id,content,status
"
# Opt-in activity log: OCED_LOG=1 appends one timestamped line per significant
# action (backup, prune, shrink, ...) to OCED_ACTIVITY_LOG.
: "${OCED_LOG:=0}"
: "${OCED_ACTIVITY_LOG:=$HOME/.local/state/opencode-db/activity.log}"
# Backup source override: if set, use a stored backup file as the DB source.
# Can be a filename (resolved under OCED_BACKUP_DIR) or an absolute path.
: "${OCED_FROM_BACKUP:=}"

# o_log <message> -> append one line to the activity log (only when OCED_LOG=1).
o_log() {
    [ "${OCED_LOG:-0}" = "1" ] || return 0
    mkdir -p "$(dirname "$OCED_ACTIVITY_LOG")" 2>/dev/null || true
    printf '%s\t%s\n' "$(o_now_utc)" "$*" >> "$OCED_ACTIVITY_LOG" 2>/dev/null || true
}

o_have() { command -v "$1" >/dev/null 2>&1; }

o_die() { printf 'error: %s\n' "$*" >&2; exit 1; }

o_now_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

o_ts() { date -u +"%Y%m%d-%H%M%S"; }

# o_effective_db -> returns the path to the DB to use (live or backup).
# Resolution is MEMOIZED in the parent shell by o_resolve_db (a backup .gz is
# decompressed to a temp file at most once per process; callers must invoke
# o_resolve_db/o_db_exists directly, never only inside $(...)).
OCED_EFFECTIVE_DB=""
OCED_TMP_DB=""

o_resolve_db() {
    [ -n "$OCED_EFFECTIVE_DB" ] && return 0
    if [ -n "${OCED_FROM_BACKUP:-}" ]; then
        local f="${OCED_FROM_BACKUP}"
        case "$f" in
            /*) ;; # absolute path
            *) f="$OCED_BACKUP_DIR/$f" ;;
        esac
        [ -f "$f" ] || o_die "Backup file not found: $f"
        if file "$f" | grep -q "gzip compressed"; then
            OCED_TMP_DB=$(mktemp /tmp/oced-backup-XXXXXX.db)
            gzip -dc "$f" > "$OCED_TMP_DB" || o_die "Could not decompress backup: $f"
            OCED_EFFECTIVE_DB="$OCED_TMP_DB"
        else
            OCED_EFFECTIVE_DB="$f"
        fi
    else
        OCED_EFFECTIVE_DB="$OPENCODE_DB"
    fi
    return 0
}

o_effective_db() {
    [ -n "$OCED_EFFECTIVE_DB" ] || o_resolve_db
    printf '%s\n' "$OCED_EFFECTIVE_DB"
}

o_db_exists() {
    o_resolve_db
    [ -f "$OCED_EFFECTIVE_DB" ] || o_die "Database not found: $OCED_EFFECTIVE_DB"
}

# o_cleanup_tmp -> removes the temp decompressed DB (safe to call twice).
o_cleanup_tmp() {
    [ -n "${OCED_TMP_DB:-}" ] && rm -f "$OCED_TMP_DB"
    OCED_TMP_DB=""
    return 0
}

o_db_uri() { printf 'file:%s?mode=ro' "$(o_effective_db)"; }

o_q() { sqlite3 "$(o_db_uri)" "$@"; }

# o_backup_aligned -> checks if the last backup is aligned with current live DB.
# Prints "aligned" or "out of sync" and returns 0 if aligned, 1 if not.
o_backup_aligned() {
    local manifest="$OCED_BACKUP_DIR/manifest.json"
    [ -f "$manifest" ] || { echo "no backups"; return 1; }
    local last_idx msess mmess mu tsess tmess tu
    last_idx=$(jq -r '.backups | length - 1' "$manifest" 2>/dev/null || echo -1)
    [ "$last_idx" -ge 0 ] || { echo "no backups"; return 1; }
    msess=$(jq -r --argjson i "$last_idx" '.backups[$i].sessions' "$manifest" 2>/dev/null || echo 0)
    mmess=$(jq -r --argjson i "$last_idx" '.backups[$i].messages' "$manifest" 2>/dev/null || echo 0)
    mu=$(jq -r --argjson i "$last_idx" '.backups[$i].max_updated' "$manifest" 2>/dev/null || echo 0)
    tsess=$(o_q "SELECT count(*) FROM session" 2>/dev/null || echo 0)
    tmess=$(o_q "SELECT count(*) FROM message" 2>/dev/null || echo 0)
    tu=$(o_q "SELECT max(time_updated) FROM session" 2>/dev/null || echo 0)
    if [ "$msess" = "$tsess" ] && [ "$mmess" = "$tmess" ] && [ "$mu" = "$tu" ]; then
        echo "aligned"
        return 0
    else
        echo "out of sync"
        return 1
    fi
}

o_human_size() {
    local bytes="$1"
    if [ -n "$bytes" ]; then numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || printf '%s' "$bytes"; fi
}

o_check_deps() {
    for dep in sqlite3 python3 jq gzip; do
        o_have "$dep" || o_die "Missing '$dep' (required by opencode-db). Install it with: opencode-db deps"
    done
}

o_safe_sed_escape() { printf '%s' "$1" | sed -E "s/['\"]/\\&/g"; }