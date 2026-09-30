#!/usr/bin/env bash
# backup.sh — oced_backup / oced_backups: consistent snapshots + sha256 + manifest.
set -uo pipefail

o_q_file() { sqlite3 "file:$1?mode=ro" "${@:2}"; }

manifest_path() { printf '%s/manifest.json' "$OCED_BACKUP_DIR"; }

manifest_read() {
    local m; m=$(manifest_path)
    if [ -f "$m" ] && jq -e '.backups | type == "array"' "$m" >/dev/null 2>&1; then
        cat "$m"
    else
        printf '{"backups":[]}'
    fi
}

manifest_write() {
    local m t
    m=$(manifest_path)
    mkdir -p "$OCED_BACKUP_DIR"
    t=$(mktemp "$OCED_BACKUP_DIR/.manifest.XXXXXX")
    printf '%s\n' "$1" > "$t"
    chmod 600 "$t"
    mv -f "$t" "$m"
}

# oc_backup_sha_state <record-json> -> "state<TAB>manifest-sha<TAB>file-sha" on
# stdout, with state = OK | MISMATCH | MISSING (the hashes are "-" when they
# could not be read). `verify` and `view` share it so a backup can never be
# described one way in the details and another way by the check.
oc_backup_sha_state() {
    local rec="$1" f expect actual path
    f=$(printf '%s' "$rec" | jq -r '.file // ""')
    expect=$(printf '%s' "$rec" | jq -r '.sha256 // "-"')
    path="$OCED_BACKUP_DIR/$f"
    if [ ! -f "$path" ]; then
        printf 'MISSING\t%s\t-\n' "$expect"
        return 2
    fi
    actual=$(sha256sum "$path" | cut -d' ' -f1)
    if [ "$actual" = "$expect" ]; then
        printf 'OK\t%s\t%s\n' "$expect" "$actual"
        return 0
    fi
    printf 'MISMATCH\t%s\t%s\n' "$expect" "$actual"
    return 1
}

# oced_backups_view <file> -> what the manifest recorded for a backup, whether
# the file on disk still matches it, and how it compares to the live DB.
# The sha check lives HERE (not in a separate `verify` row) so a details view
# can never show a backup nobody has ever validated.
oced_backups_view() {
    local f="${1:-}" json_mode=0 rec
    [ -n "$f" ] || { echo "Usage: opencode-db backups view <backup-file> [--json]"; return 1; }
    [ "${2:-}" = "--json" ] && json_mode=1
    rec=$(jq -r --arg f "$f" '.backups[]? | select(.file == $f)' "$(manifest_path)")
    [ -n "$rec" ] || { echo "Not in the manifest: $f"; echo "Try: opencode-db backups list"; return 1; }

    if [ "$json_mode" -eq 1 ]; then
        printf '%s' "$rec" | jq -c .
        return 0
    fi

    local date size size_raw sess msgs parts mu src stored_line align
    date=$(printf '%s' "$rec" | jq -r '.date // "-"')
    size=$(printf '%s' "$rec" | jq -r '.size // 0')
    size_raw=$(printf '%s' "$rec" | jq -r '.size_raw // 0')
    sess=$(printf '%s' "$rec" | jq -r '.sessions // 0')
    msgs=$(printf '%s' "$rec" | jq -r '.messages // 0')
    parts=$(printf '%s' "$rec" | jq -r '.parts // 0')
    mu=$(printf '%s' "$rec" | jq -r '.max_updated // 0')
    src=$(printf '%s' "$rec" | jq -r '.source // "-"')

    stored_line="$(o_human_size "$size") on disk"
    [ "$size" != "$size_raw" ] && stored_line+=" · $(o_human_size "$size_raw") before gzip"
    case "$f" in *.gz) stored_line+=" (gzipped)" ;; esac

    echo "== Backup: $f =="
    printf '  %-12s %s\n' "Created:" "$(o_human_iso "$date")"
    printf '  %-12s %s\n' "Size:" "$stored_line"
    printf '  %-12s %s sessions · %s messages · %s parts\n' "Content:" "$sess" "$msgs" "$parts"
    printf '  %-12s %s\n' "Newest:" "$(o_human_ms "$mu")"
    printf '  %-12s %s\n' "Source DB:" "$src"

    local state expect actual
    IFS=$'\t' read -r state expect actual < <(oc_backup_sha_state "$rec")
    printf '  %-12s %s…%s (manifest)\n' "sha256:" "${expect:0:12}" "${expect: -4}"
    case "$state" in
        OK)       echo "  [OK]         the file matches the manifest" ;;
        MISMATCH) echo "  [FAIL]       sha256 MISMATCH"
                   echo "                 manifest: $expect"
                   echo "                 file:     $actual" ;;
        *)        echo "  [MISSING]    $OCED_BACKUP_DIR/$f" ;;
    esac

    align=$(o_backup_aligned "$f" -v 2>/dev/null || true)
    printf '  %-12s %s\n' "vs live DB:" "${align:-$f is not in the manifest}"
    echo "  Restore:     opencode-db --from-backup $f <command>"
}

oced_backup() {
    o_check_deps
    o_db_exists
    local compress="$OCED_COMPRESS" yes=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --no-compress) compress=0 ;;
            --yes) yes=1 ;;
            *) o_die "Unknown argument: $1" ;;
        esac
        shift
    done

    mkdir -p "$OCED_BACKUP_DIR"
    local est_raw est_extra=0 ans
    [ -f "${OPENCODE_DB}-wal" ] && est_extra=$((est_extra + $(stat -c %s "${OPENCODE_DB}-wal"))) || true
    [ -f "${OPENCODE_DB}-shm" ] && est_extra=$((est_extra + $(stat -c %s "${OPENCODE_DB}-shm"))) || true
    est_raw=$(( $(stat -c %s "$OPENCODE_DB") + est_extra ))
    echo "-> Backup plan"
    printf '   %-11s %s\n' "Source:" "$OPENCODE_DB"
    printf '   %-11s %s/opencode-<timestamp>.db%s\n' "Target:" "$OCED_BACKUP_DIR" "$([ "$compress" -eq 1 ] && echo ' (gzipped)')"
    printf '   %-11s ~%s raw snapshot (sqlite .backup; gzip compresses on save)\n' "Est. size:" "$(o_human_size "$est_raw")"
    if [ "$yes" -ne 1 ] && [ -t 0 ]; then
        printf '   Create this backup? [y/N] '
        read -r ans || ans=""
        [[ "$ans" =~ ^[yYsS]$ ]] || { echo "   Backup cancelled."; return 1; }
    fi

    local ts stamp snap rc sha size_raw
    ts=$(o_ts)
    stamp=$(o_now_utc)
    snap=$(mktemp /tmp/opencode-db-snap-XXXXXX.db)
    trap 'rm -f -- "${snap:-}" "${snap:-}.gz" /tmp/oced-backup.err' EXIT

    echo "-> Consistent snapshot (sqlite .backup) of $OPENCODE_DB ..."
    rc=1
    for attempt in 1 2 3; do
        if sqlite3 "$OPENCODE_DB" ".backup '$snap'" 2>/tmp/oced-backup.err; then
            rc=0; break
        fi
        echo "   (attempt $attempt: DB busy, retrying in 2s)"
        sleep 2
    done
    if [ "$rc" -ne 0 ]; then
        cat /tmp/oced-backup.err >&2
        o_die "Could not create the snapshot."
    fi

    local sess msgs parts maxu
    sess=$(o_q_file "$snap" "SELECT count(*) FROM session")
    msgs=$(o_q_file "$snap" "SELECT count(*) FROM message")
    parts=$(o_q_file "$snap" "SELECT count(*) FROM part")
    maxu=$(o_q_file "$snap" "SELECT coalesce(max(time_updated),0) FROM session")

    size_raw=$(stat -c %s "$snap")
    sha=$(sha256sum "$snap" | cut -d' ' -f1)

    local fname fpath fsha fsize
    if [ "$compress" -eq 1 ]; then
        gzip -c "$snap" > "$snap.gz"
        fname="opencode-$ts.db.gz"
        fpath="$OCED_BACKUP_DIR/$fname"
        mv -f "$snap.gz" "$fpath"
        fsha=$(sha256sum "$fpath" | cut -d' ' -f1)
        fsize=$(stat -c %s "$fpath")
    else
        fname="opencode-$ts.db"
        fpath="$OCED_BACKUP_DIR/$fname"
        mv -f "$snap" "$fpath"
        fsha="$sha"
        fsize="$size_raw"
    fi

    local entry
    entry=$(jq -n \
        --arg date "$stamp" --arg file "$fname" --arg sha "$sha" --arg sha_gz "$fsha" \
        --argjson size $size_raw --argjson size_gz $fsize \
        --argjson sessions $sess --argjson messages $msgs --argjson parts $parts \
        --argjson max_updated $maxu --arg source "$OPENCODE_DB" \
        '{date: $date, file: $file, sha256_raw: $sha, sha256: $sha_gz, size_raw: $size, size: $size_gz, sessions: $sessions, messages: $messages, parts: $parts, max_updated: $max_updated, source: $source}')
    manifest_write "$(manifest_read | jq --argjson e "$entry" '.backups += [$e]')"
    trap - EXIT

    o_log "backup created: $fpath (sessions=$sess messages=$msgs parts=$parts)"
    echo "[OK] Backup: $fpath"
    printf '   %-16s %s\n' "Created:" "$stamp"
    printf '   %-16s %s\n' "Size:" "$(o_human_size "$fsize") (raw $(o_human_size "$size_raw"))"
    printf '   %-16s %s\n' "Sessions:" "$sess"
    printf '   %-16s %s\n' "sha256:" "$fsha"
    echo "   Alignment: check with: opencode-db status"
}

oced_backups() {
    local manifest; manifest=$(manifest_path)
    [ -f "$manifest" ] || { echo "No backups recorded yet."; return 0; }
    local n
    n=$(jq -r '.backups | length' "$manifest")
    case "${1:-list}" in
        list)
            echo "== Backups ($n) =="
            jq -r '.backups | sort_by(.date) | reverse | to_entries[] | "  \(.key + 1). " + (.value.date | sub("T"; "_") | sub("Z$"; "")) + "  " + .value.file + "  (" + (.value.size|tostring) + " bytes, " + (.value.sessions|tostring) + " sessions)"' "$manifest"
            echo ""
            echo "  view <file> [--json]  ·  verify <file>  ·  prune <N>"
            ;;
        view)   shift; oced_backups_view "$@" ;;
        verify)
            shift
            local f="${1:-}" rec state expect actual
            [ -n "$f" ] || { echo "Usage: opencode-db backups verify <backup-file>"; return 1; }
            rec=$(jq -r --arg f "$f" '.backups[]? | select(.file == $f)' "$manifest")
            [ -n "$rec" ] || { echo "Not in the manifest: $f"; return 1; }
            IFS=$'\t' read -r state expect actual < <(oc_backup_sha_state "$rec")
            case "$state" in
                OK)       echo "[OK]   $f  sha256 matches" ;;
                MISMATCH) echo "[FAIL] $f  sha256 MISMATCH"
                           echo "   manifest: $expect"
                           echo "   file:     $actual" ;;
                *)        echo "File not found: $OCED_BACKUP_DIR/$f" ;;
            esac
            ;;
        remove)
            shift
            local f="${1:-}" yes=0
            [ -n "$f" ] || { echo "Usage: opencode-db backups remove <backup-file> [--yes]"; return 1; }
            [ "${2:-}" = "--yes" ] && yes=1
            local rec
            rec=$(jq -r --arg f "$f" '.backups[]? | select(.file == $f)' "$manifest")
            [ -n "$rec" ] || { echo "Not in the manifest: $f"; return 1; }
            if [ "$yes" -eq 0 ]; then
                local ans
                printf 'Remove backup %s? [y/N] ' "$f"
                read -r ans || return 1
                [[ "$ans" =~ ^[yYsS]$ ]] || { echo "   cancelled."; return 0; }
            fi
            if [ -f "$OCED_BACKUP_DIR/$f" ]; then
                rm -f "$OCED_BACKUP_DIR/$f"
            fi
            manifest_write "$(jq --arg f "$f" '.backups |= map(select(.file != $f))' "$manifest")"
            o_log "backups remove file=$f"
            echo "Removed: $f"
            ;;
        prune)
            shift
            local keep="${1:-}"
            case "$keep" in
                ''|*[!0-9]*) echo "Usage: opencode-db backups prune <N>  (N = how many to keep)"; return 1 ;;
            esac
            [ "$keep" -ge 1 ] || { echo "N must be >= 1"; return 1; }
            local to_delete removed
            to_delete=$(jq -r --argjson k "$keep" '[.backups | sort_by(.date)] | .[0][0:(length - $k)] | .[].file' "$manifest")
            if [ -z "$to_delete" ]; then
                echo "Nothing to prune (have $n, keeping $keep)."
                return 0
            fi
            removed=0
            while IFS= read -r f; do
                [ -z "$f" ] && continue
                if [ -f "$OCED_BACKUP_DIR/$f" ]; then
                    rm -f "$OCED_BACKUP_DIR/$f" && removed=$((removed+1))
                fi
            done <<<"$to_delete"
            manifest_write "$(jq --argjson k "$keep" '.backups |= (sort_by(.date) | .[-$k:])' "$manifest")"
            o_log "backups prune keep=$keep removed=$removed"
            echo "Prune: removed $removed file(s); keeping $keep."
            ;;
        *) echo "Usage: opencode-db backups [list|view <file>|verify <file>|remove <file> [--yes]|prune <N>]"; return 1 ;;
    esac
}