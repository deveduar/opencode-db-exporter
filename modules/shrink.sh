#!/usr/bin/env bash
# shrink.sh — oced_shrink: build a lighter, pruned + VACUUMed copy of the
# opencode DB to swap in and reclaim space. NEVER writes to the live database:
# it only reads it (.backup) and produces a swap-ready file the user replaces
# manually.
# Named recipes/presets resolve from shrinklib (single source: shrinklib/flags.py
# + the OCED_SHRINK_PRESETS file); the build engine lives HERE in bash.
set -uo pipefail

# o_sql_qlist <ids...> -> SQL "'id','id'" list (single-quoted, embedded quotes
# doubled). Used to interpolate exact session ids into the keep/discard SQL.
o_sql_qlist() {
    local out="" id
    for id in "$@"; do
        [ -n "$id" ] || continue
        out+="'${id//\'/\'\'}',"
    done
    printf '%s' "${out%,}"
}

oced_shrink_usage() {
    cat <<'EOF'
Usage: opencode-db shrink [recipe|preset] [--keep N | --older-than DAYS | --since DATE | --keep-all | --keep-sessions ID[,ID] | --discard-sessions ID[,ID]] [--strip-reasoning] [--dry-run] [--out DIR] [--swap] [--yes] [--list-presets]

Recipes (built-in named presets; no recipe = --keep 10):
  lean      keep the 10 most recent sessions + strip reasoning (recommended)
  recent    keep sessions updated in the last 90 days
  full      keep ALL sessions, strip reasoning + vacuum (just reclaims space)
  bare      keep the 10 most recent sessions, keep reasoning

Named shrink presets also come from the OCED_SHRINK_PRESETS file (see
`opencode-db shrink --list-presets`); explicit flags win over a preset
(e.g. `shrink lean --keep 3` keeps 3 and still strips reasoning).

Flags:
  --keep N             keep the N most recent sessions (by last update); default 10
  --older-than DAYS    keep sessions updated within the last DAYS days
  --since DATE         keep sessions updated on or after DATE (YYYY-MM-DD, UTC)
  --keep-all           keep ALL sessions (just prune orphans + vacuum)
  --keep-sessions ID[,ID]    keep ONLY the listed sessions (+ their parents/subagents)
  --discard-sessions ID[,ID] keep everything EXCEPT the listed sessions (+ their subagents)
  --strip-reasoning    also drop the 'reasoning' parts (the bulk of the size after
                       the event store) on the copy
  --dry-run            only report what would be pruned (no output written)
  --out DIR            where to write the shrink/<stamp>/ output (default $OCED_BACKUP_DIR)
  --list-presets       list the known shrink presets (built-ins + presets file)
  --swap               build the copy AND replace the live DB with it (requires
                       confirmation, or --yes). Safe: aborts if opencode is running,
                       snapshots a .pre-shrink safety copy (sqlite .backup, WAL-safe),
                       swaps atomically and rolls back if the new DB does not open.
  --yes                skip the confirmation prompt of --swap

Exactly ONE keep rule applies (last one wins on the CLI). The kept set is closed:
every parent and subagent of a kept session is kept too (no orphans). The result
is written as a pruned + VACUUMed copy; the live DB is never modified unless
--swap is given.
EOF
}

# oced_shrink_swap <snap> <yes> — replace the LIVE opencode DB with the pruned copy.
# Explicit opt-in (--swap/--yes) that does the manual swap safely:
#   1. abort if opencode (or any process whose cmdline mentions opencode) is running
#   2. re-verify the copy read-only (integrity_check + foreign_key_check)
#   3. snapshot the live DB with sqlite .backup (WAL-safe) to $OCED_BACKUP_DIR/pre-shrink/opencode.pre-shrink-<ts>
#   4. swap with an atomic mv and drop the stale -wal/-shm tail of the old file
#   5. open the new DB read-only and verify; roll back on failure
oced_shrink_swap() {
    local snap="$1" yes="$2" live="$OPENCODE_DB"

    if [ "$yes" -eq 1 ] || oc_shrink_confirm "$snap" "$live"; then :; else return 1; fi

    # 1) guard: opencode must not be running. Match any process whose full cmdline
    #    mentions 'opencode' but exclude ourselves, the wrapper and pgrep itself.
    local procs
    if command -v pgrep >/dev/null 2>&1; then
        procs=$(pgrep -af opencode 2>/dev/null | grep -v -E 'pgrep|opencode-db|opencode-db-exporter' || true)
    else
        procs=$(ps -eo args 2>/dev/null | grep 'opencode' | grep -v -E 'ps |grep |opencode-db|opencode-db-exporter' || true)
    fi
    if [ -n "$procs" ]; then
        echo "   [ABORT] opencode appears to be running:"
        printf '%s\n' "$procs" | sed 's/^/     /'
        echo "   Close opencode (TUI/server) before swapping. The copy is untouched: $snap"
        return 1
    fi

    # 2) re-verify the copy read-only (belt and braces; checked at build too)
    local integrity fk
    integrity=$(sqlite3 "file:$snap?mode=ro" "PRAGMA integrity_check;" | head -1)
    fk=$(sqlite3 "file:$snap?mode=ro" "PRAGMA foreign_key_check;" | wc -l | tr -d ' ')
    if [ "$integrity" != "ok" ] || [ "$fk" -ne 0 ]; then
        echo "   [ABORT] the copy failed re-verification (integrity=$integrity foreign_key_check=$fk). Nothing swapped."
        return 1
    fi

    # 3) WAL-safe safety snapshot of the live DB -> managed pre-shrink dir
    local ts preshrink_dir safety
    ts=$(date +%s)
    preshrink_dir="$OCED_BACKUP_DIR/pre-shrink"
    mkdir -p "$preshrink_dir"
    safety="$preshrink_dir/opencode.pre-shrink-${ts}.db"
    echo "   Safety snapshot (sqlite .backup, WAL-safe) -> $safety"
    if ! sqlite3 "$live" ".backup '$safety'"; then
        echo "   [ABORT] could not snapshot the live DB before swapping. Nothing modified."
        return 1
    fi

    # Keep only the most recent pre-shrink (remove older ones)
    find "$preshrink_dir" -maxdepth 1 -type f -name 'opencode.pre-shrink-*.db' -printf '%T@ %p\n' 2>/dev/null | sort -rn | tail -n +2 | cut -d' ' -f2- | xargs -r rm -f

    # 4) atomic swap + drop the stale WAL/SHM tail of the old file
    if ! mv -f -- "$snap" "$live"; then
        echo "   [FAIL] the swap move failed; restoring the snapshot."
        mv -f -- "$safety" "$live" 2>/dev/null || true
        return 1
    fi
    rm -f -- "$live-wal" "$live-shm"

    # 5) open the new DB read-only and verify; roll back if unusable
    integrity=$(sqlite3 "file:$live?mode=ro" "PRAGMA integrity_check;" | head -1)
    if [ "$integrity" != "ok" ]; then
        echo "   [FAIL] the swapped DB failed its integrity check; rolling back."
        rm -f -- "$live"
        mv -f -- "$safety" "$live"
        return 1
    fi

    echo ""
    echo "   [OK] Swap complete."
    echo "   New live DB: $live ($(o_human_size "$(stat -c %s "$live")"))"
    echo "   Safety copy (pre-shrink): $safety"
    echo "   Keep this safety copy until opencode has opened the new DB without problems."
    echo "   Older pre-shrink copies are auto-cleaned; list with: opencode-db shrinks verify"
    return 0
}

# oc_shrink_confirm <snap> <live> — y/N gate for --swap (skipped by --yes).
oc_shrink_confirm() {
    echo ""
    echo "   WARNING: this REPLACES the live database at:"
    echo "     $2"
    echo "   with the pruned copy. Close opencode before continuing."
    printf '   Proceed? [y/N] '
    local ans
    read -r ans || ans=N
    case "$ans" in
        y|Y|yes|YES) return 0 ;;
        *)
            echo "   Aborted. The copy is untouched: $1"
            return 1
            ;;
    esac
}

oced_shrink() {
    # --list-presets is pure metadata (no DB needed): resolve it straight away so
    # it also works before a DB exists.
    local a
    for a in "$@"; do
        if [ "$a" = "--list-presets" ]; then
            python3 "$SCRIPT_DIR/shrinklib/plan.py" list-presets
            return 0
        fi
    done
    o_check_deps
    o_db_exists
    local keep_n=10 keep_all=0 older_than=0 since_ms=0 dry=0 strip=0 swap=0 yes=0 outdir="$OCED_BACKUP_DIR" criteria=""
    local rule="" since_date=""
    local -a keep_sessions=() discard_sessions=()

    # Named recipe/preset: the first non-flag token is resolved via shrinklib
    # plan.py (single source of truth). Its baked flags are PREPENDED, so the
    # user's explicit flags later still win (last-wins).
    if [ "$#" -gt 0 ] && [[ "$1" != -* ]]; then
        local baked rc
        baked=$(python3 "$SCRIPT_DIR/shrinklib/plan.py" bake "$1" 2>/dev/null)
        rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "Unknown shrink recipe/preset: $1" >&2
            echo "Known: $(python3 "$SCRIPT_DIR/shrinklib/plan.py" names 2>/dev/null | tr '\n' ' ')" >&2
            echo "Try: opencode-db shrink --list-presets" >&2
            return 1
        fi
        shift
        [ -n "$baked" ] && set -- $baked "$@"
    fi

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --list-presets)
                python3 "$SCRIPT_DIR/shrinklib/plan.py" list-presets
                return 0 ;;
            --keep)
                [ "$#" -ge 2 ] || o_die "--keep needs a number"
                case "$2" in
                    ''|*[!0-9]*) o_die "--keep needs a positive number" ;;
                esac
                keep_n="$2"; keep_all=0; older_than=0; since_ms=0; since_date=""
                keep_sessions=(); discard_sessions=(); rule="keep"
                shift 2 ;;
            --older-than)
                [ "$#" -ge 2 ] || o_die "--older-than needs a number of days"
                case "$2" in
                    ''|*[!0-9]*) o_die "--older-than needs a positive number of days" ;;
                esac
                older_than="$2"; keep_n=0; keep_all=0; since_ms=0; since_date=""
                keep_sessions=(); discard_sessions=(); rule="older_than"
                shift 2 ;;
            --since)
                [ "$#" -ge 2 ] || o_die "--since needs a date (YYYY-MM-DD)"
                local d="$2"
                case "$d" in
                    [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]) ;;
                    *) o_die "--since date must be YYYY-MM-DD" ;;
                esac
                since_ms=$(( $(date -u -d "$d 00:00:00" +%s 2>/dev/null || date -u -j -f "%Y-%m-%d" "$d" +%s 2>/dev/null) * 1000 ))
                [ "$since_ms" -gt 0 ] || o_die "Invalid date for --since: $d"
                since_date="$d"; keep_n=0; keep_all=0; older_than=0
                keep_sessions=(); discard_sessions=(); rule="since"
                shift 2 ;;
            --keep-all)
                keep_all=1; keep_n=0; older_than=0; since_ms=0; since_date=""
                keep_sessions=(); discard_sessions=(); rule="keep_all"
                shift ;;
            --keep-sessions)
                [ "$#" -ge 2 ] || o_die "--keep-sessions needs at least one session id"
                local -a parts=(); local id
                IFS=',' read -r -a parts <<< "$2"
                keep_sessions=()
                for id in "${parts[@]}"; do
                    [ -n "$id" ] && keep_sessions+=("$id")
                done
                [ "${#keep_sessions[@]}" -gt 0 ] || o_die "--keep-sessions needs at least one session id"
                discard_sessions=(); keep_all=0; keep_n=0; older_than=0; since_ms=0; since_date=""
                rule="keep_sessions"
                shift 2 ;;
            --discard-sessions)
                [ "$#" -ge 2 ] || o_die "--discard-sessions needs at least one session id"
                local -a dparts=(); local did
                IFS=',' read -r -a dparts <<< "$2"
                discard_sessions=()
                for did in "${dparts[@]}"; do
                    [ -n "$did" ] && discard_sessions+=("$did")
                done
                [ "${#discard_sessions[@]}" -gt 0 ] || o_die "--discard-sessions needs at least one session id"
                keep_sessions=(); keep_all=0; keep_n=0; older_than=0; since_ms=0; since_date=""
                rule="discard_sessions"
                shift 2 ;;
            --strip-reasoning) strip=1; shift ;;
            --dry-run) dry=1; shift ;;
            --out) [ "$#" -ge 2 ] || o_die "--out needs a directory"; outdir="$2"; shift 2 ;;
            --swap) swap=1; shift ;;
            --yes) yes=1; shift ;;
            -h|--help) oced_shrink_usage; return 0 ;;
            *) o_die "Unknown shrink argument: $1 (see: opencode-db shrink --help)" ;;
        esac
    done
    [ "$swap" -eq 1 ] && [ "$dry" -eq 1 ] && o_die "--swap cannot be combined with --dry-run"
    [ -n "$rule" ] || rule="keep"   # no keep rule given -> default --keep 10

    case "$rule" in
        keep)           criteria="keep the $keep_n most recent session(s)" ;;
        older_than)     criteria="keep sessions updated within the last $older_than day(s)" ;;
        since)          criteria="keep sessions updated since $since_date" ;;
        keep_all)       criteria="keep all sessions" ;;
        keep_sessions)  criteria="keep only the ${#keep_sessions[@]} listed session(s) (+ their parents and subagents)" ;;
        discard_sessions) criteria="keep everything except the ${#discard_sessions[@]} listed session(s) (+ their subagents)" ;;
    esac
    [ "$strip" -eq 1 ] && criteria="$criteria + strip reasoning"

    # Selection metadata for shrink.json (rule/ids/value shape, mirrors plan.py's
    # "selection" contract used by the menu).
    local selection_json
    case "$rule" in
        keep)           selection_json=$(printf '{"rule": "keep", "value": %s}' "$keep_n") ;;
        older_than)     selection_json=$(printf '{"rule": "older_than", "value": %s}' "$older_than") ;;
        since)          selection_json=$(printf '{"rule": "since", "value": "%s"}' "${since_date# }") ;;
        keep_all)       selection_json='{"rule": "keep_all"}' ;;
        keep_sessions)  selection_json=$(printf '%s\n' "${keep_sessions[@]}" | jq -Rn '{rule: "keep_sessions", ids: [inputs]}') ;;
        discard_sessions) selection_json=$(printf '%s\n' "${discard_sessions[@]}" | jq -Rn '{rule: "discard_sessions", ids: [inputs]}') ;;
    esac

    # --- snapshot the live DB (read-only source) into a temp file ---------------
    local stamp snap temp_snap
    stamp=$(o_ts)
    if [ "$dry" -eq 1 ]; then
        snap=$(mktemp /tmp/opencode-db-shrink-XXXXXX.db)
        trap 'rm -f -- "$snap"' EXIT
    else
        temp_snap=$(mktemp /tmp/opencode-db-shrink-XXXXXX.db)
        trap 'rm -f -- "$temp_snap" "$temp_snap-journal"' EXIT
        snap="$temp_snap"
    fi
    echo "-> Snapshot (sqlite .backup, read-only source) ..."
    if ! sqlite3 "$OPENCODE_DB" ".backup '$snap'"; then
        o_die "Could not create the snapshot (is the DB locked?)."
    fi

    # --- compute the kept set (one keep rule + closure over the tree) --------
    local before_size keep_base
    before_size=$(stat -c %s "$snap")
    if [ "$rule" = "keep_all" ]; then
        keep_base="SELECT id FROM session"
    elif [ "$rule" = "since" ]; then
        keep_base="SELECT id FROM session WHERE time_updated >= $since_ms"
    elif [ "$rule" = "older_than" ]; then
        local cutoff_ms
        cutoff_ms=$(( $(date +%s) * 1000 - older_than * 86400 * 1000 ))
        keep_base="SELECT id FROM session WHERE time_updated >= $cutoff_ms"
    elif [ "$rule" = "keep_sessions" ]; then
        keep_base="SELECT id FROM session WHERE id IN ($(o_sql_qlist "${keep_sessions[@]}"))"
    else
        keep_base="SELECT id FROM (SELECT id FROM session ORDER BY time_updated DESC, time_created DESC LIMIT $keep_n)"
    fi
    if [ "$rule" = "discard_sessions" ]; then
        # Kept = everything NOT reachable as discard (the listed ids + their
        # subagents). The discard set is descendant-closed, so a kept session can
        # never have a discarded parent — no extra closure is needed for the keep
        # side (FK-safe by construction).
        sqlite3 "$snap" "
            DROP TABLE IF EXISTS _keep;
            CREATE TABLE _keep(id TEXT PRIMARY KEY);
            WITH RECURSIVE discard(id) AS (
                SELECT id FROM session WHERE id IN ($(o_sql_qlist "${discard_sessions[@]}"))
                UNION
                SELECT s.id FROM session s JOIN discard d ON s.parent_id = d.id
            )
            INSERT INTO _keep SELECT id FROM session WHERE id NOT IN (SELECT id FROM discard);"
    else
        sqlite3 "$snap" "
            DROP TABLE IF EXISTS _keep;
            CREATE TABLE _keep(id TEXT PRIMARY KEY);
            WITH RECURSIVE kept(id) AS (
                $keep_base
                UNION
                SELECT s.id FROM session s JOIN kept k ON s.parent_id = k.id
                UNION
                SELECT s.parent_id FROM session s JOIN kept k ON s.id = k.id
                       WHERE s.parent_id IS NOT NULL AND s.parent_id != ''
            )
            INSERT INTO _keep SELECT id FROM kept;"
    fi

    local total keptcnt deleted
    total=$(sqlite3 "$snap" "SELECT count(*) FROM session;")
    keptcnt=$(sqlite3 "$snap" "SELECT count(*) FROM session WHERE id IN (SELECT id FROM _keep);")
    deleted=$((total - keptcnt))

    echo ""
    echo "== shrink plan =="
    printf '   %-16s %s\n' "Criteria:" "$criteria"
    printf '   %-16s %s\n' "Sessions total:" "$total"
    printf '   %-16s %s\n' "Would keep:" "$keptcnt"
    printf '   %-16s %s\n' "Would delete:" "$deleted"
    printf '   %-16s %s\n' "Size before:" "$(o_human_size "$before_size") ($before_size bytes)"
    local min_ts max_ts min_dt max_dt
    min_ts=$(sqlite3 "$snap" "SELECT coalesce(min(time_updated),0) FROM session;")
    max_ts=$(sqlite3 "$snap" "SELECT coalesce(max(time_updated),0) FROM session;")
    if [ "$min_ts" -gt 0 ] && [ "$max_ts" -gt 0 ]; then
        min_dt=$(date -u -d "@$((min_ts/1000))" +%Y-%m-%d 2>/dev/null || date -u -r $((min_ts/1000)) +%Y-%m-%d 2>/dev/null)
        max_dt=$(date -u -d "@$((max_ts/1000))" +%Y-%m-%d 2>/dev/null || date -u -r $((max_ts/1000)) +%Y-%m-%d 2>/dev/null)
        printf '   %-16s %s .. %s\n' "Date range:" "$min_dt" "$max_dt"
    fi

    if [ "$rule" = "discard_sessions" ] && [ "$dry" -eq 0 ]; then
        local ids_csv
        ids_csv=$(IFS=','; echo "${discard_sessions[*]}")
        echo ""
        echo "   TEMPORARY: the listed sessions will NOT survive in the copy — to keep a"
        echo "   reference of them in an export BEFORE building the shrink copy, run:"
        echo "     opencode-db export memory --sessions $ids_csv"
        echo ""
    fi

    if [ "$deleted" -eq 0 ]; then
        echo "   Nothing to prune for this criteria."
        [ "$dry" -eq 1 ] && { echo "   (dry-run, nothing written)"; trap - EXIT; return 0; }
        # still deliver a vacuumed copy if there is nothing to delete
    fi

    # --- delete non-kept rows (FK-safe order) on OUR copy --------------------
    # session-bound tables first (open code also keeps todo + the event store,
    # whose aggregates are the session ids: without them the space is not
    # reclaimed and orphan events would reference deleted sessions).
    local t cols before after
    local -A removed=()
    local removed_total=0
    for t in part message todo session_message session_share session_context_epoch session_input; do
        cols=$(sqlite3 "$snap" "PRAGMA table_info(${t});" | awk -F'|' '$2 == "session_id" {print 1}')
        [ -n "$cols" ] || continue
        before=$(sqlite3 "$snap" "SELECT count(*) FROM ${t};")
        sqlite3 "$snap" "DELETE FROM ${t} WHERE session_id NOT IN (SELECT id FROM _keep);"
        after=$(sqlite3 "$snap" "SELECT count(*) FROM ${t};")
        removed["$t"]=$((before - after))
        removed_total=$((removed_total + before - after))
    done
    for t in event event_sequence; do
        cols=$(sqlite3 "$snap" "PRAGMA table_info(${t});" | awk -F'|' '$2 == "aggregate_id" {print 1}')
        [ -n "$cols" ] || continue
        before=$(sqlite3 "$snap" "SELECT count(*) FROM ${t} WHERE aggregate_id LIKE 'ses_%';")
        sqlite3 "$snap" "DELETE FROM ${t} WHERE aggregate_id LIKE 'ses_%' AND aggregate_id NOT IN (SELECT id FROM _keep);"
        after=$(sqlite3 "$snap" "SELECT count(*) FROM ${t} WHERE aggregate_id LIKE 'ses_%';")
        removed["$t"]=$((before - after))
        removed_total=$((removed_total + before - after))
    done
    sqlite3 "$snap" "DELETE FROM session WHERE id NOT IN (SELECT id FROM _keep);
                     DROP TABLE IF EXISTS _keep;"

    # --- optional strip-reasoning: the 'reasoning' parts are the bulk of the
    # --- text weight (ocgc reports ~77% savings); only applied ON THE COPY.
    local stripped_reasoning=0
    if [ "$strip" -eq 1 ] && [ "$(sqlite3 "$snap" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='part';")" -gt 0 ]; then
        stripped_reasoning=$(sqlite3 "$snap" "SELECT count(*) FROM part WHERE json_extract(data, '$.type') = 'reasoning';")
        sqlite3 "$snap" "DELETE FROM part WHERE json_extract(data, '$.type') = 'reasoning';"
        [ "$stripped_reasoning" -gt 0 ] && printf '   %-16s %s\n' "Strip reasoning:" "$stripped_reasoning"
    fi

    # --- integrity: never ship a copy with orphans or corruption --------------
    local integrity fk_rows fk_status
    integrity=$(sqlite3 "$snap" "PRAGMA integrity_check;" | head -1)
    fk_rows=$(sqlite3 "$snap" "PRAGMA foreign_key_check;" | wc -l | tr -d ' ')
    [ "$fk_rows" -eq 0 ] && fk_status="clean" || fk_status="has $fk_rows orphan row(s)"
    if [ "$integrity" != "ok" ] || [ "$fk_rows" -ne 0 ]; then
        echo "   [FAIL] integrity_check=$integrity  foreign_key_check=$fk_status"
        o_die "The pruned copy failed the integrity checks — nothing was written."
    fi
    sqlite3 "$snap" "VACUUM;"

    # --- move temp snapshot to final location (non-dry-run only) ---------------
    if [ "$dry" -eq 0 ]; then
        mkdir -p "$outdir/shrink/$stamp"
        mv -f "$temp_snap" "$outdir/shrink/$stamp/opencode.shrunk.db"
        snap="$outdir/shrink/$stamp/opencode.shrunk.db"
        trap 'rm -f -- "$snap" "$snap-journal"' EXIT
    fi
    for k in "${!removed[@]}"; do
        [ "${removed[$k]}" -gt 0 ] && printf '   %-16s %s\n' "Removed ${k}:" "${removed[$k]}"
    done
    [ "$removed_total" -gt 0 ] && printf '   %-16s %s\n' "Removed total:" "$removed_total"

    # --- report + store -------------------------------------------------------
    local after_size free_pct max_updated
    after_size=$(stat -c %s "$snap")
    free_pct=0
    [ "$after_size" -lt "$before_size" ] && free_pct=$(( (before_size - after_size) * 100 / before_size ))
    max_updated=$(sqlite3 "$snap" "SELECT coalesce(max(time_updated),0) FROM session;" 2>/dev/null || echo 0)
    printf '   %-16s %s (%s bytes)\n' "Size after:" "$(o_human_size "$after_size")" "$after_size"
    printf '   %-16s %s%%\n' "Freed:" "$free_pct"

    if [ "$dry" -eq 1 ]; then
        echo ""
        echo "   (dry-run: nothing written to disk)"
        trap - EXIT
        return 0
    fi

    local removed_json rem_txt=""
    for k in "${!removed[@]}"; do
        rem_txt+="\"$k\": ${removed[$k]}, "
    done
    rem_txt="${rem_txt%, }"
    removed_json="{${rem_txt:-}}"

    jq -n --arg tool "opencode-db/shrink" --arg date "$(o_now_utc)" --arg criteria "$criteria" \
        --arg source "$OPENCODE_DB" --arg stamp "$stamp" \
        --argjson total "$total" --argjson kept "$keptcnt" --argjson deleted "$deleted" \
        --arg max_updated "$max_updated" \
        --argjson selection "$selection_json" \
        --argjson before "$before_size" --argjson after "$after_size" \
        --argjson removed_ob "$removed_json" --argjson removed_total "$removed_total" \
        --argjson stripped_reasoning "$stripped_reasoning" \
        --arg integrity "$integrity" --arg fk "$fk_status" \
        '{tool: $tool, date: $date, source: $source, stamp: $stamp, criteria: $criteria,
          selection: $selection,
          sessions: {total: $total, kept: $kept, deleted: $deleted, max_updated: ($max_updated | tonumber)},
          size: {before: $before, after: $after},
          integrity_check: $integrity,
          foreign_key_check: $fk,
          removed: $removed_ob,
          removed_total: $removed_total,
          stripped_reasoning: $stripped_reasoning,
          file: "opencode.shrunk.db"}' \
        > "$outdir/shrink/$stamp/shrink.json"

    o_log "shrink: $criteria (deleted=$deleted kept=$keptcnt) -> $outdir/shrink/$stamp"
    trap - EXIT

    if [ "$swap" -eq 1 ]; then
        oced_shrink_swap "$snap" "$yes"
        return $?
    fi

    echo ""
    echo "   Copy ready: $snap"
    echo ""
    echo "   To use it, close opencode first and replace the live DB manually (safest:"
    echo "   re-run with --swap, which snapshots an automatic safety copy):"
    echo "     cp \"$OPENCODE_DB\" \"$OCED_BACKUP_DIR/pre-shrink/opencode.pre-shrink\$(date +%s).db\"   # safety"
    echo "     cp \"$snap\" \"$OPENCODE_DB\""
    echo "     rm -f \"$OPENCODE_DB-wal\" \"$OPENCODE_DB-shm\""
    echo "   The live DB was never modified; inspect the copy before swapping."
}

#-----------------------------------------------------------------------
# shrinks — manager of the produced shrink copies (like exports for runs).
# Runs live under $OCED_BACKUP_DIR/shrink/<o_ts-stamp>/ (shrink.json + the
# copy). list/view/remove/prune never touch the live DB.
#-----------------------------------------------------------------------

shrinks_dir() { printf '%s/shrink' "$OCED_BACKUP_DIR"; }

# shrinks_runs_find -> run dirs under <backup>/shrink, newest first.
shrinks_runs_find() {
    [ -d "$(shrinks_dir)" ] || return 0
    find "$(shrinks_dir)" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r
}

# shrinks_stamp_human <stamp 20260921-083000> -> "2026-09-21 08:30:00 UTC".
shrinks_stamp_human() {
    local s="$1"
    case "$s" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9])
            printf '%s-%s-%s %s:%s:%s UTC' "${s:0:4}" "${s:4:2}" "${s:6:2}" "${s:9:2}" "${s:11:2}" "${s:13:2}" ;;
        *) printf '%s' "$s" ;;
    esac
}

# shrinks_run_row <run-dir> -> TSV 'stamp<TAB>display' (single source for the
# menu picker, like exports view/list share one aggregation).
shrinks_run_row() {
    local run="$1" stamp j
    local jcriteria jsess jkept jdel jbefore jafter jstrip
    local size freed pct db_state
    stamp="${run##*/}"
    j="$run/shrink.json"
    if [ -f "$j" ]; then
        jcriteria=$(jq -r '.criteria // "(no criteria)"' "$j")
        jsess=$(jq -r '.sessions.total // 0' "$j")
        jkept=$(jq -r '.sessions.kept // 0' "$j")
        jdel=$(jq -r '.sessions.deleted // 0' "$j")
        jbefore=$(jq -r '.size.before // 0' "$j")
        jafter=$(jq -r '.size.after // 0' "$j")
        jstrip=$(jq -r '.stripped_reasoning // 0' "$j")
    else
        jcriteria="(no shrink.json)"
        jsess="?"; jkept="?"; jdel="?"; jbefore=0; jafter=0; jstrip=0
    fi
    if [ -f "$run/opencode.shrunk.db" ]; then
        size=$(stat -c %s "$run/opencode.shrunk.db" 2>/dev/null || echo 0)
        db_state="$(o_human_size "$size")"
    else
        size=0
        db_state="(swapped/no copy)"
    fi
    freed="--"
    pct=""
    if [ "$jbefore" -gt 0 ] && [ "$jafter" -gt 0 ]; then
        freed="$(o_human_size "$((jbefore - jafter))")"
        [ "$jbefore" -gt "$jafter" ] && pct="$(( (jbefore - jafter) * 100 / jbefore ))%"
    fi
    printf '%s\t%s\n' "$stamp" \
        "$(printf '%s  %s  %s sess / %s del  %s -> %s (%s)%s  %s' \
            "$(shrinks_stamp_human "$stamp")" "$jcriteria" \
            "$jkept" "$jdel" "$(o_human_size "$jbefore")" "$(o_human_size "$jafter")" \
            "$freed" "$pct" "$db_state")"
}

oced_shrinks() {
    local cmd="${1:-list}"
    case "$cmd" in
        list)   shift; oced_shrinks_list "$@" ;;
        view)   shift; oced_shrinks_view "$@" ;;
        remove) shift; oced_shrinks_remove "$@" ;;
        prune)  shift; oced_shrinks_prune "$@" ;;
        verify) shift; oced_shrinks_verify "$@" ;;
        *) echo "Usage: opencode-db shrinks [list [--tsv]|view <stamp>|remove <stamp> [--yes]|prune <N>|verify [--yes]]"; return 1 ;;
    esac
}

oced_shrinks_list() {
    local tsv=0
    [ "${1:-}" = "--tsv" ] && tsv=1
    local -a runs rows=()
    local run stamp
    mapfile -t runs < <(shrinks_runs_find)
    if [ "$tsv" -eq 0 ]; then
        echo "== Shrink copies (${#runs[@]}) =="
    fi
    if [ "${#runs[@]}" -eq 0 ]; then
        [ "$tsv" -eq 1 ] && return 0
        echo "   (no shrink runs yet; run: opencode-db shrink)"
        return 0
    fi
    for run in "${runs[@]}"; do
        stamp="${run##*/}"
        if [ "$tsv" -eq 1 ]; then
            shrinks_run_row "$run"
        else
            local row
            row=$(printf '%s' "$(shrinks_run_row "$run")" | cut -f2-)
            rows+=("  $((${#rows[@]} + 1)).  $row")
        fi
    done
    if [ "$tsv" -eq 0 ]; then
        for row in "${rows[@]}"; do echo "$row"; done
        echo ""
        echo "  view <stamp>  ·  remove <stamp>  ·  prune <N>"
    fi
}

oced_shrinks_view() {
    local stamp="${1:-}" target j
    [ -n "$stamp" ] || { echo "Usage: opencode-db shrinks view <stamp>"; return 1; }
    target="$(shrinks_dir)/$stamp"
    [ -d "$target" ] || { echo "Not found: $target"; echo "Try: opencode-db shrinks list"; return 1; }
    j="$target/shrink.json"
    [ -f "$j" ] || { echo "No shrink.json in $target"; return 1; }
    echo "== Shrink run: $stamp =="
    jq . "$j"
    echo ""
    echo "  files:"
    find "$target" -maxdepth 1 -type f -printf '    %f  %k KiB\n' 2>/dev/null
}

oced_shrinks_remove() {
    local stamp="${1:-}" yes=0 target
    [ -n "$stamp" ] || { echo "Usage: opencode-db shrinks remove <stamp> [--yes]"; return 1; }
    [ "${2:-}" = "--yes" ] && yes=1
    target="$(shrinks_dir)/$stamp"
    [ -d "$target" ] || { echo "Not found: $target"; echo "Try: opencode-db shrinks list"; return 1; }
    if [ "$yes" -eq 0 ]; then
        local ans
        printf 'Remove shrink run %s? This deletes the pruned copy. [y/N] ' "$stamp"
        read -r ans || return 1
        [[ "$ans" =~ ^[yYsS]$ ]] || { echo "   cancelled."; return 0; }
    fi
    rm -rf -- "$target"
    o_log "shrinks remove stamp=$stamp"
    echo "Removed: $target"
}

oced_shrinks_prune() {
    local keep="${1:-}" yes=0
    [ "${2:-}" = "--yes" ] && yes=1
    case "$keep" in
        ''|*[!0-9]*) echo "Usage: opencode-db shrinks prune <N>  (N = how many to keep)"; return 1 ;;
    esac
    [ "$keep" -ge 1 ] || { echo "N must be >= 1"; return 1; }
    local -a runs
    local total n i target
    mapfile -t runs < <(shrinks_runs_find)
    total=${#runs[@]}
    if [ "$total" -le "$keep" ]; then
        echo "Nothing to prune (have $total, keeping $keep)."
        return 0
    fi
    n=0
    for ((i = keep; i < total; i++)); do
        target="${runs[$i]}"
        rm -rf -- "$target"
        n=$((n + 1))
    done
    o_log "shrinks prune keep=$keep removed=$n"
    echo "Prune: removed $n run(s); keeping $keep."
}

# o_shrink_stale <shrink.json> — compares the live DB against a shrink copy
# (read-only). Echoes a warning (or nothing when clean/up to date) and returns
# 0 = up to date, 1 = stale or unverifiable. This is the single stale-check for
# guides, pickers and verify so the logic changes in one place.
o_shrink_stale() {
    local j="$1"
    local live_max=0 shrink_max=0
    [ -f "$j" ] || { echo "shrink.json missing: $j"; return 1; }
    live_max=$(o_q "SELECT coalesce(max(time_updated),0) FROM session" 2>/dev/null || echo 0)
    shrink_max=$(jq -r '.sessions.max_updated // 0' "$j" 2>/dev/null || echo 0)
    if [ "$shrink_max" -eq 0 ]; then
        echo "cannot verify freshness ($j has no sessions.max_updated — old shrink format); re-run shrink to record it."
        return 1
    fi
    if [ "$live_max" -gt "$shrink_max" ]; then
        echo "live DB has newer sessions (max_updated=$live_max) than the shrink copy ($shrink_max)."
        return 1
    fi
    return 0
}

# oced_shrinks_verify — checks for orphan dirs, old pre-shrinks, stale shrinks vs live DB
oced_shrinks_verify() {
    local yes=0
    [ "${1:-}" = "--yes" ] && yes=1
    local tsv=0
    [ "${1:-}" = "--tsv" ] && tsv=1
    [ "${2:-}" = "--tsv" ] && tsv=1

    local preshrink_dir="$OCED_BACKUP_DIR/pre-shrink"
    local issues=0

    # 1) Orphan shrink dirs (no valid shrink.json)
    local -a orphan_dirs=()
    local run
    mapfile -t runs < <(shrinks_runs_find)
    for run in "${runs[@]}"; do
        local stamp="${run##*/}"
        local j="$run/shrink.json"
        if [ ! -f "$j" ] || ! jq -e . "$j" >/dev/null 2>&1; then
            orphan_dirs+=("$run")
        fi
    done

    # 2) Pre-shrink files (keep only most recent)
    local -a old_preshrinks=()
    if [ -d "$preshrink_dir" ]; then
        local f
        mapfile -t old_preshrinks < <(
            find "$preshrink_dir" -maxdepth 1 -type f -name 'opencode.pre-shrink-*.db' -printf '%T@ %p\n' 2>/dev/null |
            sort -rn | tail -n +2 | cut -d' ' -f2-
        )
    fi

    # 3) Stale shrink vs live DB
    local stale_msg=""
    if [ ${#runs[@]} -gt 0 ]; then
        stale_msg=$(o_shrink_stale "${runs[0]}/shrink.json")
    fi

    # Output
    if [ "$tsv" -eq 1 ]; then
        # TSV: type<TAB>key<TAB>display
        for d in "${orphan_dirs[@]}"; do
            printf 'orphan\t%s\t%s\n' "${d##*/}" "Orphan dir (no valid shrink.json): $d"
        done
        for p in "${old_preshrinks[@]}"; do
            printf 'preshrink\t%s\t%s\n' "${p##*/}" "Old pre-shrink (auto-cleaned on swap): $p"
        done
        if [ -n "$stale_msg" ]; then
            printf 'stale\t%s\t%s\n' "live_vs_shrink" "$stale_msg"
        fi
        return 0
    fi

    echo "== Shrink verification =="
    echo ""

    if [ ${#orphan_dirs[@]} -gt 0 ]; then
        echo "Orphan shrink dirs (no valid shrink.json):"
        for d in "${orphan_dirs[@]}"; do
            echo "  ${d##*/}"
        done
        echo ""
        issues=1
    fi

    if [ ${#old_preshrinks[@]} -gt 0 ]; then
        echo "Old pre-shrink copies (auto-cleaned on swap, safe to remove):"
        for p in "${old_preshrinks[@]}"; do
            local sz
            sz=$(stat -c %s "$p" 2>/dev/null || echo 0)
            echo "  ${p##*/}  ($(o_human_size "$sz"))"
        done
        echo ""
        issues=1
    fi

    if [ -n "$stale_msg" ]; then
        echo "⚠️  Stale shrink warning:"
        echo "   $stale_msg"
        echo "   If you swap with this shrink, you will lose recent sessions."
        echo "   The pre-shrink copy is your only rollback."
        echo ""
        issues=1
    fi

    if [ "$issues" -eq 0 ]; then
        echo "All clean: no orphan dirs, no old pre-shrinks, last shrink is up to date."
        return 0
    fi

    if [ "$yes" -eq 1 ]; then
        # Auto-clean
        for d in "${orphan_dirs[@]}"; do
            echo "Removing orphan: $d"
            rm -rf -- "$d"
        done
        for p in "${old_preshrinks[@]}"; do
            echo "Removing old pre-shrink: $p"
            rm -f -- "$p"
        done
        echo "Cleanup complete."
    else
        echo "Run with --yes to auto-clean orphan dirs and old pre-shrinks."
        echo "Stale shrink warning requires manual decision (re-run shrink or swap carefully)."
    fi
}