#!/usr/bin/env bash
# view.sh — oced_status / oced_list / oced_info / oced_compactions (read-only, sqlite3 CLI).
set -uo pipefail

o_like_literal() {
    # Escapes a user pattern into a safe SQL single-quoted LIKE literal.
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

oced_status() {
    o_check_deps
    o_db_exists
    echo "== opencode DB =="
    printf '   %-16s %s\n' "Path:" "$OPENCODE_DB"
    local bytes
    bytes=$(stat -c %s "$OPENCODE_DB" 2>/dev/null || echo 0)
    printf '   %-16s %s (%s)\n' "Size:" "$(o_human_size "$bytes")" "$bytes bytes"
    if [ -f "$OPENCODE_DB-wal" ]; then
        local wbytes
        wbytes=$(stat -c %s "$OPENCODE_DB-wal" 2>/dev/null || echo 0)
        printf '   %-16s %s (WAL active, %d bytes not yet checkpointed)\n' "WAL:" "$(o_human_size "$wbytes")" "$wbytes"
        echo "   Use 'backup' (sqlite .backup) for a consistent snapshot, not cp."
    fi

    local tables rc
    tables=$(o_q ".tables" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "   ⚠️  Could not read the tables (possible corruption or locked DB):"
        printf '      %s\n' "$tables"
        return 1
    fi
    printf '   %-16s %s\n' "Tables:" "$(echo "$tables" | tr '\n' ' ')"
    echo ""
    echo "   Data:"
    local sessions messages parts last_ts last_title
    sessions=$(o_q "SELECT count(*) FROM session")
    messages=$(o_q "SELECT count(*) FROM message")
    parts=$(o_q "SELECT count(*) FROM part")
    IFS=$'\t' read -r last_ts last_title <<<"$(o_q -separator $'\t' "SELECT datetime(time_updated/1000,'unixepoch'), title FROM session ORDER BY time_updated DESC LIMIT 1")"
    printf '      %-18s %s\n' "Sessions:" "$sessions"
    printf '      %-18s %s\n' "Messages:" "$messages"
    printf '      %-18s %s\n' "Parts:" "$parts"
    printf '      %-18s %s\n' "Last activity:" "$last_ts  —  $last_title"

    echo ""
    echo "   Backup:"
    local manifest mfile last_idx
    manifest="$OCED_BACKUP_DIR/manifest.json"
    if [ ! -f "$manifest" ]; then
        echo "      No backups recorded yet (run: opencode-db backup)."
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
        echo "      Last: $OCED_BACKUP_DIR/$mfile"
        printf '      %-18s %s\n' "Created:" "$(jq -r --argjson i "$last_idx" '.backups[$i].date' "$manifest")"
        if [ "$msess" = "$tsess" ] && [ "$mmess" = "$tmess" ] && [ "$mu" = "$tu" ]; then
            echo "      ✅ Aligned with the current DB (same sessions/messages/last activity)."
        else
            echo "      ⚠️  Out of sync with the current DB (it changed after that backup)."
            [ "$msess" != "$tsess" ] && echo "         sessions: $msess → $tsess"
            [ "$mmess" != "$tmess" ] && echo "         messages: $mmess → $tmess"
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
            --filter) [ "$#" -ge 2 ] || o_die "--filter needs a pattern"; filter="$2"; shift ;;
            --info) showinfo=1 ;;
            *) o_die "Unknown argument: $1" ;;
        esac
        shift
    done

    local where="" col_extra=""
    case "$scope" in
        root) where="WHERE (s.parent_id IS NULL OR s.parent_id = '' OR (SELECT count(*) FROM session p WHERE p.id = s.parent_id) = 0)" ;;
        sub)  where="WHERE (s.parent_id IS NOT NULL AND s.parent_id != '')" ;;
    esac
    [ -n "$filter" ] && { [ -n "$where" ] && where+=" AND" || where+=" WHERE"; where+=" (s.id LIKE $(o_like_literal "$filter") OR s.title LIKE $(o_like_literal "$filter"))"; }

    local cols="s.id AS ID, coalesce(NULLIF(s.title,''), s.slug) AS TITLE, datetime(s.time_created/1000,'unixepoch') AS CREATED, datetime(s.time_updated/1000,'unixepoch') AS UPDATED, coalesce(s.agent,'') AS AGENT, coalesce(p.title,'') AS PARENT, s.directory AS DIR"
    [ "$showinfo" -eq 1 ] && cols="$cols, s.tokens_input AS TOK_IN, s.tokens_output AS TOK_OUT, s.cost AS COST"

    echo "== Sessions ($scope) =="
    o_q -header -column "SELECT $cols FROM session s LEFT JOIN session p ON p.id = s.parent_id $where ORDER BY s.time_created;"
}

oced_info() {
    o_check_deps
    o_db_exists
    local id="${1:-}"
    [ -n "$id" ] || o_die "Usage: opencode-db info <session_id>"
    local row rc
    row=$(o_q -line "
        SELECT
            s.id, s.slug, s.title, coalesce(s.agent,'') AS agent, s.model, s.directory, s.version,
            datetime(s.time_created/1000,'unixepoch') AS created, datetime(s.time_updated/1000,'unixepoch') AS updated,
            datetime(s.time_archived/1000,'unixepoch') AS archived,
            datetime(s.time_compacting/1000,'unixepoch') AS compacted,
            s.share_url, s.cost, s.tokens_input, s.tokens_output, s.tokens_reasoning,
            s.tokens_cache_read, s.tokens_cache_write,
            coalesce(p.title,'') AS parent_title, s.parent_id,
            (SELECT count(*) FROM session c WHERE c.parent_id = s.id) AS subagents,
            (SELECT count(*) FROM message m WHERE m.session_id = s.id) AS messages,
            (SELECT count(*) FROM part pt WHERE pt.session_id = s.id) AS parts,
            (SELECT count(*) FROM session_input i WHERE i.session_id = s.id) AS inputs
        FROM session s LEFT JOIN session p ON p.id = s.parent_id
        WHERE s.id = '${id//\'/\'\'}' LIMIT 1;" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then echo "$row" >&2; return 1; fi
    if [ -z "$row" ] || ! grep -q . <<<"$row"; then
        echo "Session not found: $id"
        echo "Try: opencode-db list"
        return 1
    fi
    echo "$row"
    echo ""
    oced_compactions "$id" || true
}

oced_compactions() {
    o_check_deps
    o_db_exists
    local id="${1:-}"
    [ -n "$id" ] || o_die "Usage: opencode-db compactions <session_id> [show [last|N|all]]"
    local n rc
    n=$(o_q "SELECT count(*) FROM part WHERE session_id='${id//\'/\'\'}' AND json_extract(data,'\$.type')='compaction'")
    echo "== Compactions ($id) =="
    echo "   Total: $n"
    [ "$n" = "0" ] && { echo "   (no compactions)"; return 0; }
    o_q -header -column "
        SELECT
            datetime(pt.time_created/1000,'unixepoch') AS DATE,
            json_extract(pt.data,'\$.tail_start_id') AS NEW_QUEUE,
            json_extract(pt.data,'\$.auto') AS AUTO
        FROM part pt
        WHERE pt.session_id='${id//\'/\'\'}' AND json_extract(pt.data,'\$.type')='compaction'
        ORDER BY pt.time_created;"
    if [ "${2:-}" = "show" ]; then
        oced_compactions_digest "$id" "${3:-all}"
    fi
}

# oced_compactions_digest <id> <last|N|all> -> the compacted-context summary
# stored in the following "mode=compaction" assistant message.
oced_compactions_digest() {
    local id="${1//\'/\'\'}" sel="${2:-all}"
    local markers digests
    markers=$(o_q "SELECT json_group_array(
        json_object('tc', time_created, 'date', datetime(time_created/1000,'unixepoch'),
                    'tail', coalesce(json_extract(data,'\$.tail_start_id'),''),
                    'auto', coalesce(json_extract(data,'\$.auto'),1),
                    'overflow', coalesce(json_extract(data,'\$.overflow'),0)))
        FROM part WHERE session_id='$id' AND json_extract(data,'\$.type')='compaction' ORDER BY time_created;")
    digests=$(o_q "SELECT json_group_array(
        json_object('tc', m.time_created, 'text', (
            SELECT group_concat(json_extract(p.data,'\$.text'), char(10))
            FROM part p WHERE p.message_id=m.id AND json_extract(p.data,'\$.type')='text')))
        FROM message m WHERE m.session_id='$id'
            AND json_extract(m.data,'\$.mode')='compaction'
        ORDER BY m.time_created;")
    printf '%s\n' "$markers" "$digests" | jq -rn --arg sel "$sel" 'input as $M | input as $D |
        ($M|length) as $L |
        ((($sel=="last") | if . then 1 else null end) // ($sel|tonumber?)) as $cnt |
        (if $cnt == null then 0 else ([$L-$cnt,0]|max) end) as $start |
        range($start; $L) as $i |
        ($D | map(select(.tc >= $M[$i].tc)) | first? // null) as $d |
        ("--- " + $M[$i].date + "  auto:" + ($M[$i].auto|tostring) + "  overflow:" + ($M[$i].overflow|tostring) + "  new queue: " + $M[$i].tail + " ---"),
        (($d.text) // "(no digest message found)"),
        ""'
}