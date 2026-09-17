#!/usr/bin/env bash
# view.sh — oced_status / oced_list / oced_info / oced_compact (read-only, sqlite3 CLI).
set -uo pipefail

o_like_literal() {
    # Escapes a user pattern into a safe SQL single-quoted LIKE literal.
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

oced_status() {
    o_check_deps
    o_db_exists
    echo "== opencode DB =="
    printf '   %-16s %s\n' "Ruta:" "$OPENCODE_DB"
    local bytes
    bytes=$(stat -c %s "$OPENCODE_DB" 2>/dev/null || echo 0)
    printf '   %-16s %s (%s)\n' "Tamaño:" "$(o_human_size "$bytes")" "$bytes bytes"
    if [ -f "$OPENCODE_DB-wal" ]; then
        local wbytes
        wbytes=$(stat -c %s "$OPENCODE_DB-wal" 2>/dev/null || echo 0)
        printf '   %-16s %s (WAL activo, %d bytes sin checkpoint)\n' "OJO WAL:" "$(o_human_size "$wbytes")" "$wbytes"
        echo "   Usa 'backup' (sqlite .backup) para un snapshot consistente, no cp."
    fi

    local tables rc
    tables=$(o_q ".tables" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "   ⚠️  No se pudieron leer las tablas (posible corrupción o DB bloqueada):"
        printf '      %s\n' "$tables"
        return 1
    fi
    printf '   %-16s %s\n' "Tablas:" "$(echo "$tables" | tr '\n' ' ')"
    echo ""
    echo "   Datos:"
    local sessions messages parts last_ts last_title
    sessions=$(o_q "SELECT count(*) FROM session")
    messages=$(o_q "SELECT count(*) FROM message")
    parts=$(o_q "SELECT count(*) FROM part")
    IFS=$'\t' read -r last_ts last_title <<<"$(o_q -separator $'\t' "SELECT datetime(time_updated/1000,'unixepoch'), title FROM session ORDER BY time_updated DESC LIMIT 1")"
    printf '      %-18s %s\n' "Sesiones:" "$sessions"
    printf '      %-18s %s\n' "Mensajes:" "$messages"
    printf '      %-18s %s\n' "Partes:" "$parts"
    printf '      %-18s %s\n' "Última activity:" "$last_ts  —  $last_title"

    echo ""
    echo "   Backup:"
    local manifest mfile last_idx
    manifest="$OCED_BACKUP_DIR/manifest.json"
    if [ ! -f "$manifest" ]; then
        echo "      Sin backups registrados aún (ejecuta: opencode-db.sh backup)."
    else
        last_idx=$(jq -r '.backups | length - 1' "$manifest")
        mfile=$(jq -r --argjson i "$last_idx" '.backups[$i].file' "$manifest")
        local msess mmess mu mt tsess tmess tu
        msess=$(jq -r --argjson i "$last_idx" '.backups[$i].sessions' "$manifest")
        mmess=$(jq -r --argjson i "$last_idx" '.backups[$i].messages' "$manifest")
        mu=$(jq -r --argjson i "$last_idx" '.backups[$i].max_updated' "$manifest")
        tsess=$(o_q "SELECT count(*) FROM session")
        tmess=$(o_q "SELECT count(*) FROM message")
        tu=$(o_q "SELECT max(time_updated) FROM session")
        echo "      Último: $OCED_BACKUP_DIR/$mfile"
        printf '      %-18s %s\n' "Creado:" "$(jq -r --argjson i "$last_idx" '.backups[$i].date' "$manifest")"
        if [ "$msess" = "$tsess" ] && [ "$mmess" = "$tmess" ] && [ "$mu" = "$tu" ]; then
            echo "      ✅ Alineado con la DB actual (mismas sesiones/mensajes/última actividad)."
        else
            echo "      ⚠️  Desalineado con la DB actual (la DB ha cambiado tras ese backup)."
            [ "$msess" != "$tsess" ] && echo "         sesiones: $msess → $tsess"
            [ "$mmess" != "$tmess" ] && echo "         mensajes: $mmess → $tmess"
        fi
    fi
}

oced_list() {
    o_check_deps
    o_db_exists
    local scope=all filter="" showinfo=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --root) scope=root ;;
            --sub) scope=sub ;;
            --all) scope=all ;;
            --filter) [ "$#" -ge 2 ] || o_die "--filter necesita un patrón"; filter="$2"; shift ;;
            --info) showinfo=1 ;;
            *) o_die "Argumento desconocido: $1" ;;
        esac
        shift
    done

    local where="" col_extra=""
    case "$scope" in
        root) where="WHERE (s.parent_id IS NULL OR s.parent_id = '' OR (SELECT count(*) FROM session p WHERE p.id = s.parent_id) = 0)" ;;
        sub)  where="WHERE (s.parent_id IS NOT NULL AND s.parent_id != '')" ;;
    esac
    [ -n "$filter" ] && { [ -n "$where" ] && where+=" AND" || where+=" WHERE"; where+=" (s.id LIKE $(o_like_literal "$filter") OR s.title LIKE $(o_like_literal "$filter"))"; }

    local cols="s.id AS ID, coalesce(NULLIF(s.title,''), s.slug) AS TITULO, datetime(s.time_created/1000,'unixepoch') AS CREADA, datetime(s.time_updated/1000,'unixepoch') AS ACTUALIZADA, coalesce(s.agent,'') AS AGENTE, coalesce(p.title,'') AS PADRE, s.directory AS DIR"
    [ "$showinfo" -eq 1 ] && cols="$cols, s.tokens_input AS TOK_IN, s.tokens_output AS TOK_OUT, s.cost AS COSTE"

    echo "== Sesiones ($scope) =="
    o_q -header -column "SELECT $cols FROM session s LEFT JOIN session p ON p.id = s.parent_id $where ORDER BY s.time_created;"
}

oced_info() {
    o_check_deps
    o_db_exists
    local id="${1:-}"
    [ -n "$id" ] || o_die "Uso: opencode-db.sh info <session_id>"
    local row rc
    row=$(o_q -line "
        SELECT
            s.id, s.slug, s.title, coalesce(s.agent,'') AS agent, s.model, s.directory, s.version,
            datetime(s.time_created/1000,'unixepoch') AS creada, datetime(s.time_updated/1000,'unixepoch') AS actualizada,
            datetime(s.time_archived/1000,'unixepoch') AS archivada,
            datetime(s.time_compacting/1000,'unixepoch') AS compactado,
            s.share_url, s.cost, s.tokens_input, s.tokens_output, s.tokens_reasoning,
            s.tokens_cache_read, s.tokens_cache_write,
            coalesce(p.title,'') AS parent_title, s.parent_id,
            (SELECT count(*) FROM session c WHERE c.parent_id = s.id) AS subagentes,
            (SELECT count(*) FROM message m WHERE m.session_id = s.id) AS mensajes,
            (SELECT count(*) FROM part pt WHERE pt.session_id = s.id) AS partes,
            (SELECT count(*) FROM session_input i WHERE i.session_id = s.id) AS inputs
        FROM session s LEFT JOIN session p ON p.id = s.parent_id
        WHERE s.id = '${id//\'/\'\'}' LIMIT 1;" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then echo "$row" >&2; return 1; fi
    if [ -z "$row" ] || ! grep -q . <<<"$row"; then
        echo "No se encontró la sesión: $id"
        echo "Prueba: opencode-db.sh list"
        return 1
    fi
    echo "$row"
    echo ""
    oced_compact "$id" || true
}

oced_compact() {
    o_check_deps
    o_db_exists
    local id="${1:-}"
    [ -n "$id" ] || o_die "Uso: opencode-db.sh compactaciones <session_id>"
    local n rc
    n=$(o_q "SELECT count(*) FROM part WHERE session_id='${id//\'/\'\'}' AND json_extract(data,'\$.type')='compaction'")
    echo "== Compactaciones ($id) =="
    echo "   Total: $n"
    [ "$n" = "0" ] && { echo "   (sin compactaciones)"; return 0; }
    o_q -header -column "
        SELECT
            datetime(pt.time_created/1000,'unixepoch') AS FECHA,
            json_extract(pt.data,'\$.tail_start_id') AS NUEVA_COLA,
            json_extract(pt.data,'\$.auto') AS AUTO
        FROM part pt
        WHERE pt.session_id='${id//\'/\'\'}' AND json_extract(pt.data,'\$.type')='compaction'
        ORDER BY pt.time_created;"
}