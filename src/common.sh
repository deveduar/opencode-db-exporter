#!/usr/bin/env bash
# common.sh — config, paths and helpers shared by the opencode-db shell modules.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Portable: when the repo checkout ships its own config and no user config exists
# under ~/.config/opencode-db, the repo files ARE the defaults (fallback for the
# no-install case). Precedence stays env > conf file > (user config | repo config) > built-in.
OCED_HOME_CONF_DIR="$HOME/.config/opencode-db"
OCED_REPO_ROOT="${SCRIPT_DIR%/src}"
OCED_PORTABLE=0
# Install markers (both overridable so tests never touch the real HOME): the
# symlink install.sh creates is what "already installed" means. Additive, not
# per-file; a home conf alone is not an install.
OCED_BIN="${OCED_BIN:-$HOME/.local/bin/opencode-db}"
OCED_PREFIX="${OCED_PREFIX:-$HOME/.local/share/opencode-db-exporter}"

# oc_is_installed -> 0 when the tool is installed (the shim exists).
oc_is_installed() { [ -e "$OCED_BIN" ]; }

o_cfg_default() { # <file> -> path; home file wins, repo shipped fallback.
    [ -f "$OCED_HOME_CONF_DIR/$1" ] && { printf '%s/%s' "$OCED_HOME_CONF_DIR" "$1"; return 0; }
    [ -f "$OCED_REPO_ROOT/$1" ] && { printf '%s/%s' "$OCED_REPO_ROOT" "$1"; return 0; }
    printf '%s/%s' "$OCED_HOME_CONF_DIR" "$1"
}

# Config precedence: environment > conf file > built-in default.
OCED_CONF="${OCED_CONF:-$(o_cfg_default opencode-db.conf)}"
# The repo IS our config home only when its conf is the one in charge (home config
# wins when both exist; an installed prefix never ships a conf at all).
[ "$OCED_CONF" = "$OCED_REPO_ROOT/opencode-db.conf" ] && [ -f "$OCED_CONF" ] && OCED_PORTABLE=1

# Optional path config (no secrets): $OCED_CONF (permissions 600; the repo-shipped
# portable conf is left as-is so git never sees a 644 -> 600 mode change per run).
# Variables: OPENCODE_DB, OCED_OUT, OCED_BACKUP_DIR, OCED_COMPRESS, OCED_LOG,
# OCED_TZ (display-only: the menu renders picker-row dates in local time),
# OCED_TRANSCRIPT_CHUNK_MB (the transcript file-size target; 0 disables splitting).
load_conf() {
    [ -f "$OCED_CONF" ] || return 0
    [ "$OCED_PORTABLE" = 1 ] || chmod 600 "$OCED_CONF" 2>/dev/null || true

    # Snapshot variables already present in the environment so the conf file
    # cannot clobber them (env wins over conf).
    local v
    local -A conf_env_set=() conf_env_val=()
    for v in OPENCODE_DB OCED_OUT OCED_BACKUP_DIR OCED_COMPRESS OCED_LOG OCED_ACTIVITY_LOG OCED_FROM_BACKUP OCED_PRESETS OCED_SHRINK_PRESETS OCED_SHRINK_DISCARD_EXPORT_PROFILE OCED_TRANSCRIPT_CHUNK_MB OCED_TZ; do
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
if [ "$OCED_PORTABLE" = 1 ]; then
    # Portable (repo-shipped conf active): data lives in the repo (gitignored),
    # so a no-install run needs no ~/.local/share/opencode-db-exporter prefix.
    : "${OCED_OUT:=$OCED_REPO_ROOT/exports}"
    : "${OCED_BACKUP_DIR:=$OCED_REPO_ROOT/backups}"
else
    : "${OCED_OUT:=$HOME/.local/share/opencode-db-exporter/exports}"
    : "${OCED_BACKUP_DIR:=$HOME/.local/share/opencode-db-exporter/backups}"
fi
: "${OCED_COMPRESS:=1}"

# Tool version (shown by 'opencode-db version' and the schema probe).
OCED_VERSION="1.2.0"

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
if [ "$OCED_PORTABLE" = 1 ]; then
    : "${OCED_ACTIVITY_LOG:=$OCED_REPO_ROOT/activity.log}"
else
    : "${OCED_ACTIVITY_LOG:=$HOME/.local/state/opencode-db/activity.log}"
fi
# Backup source override: if set, use a stored backup file as the DB source.
# Can be a filename (resolved under OCED_BACKUP_DIR) or an absolute path.
: "${OCED_FROM_BACKUP:=}"
# Export presets file (named recipes, source of truth for the menu). Absent file
# = no presets: export keeps working with raw flags.
: "${OCED_PRESETS:=$(o_cfg_default presets.json)}"
# Shrink presets file (named shrink recipes; the shipped recipes lean/recent/
# full/bare always exist — this file extends/overrides them).
: "${OCED_SHRINK_PRESETS:=$(o_cfg_default shrink-presets.json)}"
# Export profile used when shrink offers to export discarded sessions first.
# Default: review. Set to "memory" for corpus-only, or any
# valid export product/profile.
: "${OCED_SHRINK_DISCARD_EXPORT_PROFILE:=review}"

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

# o_backup_aligned [file] [-v] -> is a backup aligned with the current live DB?
#   (no file) : the LAST manifest entry — what every caller wants by default
#   file      : that specific entry, so `backups view <file>` can say how a copy
#               that is NOT the newest compares to the live DB
#   -v        : print the counts too, not just the verdict
# Prints "aligned" or "out of sync" and returns 0 if aligned, 1 if not.
o_backup_aligned() {
    local want="" verbose=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -v) verbose=1 ;;
            *)  want="$1" ;;
        esac
        shift
    done
    local manifest="$OCED_BACKUP_DIR/manifest.json"
    [ -f "$manifest" ] || { echo "no backups"; return 1; }
    # One entry, resolved either by name or as the newest — never both, so the
    # default path keeps its meaning: "is my LAST backup aligned?".
    local entry=""
    if [ -n "$want" ]; then
        entry=$(jq -r --arg f "$want" '.backups[]? | select(.file == $f)' "$manifest" 2>/dev/null) || entry=""
        # Not in the manifest = nothing to compare against; answer the safe way.
        [ -n "$entry" ] || { echo "out of sync"; return 1; }
    else
        entry=$(jq -r '.backups[-1] // empty' "$manifest" 2>/dev/null) || entry=""
    fi
    [ -n "$entry" ] || { echo "no backups"; return 1; }
    local msess mmess mu tsess tmess tu
    msess=$(printf '%s' "$entry" | jq -r '.sessions // 0')
    mmess=$(printf '%s' "$entry" | jq -r '.messages // 0')
    mu=$(printf '%s' "$entry" | jq -r '.max_updated // 0')
    tsess=$(o_q "SELECT count(*) FROM session" 2>/dev/null || echo 0)
    tmess=$(o_q "SELECT count(*) FROM message" 2>/dev/null || echo 0)
    tu=$(o_q "SELECT max(time_updated) FROM session" 2>/dev/null || echo 0)
    if [ "$msess" = "$tsess" ] && [ "$mmess" = "$tmess" ] && [ "$mu" = "$tu" ]; then
        if [ "$verbose" -eq 1 ]; then
            printf 'aligned (this: %s sess/%s msg)\n' "$msess" "$mmess"
        else
            printf 'aligned\n'
        fi
        return 0
    else
        if [ "$verbose" -eq 1 ]; then
            printf 'out of sync (this: %s sess/%s msg · live: %s sess/%s msg)\n' \
                "$msess" "$mmess" "$tsess" "$tmess"
        else
            printf 'out of sync\n'
        fi
        return 1
    fi
}

# o_backup_live_counts -> "sessions<TAB>messages<TAB>max_updated" of the LIVE DB.
# One place for the three numbers every per-row freshness check compares, so a
# list of N backups runs ONE live query instead of 3N (o_backup_aligned queries
# for one entry; a list must not call it per row).
o_backup_live_counts() {
    local ts tm tu
    ts=$(o_q "SELECT count(*) FROM session" 2>/dev/null || echo 0)
    tm=$(o_q "SELECT count(*) FROM message" 2>/dev/null || echo 0)
    tu=$(o_q "SELECT max(time_updated) FROM session" 2>/dev/null || echo 0)
    printf '%s\t%s\t%s' "$ts" "$tm" "$tu"
}

# o_backup_row_tag <sess> <msg> <max_updated> <live_sess> <live_msg> <live_max>
# -> " (stale)" when the entry differs from the live DB, empty when aligned. The
# SAME comparison `o_backup_aligned` makes, but pure: `backups list` and the menu
# picker pass their precomputed live counts, so the two rows cannot disagree.
# Only the anomaly is tagged (like `shrinks list`): a backup older than the last
# activity is stale, which is the normal state of history, so the aligned copy is
# the one worth seeing clean.
o_backup_row_tag() {
    if [ "$1" = "$4" ] && [ "$2" = "$5" ] && [ "$3" = "$6" ]; then
        printf ''
    else
        printf ' (stale)'
    fi
}

o_human_size() {
    local bytes="$1"
    if [ -n "$bytes" ]; then numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || printf '%s' "$bytes"; fi
}

# o_human_iso <ISO-8601 UTC> -> "YYYY-MM-DD HH:MM:SS UTC"; passthrough if unparsable.
o_human_iso() {
    local d="$1" out=""
    [ -n "$d" ] || { printf '%s' "-"; return 0; }
    out=$(date -u -d "$d" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null) || out=""
    printf '%s' "${out:-$d}"
}

# o_human_ms <epoch ms> -> "YYYY-MM-DD HH:MM:SS UTC"; 0/absent/garbage -> "-".
o_human_ms() {
    local ms="$1" out=""
    case "$ms" in
        '' | *[!0-9]*) printf '%s' "${ms:--}"; return 0 ;;
    esac
    [ "$ms" -gt 0 ] 2>/dev/null || { printf '%s' "-"; return 0; }
    out=$(date -u -d "@$((ms / 1000))" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null) || out=""
    printf '%s' "${out:--}"
}

# o_local_ts <"YYYY-MM-DD HH:MM:SS"[ " UTC"|"Z"]> [strftime-fmt] -> the same
# instant in the DISPLAY timezone. MENU PICKER ROWS ONLY: the menu shows local
# time (auto-detected from the system TZ; OCED_TZ overrides it), while every CLI
# surface, report and persisted file keeps UTC. Default format drops the zone;
# pass a fmt with %Z to render it. A parse failure passes the input through.
o_local_ts() {
    local ts="${1:-}" fmt="${2:-+%Y-%m-%d %H:%M:%S}" tz="${OCED_TZ:-}" out=""
    [ -n "$ts" ] || { printf '%s' "${1:-}"; return 0; }
    ts="${ts% UTC}"; ts="${ts%Z}"; ts="${ts% }"; ts="${ts/T/ }"
    if [ -n "$tz" ]; then
        out=$(TZ="$tz" date -d "$ts UTC" "$fmt" 2>/dev/null) || out=""
    else
        out=$(date -d "$ts UTC" "$fmt" 2>/dev/null) || out=""
    fi
    printf '%s' "${out:-${1:-}}"
}

o_check_deps() {
    for dep in sqlite3 python3 jq gzip; do
        o_have "$dep" || o_die "Missing '$dep' (required by opencode-db). Install it with: opencode-db deps"
    done
}

o_safe_sed_escape() { printf '%s' "$1" | sed -E "s/['\"]/\\&/g"; }
