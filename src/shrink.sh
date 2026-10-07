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

# o_shrink_discard_profile -> the export profile that protects what a shrink is
# about to drop: $OCED_SHRINK_DISCARD_EXPORT_PROFILE (any product or preset from
# o_export_profiles) or `archive` (transcript + memory) by default.
#
# It lives here, not in the menu, because BOTH the menu offer and the engine's own
# post-build hint print the same `export <profile> --sessions …` command and must
# not disagree. A name that would not resolve is a configuration mistake, so it is
# reported HERE — with the valid names — and falls back, instead of failing later
# inside an export the user already confirmed.
o_shrink_discard_profile() {
    local p="${OCED_SHRINK_DISCARD_EXPORT_PROFILE:-archive}"
    local fallback=""
    if ! o_export_profile_known "$p"; then
        if o_export_profile_known archive; then
            fallback=archive
        else
            # No presets file at all: `archive` cannot resolve, and the transcript
            # product always does.
            fallback=transcript
        fi
        {
            echo "   [!] OCED_SHRINK_DISCARD_EXPORT_PROFILE='$p' is not a valid export profile."
            echo "       Valid: $(o_export_profiles | paste -sd' ' -)"
            echo "       Using '$fallback' instead."
        } >&2
        p="$fallback"
    fi
    # The command this function feeds hands over a CLOSED set (the discarded roots
    # plus every descendant), so the profile has to preserve them. It is allowed
    # to be a product keyword, which can never gap; a preset can: `no_subagents`
    # drops the sessions themselves and `sub: omit` empties `children_of`, so no
    # subagent body is written. Either way the export SUCCEEDS with plausible
    # counts while the subagents are missing — the exact failure this offer exists
    # to prevent — so warn here, before the y/N gate, and still print the command
    # (a warning, not a veto: the user may be exporting on purpose).
    local gaps
    gaps=$(OCED_PRESETS="$OCED_PRESETS" python3 "$SCRIPT_DIR/exportlib/plan.py" subagent-gaps "$p" 2>/dev/null || true)
    if [ -n "$gaps" ]; then
        {
            echo "   [!] the export profile '$p' does not preserve subagents ($gaps)."
            echo "       The command below hands over the whole cascade, but this run would not"
            echo "       write them — use a transcript/memory profile to keep what the shrink drops."
        } >&2
    fi
    printf '%s' "$p"
}

oced_shrink_usage() {
    # The whole --help text lives in shrinklib/flags.py (--usage, single source;
    # also served by `opencode-db help`). Static fallback for a broken python.
    if ! python3 "$SCRIPT_DIR/shrinklib/flags.py" --usage 2>/dev/null; then
        cat <<'EOF'
Usage: opencode-db shrink [recipe|preset] [--keep N | --older-than DAYS | --since DATE | --keep-all | --keep-sessions ID[,ID] | --discard-sessions ID[,ID]] [--strip-reasoning] [--dry-run] [--out DIR] [--swap] [--yes] [--list-presets]
Try: opencode-db shrink --list-presets
EOF
    fi
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
        local baked rc err
        err=$(mktemp) || o_die "cannot create a temp file"
        baked=$(python3 "$SCRIPT_DIR/shrinklib/plan.py" bake "$1" 2>"$err")
        rc=$?
        if [ "$rc" -ne 0 ]; then
            # the python error is the helpful one (unknown recipe / invalid file);
            # fall back to the generic hint only when it is silent
            if [ -s "$err" ]; then cat "$err" >&2; else
                echo "Unknown shrink recipe/preset: $1" >&2
                echo "Known: $(python3 "$SCRIPT_DIR/shrinklib/plan.py" names 2>/dev/null | tr '\n' ' ')" >&2
                echo "Try: opencode-db shrink --list-presets" >&2
            fi
            rm -f "$err"
            return 1
        fi
        rm -f "$err"
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

    # Human criteria line comes from the python single source (rule-line builds
    # it from rule_lines() in presets.py — the same phrases as the menu rows).
    local crit_val="" strip_arg="0"
    case "$rule" in
        keep)           crit_val="$keep_n" ;;
        older_than)     crit_val="$older_than" ;;
        since)          crit_val="$since_date" ;;
        keep_all)       crit_val="" ;;
        keep_sessions)  crit_val="${#keep_sessions[@]}" ;;
        discard_sessions) crit_val="${#discard_sessions[@]}" ;;
    esac
    [ "$strip" -eq 1 ] && strip_arg="1"
    criteria=$(python3 "$SCRIPT_DIR/shrinklib/plan.py" rule-line "$rule" "$crit_val" "$strip_arg" 2>/dev/null)
    [ -n "$criteria" ] || criteria="keep the $keep_n most recent session(s)"

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
    # Two names, because this block lands in two different places: the menu wizard
    # already showed its own `-> shrink plan` (live-DB counts) right before its y/N,
    # so an identical `== shrink plan ==` here read as the plan being asked twice.
    # A dry run IS a plan; a real run is this copy's accounting.
    if [ "$dry" -eq 1 ]; then
        echo "== shrink plan (read-only; nothing written) =="
    else
        echo "== shrink run (criteria and counts of THIS copy) =="
    fi
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
        local ids_csv disc_csv n_disc profile
        ids_csv=$(IFS=','; echo "${discard_sessions[*]}")
        # `--sessions` matches EXACT ids while the discard set is descendant-closed
        # (the _keep closure above), so handing over only the listed roots would
        # export 2 of the 7 sessions this copy is about to drop — silently, because
        # the export still succeeds. Close the set here, from the snapshot.
        disc_csv=$(sqlite3 "$snap" "
            WITH RECURSIVE d(id) AS (
                SELECT id FROM session WHERE id IN ($(o_sql_qlist "${discard_sessions[@]}"))
                UNION
                SELECT s.id FROM session s JOIN d ON s.parent_id = d.id)
            SELECT group_concat(id) FROM (
                SELECT d.id FROM d JOIN session s ON s.id = d.id ORDER BY s.time_created);" 2>/dev/null)
        [ -n "$disc_csv" ] || disc_csv="$ids_csv"
        local -a _dcsv=()
        IFS=',' read -r -a _dcsv <<< "$disc_csv"
        n_disc=${#_dcsv[@]}
        profile=$(o_shrink_discard_profile)
        echo ""
        echo "   NOTE: $n_disc session(s) listed above will NOT survive in this copy"
        echo "   (the LIVE database still has them). To keep a readable reference,"
        echo "   export them before you swap the copy in — --swap snapshots the live DB"
        echo "   to backups/pre-shrink/ first, so nothing is really lost:"
        echo "     opencode-db export $profile --sessions $disc_csv"
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
#
# The display cell is a COLUMN, so it carries the tag (plan.py rule-tag) and not
# the criteria sentence: that sentence is 100+ characters of parentheticals written
# for shrink.json, and pasting it here made every row 225 characters and buried the
# three numbers that matter. One size expression (before -> after, -%) instead of
# three repetitions of it, and the copy's own state only when it is anomalous.
shrinks_run_row() {
    local run="$1" stamp j
    local rule rvalue nids tag db_state size pct
    local jtotal jkept jbefore jafter jstrip
    stamp="${run##*/}"
    j="$run/shrink.json"
    tag=""   # `local` does not initialise: under set -u an unset local is fatal
    if [ -f "$j" ]; then
        rule=$(jq -r '.selection.rule // ""' "$j")
        # The tag needs the rule's OWN value (keep 1 vs keep 10 are the same rule and
        # different facts, which is why the engine records .selection.value), except for
        # the two id rules, whose value IS their length.
        rvalue=$(jq -r '.selection.value // ""' "$j")
        nids=$(jq -r '(.selection.ids // []) | length' "$j")
        case "$rule" in
            keep|older_than|since) : ;;
            *) [ -n "$rvalue" ] || rvalue="$nids" ;;
        esac
        jtotal=$(jq -r '.sessions.total // 0' "$j")
        jkept=$(jq -r '.sessions.kept // 0' "$j")
        jbefore=$(jq -r '.size.before // 0' "$j")
        jafter=$(jq -r '.size.after // 0' "$j")
        jstrip=$(jq -r '.stripped_reasoning // 0' "$j")
    else
        rule=""; rvalue=""; nids=0
        jtotal=0; jkept="?"; jbefore=0; jafter=0; jstrip=0
    fi
    # The tag is python's (shrinklib/presets.py rule_tags): shrink.sh never builds
    # those phrases itself. A legacy shrink.json with no `.selection` has no rule to
    # render, so its criteria is cut rather than trusted whole.
    if [ -n "$rule" ]; then
        local strip_arg=0
        case "$jstrip" in ''|*[!0-9]*) ;; *) [ "$jstrip" -gt 0 ] && strip_arg=1 ;; esac
        [ -n "$rvalue" ] || rvalue=0
        # ${OCED_SHRINK_PRESETS:-} like oc_shrink_py: under `set -u` a bare
        # reference aborts this subshell and the row silently loses its tag.
        tag=$(OCED_SHRINK_PRESETS="${OCED_SHRINK_PRESETS:-}" python3 "$SCRIPT_DIR/shrinklib/plan.py" \
              rule-tag "$rule" "$rvalue" "$strip_arg" 2>/dev/null) || tag=""
    fi
    # One fallback for every reason the tag is missing: python not on PATH, a plan.py
    # that died, a legacy shrink.json with no .selection. The cut criteria is a poor
    # tag but it is a fact about THIS copy, while "?" says nothing at all.
    [ -n "$tag" ] || tag=$(jq -r '.criteria // "?"' "$j" 2>/dev/null | cut -c1-24)
    [ -n "$tag" ] || tag="?"
    if [ -f "$run/opencode.shrunk.db" ]; then
        size=$(stat -c %s "$run/opencode.shrunk.db" 2>/dev/null || echo 0)
        if [ "$jbefore" -gt 0 ] && [ "$jafter" -gt 0 ]; then
            pct=""
            [ "$jbefore" -gt "$jafter" ] && pct=" -$(( (jbefore - jafter) * 100 / jbefore ))%"
            printf -v db_state '%s -> %s%s' "$(o_human_size "$jbefore")" "$(o_human_size "$jafter")" "$pct"
        else
            db_state="$(o_human_size "$size")"
        fi
    else
        db_state="(swapped/no copy)"
    fi
    # kept/total (not kept/del): the two are one subtraction apart and the total is
    # what you compare against the DB you are looking at afterwards.
    printf '%s\t%s\n' "$stamp" \
        "$(printf '%-22s  %-22s  %s/%s kept  %s' \
            "$(shrinks_stamp_human "$stamp")" "$tag" "$jkept" "$jtotal" "$db_state")"
}

oced_shrinks() {
    local cmd="${1:-list}"
    case "$cmd" in
        list)   shift; oced_shrinks_list "$@" ;;
        view)   shift; oced_shrinks_view "$@" ;;
        remove) shift; oced_shrinks_remove "$@" ;;
        prune)  shift; oced_shrinks_prune "$@" ;;
        verify) shift; oced_shrinks_verify "$@" ;;
        *) echo "Usage: opencode-db shrinks [list [--tsv]|view <stamp> [--json]|remove <stamp> [--yes]|prune <N>|verify [--tsv] [--yes]]"; return 1 ;;
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
    local stamp="${1:-}" json_mode=0 target j
    [ -n "$stamp" ] || { echo "Usage: opencode-db shrinks view <stamp> [--json]"; return 1; }
    [ "${2:-}" = "--json" ] && json_mode=1
    target="$(shrinks_dir)/$stamp"
    [ -d "$target" ] || { echo "Not found: $target"; echo "Try: opencode-db shrinks list"; return 1; }
    j="$target/shrink.json"
    [ -f "$j" ] || { echo "No shrink.json in $target"; return 1; }

    # The machine view is the file itself, byte for byte: a pretty screen is added
    # IN FRONT of it, never in place of it.
    if [ "$json_mode" -eq 1 ]; then
        cat "$j"
        return 0
    fi

    # Human screen, shaped like `exports view` (banner + one fact per line). The
    # criteria sentence lives HERE and not in `shrinks list`: a detail screen has
    # room for the parentheticals, a list column does not.
    local total kept del before after strip removed
    local rule nids pct integrity fkeys fresh
    total=$(jq -r '.sessions.total // 0' "$j")
    kept=$(jq -r '.sessions.kept // 0' "$j")
    del=$(jq -r '.sessions.deleted // 0' "$j")
    before=$(jq -r '.size.before // 0' "$j")
    after=$(jq -r '.size.after // 0' "$j")
    strip=$(jq -r '.stripped_reasoning // 0' "$j")
    removed=$(jq -r '.removed_total // 0' "$j")
    rule=$(jq -r '.selection.rule // "?"' "$j")
    nids=$(jq -r '(.selection.ids // []) | length' "$j")
    integrity=$(jq -r '.integrity_check // "?"' "$j")
    fkeys=$(jq -r '.foreign_key_check // "?"' "$j")
    pct=""
    if [ "$before" -gt 0 ] && [ "$after" -gt 0 ] && [ "$before" -gt "$after" ]; then
        pct=", -$(( (before - after) * 100 / before ))%"
    fi

    echo "== Shrink copy: $stamp =="
    echo ""
    printf '  %-11s %s\n' "sessions:" "$total total · $kept kept · $del deleted"
    if [ "$before" -gt 0 ] && [ "$after" -gt 0 ]; then
        printf '  %-11s %s -> %s (freed %s%s)\n' "size:" \
            "$(o_human_size "$before")" "$(o_human_size "$after")" \
            "$(o_human_size "$(( before - after ))")" "$pct"
    else
        printf '  %-11s %s\n' "size:" "$(o_human_size "$(stat -c %s "$target/opencode.shrunk.db" 2>/dev/null || echo 0)")"
    fi
    printf '  %-11s %s\n' "selection:" "$rule · $nids id(s)"
    printf '  %-11s %s\n' "criteria:" "$(jq -r '.criteria // "?"' "$j")"
    if [ "$strip" -gt 0 ] 2>/dev/null; then
        printf '  %-11s %s\n' "reasoning:" "$strip part(s) stripped"
    fi
    printf '  %-11s %s\n' "date:" "$(jq -r '.date // "?"' "$j")"
    printf '  %-11s %s\n' "db:" "$(jq -r '.source // "?"' "$j")"
    printf '  %-11s %s\n' "integrity:" "$integrity · foreign keys $fkeys"
    # Freshness here, by the same rule as `backups view`: a detail screen must not
    # show an artifact nobody validated. Same helper as verify/swap/remove.
    if fresh=$(o_shrink_stale "$j" 2>&1); then
        printf '  %-11s %s\n' "freshness:" "ok — the live DB has no newer session than this copy"
    else
        printf '  %-11s %s\n' "freshness:" "STALE — $fresh"
    fi

    # The selected ids, capped: a 200-id discard would otherwise bury the fields
    # above. --json always has the whole list.
    if [ "${nids:-0}" -gt 0 ] 2>/dev/null; then
        local -a ids=()
        mapfile -t ids < <(jq -r '.selection.ids[]' "$j")
        echo ""
        echo "  ids (${#ids[@]}):"
        local i=0 id
        for id in "${ids[@]}"; do
            i=$((i + 1))
            [ "$i" -gt 8 ] && break
            printf '    %s\n' "$id"
        done
        [ "${#ids[@]}" -gt 8 ] && echo "    … $(( ${#ids[@]} - 8 )) more (--json has all of them)"
    fi

    # Per-table removals, biggest first: one line for the rare big ones, the rest
    # only if they are non-zero.
    if [ "${removed:-0}" -gt 0 ] 2>/dev/null; then
        echo ""
        printf '  removed:    %s row(s) total\n' "$removed"
        jq -r '.removed // {} | to_entries | map(select(.value > 0)) | sort_by(-.value)
               | .[] | "    \(.key) \(.value)"' "$j" 2>/dev/null | head -6
    fi

    echo ""
    echo "  files:"
    local f
    while IFS= read -r f; do
        printf '    %-20s %s\n' "${f##*/}" "$(o_human_size "$(stat -c %s "$f" 2>/dev/null || echo 0)")"
    done < <(find "$target" -maxdepth 1 -type f 2>/dev/null | sort)
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

# oced_shrinks_verify — audits the produced copies: orphan run dirs (no valid
# shrink.json), old pre-shrink files, and the freshness of EVERY copy vs the
# live DB (o_shrink_stale, once per run — not once for the newest).
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

    # 3) Stale shrinks vs live DB -- EVERY copy, not just the newest one.
    # A single freshness answer was a half-verification: 1 and 2 already walked
    # every run dir, so a 3-run shelf reported the orphan in the third dir but
    # never that copies 1 and 2 were stale. Each entry is "stamp<TAB>message".
    # An orphan is NOT re-reported here (o_shrink_stale would answer "shrink.json
    # missing" for it), so a broken dir shows up exactly once, as an orphan.
    local -a stale_copies=()
    local sc run
    for run in "${runs[@]}"; do
        local is_orphan=0 od
        for od in "${orphan_dirs[@]}"; do
            [ "$od" = "$run" ] && { is_orphan=1; break; }
        done
        [ "$is_orphan" -eq 1 ] && continue
        sc=$(o_shrink_stale "$run/shrink.json") || true
        [ -n "$sc" ] && stale_copies+=("${run##*/}"$'\t'"$sc")
    done

    # Output
    if [ "$tsv" -eq 1 ]; then
        # TSV: type<TAB>key<TAB>display
        for d in "${orphan_dirs[@]}"; do
            printf 'orphan\t%s\t%s\n' "${d##*/}" "Orphan dir (no valid shrink.json): $d"
        done
        for p in "${old_preshrinks[@]}"; do
            printf 'preshrink\t%s\t%s\n' "${p##*/}" "Old pre-shrink (auto-cleaned on swap): $p"
        done
        if [ ${#stale_copies[@]} -gt 0 ]; then
            for sc in "${stale_copies[@]}"; do
                printf 'stale\t%s\t%s\n' "${sc%%$'\t'*}" "${sc#*$'\t'}"
            done
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

    if [ ${#stale_copies[@]} -gt 0 ]; then
        echo "⚠️  Stale shrink copies (${#stale_copies[@]} of ${#runs[@]} vs the live DB):"
        for sc in "${stale_copies[@]}"; do
            echo "  ${sc%%$'\t'*}  —  ${sc#*$'\t'}"
        done
        echo ""
        echo "   Swapping any of these loses the sessions added since; each one is"
        echo "   only as fresh as its own shrink.json says. Create a new copy instead."
        echo "   The pre-shrink safety copy is your only rollback."
        echo ""
        issues=1
    fi

    if [ "$issues" -eq 0 ]; then
        # The count is the point (it says how many were asked), but "all 0
        # copies are up to date" is a sentence nobody should have to read.
        local scope="no shrink copies yet"
        [ "${#runs[@]}" -gt 0 ] && scope="all ${#runs[@]} shrink copies are up to date"
        echo "All clean: no orphan dirs, no old pre-shrinks, $scope."
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
        echo "Stale copies need a manual decision (re-run shrink; swap only on purpose)."
    fi
}