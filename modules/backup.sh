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

oced_backup() {
    o_check_deps
    o_db_exists
    local compress="$OCED_COMPRESS"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --no-compress) compress=0 ;;
            *) o_die "Argumento desconocido: $1" ;;
        esac
        shift
    done

    mkdir -p "$OCED_BACKUP_DIR"
    local ts stamp snap rc sha size_raw
    ts=$(o_ts)
    stamp=$(o_now_utc)
    snap=$(mktemp /tmp/opencode-db-snap-XXXXXX.db)
    trap 'rm -f -- "${snap:-}" "${snap:-}.gz" /tmp/oced-backup.err' EXIT

    echo "-> Snapshot consistente (sqlite .backup) de $OPENCODE_DB ..."
    rc=1
    for attempt in 1 2 3; do
        if sqlite3 "$OPENCODE_DB" ".backup '$snap'" 2>/tmp/oced-backup.err; then
            rc=0; break
        fi
        echo "   (intento $attempt: DB ocupada, reintento en 2s)"
        sleep 2
    done
    if [ "$rc" -ne 0 ]; then
        cat /tmp/oced-backup.err >&2
        o_die "No se pudo crear el snapshot."
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

    echo "✅ Backup: $fpath"
    printf '   %-16s %s\n' "Creado:" "$stamp"
    printf '   %-16s %s\n' "Tamaño:" "$(o_human_size "$fsize") (raw $(o_human_size "$size_raw"))"
    printf '   %-16s %s\n' "Sesiones:" "$sess"
    printf '   %-16s %s\n' "sha256:" "$fsha"
    echo "   Alineación: compruébala con: opencode-db.sh status"
}

oced_backups() {
    local manifest; manifest=$(manifest_path)
    [ -f "$manifest" ] || { echo "No hay backups registrados."; return 0; }
    local n
    n=$(jq -r '.backups | length' "$manifest")
    case "${1:-list}" in
        list)
            echo "== Backups ($n) =="
            jq -r '.backups | sort_by(.date) | reverse | to_entries[] | "  \(.key + 1). " + .value.date + "  " + .value.file + "  (" + (.value.size|tostring) + " bytes, " + (.value.sessions|tostring) + " sesiones)"' "$manifest"
            echo ""
            echo "  verify <file>  ·  prune <N>"
            ;;
        verify)
            local f="${2:-}"
            [ -n "$f" ] || { echo "Uso: opencode-db.sh backups verify <backup-file>"; return 1; }
            local rec
            rec=$(jq -r --arg f "$f" '.backups[] | select(.file == $f)' "$manifest")
            [ -n "$rec" ] || { echo "No está en el manifiesto: $f"; return 1; }
            local expect actual
            expect=$(printf '%s' "$rec" | jq -r '.sha256')
            if [ -f "$OCED_BACKUP_DIR/$f" ]; then
                actual=$(sha256sum "$OCED_BACKUP_DIR/$f" | cut -d' ' -f1)
                [ "$actual" = "$expect" ] && echo "✅ $f  OK (sha256 coincide)" \
                    || { echo "❌ $f  sha256 NO coincide"; echo "   manifiesto: $expect"; echo "   archivo:    $actual"; }
            else
                echo "No existe el archivo: $OCED_BACKUP_DIR/$f"
            fi
            ;;
        prune)
            local keep="${2:-}"
            case "$keep" in
                ''|*[!0-9]*) echo "Uso: opencode-db.sh backups prune <N>  (N = cuántos mantener)"; return 1 ;;
            esac
            [ "$keep" -ge 1 ] || { echo "N debe ser >= 1"; return 1; }
            local to_delete removed
            to_delete=$(jq -r --argjson k "$keep" '[.backups | sort_by(.date)] | .[0][0:(length - $k)] | .[].file' "$manifest")
            if [ -z "$to_delete" ]; then
                echo "Nada que podar (hay $n, se mantienen $keep)."
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
            echo "Prune: eliminados $removed archivos; quedan $keep."
            ;;
        *) echo "Uso: opencode-db.sh backups [list|verify <file>|prune <N>]"; return 1 ;;
    esac
}