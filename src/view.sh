#!/usr/bin/env bash
# view.sh — oced_status / oced_list / oced_info / oced_digest (read-only, sqlite3 CLI).
set -uo pipefail

o_like_literal() {
    # Escapes a user pattern into a safe SQL single-quoted LIKE literal.
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

# `list --order` vocabulary (axis + direction, comma-separated for messages).
# The default is created-asc (the historical order, i.e. oldest first); the
# shrink sessions picker asks for updated-desc (most recently used first).
OCED_LIST_ORDERS="created-asc, created-desc, updated-asc, updated-desc"

# o_version_block -> tool version + opencode CLI version + migrations (3-space prefix).
o_version_block() {
    local oc_version mig_count mig_last
    oc_version=$(o_q "SELECT COALESCE(max(version),'unknown') FROM session" 2>/dev/null || echo unknown)
    printf '   %-16s %s\n' "opencode-db:" "$OCED_VERSION (tool)"
    printf '   %-16s %s\n' "opencode:" "$oc_version (CLI, max session.version)"
    mig_count=$(o_q "SELECT count(*) FROM migration" 2>/dev/null || echo 0)
    mig_last=$(o_q "SELECT id FROM migration ORDER BY time_completed DESC LIMIT 1" 2>/dev/null || echo "")
    printf '   %-16s %s\n' "Migrations:" "$mig_count"
    printf '   %-16s %s\n' "Latest migr.:" "$mig_last"
}

# o_schema_probe -> prints the schema probe block; returns 0 when compatible.
o_schema_probe() {
    local tables
    tables=$(o_q "SELECT name FROM sqlite_master WHERE type='table'" 2>/dev/null || true)
    local t missing_tables=()
    for t in $OCED_EXPECTED_TABLES; do
        printf '%s\n' "$tables" | grep -qx "$t" || missing_tables+=("$t")
    done

    local spec tbl cols have col
    local missing_cols=()
    while IFS= read -r spec; do
        [ -n "$spec" ] || continue
        tbl="${spec%%:*}"
        cols="${spec#*:}"
        printf '%s\n' "$tables" | grep -qx "$tbl" || continue  # missing table already reported
        have=$(o_q "SELECT group_concat(name,',') FROM pragma_table_info('$tbl')" 2>/dev/null || true)
        local -a carr=()
        IFS=',' read -r -a carr <<<"$cols"
        for col in "${carr[@]}"; do
            [ -n "$col" ] || continue
            case ",$have," in
                *",$col,"*) ;;
                *) missing_cols+=("$tbl.$col") ;;
            esac
        done
    done <<<"$OCED_EXPECTED_COLUMNS"

    if [ "${#missing_tables[@]}" -eq 0 ] && [ "${#missing_cols[@]}" -eq 0 ]; then
        echo "      [OK]  All expected tables and columns are present."
        return 0
    fi
    [ "${#missing_tables[@]}" -gt 0 ] && echo "      [!]  Missing tables: ${missing_tables[*]}"
    [ "${#missing_cols[@]}" -gt 0 ] && echo "      [!]  Missing columns: ${missing_cols[*]}"
    echo "      The opencode DB schema may have changed; some commands may fail."
    return 1
}

# o_deps_report -> lists core/optional dependency presence (no sudo). rc=0 always.
o_deps_report() {
    local dep
    for dep in sqlite3 python3 jq gzip; do
        if o_have "$dep"; then printf '      OK        %s\n' "$dep"; else printf '      MISSING   %s\n' "$dep"; fi
    done
    if o_have fzf; then printf '      OK        %s (menu)\n' fzf; else printf '      MISSING   %s (menu, optional)\n' fzf; fi
}

oced_status() {
    o_check_deps
    o_db_exists
    local db_path
    db_path=$(o_effective_db)
    echo "== opencode DB =="
    printf '   %-16s %s\n' "Path:" "$db_path"
    if [ -n "${OCED_FROM_BACKUP:-}" ]; then
        printf '   %-16s %s\n' "Source:" "backup (${OCED_FROM_BACKUP})"
        local align
        align=$(o_backup_aligned 2>/dev/null || echo "unknown")
        if [ "$align" = "aligned" ]; then
            printf '   %-16s %s\n' "Alignment:" "[OK] aligned with live DB"
        elif [ "$align" = "out of sync" ]; then
            printf '   %-16s %s\n' "Alignment:" "[!] OUT OF SYNC with live DB"
        else
            printf '   %-16s %s\n' "Alignment:" "unknown"
        fi
    fi
    local bytes
    bytes=$(stat -c %s "$db_path" 2>/dev/null || echo 0)
    printf '   %-16s %s (%s)\n' "Size:" "$(o_human_size "$bytes")" "$bytes bytes"
    printf '   %-16s %s\n' "Exports:" "$OCED_OUT"
    printf '   %-16s %s\n' "Backups:" "$OCED_BACKUP_DIR"
    if [ -z "${OCED_FROM_BACKUP:-}" ] && [ -f "$OPENCODE_DB-wal" ]; then
        local wbytes
        wbytes=$(stat -c %s "$OPENCODE_DB-wal" 2>/dev/null || echo 0)
        printf '   %-16s %s (WAL active, %d bytes not yet checkpointed)\n' "WAL:" "$(o_human_size "$wbytes")" "$wbytes"
        echo "   Use 'backup' (sqlite .backup) for a consistent snapshot, not cp."
    fi
    if [ "$bytes" -ge 1073741824 ]; then
        echo ""
        echo "   [!]  DB is over 1 GiB. It only grows: deleting sessions frees pages for"
        echo "        reuse but does NOT shrink the file. To reclaim space:"
        echo "          1. opencode-db backup                     (safe snapshot first)"
        echo "          2. opencode-db exports prune N            (drop old export runs)"
        echo "          3. opencode-db shrink --older-than 90         (pruned + VACUUMed copy)"
        echo "        shrink never writes to the live DB; it writes a copy you swap manually."
    fi

    local tables rc
    tables=$(o_q ".tables" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "   [!]  Could not read the tables (possible corruption or locked DB):"
        printf '      %s\n' "$tables"
        return 1
    fi
    local tnames
    tnames=$(printf '%s\n' "$tables" | tr ' ' '\n' | sed '/^[[:space:]]*$/d')
    printf '   %-16s\n' "Tables:"
    if command -v column >/dev/null 2>&1; then
        printf '%s\n' "$tnames" | column -c "$(tput cols 2>/dev/null || echo 80)" | sed 's/^/      /'
    else
        local -a tarr=($tnames)
        local i
        for ((i = 0; i < ${#tarr[@]}; i += 4)); do
            printf '      %-20s%-20s%-20s%s\n' "${tarr[i]:-}" "${tarr[i+1]:-}" "${tarr[i+2]:-}" "${tarr[i+3]:-}"
        done
    fi
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
            echo "      [OK]  Aligned with the current DB (same sessions/messages/last activity)."
        else
            echo "      [!]  Out of sync with the current DB (it changed after that backup)."
            [ "$msess" != "$tsess" ] && echo "         sessions: $msess → $tsess"
            [ "$mmess" != "$tmess" ] && echo "         messages: $mmess → $tmess"
        fi
    fi

    echo ""
    echo "   Version / schema:"
    o_version_block
    echo "   Schema probe:"
    o_schema_probe || true

    echo ""
    echo "   Dependencies:"
    o_deps_report
}

# oced_version -> tool version, the opencode CLI version and a schema probe.
# Returns 0 when the schema looks compatible, 1 when something expected is missing.
oced_version() {
    o_check_deps
    o_db_exists
    local db_path
    db_path=$(o_effective_db)
    echo "== opencode-db =="
    printf '   %-16s %s\n' "Path:" "$db_path"
    [ -n "${OCED_FROM_BACKUP:-}" ] && printf '   %-16s %s\n' "Source:" "backup (${OCED_FROM_BACKUP})"
    o_version_block

    echo ""
    echo "   Schema probe:"
    o_schema_probe
}

oced_list() {
    o_check_deps
    o_db_exists
    local scope=all filter="" showinfo=0 order=created-asc oby="" odir="" tsv=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --root) scope=root ;;
            --sub) scope=sub ;;
            --all) scope=all ;;
            --filter) [ "$#" -ge 2 ] || o_die "--filter needs a pattern"; filter="$2"; shift ;;
            --info) showinfo=1 ;;
            --tsv) tsv=1 ;;
            --order)
                [ "$#" -ge 2 ] || o_die "--order needs a value ($OCED_LIST_ORDERS)"
                order="$2"; shift ;;
            *) o_die "Unknown argument: $1" ;;
        esac
        shift
    done
    # --order is a WHITELIST (no interpolation of the raw value): the axis and
    # the direction are picked apart and the SQL is rebuilt from constants.
    case "$order" in
        created-asc)  oby="s.time_created";     odir="ASC"  ;;
        created-desc) oby="s.time_created";     odir="DESC" ;;
        updated-asc)  oby="s.time_updated";     odir="ASC"  ;;
        updated-desc) oby="s.time_updated";     odir="DESC" ;;
        *) o_die "Unknown --order '$order' (choose: $OCED_LIST_ORDERS)" ;;
    esac
    # A tie on the ordering axis always falls back to time_created (same
    # direction), so the order is total and stable; when the axis already IS
    # time_created there is nothing left to break.
    local orderby="$oby $odir"
    [ "$oby" = "s.time_created" ] || orderby="$orderby, s.time_created $odir"

    local where="" col_extra=""
    case "$scope" in
        root) where="WHERE (s.parent_id IS NULL OR s.parent_id = '' OR (SELECT count(*) FROM session p WHERE p.id = s.parent_id) = 0)" ;;
        sub)  where="WHERE (s.parent_id IS NOT NULL AND s.parent_id != '')" ;;
    esac
    [ -n "$filter" ] && { [ -n "$where" ] && where+=" AND" || where+=" WHERE"; where+=" (s.id LIKE $(o_like_literal "$filter") OR s.title LIKE $(o_like_literal "$filter"))"; }

    local cols="s.id AS ID, coalesce(NULLIF(s.title,''), s.slug) AS TITLE, datetime(s.time_created/1000,'unixepoch') AS CREATED, datetime(s.time_updated/1000,'unixepoch') AS UPDATED, coalesce(s.agent,'') AS AGENT, coalesce(p.title,'') AS PARENT, s.directory AS DIR"
    [ "$showinfo" -eq 1 ] && cols="$cols, s.tokens_input AS TOK_IN, s.tokens_output AS TOK_OUT, s.cost AS COST"

    if [ "$tsv" -eq 1 ]; then
        # The MENU feed: clean tab-separated rows, no -column padding, no banner
        # and no token/cost columns (the picker builds its own label from these
        # fields). PARENT_ID and DIRECTORY travel too so the row can render the
        # compact `→ <shortid_word>` parent token and the session's own path.
        o_q -separator $'\t' "
            SELECT s.id,
                   coalesce(NULLIF(s.title,''), s.slug),
                   datetime(s.time_created/1000,'unixepoch'),
                   datetime(s.time_updated/1000,'unixepoch'),
                   coalesce(s.agent,''),
                   coalesce(p.id,''),
                   coalesce(p.title,''),
                   coalesce(s.directory,'')
            FROM session s LEFT JOIN session p ON p.id = s.parent_id
            $where ORDER BY $orderby;"
        return 0
    fi

    echo "== Sessions ($scope) =="
    o_q -header -column "SELECT $cols FROM session s LEFT JOIN session p ON p.id = s.parent_id $where ORDER BY $orderby;"
}

oced_info() {
    o_check_deps
    o_db_exists
    local id="${1:-}" json_mode=0 want_digest=1
    [ -n "$id" ] || o_die "Usage: opencode-db info <session_id> [--json] [--no-digest]"
    # The digest block is a REPORT section, not part of the row: the browse
    # screen offers a compactions toggle and it has to be able to hide it.
    # --json never carries it either way, so the flag is ignored in that mode.
    case "${2:-}" in
        --json) json_mode=1 ;;
        --no-digest) want_digest=0 ;;
        "") ;;
        *) o_die "Usage: opencode-db info <session_id> [--json] [--no-digest]" ;;
    esac
    
    if [ "$json_mode" -eq 1 ]; then
        o_q -json "
            SELECT
                s.id, s.slug, s.title, s.project_id,
                coalesce(s.agent,'') AS agent, s.model, s.directory, s.version,
                datetime(s.time_created/1000,'unixepoch') AS created,
                datetime(s.time_updated/1000,'unixepoch') AS updated,
                datetime(s.time_archived/1000,'unixepoch') AS archived,
                datetime(s.time_compacting/1000,'unixepoch') AS compacted,
                s.share_url, s.cost, s.tokens_input, s.tokens_output, s.tokens_reasoning,
                s.tokens_cache_read, s.tokens_cache_write,
                coalesce(p.title,'') AS parent_title, s.parent_id,
                (SELECT count(*) FROM session c WHERE c.parent_id = s.id) AS subagents,
                (SELECT count(*) FROM message m WHERE m.session_id = s.id) AS messages,
                (SELECT count(*) FROM part pt WHERE pt.session_id = s.id) AS parts,
                (SELECT count(*) FROM session_input i WHERE i.session_id = s.id) AS inputs,
                (SELECT count(*) FROM todo t WHERE t.session_id = s.id AND t.status != 'done') AS todos_open,
                (SELECT count(*) FROM todo t WHERE t.session_id = s.id AND t.status = 'done') AS todos_done,
                (SELECT count(*) FROM part pt WHERE pt.session_id = s.id AND json_extract(pt.data,'$.type')='text') AS parts_text,
                (SELECT count(*) FROM part pt WHERE pt.session_id = s.id AND json_extract(pt.data,'$.type')='reasoning') AS parts_reasoning,
                (SELECT count(*) FROM part pt WHERE pt.session_id = s.id AND json_extract(pt.data,'$.type')='tool') AS parts_tool,
                (SELECT count(*) FROM part pt WHERE pt.session_id = s.id AND json_extract(pt.data,'$.type')='patch') AS parts_patch,
                (SELECT count(*) FROM part pt WHERE pt.session_id = s.id AND json_extract(pt.data,'$.type')='file') AS parts_file,
                (SELECT count(*) FROM part pt WHERE pt.session_id = s.id AND json_extract(pt.data,'$.type')='step-start') AS parts_step_start,
                (SELECT count(*) FROM part pt WHERE pt.session_id = s.id AND json_extract(pt.data,'$.type')='step-finish') AS parts_step_finish,
                (SELECT count(*) FROM part pt WHERE pt.session_id = s.id AND json_extract(pt.data,'$.type')='compaction') AS parts_compaction
            FROM session s LEFT JOIN session p ON p.id = s.parent_id
            WHERE s.id = '${id//\'/\'\'}' LIMIT 1;" 2>&1
        return 0
    fi

    local row rc
    row=$(o_q -line "
        SELECT
            s.id, s.slug, s.title, s.project_id,
            coalesce(s.agent,'') AS agent, s.model, s.directory, s.version,
            datetime(s.time_created/1000,'unixepoch') AS created,
            datetime(s.time_updated/1000,'unixepoch') AS updated,
            datetime(s.time_archived/1000,'unixepoch') AS archived,
            datetime(s.time_compacting/1000,'unixepoch') AS compacted,
            s.share_url, s.cost, s.tokens_input, s.tokens_output, s.tokens_reasoning,
            s.tokens_cache_read, s.tokens_cache_write,
            coalesce(p.title,'') AS parent_title, s.parent_id,
            (SELECT count(*) FROM session c WHERE c.parent_id = s.id) AS subagents,
            (SELECT count(*) FROM message m WHERE m.session_id = s.id) AS messages,
            (SELECT count(*) FROM part pt WHERE pt.session_id = s.id) AS parts,
            (SELECT count(*) FROM session_input i WHERE i.session_id = s.id) AS inputs,
            (SELECT count(*) FROM todo t WHERE t.session_id = s.id AND t.status != 'done') AS todos_open,
            (SELECT count(*) FROM todo t WHERE t.session_id = s.id AND t.status = 'done') AS todos_done,
            (SELECT count(*) FROM part pt WHERE pt.session_id = s.id AND json_extract(pt.data,'$.type')='text') AS parts_text,
            (SELECT count(*) FROM part pt WHERE pt.session_id = s.id AND json_extract(pt.data,'$.type')='reasoning') AS parts_reasoning,
            (SELECT count(*) FROM part pt WHERE pt.session_id = s.id AND json_extract(pt.data,'$.type')='tool') AS parts_tool,
            (SELECT count(*) FROM part pt WHERE pt.session_id = s.id AND json_extract(pt.data,'$.type')='patch') AS parts_patch,
            (SELECT count(*) FROM part pt WHERE pt.session_id = s.id AND json_extract(pt.data,'$.type')='file') AS parts_file,
            (SELECT count(*) FROM part pt WHERE pt.session_id = s.id AND json_extract(pt.data,'$.type')='step-start') AS parts_step_start,
            (SELECT count(*) FROM part pt WHERE pt.session_id = s.id AND json_extract(pt.data,'$.type')='step-finish') AS parts_step_finish,
            (SELECT count(*) FROM part pt WHERE pt.session_id = s.id AND json_extract(pt.data,'$.type')='compaction') AS parts_compaction
        FROM session s LEFT JOIN session p ON p.id = s.parent_id
        WHERE s.id = '${id//\'/\'\'}' LIMIT 1;" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then echo "$row" >&2; return 1; fi
    if [ -z "$row" ] || ! grep -q . <<<"$row"; then
        echo "Session not found: $id"
        echo "Try: opencode-db list"
        return 1
    fi
    # Banner first: the raw `key = value` dump is unreadable without the id/title
    # in front of it (same shape as the `== Digests ($id) — $title ==` header).
    local title
    title=$(sed -n 's/^ *title *= *//p' <<<"$row")
    [ -n "$title" ] || title=$(sed -n 's/^ *slug *= *//p' <<<"$row")
    echo "== Session ($id)${title:+ — $title} =="
    echo ""
    echo "$row"
    [ "$want_digest" -eq 1 ] || return 0
    echo ""
    oced_digest "$id" || true
}

# oced_digest <id> [show [last|N|all]]
# Two DIFFERENT things, labelled separately so they cannot be confused:
#   a compaction MARKER is the event opencode records as a part with
#     data.type='compaction' (when the history was compressed, auto/overflow,
#     where the new queue starts) and carries no text of its own;
#   a DIGEST is the summary the assistant wrote FOR that event: the `text` part
#     of the next message, whose data.mode='compaction' (Objective, Next Moves…).
# The default view lists the markers; `show` prints the digest text.
oced_digest() {
    o_check_deps
    o_db_exists
    local id="${1:-}"
    [ -n "$id" ] || o_die "Usage: opencode-db digest <session_id> [show [last|N|all]]"
    local title agent sess_row
    sess_row=$(o_q -separator $'\t' "SELECT coalesce(NULLIF(title,''),slug), coalesce(agent,'') FROM session WHERE id='${id//\'/\'\'}' LIMIT 1")
    if [ -n "$sess_row" ]; then
        IFS=$'\t' read -r title agent <<<"$sess_row"
    fi
    local n ndig
    n=$(o_q "SELECT count(*) FROM part WHERE session_id='${id//\'/\'\'}' AND json_extract(data,'\$.type')='compaction'")
    ndig=$(o_q "SELECT count(*) FROM message WHERE session_id='${id//\'/\'\'}' AND json_extract(data,'\$.mode')='compaction'")
    echo "== Digests ($id)${title:+ — $title} =="
    [ -n "$agent" ] && printf '   %-19s %s\n' "Agent:" "$agent"
    printf '   %-19s %s\n' "Compaction markers:" "$n"
    printf '   %-19s %s\n' "Digests:" "$ndig"
    if [ "$n" = "0" ]; then
        echo "   (no compaction markers)"
        [ "$ndig" != "0" ] && echo "   (but there are digests: run 'digest $id show')"
        return 0
    fi
    o_q -header -column "
        SELECT
            datetime(pt.time_created/1000,'unixepoch') AS DATE,
            json_extract(pt.data,'\$.tail_start_id') AS NEW_QUEUE,
            json_extract(pt.data,'\$.auto') AS AUTO
        FROM part pt
        WHERE pt.session_id='${id//\'/\'\'}' AND json_extract(pt.data,'\$.type')='compaction'
        ORDER BY pt.time_created;"
    if [ "${2:-}" = "show" ]; then
        oced_digest_text "$id" "${3:-all}"
    fi
}

# oced_digest_text <id> <last|N|all> -> the compacted-context summary stored in
# the "mode=compaction" assistant message that follows each marker.
oced_digest_text() {
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