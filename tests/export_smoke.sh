#!/usr/bin/env bash
# export_smoke.sh — end-to-end tests against a fake opencode DB (no real data touched).
# Usage: tests/export_smoke.sh
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$TESTS_DIR/../src"
TMP="$(mktemp -d /tmp/opencode-db-smoke-XXXXXX)"
# Only the TOP-LEVEL shell may delete $TMP: bash runs an inherited EXIT trap in
# EVERY subshell, so one dying subshell would otherwise `rm -rf` the fixture
# mid-run and the suite would keep asserting against a deleted TMP.
smoke_cleanup() { [ "${BASH_SUBSHELL:-0}" -eq 0 ] && rm -rf -- "$TMP"; return 0; }
trap smoke_cleanup EXIT

FAKE="$TMP/fake.db"
OUT="$TMP/out"
BK="$TMP/backups"
bash "$TESTS_DIR/make_fake_db.sh" "$FAKE" >/dev/null

export OPENCODE_DB="$FAKE"
export OCED_OUT="$OUT"
export OCED_BACKUP_DIR="$BK"
EX_PRESETS="$TESTS_DIR/../presets.json"
# Hermetic config: a missing OCED_CONF keeps the suite independent of the
# developer's ~/.config AND of the repo-shipped portable conf (env > conf; the
# portable-detection tests below override this with env -u OCED_CONF ...).
export OCED_CONF="$TMP/missing-conf.conf"
# Pin the display TZ: any date formatting that is not explicitly `date -u` must
# still be deterministic across hosts.
export TZ=UTC

pass=0; fail=0
ok() { echo "  [OK]   $1"; pass=$((pass+1)); }
bad() { echo "  [FAIL] $1"; fail=$((fail+1)); }
run() { bash "$MOD/opencode-db.sh" "$@" 2>&1; }
# stamp_of <run-output> -> the stamp the run itself reported.
# NOT "newest metadata by mtime": two exports inside the same sub-second tick tie
# on %T@, and the sort then picks by path, which can hand back the PREVIOUS run.
# Every test that reads back what it just ran must use the run's own answer.
# The reported path is always the run root.
# of rebuilding it (no basename round-trip, no mtime, no name mangling).
out_dir_of() {   # $1 = run output -> the dir it wrote
    printf '%s' "$1" | sed -n 's/.* to: //p' | tail -1 | sed 's:/*$::'
}
stamp_of() {
    basename "$(out_dir_of "$1")"
}
# Single-product metadata sits at the run root; bundle metadata is product-suffixed.
meta_of() { out_dir_of "$1" | xargs -r -I{} printf '%s/metadata.json' "{}"; }
grep_run() { # $1=pattern, rest=CLI args: capture output before grep (avoids SIGPIPE/pipefail)
    local pat="$1"; shift
    local out; out=$(run "$@")
    printf '%s' "$out" | grep -q "$pat"
}

echo "== Python-only export entry point =="
python3 "$TESTS_DIR/test_exportlib_paths.py" \
    && ok "Python database paths and read-only SQLite URI" \
    || bad "Python database path tests"
PRODUCTS=$(python3 "$TESTS_DIR/../opencode-db-export.py" --list-products 2>&1)
printf '%s' "$PRODUCTS" | grep -q 'transcript' \
    && ok "root Python entry point lists products without Bash" \
    || bad "root Python entry point: $PRODUCTS"
PY_PLAN=$(python3 "$TESTS_DIR/../opencode-db-export.py" transcript --dry-run 2>&1)
printf '%s' "$PY_PLAN" | grep -q '^Matched: ' \
    && ok "root Python entry point reads the fake DB directly" \
    || bad "root Python export dry run: $PY_PLAN"
PY_CHECK=$(python3 "$TESTS_DIR/../opencode-db-export.py" --check --json 2>&1)
printf '%s' "$PY_CHECK" | jq -e --arg db "$FAKE" \
    '.schema_version == 1 and .status == "ready" and .database == $db and .session_count == 6 and .no_data_reason == null and .writes == false' >/dev/null \
    && ok "Python JSON preflight reports database and session count" \
    || bad "Python preflight JSON: $PY_CHECK"
PY_DRY=$(OCED_OUT="$TMP/dry-run-must-not-exist" \
    python3 "$TESTS_DIR/../opencode-db-export.py" transcript --last 1 --dry-run --json 2>&1)
printf '%s' "$PY_DRY" | jq -e \
    '.schema_version == 1 and .status == "ready" and .selected_session_count > 0 and .writes == false and .database_read == true' >/dev/null \
    && [ ! -e "$TMP/dry-run-must-not-exist" ] \
    && ok "Python JSON dry-run reports its selection and creates no output" \
    || bad "Python dry-run JSON or unexpected output: $PY_DRY"
PY_SHOW=$(python3 "$TESTS_DIR/../opencode-db-export.py" complete --show --json 2>&1)
printf '%s' "$PY_SHOW" | jq -e \
    '.schema_version == 1 and .status == "ready" and .profile == "complete" and .database_read == false and .writes == false and (.plan | type == "string")' >/dev/null \
    && ok "Python JSON show returns a static plan without reading the database" \
    || bad "Python show JSON: $PY_SHOW"
EMPTY_DRY=$(OCED_OUT="$TMP/empty-dry-run-must-not-exist" \
    OPENCODE_DB="$FAKE" python3 "$TESTS_DIR/../opencode-db-export.py" transcript \
        --sessions ses_missing --dry-run --json 2>&1); EMPTY_DRY_RC=$?
[ "$EMPTY_DRY_RC" -eq 3 ] \
    && printf '%s' "$EMPTY_DRY" | jq -e \
        '.schema_version == 1 and .status == "no_data" and .selected_session_count == 0 and .no_data_reason != null and .writes == false' >/dev/null \
    && [ ! -e "$TMP/empty-dry-run-must-not-exist" ] \
    && ok "empty Python dry-run has a distinct no-data status and writes nothing" \
    || bad "empty dry-run rc=$EMPTY_DRY_RC: $EMPTY_DRY"
EMPTY_DB="$TMP/empty.db"
python3 - "$EMPTY_DB" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as con:
    con.execute("CREATE TABLE session (id TEXT)")
PY
EMPTY_CHECK=$(OPENCODE_DB="$EMPTY_DB" \
    python3 "$TESTS_DIR/../opencode-db-export.py" --check --json 2>&1); EMPTY_RC=$?
[ "$EMPTY_RC" -eq 3 ] \
    && printf '%s' "$EMPTY_CHECK" | jq -e \
        '.schema_version == 1 and .status == "no_data" and .session_count == 0 and .no_data_reason == "database_has_no_sessions"' >/dev/null \
    && ok "Python preflight distinguishes a valid empty database" \
    || bad "empty database preflight rc=$EMPTY_RC: $EMPTY_CHECK"
MISSING_CHECK=$(OPENCODE_DB="$TMP/missing.db" \
    python3 "$TESTS_DIR/../opencode-db-export.py" --check --json 2>&1); MISSING_RC=$?
[ "$MISSING_RC" -eq 1 ] \
    && printf '%s' "$MISSING_CHECK" | jq -e '.schema_version == 1 and .status == "error" and .session_count == null and .error != null' >/dev/null \
    && ok "Python preflight distinguishes runtime/path errors from no data" \
    || bad "missing database preflight rc=$MISSING_RC: $MISSING_CHECK"

echo "== Python --list-sessions =="
PY_LS=$(OCED_OUT="$TMP/list-must-not-exist" \
    python3 "$TESTS_DIR/../opencode-db-export.py" --list-sessions --json 2>&1)
printf '%s' "$PY_LS" | jq -e --arg db "$FAKE" '
    .schema_version == 1 and .tool == "opencode-db/exportlib"
    and .ok == true and .status == "ready" and .writes == false
    and .sessions_found == 6 and (.sessions | length) == 6
    and .source.resolved == $db and .source.exists == true and .source.origin == "environment"
    and .sessions[0].id == "ses_ORPHAN01"
    and ([.sessions[] | select(.id == "ses_A0002") | .kind] == ["subagent"])
    and ([.sessions[] | select(.id == "ses_ORPHAN01") | .kind] == ["root"])
    and ([.sessions[] | select(.id == "ses_A0001")
          | {title, directory, project_id, source, source_file,
             created_ok: (.created | length > 0), updated_ok: (.updated | length > 0)}]
         == [{title: "Project Alpha", directory: "/tmp/projA", project_id: "proj1",
              source: "opencode", source_file: $db, created_ok: true, updated_ok: true}])
' >/dev/null && [ ! -e "$TMP/list-must-not-exist" ] \
    && ok "Python --list-sessions --json is stable, read-only and ordered updated-desc" \
    || bad "list-sessions JSON: $PY_LS"
PY_LS_TEXT=$(python3 "$TESTS_DIR/../opencode-db-export.py" --list-sessions 2>&1)
printf '%s' "$PY_LS_TEXT" | grep -q '^Sessions found: 6$' \
    && printf '%s' "$PY_LS_TEXT" | grep -q 'ses_ORPHAN01' \
    && printf '%s' "$PY_LS_TEXT" | grep -q 'ses_A0001' \
    && ok "Python --list-sessions prints one line per session" \
    || bad "list-sessions text: $PY_LS_TEXT"
PY_LS_ORDER=$(python3 "$TESTS_DIR/../opencode-db-export.py" \
    --list-sessions --order created-asc --json 2>&1)
printf '%s' "$PY_LS_ORDER" | jq -e '.sessions[0].id == "ses_A0001"' >/dev/null \
    && ok "Python --list-sessions honors --order created-asc" \
    || bad "list-sessions created-asc: $PY_LS_ORDER"
PY_LS_LAST=$(python3 "$TESTS_DIR/../opencode-db-export.py" \
    --list-sessions --last 1 --json 2>&1)
printf '%s' "$PY_LS_LAST" | jq -e '.sessions_found == 1 and .sessions[0].id == "ses_ORPHAN01"' >/dev/null \
    && ok "Python --list-sessions reuses --last" \
    || bad "list-sessions --last: $PY_LS_LAST"
PY_LS_IDS=$(python3 "$TESTS_DIR/../opencode-db-export.py" \
    --list-sessions --sessions ses_A0001 --json 2>&1)
printf '%s' "$PY_LS_IDS" | jq -e '.sessions_found == 1 and .sessions[0].id == "ses_A0001"' >/dev/null \
    && ok "Python --list-sessions reuses exact --sessions" \
    || bad "list-sessions --sessions: $PY_LS_IDS"
EMPTY_LS="$TMP/empty-list.db"; cp "$FAKE" "$EMPTY_LS"
sqlite3 "$EMPTY_LS" 'DELETE FROM session;'
PY_LS_EMPTY=$(OPENCODE_DB="$EMPTY_LS" \
    python3 "$TESTS_DIR/../opencode-db-export.py" --list-sessions --json 2>&1); PY_LS_EMPTY_RC=$?
[ "$PY_LS_EMPTY_RC" -eq 3 ] \
    && printf '%s' "$PY_LS_EMPTY" | jq -e \
        '.status == "no_data" and .sessions_found == 0 and .no_data_reason == "database_has_no_sessions" and .writes == false' >/dev/null \
    && ok "Python --list-sessions distinguishes a valid empty database" \
    || bad "empty list-sessions rc=$PY_LS_EMPTY_RC: $PY_LS_EMPTY"
PY_LS_MISSING=$(OPENCODE_DB="$TMP/missing-list.db" \
    python3 "$TESTS_DIR/../opencode-db-export.py" --list-sessions --json 2>&1); PY_LS_MISSING_RC=$?
[ "$PY_LS_MISSING_RC" -eq 1 ] \
    && printf '%s' "$PY_LS_MISSING" | jq -e \
        '.status == "error" and .sessions_found == null and .error != null and .writes == false' >/dev/null \
    && ok "Python --list-sessions reports a missing database as an error" \
    || bad "missing list-sessions rc=$PY_LS_MISSING_RC: $PY_LS_MISSING"
python3 "$TESTS_DIR/../opencode-db-export.py" --json >/dev/null 2>&1; PY_JSON_RC=$?
[ "$PY_JSON_RC" -eq 2 ] \
    && ok "Python --json still refuses to run without a JSON-producing command" \
    || bad "bare --json rc=$PY_JSON_RC"

PY_COMPLETE=$(HOME="$TMP/python-home" env -u OCED_PRESETS \
    python3 "$TESTS_DIR/../opencode-db-export.py" complete --show 2>&1)
printf '%s' "$PY_COMPLETE" | grep -q '^== Export plan: complete ==' \
    && printf '%s' "$PY_COMPLETE" | grep -q 'transcript + memory + faithful' \
    && ok "Python entry point resolves the shipped complete bundle preset" \
    || bad "Python complete plan: $PY_COMPLETE"
PY_FULL=$(python3 "$TESTS_DIR/../opencode-db-export.py" full --show 2>&1)
printf '%s' "$PY_FULL" | grep -q '^== Export plan: transcript ==' \
    && ok "full is normalized to the transcript product alias" \
    || bad "full alias plan: $PY_FULL"
PY_EXPORT=$(OCED_OUT="$TMP/python-out" python3 "$TESTS_DIR/../opencode-db-export.py" \
    transcript --sessions ses_A0001 2>&1)
PY_MD=$(find "$TMP/python-out" -type f -name '*.md' -print -quit)
printf '%s' "$PY_EXPORT" | grep -q '\[OK\] Exported (transcript)' && [ -n "$PY_MD" ] \
    && ok "root Python entry point writes a transcript without Bash" \
    || bad "root Python export: $PY_EXPORT"
last_transcript() { # $1=profile $2=title (newest by mtime)
    find "$OUT" -type f \( -name "$2.md" -o -name "$2.transcript.md" \) \
        -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-
}
last_meta() { # $1=profile (newest by mtime, path breaks a tie)
    find "$OUT" -type f \( -name metadata.json -o -name "metadata.$1.json" \) -print0 \
        | while IFS= read -r -d '' meta; do
            jq -e --arg profile "$1" '.profile == $profile' "$meta" >/dev/null 2>&1 || continue
            printf '%s\t%s\n' "$(stat -c %y "$meta")" "$meta"
        done | sort -k1,1n -k2,2 | tail -1 | cut -f2-
}

echo "== status (incl. version/schema/deps sections) =="
grep_run "Sessions:" status && ok "status ready" || bad "status"
grep_run "Tables:" status && ok "status reads tables" || bad "status tables"
grep_run "opencode-db:" status && ok "status shows the tool version" || bad "status version section"
grep_run "CLI, max session.version" status && ok "status shows the opencode CLI version" || bad "status opencode version"
grep_run "Schema probe:" status && ok "status shows the schema probe" || bad "status schema section"
grep_run "All expected tables and columns are present" status && ok "status schema probe passes on the fake DB" || bad "status schema ok"
grep_run "Dependencies:" status && ok "status shows the dependencies section" || bad "status deps section"
grep_run "sqlite3" status && ok "status lists the core dependencies" || bad "status deps list"

echo "== version / schema probe =="
V=$(run version)
printf '%s' "$V" | grep -q "opencode-db:" && ok "version shows tool version" || bad "version tool"
printf '%s' "$V" | grep -q "CLI, max session.version" && ok "version shows the opencode CLI version" || bad "version db"
printf '%s' "$V" | grep -q "Migrations:" && ok "version shows schema fingerprint" || bad "version migrations"
printf '%s' "$V" | grep -q "All expected tables and columns are present" && ok "schema probe passes on the fake DB" || bad "schema probe: $V"
# Incomplete DB -> probe must report the gaps and return non-zero.
BADDB="$TMP/incomplete.db"
sqlite3 "$BADDB" "CREATE TABLE session (id TEXT, title TEXT);"
OPENCODE_DB="$BADDB" bash "$MOD/opencode-db.sh" version >"$TMP/badver.txt" 2>&1
rc=$?
grep -q "Missing tables:" "$TMP/badver.txt" && ok "schema probe reports missing tables" || bad "schema probe missing tables"
[ "$rc" -ne 0 ] && ok "schema probe returns non-zero on incompatible schema" || bad "schema probe rc"

echo "== config precedence: env > conf > default =="
CONF="$TMP/oced.conf"
{
    printf 'OCED_ACTIVITY_LOG="/from/conf.log"\n'
    printf 'OCED_OUT="%s/from-conf"\n' "$TMP"
} > "$CONF"
PREC=$(OCED_CONF="$CONF" OCED_ACTIVITY_LOG="/from/env.log" bash -c '. "$1"; printf "%s" "$OCED_ACTIVITY_LOG"' _ "$MOD/common.sh")
[ "$PREC" = "/from/env.log" ] && ok "env OCED_ACTIVITY_LOG beats conf" || bad "precedence activity log: $PREC"
PREC=$(OCED_CONF="$CONF" OCED_FROM_BACKUP="env-backup.db" bash -c '. "$1"; printf "%s" "$OCED_FROM_BACKUP"' _ "$MOD/common.sh")
[ "$PREC" = "env-backup.db" ] && ok "env OCED_FROM_BACKUP beats conf" || bad "precedence from-backup: $PREC"
PREC=$(env -u OCED_OUT OCED_CONF="$CONF" bash -c '. "$1"; printf "%s" "$OCED_OUT"' _ "$MOD/common.sh")
[ "$PREC" = "$TMP/from-conf" ] && ok "conf value applies when the env does not set it" || bad "conf applies: $PREC"

echo "== portable: repo-shipped config (no install) =="
# The shipped real files are the SOLE source of truth (there are no .example
# copies to drift from anymore), so the guards validate them directly.
PORT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
PORT_JSON="$PORT_ROOT/presets.json"
PORT_CONF="$PORT_ROOT/opencode-db.conf"
python3 "$TESTS_DIR/validate_schema.py" "$TESTS_DIR/../generated/presets.schema.json" "$PORT_JSON" >/dev/null 2>&1 \
    && ok "shipped presets.json satisfies presets.schema.json" || bad "shipped presets.json vs schema"
[ -s "$PORT_JSON" ] && [ -s "$PORT_ROOT/shrink-presets.json" ] && [ -s "$PORT_CONF" ] \
    && ok "shipped conf/presets are non-empty files" || bad "shipped config files missing/empty"

# Fake HOME with NO .config/opencode-db: the repo files are the defaults and the
# data dirs live inside the repo (gitignored). OCED_CONF must be unset so the
# default resolution runs; env -u strips the hermetic export above.
FAKEHOME="$TMP/fakehome"
mkdir -p "$FAKEHOME"
PORT_DEFAULTS=$(HOME="$FAKEHOME" env -u OCED_CONF -u OCED_OUT -u OCED_BACKUP_DIR -u OCED_PRESETS -u OCED_SHRINK_PRESETS \
    bash -c '. "$1"; printf "%s\n%s\n%s\n" "$OCED_CONF" "$OCED_OUT" "$OCED_BACKUP_DIR"' _ "$MOD/common.sh")
POC=$(printf '%s\n' "$PORT_DEFAULTS" | sed -n 1p)
POUT=$(printf '%s\n' "$PORT_DEFAULTS" | sed -n 2p)
PBK=$(printf '%s\n' "$PORT_DEFAULTS" | sed -n 3p)
[ "$POC" = "$PORT_CONF" ] && ok "portable OCED_CONF resolves to the repo conf" || bad "portable OCED_CONF: $POC"
[ "$POUT" = "$PORT_ROOT/exports" ] && ok "portable OCED_OUT defaults into the repo" || bad "portable OCED_OUT: $POUT"
[ "$PBK" = "$PORT_ROOT/backups" ] && ok "portable OCED_BACKUP_DIR defaults into the repo" || bad "portable OCED_BACKUP_DIR: $PBK"

# A checkout keeps repo-local data defaults even if a Linux install left its
# user config behind. Only an explicit OCED_OUT in that config changes it.
INSTALLED_HOME="$TMP/installed-home"
mkdir -p "$INSTALLED_HOME/.config/opencode-db"
printf '# installed user config; output remains unset\n' > "$INSTALLED_HOME/.config/opencode-db/opencode-db.conf"
CHECKOUT_WITH_HOME_CONF=$(HOME="$INSTALLED_HOME" env -u OCED_CONF -u OCED_OUT -u OCED_BACKUP_DIR \
    bash -c '. "$1"; printf "%s\n%s\n%s\n" "$OCED_OUT" "$OCED_BACKUP_DIR" "$OCED_ACTIVITY_LOG"' _ "$MOD/common.sh")
[ "$(printf '%s\n' "$CHECKOUT_WITH_HOME_CONF" | sed -n 1p)" = "$PORT_ROOT/exports" ] \
    && ok "a leftover install config does not redirect checkout exports" \
    || bad "checkout with install config OCED_OUT: $(printf '%s\n' "$CHECKOUT_WITH_HOME_CONF" | sed -n 1p)"
[ "$(printf '%s\n' "$CHECKOUT_WITH_HOME_CONF" | sed -n 2p)" = "$PORT_ROOT/backups" ] \
    && ok "checkout backup default stays repo-local with a user config" \
    || bad "checkout with install config backup dir: $(printf '%s\n' "$CHECKOUT_WITH_HOME_CONF" | sed -n 2p)"
CHECKOUT_OVERRIDE=$(HOME="$INSTALLED_HOME" env -u OCED_CONF OCED_OUT="$TMP/custom-exports" \
    bash -c '. "$1"; printf "%s" "$OCED_OUT"' _ "$MOD/common.sh")
[ "$CHECKOUT_OVERRIDE" = "$TMP/custom-exports" ] \
    && ok "explicit OCED_OUT still overrides checkout default" \
    || bad "checkout OCED_OUT override: $CHECKOUT_OVERRIDE"

# End-to-end: the repo presets are actually usable — `complete` exists only in the
# shipped presets.json, so resolving it proves the portable default kicked in.
PO="$TMP/po"
mkdir -p "$PO"
PORT_RUN=$(HOME="$FAKEHOME" env -u OCED_CONF -u OCED_OUT -u OCED_BACKUP_DIR -u OCED_PRESETS -u OCED_SHRINK_PRESETS \
    OPENCODE_DB="$FAKE" OCED_OUT="$PO" bash "$MOD/opencode-db.sh" export complete --sessions ses_A0001 2>&1)
[ -n "$(find "$PO" \( -name metadata.json -o -name 'metadata.*.json' \) -type f 2>/dev/null | head -1)" ] \
    && ok "portable export resolves the repo presets (complete)" \
    || bad "portable export: $(printf '%s' "$PORT_RUN" | tail -2)"

# A user ~/.config presets file beats the repo-shipped one (the repo is only the
# no-install fallback, exactly what the precedence promise says).
mkdir -p "$FAKEHOME/.config/opencode-db"
printf '{"presets":{"myhome":{"product":"memory"}}}\n' > "$FAKEHOME/.config/opencode-db/presets.json"
PO2="$TMP/po2"
mkdir -p "$PO2"
PORT_HOME=$(HOME="$FAKEHOME" env -u OCED_CONF -u OCED_OUT -u OCED_BACKUP_DIR -u OCED_PRESETS -u OCED_SHRINK_PRESETS \
    OPENCODE_DB="$FAKE" OCED_OUT="$PO2" bash "$MOD/opencode-db.sh" export myhome --sessions ses_A0001 2>&1)
[ -n "$(find "$PO2" -name metadata.json 2>/dev/null | head -1)" ] \
    && ok "a user ~/.config preset wins over the repo file" \
    || bad "home preset precedence: $(printf '%s' "$PORT_HOME" | tail -2)"

# An install prefix ships the src tree only, never a repo-config copy, so it must
# NOT go portable: defaults stay in ~/. local/share/opencode-db-exporter/.
PFX2="$TMP/prefix"
mkdir -p "$PFX2"
cp -r "$TESTS_DIR/../src" "$PFX2/src"
NPFX=$(HOME="$FAKEHOME" env -u OCED_CONF -u OCED_OUT -u OCED_BACKUP_DIR -u OCED_PRESETS \
    bash -c '. "$1"; printf "%s" "$OCED_OUT"' _ "$PFX2/src/common.sh")
[ "$NPFX" = "$FAKEHOME/.local/share/opencode-db-exporter/exports" ] \
    && ok "an install prefix without the repo conf stays non-portable" \
    || bad "prefix portable leak: $NPFX"

echo "== the guide is gone =="
# The interactive guide was removed: its three steps are the pickers (exports /
# shrinks / swap), and a linear read-stdin wizard nested inside fzf was both
# fragile (run_oced_tool buffers stdout, so its prompts appeared out of order)
# and redundant. The command must be GONE, not merely undocumented: a silent
# alias would still leave the broken wizard on disk.
HB=$(run help)
printf '%s' "$HB" | grep -qi "guide" && bad "help still advertises guide" || ok "help no longer mentions guide"
run guide >/dev/null 2>&1 && bad "guide subcommand still exists" || ok "guide subcommand is gone"

echo "== list =="
grep_run "Project" list --root && ok "list --root" || bad "list --root"
grep_run "ORPHAN" list --sub --info && ok "list --sub includes orphan" || bad "list --sub"
grep_run "Project Beta" list --filter 'Project Beta' && ok "list --filter" || bad "list --filter"

echo "== info / digest =="
I=$(run info ses_A0001); grep_run "Digests" info ses_A0001 && ok "info" || bad "info"
printf "%s" "$I" | grep -q "1$" && ok "info counts 1 compaction" || bad "info count"
# A detail screen must lead with a banner: the raw `key = value` dump is unreadable alone.
printf "%s" "$I" | sed -n '1p' | grep -q "^== Session (ses_A0001)" \
    && ok "info leads with a session header" || bad "info header: $(printf '%s' "$I" | sed -n '1p')"
# --no-digest is the REPORT filter behind the browse screen's compactions toggle:
# `info` ends with the digest block, so hiding compactions means dropping it,
# not calling `digest` a second time.
IN=$(run info ses_A0001 --no-digest)
printf "%s" "$IN" | grep -q "== Session (ses_A0001)" \
    && ok "info --no-digest keeps the session dump" || bad "info --no-digest dump"
printf "%s" "$IN" | grep -q "== Digests" && bad "info --no-digest still prints digests" \
    || ok "info --no-digest drops the digest block"
printf "%s" "$IN" | grep -q "parts_compaction = 1" \
    && ok "info --no-digest keeps the compaction counter" || bad "info --no-digest counter"
grep_run "Usage: opencode-db info" info ses_A0001 --bogus && ok "info rejects an unknown flag" \
    || bad "info accepted an unknown flag"
IJ=$(run info ses_A0001 --json)
printf "%s" "$IJ" | jq -e '.[0].id == "ses_A0001"' >/dev/null \
    && ok "info --json is a structured row" || bad "info --json"
printf '%s' "$IJ" | grep -q "== Session" && bad "info --json header" || ok "info --json has no header"
# `compactions` stays a working deprecated alias of `digest`.
CA=$(run compactions ses_A0001)
CB=$(run digest ses_A0001)
[ "$CA" = "$CB" ] && ok "compactions is a deprecated alias of digest" || bad "alias compactions != digest"
printf "%s" "$CB" | grep -q "Digests:" && ok "digest detected" || bad "digest"

echo "== backup =="
grep_run "No backups recorded yet." backups list && ok "backups list w/o manifest" || bad "backups list w/o manifest"

# --dry-run: the plan and NOTHING else. The menu prints it BEFORE its own y/N and
# then runs `backup --yes`, so a dry-run that wrote a file (or asked something) would
# create a backup the user never confirmed.
NFILES_BEFORE=$(find "$BK" -maxdepth 1 -name 'opencode-*' 2>/dev/null | wc -l)
NMANIFEST_BEFORE=$(jq -r '.backups | length' "$BK/manifest.json" 2>/dev/null || echo 0)
DRY=$(run backup --dry-run)
printf '%s' "$DRY" | grep -q "Backup plan" && printf '%s' "$DRY" | grep -q "Est\. size:" \
    && ok "backup --dry-run prints the plan (source/target/est. size)" || bad "backup dry-run plan: [$(printf '%s' "$DRY" | tail -3)]"
printf '%s' "$DRY" | grep -q "Target:" && ok "backup --dry-run names the target dir + compression" \
    || bad "backup dry-run target: [$(printf '%s' "$DRY" | tail -3)]"
printf '%s' "$DRY" | grep -q "nothing written" && ok "backup --dry-run says it wrote nothing" \
    || bad "backup dry-run note: [$(printf '%s' "$DRY" | tail -2)]"
printf '%s' "$DRY" | grep -q 'Create this backup?' && bad "backup --dry-run still asks to confirm" \
    || ok "backup --dry-run asks nothing (the menu owns the gate)"
[ "$(find "$BK" -maxdepth 1 -name 'opencode-*' 2>/dev/null | wc -l)" -eq "$NFILES_BEFORE" ] \
    && ok "backup --dry-run wrote no backup file" || bad "backup dry-run wrote a file"
[ "$(jq -r '.backups | length' "$BK/manifest.json" 2>/dev/null || echo 0)" -eq "$NMANIFEST_BEFORE" ] \
    && ok "backup --dry-run added no manifest entry" || bad "backup dry-run touched the manifest"
# --dry-run wins over --yes (it is the stronger "write nothing" promise), and the
# prompt is skipped either way: an unknown flag must still be refused.
DRY2=$(run backup --dry-run --yes)
[ "$(find "$BK" -maxdepth 1 -name 'opencode-*' 2>/dev/null | wc -l)" -eq "$NFILES_BEFORE" ] \
    && ok "backup --dry-run --yes still writes nothing" || bad "backup dry-run --yes wrote a file"
printf '%s' "$DRY2" | grep -q "Backup plan" && ok "backup --dry-run --yes still shows the plan (--dry-run always does)" \
    || bad "backup --dry-run --yes lost the plan"
grep_run "Unknown argument: --nope" backup --nope && ok "backup refuses an unknown flag" || bad "backup unknown flag"

B=$(run backup --yes)
printf "%s" "$B" | grep -qE "opencode-[0-9-]+\.db\.gz" && ok "compressed backup" || bad "backup"
# --yes means "the caller owns the gate and already showed the plan". Re-printing
# it put the SAME block twice on the menu screen (reported live: the plan appeared
# again right after answering y). The plan's fields are asserted on --dry-run above.
printf "%s" "$B" | grep -q "Backup plan" && bad "backup --yes repeats the plan the caller showed" \
    || ok "backup --yes does not repeat the plan (one decision, one plan)"
printf "%s" "$B" | grep -q "\[OK\] Backup:" && ok "backup --yes still reports the created backup" \
    || bad "backup --yes report: [$(printf '%s' "$B" | tail -3)]"
grep_run "opencode-" backups list && ok "backups list" || bad "backups list"
FNAME=$(run backups list | grep -oE 'opencode-[0-9-]+\.db\.gz' | head -1)
grep_run "OK" backups verify "$FNAME" && ok "backups verify" || bad "backups verify"

# backups view: the manifest record + the sha256 check + how it compares to live
V=$(run backups view "$FNAME")
printf '%s' "$V" | grep -q "== Backup: $FNAME ==" && ok "backups view names the backup" || bad "backups view header"
printf '%s' "$V" | grep -q "Created:  " && ok "backups view shows when it was made" || bad "backups view date"
printf '%s' "$V" | grep -q "before gzip" && ok "backups view shows the raw size next to the stored one" || bad "backups view size"
printf '%s' "$V" | grep -qE "Content: +[0-9]+ sessions · [0-9]+ messages · [0-9]+ parts" && ok "backups view shows the recorded counts" || bad "backups view counts: $V"
printf '%s' "$V" | grep -q "Newest:  " && ok "backups view shows the newest session timestamp" || bad "backups view newest"
printf '%s' "$V" | grep -q "Source DB:" && ok "backups view names the source DB" || bad "backups view source"
printf '%s' "$V" | grep -qE "sha256: +[0-9a-f]{12}…[0-9a-f]{4}" && ok "backups view shows the manifest sha256 (abbreviated)" || bad "backups view sha"
printf '%s' "$V" | grep -q "\[OK\].*matches the manifest" && ok "backups view RUNS the sha256 check" || bad "backups view check"
printf '%s' "$V" | grep -q "vs live DB:" && ok "backups view compares the copy with the live DB" || bad "backups view live"
printf '%s' "$V" | grep -q -- "--from-backup $FNAME" && ok "backups view shows how to use the copy" || bad "backups view restore hint"
grep_run "Usage: opencode-db backups view" backups view && ok "backups view without a file prints the usage" || bad "backups view usage"
grep_run "Not in the manifest" backups view nope.db && ok "backups view refuses an unknown file" || bad "backups view unknown"

# A byte flipped on disk must NOT pass as the manifest copy.
TDIR="$TMP/tampered"
cp -r "$BK" "$TDIR"
printf 'X' | dd of="$TDIR/$FNAME" bs=1 seek=64 conv=notrunc status=none
T=$(OCED_BACKUP_DIR="$TDIR" run backups view "$FNAME")
printf '%s' "$T" | grep -q "MISMATCH" && ok "backups view reports a tampered backup as MISMATCH" || bad "backups view tamper"
printf '%s' "$T" | grep -qE "manifest: [0-9a-f]{64}" && ok "backups view prints both hashes on a mismatch" || bad "backups view tamper hashes"
OCED_BACKUP_DIR="$TDIR" grep_run "MISMATCH" backups verify "$FNAME" && ok "verify agrees with view on the tamper" || bad "verify tamper"
rm -f "$TDIR/$FNAME"
M=$(OCED_BACKUP_DIR="$TDIR" run backups view "$FNAME")
printf '%s' "$M" | grep -q "MISSING" && ok "backups view reports a deleted file as MISSING" || bad "backups view missing"
OCED_BACKUP_DIR="$TDIR" grep_run "File not found" backups verify "$FNAME" && ok "verify agrees with view on the missing file" || bad "verify missing"
grep_run "Aligned" status && ok "status aligned after backup" || bad "alignment"

# Per-row freshness: `backups list` tags the copy `(stale)` once the live DB has
# moved on — one tag PER ROW, not only for the newest. Isolated DB so the shared
# $FAKE (read by every other test) is never mutated by the UPDATE below.
SDB="$TMP/stale.db"; SBK="$TMP/stale-bk"
bash "$TESTS_DIR/make_fake_db.sh" "$SDB" >/dev/null
OPENCODE_DB="$SDB" OCED_BACKUP_DIR="$SBK" run backup --yes >/dev/null
SL=$(OPENCODE_DB="$SDB" OCED_BACKUP_DIR="$SBK" run backups list)
printf '%s' "$SL" | grep -q "(stale)" && bad "backups list tags an aligned copy as stale" \
    || ok "backups list leaves an aligned copy untagged"
sqlite3 "$SDB" "UPDATE session SET time_updated = time_updated + 1000000;"
OPENCODE_DB="$SDB" OCED_BACKUP_DIR="$SBK" grep_run "(stale)" backups list \
    && ok "backups list tags a diverged copy as (stale)" || bad "backups list stale tag"

# Pre-shrink safety copy (what --swap snapshots before replacing the live DB):
# registered as the manifest's `.pre_shrink` SINGLETON, but it belongs to the
# SHRINK domain — `backups` never lists or accepts it, `shrinks preshrink`
# shows/checks/removes it, `status` reports it, and `prune` never drops it.
PSBK="$TMP/ps-bk"; mkdir -p "$PSBK/pre-shrink"
PSNAME="opencode.pre-shrink-1789002100.db"
head -c 2048 /dev/zero > "$PSBK/pre-shrink/$PSNAME"
PSSHA=$(sha256sum "$PSBK/pre-shrink/$PSNAME" | cut -d' ' -f1)
LIVE_MAX=$(sqlite3 "$SDB" "SELECT coalesce(max(time_updated),0) FROM session")
jq -n --arg f "pre-shrink/$PSNAME" --arg sha "$PSSHA" --argjson mu "$LIVE_MAX" \
    '{backups: [], pre_shrink: {date:"2026-09-09T00:00:00Z", file:$f, kind:"pre-shrink",
       sha256:$sha, sha256_raw:$sha, size:2048, size_raw:2048,
       sessions:1, messages:0, parts:0, max_updated:$mu, source:"/tmp/x.db"}}' > "$PSBK/manifest.json"
# `backups` NEVER list or accept it (it belongs to the shrink domain); `status`
# still reports it, because it is the rollback of the LIVE DB.
PSL=$(OPENCODE_DB="$SDB" OCED_BACKUP_DIR="$PSBK" run backups list)
printf '%s' "$PSL" | grep -q "$PSNAME" && bad "backups list leaked the pre-shrink" \
    || ok "backups list never shows the pre-shrink"
PSB=$(OPENCODE_DB="$SDB" OCED_BACKUP_DIR="$PSBK" run backups view "pre-shrink/$PSNAME" 2>&1)
printf '%s' "$PSB" | grep -q "Not in the manifest" \
    && ok "backups view refuses the pre-shrink (not a backup)" || bad "backups view: [$PSB]"
PST=$(OPENCODE_DB="$SDB" OCED_BACKUP_DIR="$PSBK" run status)
printf '%s' "$PST" | grep -q "Safety:.*$PSNAME" && ok "status surfaces the pre-shrink as Safety" \
    || bad "status safety: $(printf '%s' "$PST" | sed -n '/Shrinks/,/Version/p')"
printf '%s' "$PST" | grep -q "fresh — the live DB has not moved past it" \
    && ok "status reports a fresh pre-shrink" || bad "status fresh verdict: [$PST]"
# `shrinks preshrink` is its screen: details + sha check + freshness verdict.
PSS=$(OPENCODE_DB="$SDB" OCED_BACKUP_DIR="$PSBK" run shrinks preshrink)
printf '%s' "$PSS" | grep -q "== Pre-shrink safety copy ==" && ok "shrinks preshrink leads with its banner" || bad "preshrink view: [$PSS]"
printf '%s' "$PSS" | grep -q "$PSNAME" && ok "shrinks preshrink names the file" || bad "preshrink name"
printf '%s' "$PSS" | grep -q "the file matches the manifest" && ok "shrinks preshrink sha-checks the copy" || bad "preshrink sha"
printf '%s' "$PSS" | grep -q "has not moved past it" && ok "shrinks preshrink: fresh verdict" || bad "preshrink fresh: [$PSS]"
printf '%s' "$(OPENCODE_DB="$SDB" OCED_BACKUP_DIR="$PSBK" run shrinks preshrink --json)" \
    | jq -e --arg f "pre-shrink/$PSNAME" '.file == $f' >/dev/null \
    && ok "shrinks preshrink --json returns the raw record" || bad "preshrink json"
# prune rewrites .backups and must leave .pre_shrink alone.
jq -n --arg f "pre-shrink/$PSNAME" --arg sha "$PSSHA" \
    '{backups: [
       {date:"2026-09-01T00:00:00Z", file:"opencode-old.db",  sha256:"x", sha256_raw:"x", size:1, size_raw:1, sessions:0, messages:0, parts:0, max_updated:"0", source:"/tmp/x.db"},
       {date:"2026-09-02T00:00:00Z", file:"opencode-new.db",  sha256:"y", sha256_raw:"y", size:1, size_raw:1, sessions:0, messages:0, parts:0, max_updated:"0", source:"/tmp/x.db"}],
       pre_shrink: {date:"2026-09-09T00:00:00Z", file:$f, kind:"pre-shrink",
         sha256:$sha, sha256_raw:$sha, size:2048, size_raw:2048,
         sessions:1, messages:0, parts:0, max_updated:"0", source:"/tmp/x.db"}}' > "$PSBK/manifest.json"
: > "$PSBK/opencode-old.db"; : > "$PSBK/opencode-new.db"
OPENCODE_DB="$SDB" OCED_BACKUP_DIR="$PSBK" run backups prune 1 >/dev/null
jq -e '.pre_shrink.file' "$PSBK/manifest.json" >/dev/null \
    && ok "backups prune keeps the .pre_shrink singleton" || bad "prune dropped .pre_shrink"
# A copy with no usable max_updated is flagged as unverifiable; one the live DB
# has moved past is flagged stale. Same helper behind status and the CLI screen.
printf '%s' "$(OPENCODE_DB="$SDB" OCED_BACKUP_DIR="$PSBK" run shrinks preshrink)" \
    | grep -q "cannot verify freshness" && ok "shrinks preshrink flags an unverifiable copy" || bad "preshrink unverifiable"
jq '.pre_shrink.max_updated = "1"' "$PSBK/manifest.json" > "$TMP/ps-stale.json" && mv "$TMP/ps-stale.json" "$PSBK/manifest.json"
printf '%s' "$(OPENCODE_DB="$SDB" OCED_BACKUP_DIR="$PSBK" run status)" \
    | grep -q "newer than this rollback copy" && ok "status flags a stale pre-shrink" || bad "status stale verdict"
# `shrinks preshrink remove` clears the singleton and deletes the file; `backups`
# is never touched.
OPENCODE_DB="$SDB" OCED_BACKUP_DIR="$PSBK" run shrinks preshrink remove --yes >/dev/null
[ -f "$PSBK/pre-shrink/$PSNAME" ] && bad "pre-shrink file not removed" || ok "shrinks preshrink remove deletes the file"
jq -e 'has("pre_shrink") | not' "$PSBK/manifest.json" >/dev/null \
    && ok "shrinks preshrink remove clears .pre_shrink" || bad "pre_shrink still in manifest"
OPENCODE_DB="$SDB" OCED_BACKUP_DIR="$PSBK" run shrinks preshrink 2>&1 | grep -q "No pre-shrink safety copy" \
    && ok "shrinks preshrink says when there is none" || bad "preshrink empty message"

# status carries a Shrinks section (the other snapshot family). It is empty
# before any shrink copy exists; the populated case is asserted in the shrink
# section below, right after the first copy is made.
STAT=$(run status)
printf '%s' "$STAT" | grep -q "Shrinks:" && ok "status has a Shrinks section" || bad "status Shrinks section"
printf '%s' "$STAT" | grep -q "No shrink copies yet" && ok "status says when there are no shrink copies" \
    || bad "status shrink empty"


echo "== activity log (opt-in OCED_LOG) =="
LOGFILE="$TMP/activity.log"
OCED_LOG=1 OCED_ACTIVITY_LOG="$LOGFILE" run backup --yes >/dev/null
grep -q "backup created" "$LOGFILE" && ok "OCED_LOG records backup" || bad "OCED_LOG backup"
run export transcript --stamp logtest-a >/dev/null
run export transcript --stamp logtest-b >/dev/null
OCED_LOG=1 OCED_ACTIVITY_LOG="$LOGFILE" run exports prune 1 --yes >/dev/null
grep -q "exports prune" "$LOGFILE" && ok "OCED_LOG records prune" || bad "OCED_LOG prune"
run exports prune 99 --yes >/dev/null

echo "== deps --check =="
grep_run "All core dependencies present." deps --check && ok "deps --check" || bad "deps --check"

echo "== export transcript default =="
grep_run "Exported" export transcript && ok "transcript export" || bad "transcript export"
TC=$(cat "$(last_transcript transcript 'Project-Alpha')")
echo "$TC" | grep -q "**Tool:**" && ok "transcript keeps tool calls" || bad "transcript no tools"
echo "$TC" | grep -q "Let me think first" && ok "transcript keeps reasoning by default" || bad "transcript reasoning lost"
printf '%s\n' "$TC" | sed -n '1,12p' | grep -qx -- '---' \
    && printf '%s\n' "$TC" | sed -n '1,12p' | grep -q '^session_id: "ses_A0001"$' \
    && printf '%s\n' "$TC" | sed -n '1,12p' | grep -q '^agent: "build"$' \
    && printf '%s\n' "$TC" | sed -n '1,12p' | grep -q '^messages: ' \
    && printf '%s\n' "$TC" | sed -n '1,12p' | grep -q '^---$' \
    && ok "transcript metadata is Obsidian YAML frontmatter" \
    || bad "transcript frontmatter: $(printf '%s\n' "$TC" | sed -n '1,14p')"
MT=$(last_meta transcript)
jq -e '.profile == "transcript" and .flags.sanitize == false and .flags.no_reasoning == false and .flags.tool_output == "truncated"' "$MT" >/dev/null \
    && ok "transcript metadata reflects the flags" || bad "transcript metadata: $(jq -c '{profile,flags}' "$MT")"

echo "== export transcript --no-reasoning =="
run export transcript --no-reasoning --filter ses_A0001 >/dev/null
TC=$(cat "$(last_transcript transcript 'Project-Alpha')")
echo "$TC" | grep -q "Let me think first" && bad "no-reasoning kept reasoning" || ok "no-reasoning omits reasoning"
echo "$TC" | grep -q "I'll look at the files" && ok "no-reasoning keeps the text" || bad "no-reasoning lost text"
MT=$(last_meta transcript)
jq -e '.flags.no_reasoning == true' "$MT" >/dev/null && ok "no-reasoning recorded in metadata" || bad "no-reasoning metadata"

echo "== export transcript --role user (prompts only, flag not a preset) =="
run export transcript --role user --filter ses_A0001 >/dev/null
TC=$(cat "$(last_transcript transcript 'Project-Alpha')")
echo "$TC" | grep -q "Done\." && bad "--role user kept the assistant answer" || ok "--role user excludes assistant messages"
echo "$TC" | grep -q "Still working" && ok "--role user keeps the prompts" || bad "--role user lost prompts"

echo "== digest show =="
CS=$(run digest ses_A0001 show last)
# A marker and a digest are two different things and must be counted separately.
printf '%s' "$CS" | grep -qE "Compaction markers: +1" && ok "digest counts markers" || bad "digest markers"
printf '%s' "$CS" | grep -qE "Digests: +1" && ok "digest counts digests" || bad "digests count"
printf '%s' "$CS" | grep -q "DIGEST_A" && ok "digest show last" || bad "digest show"

echo "== export digest profile =="
# 'compactions' is the deprecated alias of 'digest' and must resolve to the SAME
# product (same folder, same metadata), not a second product.
ALIASOUT=$(run export compactions --filter ses_A0001 --stamp "digest-alias")
ALIASMETA=$(meta_of "$ALIASOUT")
jq -e '.profile == "digest"' "$ALIASMETA" >/dev/null \
    && ok "the compactions alias normalises to the digest profile" || bad "alias profile: $(jq -r '.profile' "$ALIASMETA")"
DIGRUN=$(run export digest --filter ses_A0001 --stamp "digest-run")
CC=$(cat "$(out_dir_of "$DIGRUN")"/*/'Project-Alpha'*.md)
echo "$CC" | grep -q "DIGEST_A" && ok "digest profile exported" || bad "digest profile"
echo "$CC" | grep -q "\*\*Tool:\*\*" && bad "digest profile has tools" || ok "digest profile no tools"
printf '%s\n' "$CC" | sed -n '1,14p' | grep -q '^profile: "digest"$' \
    && printf '%s\n' "$CC" | sed -n '1,14p' | grep -q '^digests: 1$' \
    && ok "digest metadata is YAML frontmatter" \
    || bad "digest frontmatter: $(printf '%s\n' "$CC" | sed -n '1,14p')"

echo "== long output truncation =="
run export transcript --filter ses_B0001 >/dev/null
FT=$(cat "$(last_transcript transcript 'Project-Beta')")
echo "$FT" | grep -q "truncated:" && ok "long output truncated" || bad "output not truncated"

echo "== transcript toggles: compaction markers + summary diffs =="
run export transcript --mark-compactions --summary-diffs --filter ses_A0001 >/dev/null
TC2=$(cat "$(last_transcript transcript 'Project-Alpha')")
echo "$TC2" | grep -q "Context compaction" && ok "compaction marker" || bad "compaction marker"
echo "$TC2" | grep -q "Summary of changes" && ok "summary diffs" || bad "summary diffs"
echo "$TC2" | grep -Eq '<!-- step-(start|finish) -->' && bad "structural step markers leaked into Markdown" || ok "structural step markers omitted from Markdown"

echo "== conversation preset omits marker-only messages and separator noise =="
sqlite3 "$FAKE" <<'SQL'
INSERT INTO message VALUES
 ('msg_A_structural','ses_A0001',1789000500000,1789000500000,
  '{"role":"assistant","time":{"created":1789000500000},"agent":"build"}');
INSERT INTO part VALUES
 ('prt_A_struct_start','msg_A_structural','ses_A0001',1789000500001,1789000500001,
  '{"type":"step-start","tool":"plan"}'),
 ('prt_A_struct_finish','msg_A_structural','ses_A0001',1789000500002,1789000500002,
  '{"type":"step-finish","reason":"tool-calls"}');
SQL
CONV_RUN=$(run export conversation --sessions ses_A0001)
CONV_DIR=$(out_dir_of "$CONV_RUN")
CONV_FILE=$(find "$CONV_DIR" -name 'Project-Alpha.md' -type f -print -quit)
[ -f "$CONV_DIR/metadata.json" ] && [ ! -d "$CONV_DIR/transcript" ] \
    && ok "conversation writes directly into its run root" \
    || bad "conversation created an extra product directory: $CONV_DIR"
if grep -Eq '<!-- step-(start|finish) -->' "$CONV_FILE"; then
    bad "conversation includes structural step comments"
else
    ok "conversation omits internal step comments"
fi
[ "$(grep -c '^## Assistant' "$CONV_FILE")" -eq 4 ] \
    && ok "marker-only assistant message has no empty timestamp heading" \
    || bad "conversation assistant headings: $(grep -c '^## Assistant' "$CONV_FILE")"
[ "$(grep -c '^---$' "$CONV_FILE")" -eq 2 ] \
    && ok "conversation has only the two frontmatter delimiters, no per-message separator noise" \
    || bad "conversation horizontal rules: $(grep -c '^---$' "$CONV_FILE")"
sqlite3 "$FAKE" "DELETE FROM part WHERE message_id='msg_A_structural'; DELETE FROM message WHERE id='msg_A_structural';"

echo "== token backfill from step-finish (session row has 0 tokens) =="
run export transcript --filter ses_A0001 >/dev/null
MT=$(last_meta transcript)
jq -e '.tokens_backfilled == 1' "$MT" >/dev/null && ok "metadata records the backfill" || bad "tokens_backfilled: $(jq '.tokens_backfilled' "$MT")"
run export memory --filter ses_A0001 >/dev/null
MB=$(last_meta memory); MB="${MB%/metadata.json}"
printf '%s' "$(sed -n '1p' "$MB/corpus.jsonl")" | jq -e '.tokens.input == 1100 and .tokens.output == 600 and .tokens.reasoning == 80 and .tokens.cache.read == 50 and .tokens.cache.write == 120 and .tokens.backfilled == true and .cost == 0.05' >/dev/null \
    && ok "memory corpus exposes the backfilled tokens + cost" || bad "memory backfill: $(sed -n '1p' "$MB/corpus.jsonl" | jq -c '.tokens')"

echo "== contract hardening: schema_version / model / null / ISO dates =="
printf '%s' "$(sed -n '1p' "$MB/corpus.jsonl")" | jq -e '.schema_version == 1 and .model == "model-a" and .parent_id == null and .created == "2026-09-10T00:26:40Z"' >/dev/null \
    && ok "corpus line: schema_version, plain model id, null parent, ISO date" \
    || bad "corpus contract: $(sed -n '1p' "$MB/corpus.jsonl" | jq -c '{schema_version,model,parent_id,created}')"
jq -e '.flags.files == false and .artifacts == ["corpus.jsonl", "index.md"] and .profile == "memory"' "$MB/metadata.json" >/dev/null \
    && ok "memory metadata: flags.files false + artifacts list" \
    || bad "memory meta contract: $(jq -c '{flags,artifacts,profile}' "$MB/metadata.json")"

echo "== faithful product (lossless JSON archive) =="
run export faithful --filter ses_A0001 >/dev/null
FR=$(find "$OUT" -type f \( -name 'Project-Alpha.json' -o -name 'Project-Alpha.faithful.json' \) \
    -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
[ -n "$FR" ] && ok "faithful JSON file written in the run/session folder" || bad "faithful json file missing"
jq -e '.info.id == "ses_A0001" and .info.tokens.input == 1100 and .info.tokens.backfilled == true and .info.cost == 0.05' "$FR" >/dev/null \
    && ok "faithful info carries the backfilled tokens" || bad "faithful info tokens"
jq -e '.messages | length == 6' "$FR" >/dev/null && ok "faithful keeps ALL messages (6)" || bad "faithful messages: $(jq '.messages | length' "$FR")"
jq -e '.messages[0].parts[0].type == "text"' "$FR" >/dev/null && ok "faithful message shape {info, parts}" || bad "faithful shape"
jq -e '[.messages[].parts[].type] | index("step-finish") != null' "$FR" >/dev/null \
    && ok "faithful keeps raw step-finish parts" || bad "faithful lost step-finish parts"
printf '%s' "$(cat "$FR")" | grep -q "sk-test1234567890abcdefghijkl" && ok "faithful keeps raw data when not sanitizing" || bad "faithful raw data missing"
jq -e '.info.model == "model-a" and .info.parentId == null and .info.agent == "build" and (.info.time.created | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' "$FR" >/dev/null \
    && ok "faithful info: plain model id, null parentId, ISO time" \
    || bad "faithful contract: $(jq -c '.info | {model,parentId,agent,time}' "$FR")"

echo "== --sanitize redacts secrets in markdown and faithful JSON =="
run export transcript --sanitize --filter ses_A0001 >/dev/null
TC=$(cat "$(last_transcript transcript 'Project-Alpha')")
printf '%s' "$TC" | grep -q "sk-test1234567890abcdefghijkl" && bad "sanitize leaked the API key" || ok "sanitize redacts the API key"
printf '%s' "$TC" | grep -q "sk-\[REDACTED\]" && ok "sanitize shows the redaction marker" || bad "sanitize marker missing"
run export faithful --sanitize --filter ses_A0001 >/dev/null
FR=$(find "$OUT" -type f \( -name 'Project-Alpha.json' -o -name 'Project-Alpha.faithful.json' \) \
    -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
printf '%s' "$(cat "$FR")" | grep -q "sk-test1234567890abcdefghijkl" && bad "faithful sanitize leaked" || ok "faithful sanitize redacts recursively"
MT=$(last_meta faithful)
jq -e '.flags.sanitize == true' "$MT" >/dev/null && ok "faithful sanitize recorded in metadata" || bad "faithful sanitize metadata"

echo "== shared-stamp bundle (products share one run folder) =="
BSTAMP="stplug-$(date -u +%s)"
SELRUN="selrun-$(date -u +%s)"
run export study --stamp "$BSTAMP" --filter ses_A0001 >/dev/null
[ -f "$OUT/$BSTAMP/metadata.transcript.json" ] && [ -f "$OUT/$BSTAMP/metadata.memory.json" ] \
    && [ ! -d "$OUT/$BSTAMP/transcript" ] && [ ! -d "$OUT/$BSTAMP/memory" ] \
    && ok "two products are siblings directly under the stamp" || bad "stamp bundle dirs"
ALROW=$(run exports list | awk -v s="$BSTAMP" '$0 ~ s {print; exit}')
printf '%s' "$ALROW" | grep -q "transcript" && printf '%s' "$ALROW" | grep -q "memory" \
    && ok "exports list aggregates products joined with +" || bad "exports list aggregate: $ALROW"
VIEW=$(run exports view "$BSTAMP")
printf '%s' "$VIEW" | grep -q "transcript" && printf '%s' "$VIEW" | grep -q "memory" && printf '%s' "$VIEW" | grep -q "totals:" \
    && ok "exports view shows every product of the run" || bad "exports view aggregate: $(printf '%s' "$VIEW" | sed -n '1,6p')"
# A detail screen must lead with a banner, like info/backups/shrinks.
printf '%s' "$VIEW" | sed -n '1p' | grep -q "^== Export run: $BSTAMP ==" \
    && ok "exports view leads with a run header" || bad "exports view header: $(printf '%s' "$VIEW" | sed -n '1p')"
printf '%s' "$VIEW" | grep -c "== Export run:" | grep -qx "1" \
    && ok "exports view repeats the run header once (per product)" || bad "exports view header repeated"
VJSON=$(run exports view "$BSTAMP" --json)
printf '%s' "$VJSON" | jq -e 'type == "array" and (map(.profile) | sort) == ["memory","transcript"]' >/dev/null \
    && ok "exports view --json is one metadata record per product" || bad "exports view --json: $VJSON"
printf '%s' "$VJSON" | grep -q "== Export run" && bad "exports view --json header" || ok "exports view --json has no header"
echo "== named bundle folder layout =="
BUNDLE_STAMP="bundle-layout-$$"
BUNDLE_DB="$TMP/bundle-layout.db"
BUNDLE_OUT="$TMP/bundle-layout-out"
cp "$FAKE" "$BUNDLE_DB"
mkdir -p "$BUNDLE_OUT"
OPENCODE_DB="$BUNDLE_DB" OCED_OUT="$BUNDLE_OUT" OCED_PRESETS="$EX_PRESETS" \
    run export complete --sessions ses_A0001 --stamp "$BUNDLE_STAMP" >/dev/null
SESSION_FOLDER=$(find "$BUNDLE_OUT/$BUNDLE_STAMP" -mindepth 1 -maxdepth 1 \
    -type d -printf '%f\n' | head -1)
[ -f "$BUNDLE_OUT/$BUNDLE_STAMP/index.md" ] \
    && [ -f "$BUNDLE_OUT/$BUNDLE_STAMP/index.transcript.md" ] \
    && [ -f "$BUNDLE_OUT/$BUNDLE_STAMP/index.memory.md" ] \
    && [ -f "$BUNDLE_OUT/$BUNDLE_STAMP/index.faithful.md" ] \
    && [ -f "$BUNDLE_OUT/$BUNDLE_STAMP/metadata.transcript.json" ] \
    && [ -f "$BUNDLE_OUT/$BUNDLE_STAMP/metadata.memory.json" ] \
    && [ -f "$BUNDLE_OUT/$BUNDLE_STAMP/metadata.faithful.json" ] \
    && [ ! -d "$BUNDLE_OUT/$BUNDLE_STAMP/transcript" ] \
    && [ ! -d "$BUNDLE_OUT/$BUNDLE_STAMP/memory" ] \
    && [ ! -d "$BUNDLE_OUT/$BUNDLE_STAMP/faithful" ] \
    && [[ "$SESSION_FOLDER" == ????-??-??__Project-Alpha_ses_A000* ]] \
    && [ -f "$BUNDLE_OUT/$BUNDLE_STAMP/$SESSION_FOLDER/Project-Alpha.transcript.md" ] \
    && [ -f "$BUNDLE_OUT/$BUNDLE_STAMP/$SESSION_FOLDER/Project-Alpha.faithful.json" ] \
    && ! [[ "$SESSION_FOLDER" =~ ^[0-9]{2}- ]] \
    && [ ! -e "$BUNDLE_OUT/${BUNDLE_STAMP}__complete" ] \
    && ok "bundle products are siblings without product directories" \
    || bad "bundle layout: $(find "$BUNDLE_OUT" -maxdepth 3 -type f | sort)"
sqlite3 "$BUNDLE_DB" "UPDATE session SET time_updated=time_updated+1000000 WHERE id='ses_A0001';"
OPENCODE_DB="$BUNDLE_DB" OCED_OUT="$BUNDLE_OUT" OCED_PRESETS="$EX_PRESETS" \
    run exports update "$BUNDLE_STAMP" --yes >/dev/null
[ -f "$BUNDLE_OUT/$BUNDLE_STAMP/index.md" ] \
    && [ -f "$BUNDLE_OUT/$BUNDLE_STAMP/index.transcript.md" ] \
    && [ -f "$BUNDLE_OUT/$BUNDLE_STAMP/index.memory.md" ] \
    && [ -f "$BUNDLE_OUT/$BUNDLE_STAMP/index.faithful.md" ] \
    && [ -f "$BUNDLE_OUT/$BUNDLE_STAMP/metadata.transcript.json" ] \
    && [ -f "$BUNDLE_OUT/$BUNDLE_STAMP/metadata.memory.json" ] \
    && [ -f "$BUNDLE_OUT/$BUNDLE_STAMP/metadata.faithful.json" ] \
    && [ -f "$BUNDLE_OUT/$BUNDLE_STAMP/$SESSION_FOLDER/Project-Alpha.transcript.md" ] \
    && [ -f "$BUNDLE_OUT/$BUNDLE_STAMP/$SESSION_FOLDER/Project-Alpha.faithful.json" ] \
    && [ ! -e "$BUNDLE_OUT/${BUNDLE_STAMP}__complete" ] \
    && ok "updating a bundle preserves the same product folder layout" \
    || bad "updated bundle layout: $(find "$BUNDLE_OUT" -maxdepth 3 -type f | sort)"
IDX=$(cat "$BUNDLE_OUT/$BUNDLE_STAMP/index.md")
printf '%s' "$IDX" | grep -q 'Updated from' \
    && ok "updated bundle index remains in the shared run directory" \
    || bad "updated bundle index: $IDX"
# `.selection.ids` is an ARRAY: the Selection line must join it, never concat it.
mkdir -p "$OUT/$SELRUN"
jq -n '{tool:"opencode-db/exportlib",version:"0",date:"2026-01-02T03:04:05Z",db:"/db",db_sha256:"x",
        last_backup:null,profile:"transcript",preset:"archive",
        selection:{rule:"sessions",ids:["ses_A0001","ses_B0001"]},
        scope:{rule:"all"},excluded:[],
        session_records:[{id:"ses_A0001",title:"Alpha",kind:"root",parent_id:null,created:"2026-01-01T00:00:00Z",updated:"2026-01-01T00:00:00Z"},
                         {id:"ses_B0001",title:"Beta",kind:"root",parent_id:null,created:"2026-01-01T00:00:00Z",updated:"2026-01-01T00:00:00Z"}],
        flags:{no_subagents:false,no_orphan_subagents:false,sub:"separate",tool_output:"truncated",
               no_reasoning:false,mark_compactions:false,summary_diffs:false,role:"all",sanitize:false},
        subagents_hidden:0,messages:2,compactions:0,digests:0,tokens_backfilled:0,
        artifacts:["index.md"]}' \
    > "$OUT/$SELRUN/metadata.json"
SELV=$(run exports view "$SELRUN")
printf '%s' "$SELV" | grep -q "jq: error" && bad "exports view selection array: jq error" || ok "exports view renders an array selection"
printf '%s' "$SELV" | grep -qE "selection: +2 explicit session id\(s\)" \
    && ok "exports view joins selection.ids" || bad "exports view selection array: $(printf '%s' "$SELV" | grep -i 'selection')"
# It must NOT be printed per product: it is a run-level fact.
[ "$(printf '%s' "$SELV" | grep -ci 'selection:')" -eq 1 ] \
    && ok "exports view prints the selection once per run" || bad "exports view repeats the selection"
printf '%s' "$SELV" | grep -qE "^  scope: +ALL sessions" \
    && ok "exports view names the wider scope" || bad "view scope: $(printf '%s' "$SELV" | grep -i scope)"
# Keys a product does not have must not be invented: `cap`/`files` are
# memory-only `.flags` keys, and this fixture is a transcript.
printf '%s' "$SELV" | grep -qE "^  (Cap|Touched files):" \
    && bad "exports view invents memory-only keys: $(printf '%s' "$SELV" | grep -E "^  (Cap|Touched)")" \
    || ok "exports view omits keys the product does not have"
# Field labels must align on one column.
BADALIGN=$(printf '%s' "$SELV" | sed -n '/== Details per product ==/,$p' | grep -E '^  [A-Za-z].*[A-Za-z]+: ' | grep -vcE '^  [A-Za-z][A-Za-z ()]*: {2,}')
[ "$BADALIGN" -eq 0 ] && ok "exports view field labels align" || bad "exports view label alignment ($BADALIGN ragged)"
# Every canonical metadata key is required. A run missing one is refused with a
# re-export instruction; no legacy top-level mirror is reconstructed from.
for badkey in selection scope flags session_records excluded artifacts; do
    NKEY="nokey-$badkey-$(date -u +%s%N)"
    mkdir -p "$OUT/$NKEY"
    jq "del(.$badkey)" "$OUT/$SELRUN/metadata.json" > "$OUT/$NKEY/metadata.json"
    KOUT=$(run exports view "$NKEY" 2>&1); krc=$?
    [ "$krc" -ne 0 ] && printf '%s' "$KOUT" | grep -q "incomplete canonical metadata; re-export this run" \
        && ok "exports view refuses a run without .$badkey" \
        || bad "missing .$badkey: rc=$krc $(printf '%s' "$KOUT" | head -1)"
    rm -rf "$OUT/$NKEY"
done
# The legacy `metadatos.json` file name is gone: a run dir that only has it is
# invalid, rather than silently omitted from `exports list`.
LEGACY="legacy-$(date -u +%s)"
mkdir -p "$OUT/$LEGACY"
echo '{"profile":"transcript","session_records":[],"messages":2,"compactions":0}' > "$OUT/$LEGACY/metadatos.json"
LEGACYV=$(run exports view "$LEGACY" 2>&1)
[ $? -ne 0 ] && printf '%s' "$LEGACYV" | grep -q "No metadata.json found" \
    && ok "exports view refuses a legacy-only metadatos.json run dir" \
    || bad "exports view legacy: $(printf '%s' "$LEGACYV" | head -1)"
EXL=$(run exports list); exlrc=$?
[ "$exlrc" -eq 0 ] && printf '%s' "$EXL" | grep -q "$LEGACY" \
    && printf '%s' "$EXL" | grep -q '?' \
    && ok "exports list tolerates a run without canonical metadata (flags it '?')" \
    || bad "legacy list: rc=$exlrc $(printf '%s' "$EXL" | head -1)"
rm -rf "$OUT/$LEGACY"

# A NARROWED run records `.scope` (the wider set) + `.excluded` (what it left
# out). `exports view` must name the scope and list the excluded gap, and
# `exports list` must spell out `K/N kept (E excl)` — otherwise a narrowed run
# reads as a full one. Both come straight from metadata (no DB read), so a
# synthetic run proves the rendering deterministically.
SCOPER="scoper-$(date -u +%s)"
mkdir -p "$OUT/$SCOPER"
jq -n '{profile:"transcript",preset:"notes",date:"2026-01-02T03:04:05Z",db:"/db",db_sha256:"x",
        selection:{rule:"sessions",ids:["ses_A0001"]},scope:{rule:"all"},
        excluded:[{id:"ses_B0001",title:"Left out one",updated:"2026-01-01T00:00:00Z"},
                  {id:"ses_B0002",title:"Left out two",updated:"2026-01-01T00:00:00Z"}],
        session_records:[{id:"ses_A0001",title:"Kept",kind:"root",parent_id:null,created:"2026-01-01T00:00:00Z",updated:"2026-01-01T00:00:00Z"}],
        flags:{sub:"separate",no_subagents:false,no_orphan_subagents:false},subagents_hidden:0,
        messages:2,compactions:0,digests:0,tokens_backfilled:0,artifacts:["index.md"]}' \
    > "$OUT/$SCOPER/metadata.json"
SCOPEV=$(run exports view "$SCOPER")
printf '%s' "$SCOPEV" | grep -qE "^  scope: +ALL sessions" \
    && ok "exports view names the run's scope" || bad "view scope: $(printf '%s' "$SCOPEV" | grep -i 'scope')"
printf '%s' "$SCOPEV" | grep -q "== Excluded (2 kept out of scope) ==" \
    && ok "exports view lists the excluded gap" || bad "view excluded: $(printf '%s' "$SCOPEV" | grep -i excluded)"
printf '%s' "$SCOPEV" | grep -q "ses_B0001" \
    && ok "exports view names an excluded session" || bad "view excluded id"
printf '%s' "$(run exports list)" | grep -qE "$SCOPER.*1/3 kept · 1 root 0 sub" \
    && ok "exports list spells the narrowed run as K/N kept" || bad "list kept/excluded: $(run exports list | grep "$SCOPER")"
# The preset the run came from rides right after the size (`size · preset · tag ·
# refresh`), so the recipe is visible next to the artifact it produced while the
# freshness tag keeps the last word.
printf '%s' "$(run exports list | grep "$SCOPER")" | grep -qE "notes($| )" \
    && ok "exports list names the preset on the row (after the size)" || bad "list preset column: $(run exports list | grep "$SCOPER")"
# A full run (scope == selection) shows no exclusion noise and names its
# size as `N · R root S sub` (short root/sub breakdown).
FULLV=$(run exports view "$BSTAMP")
printf '%s' "$FULLV" | grep -q "== Excluded" && printf '%s' "$(run exports list | grep "$BSTAMP")" | grep -q "excluded" \
    && bad "a full run is tagged with an excluded count" || ok "a full run carries no excluded count"
printf '%s' "$(run exports list | grep "$BSTAMP")" | grep -qE "[0-9]+ · [0-9]+ root [0-9]+ sub" \
    && ok "exports list names a full run as N · R root S sub" || bad "list full shape: $(run exports list | grep "$BSTAMP")"

echo "== filter =="
run export transcript --filter 'Project Beta' >/dev/null
ME=$(last_meta transcript)
jq -e '.selection.rule == "filter" and .selection.value == "Project Beta"' "$ME" >/dev/null && ok "filter applied in metadata" || bad "filter metadata"
jq -e '([.session_records[] | select(.kind == "root")] | length) == 1' "$ME" >/dev/null && ok "filter counts in metadata" || bad "filter counts"

echo "== recency selection: --last N / --since DATE (CLI-only) =="
# the fake DB's time_updated order is ORPHAN01 > B0001 > B0002 > A0001 > A0003 > A0002
run export transcript --last 2 >/dev/null
ME=$(last_meta transcript)
jq -e '.selection == {"rule":"last","value":2}' "$ME" >/dev/null \
    && ok "--last N is recorded as the selection rule" || bad "--last metadata: $(jq -c .selection "$ME")"
jq -e '([.session_records[] | select(.kind == "root")] | length) == 2 and ([.session_records[] | select(.kind == "subagent")] | length) == 1 and (.session_records | length) == 3' "$ME" >/dev/null \
    && ok "--last 2 = 2 newest roots + the subagent that follows one" || bad "--last counts: $(jq -c .session_records "$ME")"
grep -q '^| Selection | last 2 session(s) by last update |' "$(dirname "$ME")/index.md" \
    && ok "index.md states the --last rule" || bad "--last index row: $(grep '^| Selection' "$(dirname "$ME")/index.md")"
# --last counts ROOTS and closes the set over their subagents (like shrink --keep N)
run export transcript --last 1 >/dev/null
jq -e '([.session_records[] | select(.kind == "root")] | length) == 1 and ([.session_records[] | select(.kind == "subagent")] | length) == 0' "$(last_meta transcript)" >/dev/null \
    && ok "--last 1 = the newest root, nothing dragged in" || bad "--last 1 counts: $(jq -c .session_records "$(last_meta transcript)")"
run export transcript --last 4 >/dev/null
jq -e '([.session_records[] | select(.kind == "root")] | length) == 3 and (.session_records | length) == 6' "$(last_meta transcript)" >/dev/null \
    && ok "--last 4 (more than the 3 roots) still yields every session" || bad "--last 4 counts: $(jq -c .session_records "$(last_meta transcript)")"

run export transcript --since 2026-08-01 >/dev/null
ME=$(last_meta transcript)
jq -e '.selection == {"rule":"since","value":"2026-08-01"}' "$ME" >/dev/null \
    && ok "--since is recorded as the selection rule" || bad "--since metadata: $(jq -c .selection "$ME")"
jq -e '([.session_records[] | select(.kind == "root")] | length) == 3 and (.session_records | length) == 6' "$ME" >/dev/null \
    && ok "--since on a wide window keeps every session" || bad "--since counts: $(jq -c .session_records "$ME")"
run export transcript --since 2030-01-01 >/dev/null 2>&1
[ $? -ne 0 ] && ok "--since with no match exits non-zero" || bad "--since future was accepted"
grep_run "updated on or after 2030-01-01 matched nothing" export transcript --since 2030-01-01 \
    && ok "the empty-match error names the rule and its value" || bad "no-match error text"

# one rule per run, and the values are validated at the command line
run export transcript --last 2 --sessions ses_A0001 >/dev/null 2>&1
[ $? -ne 0 ] && ok "--last and --sessions are mutually exclusive" || bad "two selection rules were accepted"
run export transcript --last 0 >/dev/null 2>&1
[ $? -ne 0 ] && ok "--last 0 is rejected (0 would silently mean all)" || bad "--last 0 was accepted"
run export transcript --last abc >/dev/null 2>&1
[ $? -ne 0 ] && ok "--last abc is rejected" || bad "--last abc was accepted"
run export transcript --since 2026-13-99 >/dev/null 2>&1
[ $? -ne 0 ] && ok "--since with an impossible date is rejected" || bad "--since 2026-13-99 was accepted"
run export transcript --since 2026-1-1 >/dev/null 2>&1
[ $? -ne 0 ] && ok "--since insists on YYYY-MM-DD" || bad "--since 2026-1-1 was accepted"

# a run with no rule says so instead of leaving the reader guessing
run export transcript >/dev/null
jq -e '.selection == {"rule":"all"}' "$(last_meta transcript)" >/dev/null \
    && ok "no rule = selection {\"rule\":\"all\"}" || bad "default selection: $(jq -c .selection "$(last_meta transcript)")"
run export transcript --filter 'Project Beta' >/dev/null
jq -e '.selection == {"rule":"filter","value":"Project Beta"}' "$(last_meta transcript)" >/dev/null \
    && ok "the filter is the selection rule" || bad "filter selection: $(jq -c .selection "$(last_meta transcript)")"
run export transcript --sessions ses_A0001,ses_B0001 >/dev/null
jq -e '.selection.ids == ["ses_A0001","ses_B0001"]' "$(last_meta transcript)" >/dev/null \
    && ok "explicit ids are the selection rule" || bad "sessions selection: $(jq -c .selection "$(last_meta transcript)")"

echo "== sub inline / omit / separate =="
run export transcript --sub inline >/dev/null
INL=$(last_transcript transcript 'Project-Alpha')
grep -q "Subagent" "$INL" && ok "sub inline included" || bad "sub inline"
run export transcript --sub omit >/dev/null
OMIT=$(last_meta transcript)
jq -e '([.session_records[] | select(.kind == "subagent")] | length) == 0' "$OMIT" >/dev/null && ok "sub omit = 0 subagents" || bad "sub omit: $(jq '([.session_records[] | select(.kind == "subagent")] | length)' "$OMIT")"
run export transcript --sub separate >/dev/null
SEP=$(last_meta transcript)
jq -e '([.session_records[] | select(.kind == "subagent")] | length) == 3' "$SEP" >/dev/null && ok "sub separate = 3 subagents" || bad "sub separate: $(jq '([.session_records[] | select(.kind == "subagent")] | length)' "$SEP")"

echo "== subagent inclusion: --no-subagents (all products) =="
# A subagent selected alone IS exported as a root (the historical behaviour the
# "export only a subagent" use case needs) — pin it before changing it.
run export transcript --sessions ses_A0002 >/dev/null
ORPH=$(last_meta transcript)
jq -e '(.session_records | length) == 1 and ([.session_records[] | select(.kind == "root")] | length) == 1 and .flags.no_orphan_subagents == false' "$ORPH" >/dev/null \
    && ok "a lone subagent is exported standalone (default)" || bad "lone subagent: $(jq -c .session_records "$ORPH")"
# --no-subagents drops every real subagent from ALL products; the orphan (its
# parent row is gone) survives because it is a root.
for prod in transcript memory digest; do
    run export "$prod" --no-subagents >/dev/null
    M=$(last_meta "$prod")
    jq -e '.flags.no_subagents == true and .subagents_hidden == 3 and ([.session_records[] | select(.kind == "subagent")] | length) == 0
           and (.session_records | length) == 3' "$M" >/dev/null \
        && ok "--no-subagents: $prod keeps 3 roots, 0 subagents" \
        || bad "--no-subagents $prod: $(jq -c '{n:.flags.no_subagents,h:.subagents_hidden,s:.session_records}' "$M")"
done
grep_run "Excluded      : 3 subagent(s) (--no-subagents)" export transcript --no-subagents \
    && ok "--no-subagents reports the excluded count" || bad "--no-subagents report"
# The orphan is a root: it must NOT be hidden by --no-subagents.
printf '%s' "$(run export transcript --no-subagents --sessions ses_ORPHAN01)" | grep -q "Root sessions : 1" \
    && ok "--no-subagents keeps a session whose parent is gone" || bad "--no-subagents orphan"
# index.md surfaces the narrowing only when a flag set it.
run export transcript --no-subagents >/dev/null
IDX="$(dirname "$(last_meta transcript)")/index.md"
grep -q "excluded (--no-subagents)" "$IDX" \
    && ok "index.md records --no-subagents" || bad "index row: $(grep -c subagents "$IDX")"
run export transcript >/dev/null
IDX="$(dirname "$(last_meta transcript)")/index.md"
grep -q "excluded (" "$IDX" \
    && bad "index row leaked into a default run" || ok "index.md unchanged for a default run"

echo "== index.md surfaces the effective config (role / digests / extra toggles) =="
# Compaction digests is always there, right after the marker count (two counters).
grep -qE '^\| Compaction digests \| [0-9]+ \|$' "$IDX" \
    && ok "index.md reports compaction digests (besides markers)" || bad "index digests row"
# Role / summary-diffs / mark-compactions / sub are content flags: only a run
# that set them shows the row (a default run must not, same rule as --no-subagents).
grep -q '^| Role ' "$IDX" && bad "Role row leaked into a default run" || ok "index.md hides Role by default"
grep -q '^| Summary diffs ' "$IDX" && bad "Summary diffs row leaked" || ok "index.md hides Summary diffs by default"
grep -q '^| Mark compactions ' "$IDX" && bad "Mark compactions row leaked" || ok "index.md hides Mark compactions by default"
grep -q '^| Subagent layout ' "$IDX" && bad "Subagent layout row leaked" || ok "index.md hides subagent layout by default"
run export transcript --mark-compactions --summary-diffs >/dev/null
IDX="$(dirname "$(last_meta transcript)")/index.md"
{ grep -q '^| Mark compactions | `on` |$' "$IDX" && grep -q '^| Summary diffs | `on` |$' "$IDX"; } \
    && ok "index.md records --mark-compactions + --summary-diffs" || bad "index toggle rows: $(grep -E 'Mark compactions|Summary diffs' "$IDX")"
run export transcript --role user >/dev/null
IDX="$(dirname "$(last_meta transcript)")/index.md"
grep -q '^| Role | `user` |$' "$IDX" && ok "index.md records --role" || bad "index role row: $(grep '^| Role' "$IDX")"
run export transcript --sub omit >/dev/null
IDX="$(dirname "$(last_meta transcript)")/index.md"
grep -q '^| Subagent layout | `omit` |$' "$IDX" && ok "index.md records a non-default --sub" || bad "index sub row: $(grep '^| Subagent layout' "$IDX")"
# The backfill count is per-run and only surfaced when it happened.
run export transcript --filter ses_A0001 >/dev/null
IDX="$(dirname "$(last_meta transcript)")/index.md"
grep -qE '^\| Tokens backfilled \| 1 session' "$IDX" \
    && ok "index.md records the token backfill" || bad "index backfill row: $(grep '^| Tokens backfilled' "$IDX")"

echo "== subagent inclusion: --no-orphan-subagents (closed set) =="
run export transcript --sessions ses_A0001,ses_B0002 --no-orphan-subagents >/dev/null
CLOSED=$(last_meta transcript)
jq -e '.flags.no_orphan_subagents == true and .subagents_hidden == 1 and (.session_records | length) == 1
       and ([.session_records[] | select(.kind == "subagent")] | length) == 0' "$CLOSED" >/dev/null \
    && ok "--no-orphan-subagents drops a subagent whose parent is absent" \
    || bad "closed set: $(jq -c '{h:.subagents_hidden,s:.session_records}' "$CLOSED")"
# Root + its own subagent: the pair survives (only orphans are dropped).
run export transcript --sessions ses_A0001,ses_A0002 --no-orphan-subagents >/dev/null
PAIR=$(last_meta transcript)
jq -e '.subagents_hidden == 0 and (.session_records | length) == 2 and ([.session_records[] | select(.kind == "subagent")] | length) == 1' "$PAIR" >/dev/null \
    && ok "--no-orphan-subagents keeps a subagent whose parent IS exported" \
    || bad "pair: $(jq -c '{h:.subagents_hidden,s:.session_records}' "$PAIR")"
# Everything is an orphan subagent -> refuse instead of writing an empty export.
DRO=$(run export transcript --sessions ses_A0002 --no-orphan-subagents); rc=$?
[ "$rc" -ne 0 ] && ok "--no-orphan-subagents exits non-zero when nothing survives" || bad "closed set rc"
printf '%s' "$DRO" | grep -q "nothing left to export" \
    && ok "--no-orphan-subagents explains the empty result" || bad "closed set msg: $(printf '%s' "$DRO" | tail -1)"
# --no-subagents wins when both are given (it already drops every subagent).
run export transcript --no-subagents --no-orphan-subagents >/dev/null
BOTH=$(last_meta transcript)
jq -e '.flags.no_subagents == true and (.session_records | length) == 3' "$BOTH" >/dev/null \
    && ok "both flags together = the --no-subagents set" || bad "both flags: $(jq -c .session_records "$BOTH")"
# Preset key (all products) + CLI override.
PRESETS="$TMP/presets-sub.json"
cat > "$PRESETS" <<'JSON'
{"presets": {
  "roots-only": {"product": "transcript", "no_subagents": true},
  "closed":    {"product": "transcript", "sessions": ["ses_A0002"], "no_orphan_subagents": true}
}}
JSON
OCED_PRESETS="$PRESETS" run export roots-only >/dev/null
RP=$(last_meta transcript)
jq -e '.preset == "roots-only" and .flags.no_subagents == true and ([.session_records[] | select(.kind == "subagent")] | length) == 0' "$RP" >/dev/null \
    && ok "preset key no_subagents: true applies" || bad "preset no_subagents: $(jq -c .session_records "$RP")"
OCED_PRESETS="$PRESETS" run export closed >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "preset key no_orphan_subagents: true is validated + applied" || bad "preset no_orphan rc"
OCED_PRESETS="$PRESETS" run export roots-only --sessions ses_A0001,ses_A0002 >/dev/null
RO=$(last_meta transcript)
# Documented precedence: a CLI selection clobbers the preset SELECTION only — the
# preset's own config flags keep applying (so the subagent stays hidden here).
jq -e '.selection.rule == "sessions" and .selection.ids == ["ses_A0001","ses_A0002"] and .flags.no_subagents == true
       and (.session_records | length) == 1' "$RO" >/dev/null \
    && ok "CLI --sessions wins over the preset selection (preset flags still apply)" \
    || bad "preset+cli: $(jq -c '{sel:.selection,s:.session_records}' "$RO")"
# A preset may also hide subagents PER PRODUCT inside a bundle.
BPRESETS="$TMP/presets-sub-bundle.json"
cat > "$BPRESETS" <<'JSON'
{"presets": {"mixed": {"products": {"transcript": {"no_subagents": true},
                                      "memory": {"files": true}}}}}
JSON
OCED_PRESETS="$BPRESETS" run export mixed >/dev/null
BM=$(last_meta transcript)
jq -e '([.session_records[] | select(.kind == "subagent")] | length) == 0' "$BM" >/dev/null \
    && ok "bundle per-product no_subagents applies" || bad "bundle no_subagents: $(jq -c .session_records "$BM")"
jq -e '.flags.files == true' "$(last_meta memory)" >/dev/null \
    && ok "bundle sibling product keeps its own flags" || bad "bundle sibling flags"

echo "== shrink (pruned + VACUUMed copy, never touches the live DB) =="
GD=$(run shrink --keep 1 --dry-run)
printf '%s' "$GD" | grep -Eq "Would delete:[[:space:]]+5" && ok "shrink dry-run plan" || bad "shrink dry-run"
run shrink --keep 1 >/dev/null || bad "shrink run"
# status now reports the copy: newest stamp + kept/total + the freshness verdict.
ST2=$(run status)
printf '%s' "$ST2" | grep -qE "Newest:.*kept" && ok "status reports the newest shrink copy" \
    || bad "status shrink newest: $(printf '%s' "$ST2" | sed -n '/Shrinks/,/Version/p')"
printf '%s' "$ST2" | grep -q "\[OK\].*fresh" && ok "status flags a fresh shrink copy" || bad "status shrink fresh"
SHR=$(find "$BK/shrink" -name opencode.shrunk.db 2>/dev/null | sort | tail -1)
[ -n "$SHR" ] && ok "shrink produced a copy" || bad "shrink output"
GCK=$(sqlite3 "$SHR" "SELECT count(*) FROM session WHERE id IN (SELECT DISTINCT session_id FROM part);")
[ "$GCK" -eq 1 ] && ok "shrink kept 1 session" || bad "shrink kept=$GCK"
[ -f "$(dirname "$SHR")/shrink.json" ] && ok "shrink manifest" || bad "shrink manifest"
[ "$(sqlite3 "$SHR" "SELECT count(*) FROM event WHERE aggregate_id LIKE 'ses_%';")" -eq 3 ] \
    && ok "shrink pruned orphan events (kept 3)" || bad "shrink events left"
[ "$(sqlite3 "$SHR" "SELECT count(*) FROM event WHERE aggregate_id IN ('ses_A0001','ses_B0001');")" -eq 0 ] \
    && ok "shrink removed deleted sessions' events" || bad "shrink event refs"
[ "$(sqlite3 "$SHR" "SELECT count(*) FROM todo WHERE session_id NOT IN (SELECT id FROM session);")" -eq 0 ] \
    && ok "shrink removed orphan todos" || bad "shrink todo refs"
GJSON=$(cat "$(dirname "$SHR")/shrink.json")
printf '%s' "$GJSON" | jq -e '.integrity_check == "ok"' >/dev/null \
    && ok "shrink integrity_check ok" || bad "shrink integrity_check"
printf '%s' "$GJSON" | jq -e '.foreign_key_check == "clean"' >/dev/null \
    && ok "shrink foreign_key_check clean" || bad "shrink foreign_key_check"
printf '%s' "$GJSON" | jq -e '.removed.event == 6 and .removed.todo == 3 and .removed.event_sequence == 2 and .removed.part > 0' >/dev/null \
    && ok "shrink manifest removed counts + event store" || bad "shrink removed counts"

echo "== shrink --strip-reasoning (only drops 'reasoning' parts on the copy) =="
run shrink --keep 6 --strip-reasoning >/dev/null || bad "shrink strip run"
SRS=$(find "$BK/shrink" -name opencode.shrunk.db 2>/dev/null | sort | tail -1)
[ "$(sqlite3 "$SRS" "SELECT count(*) FROM part WHERE json_extract(data, '$.type') = 'reasoning';")" -eq 0 ] \
    && ok "shrink strip removed all reasoning parts" || bad "shrink strip reasoning left"
[ "$(sqlite3 "$SRS" "SELECT count(*) FROM part WHERE json_extract(data, '$.type') = 'text';")" -gt 0 ] \
    && ok "shrink strip kept the text parts" || bad "shrink strip lost text"
printf '%s' "$(cat "$(dirname "$SRS")/shrink.json")" | jq -e '.stripped_reasoning == 1 and (.criteria | contains("strip reasoning"))' >/dev/null \
    && ok "shrink strip recorded in shrink.json" || bad "shrink strip manifest"

echo "== shrink integrity failure leaves no orphan run dir =="
# A corrupted source must fail the integrity check BEFORE storing anything: no
# run dir, no shrink.json (the temp snapshot is removed on the way out).
BAD="$TMP/bad-src.db"
cp "$FAKE" "$BAD"
python3 - "$BAD" <<'PYEOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("PRAGMA writable_schema=ON")
con.execute("UPDATE sqlite_master SET sql='CREATE TABLE broken_session(x)' WHERE name='session'")
con.commit()
con.close()
PYEOF
DIRS_BEFORE="$(find "$BK/shrink" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
OPENCODE_DB="$BAD" bash "$MOD/opencode-db.sh" shrink --keep 1 >/dev/null 2>&1
DIRS_AFTER="$(find "$BK/shrink" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
[ "$DIRS_BEFORE" -eq "$DIRS_AFTER" ] && ok "failed shrink leaves no orphan run dir ($DIRS_AFTER)" || bad "orphan dir after failed shrink"
OPENCODE_DB="$FAKE"

echo "== shrink recipes (named OPERATIONS, selection stays a CLI flag) =="
newest_sj() { find "$BK/shrink" -name shrink.json 2>/dev/null | sort | tail -1; }
# lean = strip_reasoning ONLY: the session selection is the CLI default (--keep 10)
run shrink lean >/dev/null || bad "shrink lean run"
printf '%s' "$(cat "$(newest_sj)")" | jq -e '.sessions.kept == 6 and .stripped_reasoning == 1 and (.criteria | contains("keep the 10 most recent") and contains("strip reasoning"))' >/dev/null \
    && ok "shrink lean = default selection + strip reasoning" || bad "shrink lean: $(cat "$(newest_sj)")"
# quiet = no operation: the recipe must NOT prune sessions nor strip anything
run shrink quiet >/dev/null || bad "shrink quiet run"
printf '%s' "$(cat "$(newest_sj)")" | jq -e '.stripped_reasoning == 0' >/dev/null \
    && ok "shrink quiet strips nothing" || bad "shrink quiet: $(cat "$(newest_sj)")"
SB=$(find "$BK/shrink" -name opencode.shrunk.db 2>/dev/null | sort | tail -1)
[ "$(sqlite3 "$SB" "SELECT count(*) FROM part WHERE json_extract(data, '$.type') = 'reasoning';")" -eq 1 ] \
    && ok "shrink quiet keeps reasoning" || bad "shrink quiet reasoning lost"
# explicit flags win over the recipe: `lean --keep 2` keeps 2 AND strips
# (the kept set is closed: their subagent is kept too -> 3 rows; the fixture's
# only reasoning part belongs to a dropped session -> nothing left to strip)
run shrink lean --keep 2 >/dev/null || bad "shrink lean --keep 2 run"
printf '%s' "$(cat "$(newest_sj)")" | jq -e '.sessions.kept == 3 and (.criteria | contains("keep the 2 most recent") and contains("strip reasoning"))' >/dev/null \
    && ok "explicit selection wins over the recipe (lean --keep 2)" || bad "lean --keep 2: $(cat "$(newest_sj)")"
# the selection CLI rules are still there (not "legacy"): the age-based one
run shrink --older-than 90 >/dev/null || bad "shrink --older-than 90 run"
printf '%s' "$(cat "$(newest_sj)")" | jq -e '.sessions.kept == 6 and (.criteria | contains("last 90 day"))' >/dev/null \
    && ok "shrink --older-than 90 = sessions updated in the last 90 days" || bad "older-than: $(cat "$(newest_sj)")"

echo "== shrink session selection: keep-sessions closure =="
run shrink --keep-sessions ses_A0001 >/dev/null || bad "shrink keep-sessions run"
SKS=$(find "$BK/shrink" -name opencode.shrunk.db 2>/dev/null | sort | tail -1)
[ "$(sqlite3 "$SKS" "SELECT count(*) FROM session;")" -eq 3 ] \
    && ok "keep-sessions keeps the listed session + its subagents (3)" || bad "keep-sessions kept=$(sqlite3 "$SKS" "SELECT count(*) FROM session;")"
[ "$(sqlite3 "$SKS" "PRAGMA foreign_key_check;" | wc -l)" -eq 0 ] && ok "keep-sessions FK clean" || bad "keep-sessions FK"
printf '%s' "$(cat "$(dirname "$SKS")/shrink.json")" | jq -e '.sessions.max_updated' >/dev/null \
    && ok "keep-sessions records the max_updated of the kept set" || bad "keep-sessions max_updated"
# A discard-sessions that matches nothing (deleted=0) is a NOOP: the plan must
# still mention the ids it was handed, and the run must not gain a .selection.cascade.
run shrink --discard-sessions ses_B0001 >/dev/null
DSJ=$(ls -t "$BK"/shrink/*/shrink.json | head -1)
DSTAMP=$(basename "$(dirname "$DSJ")")
jq -e '.selection.ids == ["ses_B0001"]' "$DSJ" >/dev/null \
    && ok "a discard run with no matches still records the ids it was handed" \
    || bad "discard ids: $(jq -c '.selection.ids' "$DSJ")"
jq -e 'has("discard_exported") | not' "$DSJ" >/dev/null \
    && ok "a discard run with no export yet has no discard_exported key" \
    || bad "discard_exported present on a never-exported discard"

# The discard-export coverage check needs its OWN shelf + export dir: it re-asks
# the exports shelf at verify time, so adding/removing runs must never disturb
# the shared fixtures above.
UMK="$TMP/umk"; UOU="$TMP/umk-out"
rm -rf "$UMK" "$UOU"; mkdir -p "$UMK" "$UOU"
OCED_BACKUP_DIR="$UMK" OCED_OUT="$UOU" OCED_PRESETS="$EX_PRESETS" \
    run shrink --discard-sessions ses_B0001 >/dev/null || bad "discard run on the verify shelf"
USJ=$(ls -t "$UMK"/shrink/*/shrink.json | head -1)
USTAMP=$(basename "$(dirname "$USJ")")
jq -r '.selection.cascade | join(",")' "$USJ" | grep -qx 'ses_B0001,ses_B0002' \
    && ok "a discard run stores its closed cascade in .selection.cascade" \
    || bad "cascade: $(jq -c '.selection' "$USJ" 2>/dev/null)"

# A ROOT-ONLY export of the same root is a DIFFERENT set: exact ids, so it
# must never clear the flag (the whole reason the offer hands the full cascade).
OSTAB=$(OCED_PRESETS="$EX_PRESETS" OCED_OUT="$UOU" run export complete --sessions ses_B0001)
SSTAB=$(stamp_of "$OSTAB")
UVT2=$(OCED_BACKUP_DIR="$UMK" OCED_OUT="$UOU" run shrinks verify --tsv)
[ "$(printf '%s\n' "$UVT2" | grep -c '^unexported')" -eq 1 ] \
    && printf '%s\n' "$UVT2" | grep -q "^unexported	$USTAMP" \
    && ok "a root-only export is a different set: the discard stays flagged" \
    || bad "root-only export cleared the flag: [$UVT2]"
# 3) the CASCADE exported AFTER the shrink -> the live re-check finds it: clean.
OCAS=$(OCED_PRESETS="$EX_PRESETS" OCED_OUT="$UOU" run export complete --sessions ses_B0001,ses_B0002)
SCAS=$(stamp_of "$OCAS")
UV2=$(OCED_BACKUP_DIR="$UMK" OCED_OUT="$UOU" run shrinks verify)
printf '%s' "$UV2" | grep -q "All clean: no orphan dirs, no old pre-shrinks, no unexported discards" \
    && ok "an export made AFTER the shrink clears the flag (the check is live)" \
    || bad "post-export verify: $UV2"
# 4) legacy copies (no sessions.max_updated) is UNVERIFIABLE, and that must be the
# tag too — a list that silently called it clean would violate the one-helper rule.
LCOPY=$(find "$BK/shrink" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)
LCOPY2=$(find "$BK/shrink" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -2 | head -1)
LCOPY3=$(find "$BK/shrink" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -3 | head -1)
LCOPY4=$(find "$BK/shrink" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -4 | head -1)
# 5) remove the covering export -> flagged again (coverage is re-asked LIVE).
OCED_OUT="$UOU" run exports remove "$SCAS" --yes >/dev/null
UVT4=$(OCED_BACKUP_DIR="$UMK" OCED_OUT="$UOU" run shrinks verify --tsv)
[ "$(printf '%s\n' "$UVT4" | grep -c '^unexported')" -eq 1 ] \
    && printf '%s\n' "$UVT4" | grep -q "^unexported	$USTAMP" \
    && printf '%s\n' "$UVT4" | grep '^unexported' | cut -f3 | grep -qF "covers the 2 discarded" \
    && ok "exports remove brings the flag back (the live check is re-run)" \
    || bad "after remove: [$(printf '%s\n' "$UVT4" | grep '^unexported')]"
# 6) scope: a --keep run that DELETED sessions is NOT a discard and is never
# flagged — the helper's gate (rule == discard_sessions) is what makes that
# structural, so the json must not even carry a cascade.
OCED_BACKUP_DIR="$UMK" OCED_OUT="$UOU" run shrink --keep 1 >/dev/null
K1SJ=$(ls -t "$UMK"/shrink/*/shrink.json | head -1)
jq -e '.sessions.deleted > 0 and (.selection | has("cascade") | not)' "$K1SJ" >/dev/null \
    && ok "a --keep run that deleted sessions stores no cascade (scope is structural)" \
    || bad "keep-run selection: $(jq -c '{d: .sessions.deleted, sel: .selection}' "$K1SJ")"
UVT5=$(OCED_BACKUP_DIR="$UMK" OCED_OUT="$UOU" run shrinks verify --tsv)
[ "$(printf '%s\n' "$UVT5" | grep -c '^unexported')" -eq 1 ] \
    && printf '%s\n' "$UVT5" | grep -q "^unexported	$USTAMP" \
    && ok "verify never flags a non-discard copy (discard-only scope)" \
    || bad "keep copy flagged: [$(printf '%s\n' "$UVT5" | grep '^unexported')]"

# The update section needs its OWN DB/output: it edits sessions in place, so the
# shared $FAKE must never move.
UPDB="$TMP/upd-fake.db"
bash "$TESTS_DIR/make_fake_db.sh" "$UPDB" >/dev/null
UPD="$TMP/upd"; UPBK="$TMP/upd-bk"
rm -rf "$UPD" "$UPBK"; mkdir -p "$UPD"
runu() { OPENCODE_DB="$UPDB" OCED_OUT="$UPD" OCED_BACKUP_DIR="$UPBK" \
         OCED_PRESETS="$UPRESETS" run "$@"; }
usql() { sqlite3 "$UPDB" "$@"; }
cat > "$TMP/presets-upd.json" <<'EOF'
{"presets": {
  "narrow": {"product": "transcript", "filter": "ses_%"},
  "pair":   {"products": {"transcript": {}, "memory": {}}}
}}
EOF
UPRESETS="$TMP/presets-upd.json"
# A session that exists only in this private DB, so the narrowed run has a real
# excluded id that the live DB can edit later.
usql "INSERT INTO session (id,project_id,slug,directory,title,version,parent_id,agent,model,cost,time_created,time_updated) VALUES ('ses_NEW01','p','n','/tmp','Fresh subagent (@build subagent)','v1','ses_A0001','build','m',0,1789003000000,1789003100000);"
# Keep the narrowed gap easy to read: the nested subagent is not in the scope.
usql "DELETE FROM session WHERE id='ses_A0003';"

# 7) a narrowed run keeps its gap: the base scope is remembered, the run stays
#    as narrow as the menu left it, and --sticky decides revivals.
NRUN=$(runu export narrow --sessions ses_A0001,ses_A0002)
NSTAMP=$(stamp_of "$NRUN")
NSMETA="$UPD/$NSTAMP/metadata.json"
jq -e '.scope == {"rule":"filter","value":"ses_%"} and ([.excluded[].id]|sort) == ["ses_B0001","ses_B0002","ses_NEW01","ses_ORPHAN01"]' "$NSMETA" >/dev/null \
    && ok "a narrowed run records the SCOPE it was drawn from and the ids it left out" \
    || bad "narrow: $(jq -c '.scope,[.excluded[].id]' "$NSMETA")"
printf '%s' "$(runu exports update "$NSTAMP" --dry-run)" | grep -qE "After the update : 2" \
    && ok "update keeps a narrowed run narrow (no silent widening)" \
    || bad "narrow update: $(runu exports update "$NSTAMP" --dry-run)"
usql "UPDATE session SET time_updated=time_updated+9000000 WHERE id='ses_NEW01';"
printf '%s' "$(runu exports update "$NSTAMP" --dry-run)" | grep -qE "revived  : 1" \
    && ok "an edited excluded session is revived (--sticky stale, the default)" \
    || bad "sticky stale: $(runu exports update "$NSTAMP" --dry-run)"
printf '%s' "$(runu exports update "$NSTAMP" --dry-run --sticky never)" | grep -qE "revived  : 0" \
    && ok "--sticky never keeps a deliberate skip skipped" \
    || bad "sticky never: $(runu exports update "$NSTAMP" --dry-run --sticky never)"

# 7b) the run's OWN subagent policy is not a selection gap: `.excluded` stays
#     empty, and an edited subagent can never be revived only to be dropped again.
NSRUN=$(runu export transcript --no-subagents)
NSSTAMP=$(stamp_of "$NSRUN")
NSMETA="$UPD/$NSSTAMP/metadata.json"
jq -e '(.excluded|length) == 0 and (.subagents_hidden // 0) > 0 and .flags.no_subagents == true' "$NSMETA" >/dev/null \
    && ok "a --no-subagents run records its drop in the flags, not in .excluded" \
    || bad "no-subagents meta: $(jq -c '{excluded,subagents_hidden,no_subagents:.flags.no_subagents}' "$NSMETA")"
usql "UPDATE session SET time_updated=time_updated+9000000 WHERE id='ses_A0002';"
NSPJ=$(runu exports update "$NSSTAMP" --dry-run --json)
printf '%s' "$NSPJ" | jq -e '.up_to_date == true and .counts.revived == 0 and .counts.excluded_total == 0' >/dev/null \
    && ok "a policy-dropped subagent is never revived (plan and artifacts agree)" \
    || bad "no-subagents plan: $NSPJ"
printf '%s' "$(runu exports update "$NSSTAMP" --yes)" | grep -q "Nothing to do" \
    && ok "a --no-subagents run stays up to date after a dropped subagent is edited" \
    || bad "no-subagents idempotent: $(runu exports update "$NSSTAMP" --yes)"
# A stray `.excluded` entry is not a policy drop: the recorded flags still make
# the plan ignore it, so a dropped subagent can never be revived only to be
# dropped again.
jq '.excluded=[{"id":"ses_A0002","title":"Explore gaps (@explore subagent)"}]' "$NSMETA" > "$NSMETA.tmp" \
    && mv "$NSMETA.tmp" "$NSMETA"
NSPJ2=$(runu exports update "$NSSTAMP" --dry-run --json)
printf '%s' "$NSPJ2" | jq -e '.up_to_date == true and .counts.revived == 0 and (.target|length) == 3' >/dev/null \
    && ok "a stray .excluded entry cannot revive a policy-dropped subagent" \
    || bad "no-subagents stray excluded plan: $NSPJ2"

# 8) `.flags` and `.scope` are REQUIRED: a run missing either is refused with a
#    re-export instruction; no legacy top-level mirror is reconstructed from.
FLRUN=$(runu export transcript)
FLSTAMP=$(stamp_of "$FLRUN")
FLMETA="$UPD/$FLSTAMP/metadata.json"
jq 'del(.flags)' "$FLMETA" > "$FLMETA.tmp" && mv "$FLMETA.tmp" "$FLMETA"
FLOUT=$(runu exports update "$FLSTAMP" --dry-run 2>&1); flrc=$?
[ "$flrc" -ne 0 ] && printf '%s' "$FLOUT" | grep -qE "missing (or invalid )?\.flags; re-export this run" \
    && ok "update refuses a run without .flags (no legacy fallback)" \
    || bad "missing .flags: rc=$flrc $(printf '%s' "$FLOUT" | head -1)"
SCRUN=$(runu export transcript)
SCSTAMP=$(stamp_of "$SCRUN")
SCMETA="$UPD/$SCSTAMP/metadata.json"
jq 'del(.scope)' "$SCMETA" > "$SCMETA.tmp" && mv "$SCMETA.tmp" "$SCMETA"
SCOUT=$(runu exports update "$SCSTAMP" --dry-run 2>&1); scrc=$?
[ "$scrc" -ne 0 ] && printf '%s' "$SCOUT" | grep -qE "missing (or invalid )?\.scope; re-export this run" \
    && ok "update refuses a run without .scope (no legacy fallback)" \
    || bad "missing .scope: rc=$scrc $(printf '%s' "$SCOUT" | head -1)"

# 9) bundles: one shared stamp, per-product provenance, one bundle index.
BOUT=$(runu export pair)
BSTAMP2=$(stamp_of "$BOUT")
jq -e --arg s "$BSTAMP2" '.updated_from == null' "$UPD/$BSTAMP2/metadata.transcript.json" >/dev/null \
    && ok "a fresh bundle carries no update provenance" || bad "bundle fresh"
usql "UPDATE session SET time_updated=time_updated+9000000 WHERE id='ses_B0002';"
runu exports update "$BSTAMP2" --yes >/dev/null
for p in transcript memory; do
    jq -e --arg s "$BSTAMP2" '.updated_from == $s' "$UPD/$BSTAMP2/metadata.$p.json" >/dev/null \
        || bad "bundle $p did not record updated_from"
done
jq -e --arg s "$BSTAMP2" '.updated_from == $s' "$UPD/$BSTAMP2/metadata.transcript.json" >/dev/null \
    && ok "an updated bundle records the provenance in EVERY product" \
    || bad "bundle provenance"
grep -q '^| Updated from |' "$UPD/$BSTAMP2/index.md" \
    && ok "the bundle index gains the Updated from row" || bad "bundle index row"

# 10) refusals: unknown stamp, a run with no records, a bad mode.
printf '%s' "$(runu exports update nope-stamp 2>&1)" | grep -q "Not found" \
    && ok "update refuses an unknown stamp" || bad "unknown stamp"
LSTAMP=$(stamp_of "$(runu export transcript)")
LEGRUN="$UPD/$LSTAMP"
jq 'del(.session_records)' "$LEGRUN/metadata.json" > "$LEGRUN/metadata.json.t" \
    && mv "$LEGRUN/metadata.json.t" "$LEGRUN/metadata.json"
printf '%s' "$(runu exports update "$LSTAMP" --dry-run 2>&1)" | grep -qE "re-export (it instead|this run)" \
    && ok "update refuses a run that cannot say what it contains" || bad "legacy refusal: $(runu exports update "$LSTAMP" --dry-run 2>&1 | head -1)"
runu exports update "$NSTAMP" --mode nope >/dev/null 2>&1 \
    && bad "update accepted a bad --mode" || ok "update refuses a bad --mode"

echo ""
echo "RESULT: $pass OK / $fail FAIL"
[ "$fail" -eq 0 ]
