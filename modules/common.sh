#!/usr/bin/env bash
# common.sh — config, paths and helpers shared by the opencode-db modules.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Defaults (overridable via env or the optional conf file).
OPENCODE_DB="${OPENCODE_DB:-$HOME/.local/share/opencode/opencode.db}"
OCED_OUT="${OCED_OUT:-$HOME/.local/share/opencode-db-exporter/exports}"
OCED_BACKUP_DIR="${OCED_BACKUP_DIR:-$HOME/.local/share/opencode-db-exporter/backups}"
OCED_COMPRESS="${OCED_COMPRESS:-1}"
OCED_CONF="${OCED_CONF:-$HOME/.config/opencode-db/opencode-db.conf}"

# Optional path config (no secrets): $OCED_CONF (permissions 600).
# Variables: OPENCODE_DB, OCED_OUT, OCED_BACKUP_DIR, OCED_COMPRESS.
load_conf() {
    [ -f "$OCED_CONF" ] || return 0
    chmod 600 "$OCED_CONF" 2>/dev/null || true
    set -a; . "$OCED_CONF"; set +a
}
load_conf

o_have() { command -v "$1" >/dev/null 2>&1; }

o_die() { printf 'error: %s\n' "$*" >&2; exit 1; }

o_now_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

o_ts() { date -u +"%Y%m%d-%H%M%S"; }

o_db_exists() {
    [ -f "$OPENCODE_DB" ] || o_die "Database not found: $OPENCODE_DB"
}

o_db_uri() { printf 'file:%s?mode=ro' "$OPENCODE_DB"; }

o_q() { sqlite3 "$(o_db_uri)" "$@"; }

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