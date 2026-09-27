#!/usr/bin/env bash
# export_smoke.sh — end-to-end tests against a fake opencode DB (no real data touched).
# Usage: tests/export_smoke.sh
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$TESTS_DIR/../modules"
TMP="$(mktemp -d /tmp/opencode-db-smoke-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

FAKE="$TMP/fake.db"
OUT="$TMP/out"
BK="$TMP/backups"
bash "$TESTS_DIR/make_fake_db.sh" "$FAKE" >/dev/null

export OPENCODE_DB="$FAKE"
export OCED_OUT="$OUT"
export OCED_BACKUP_DIR="$BK"

pass=0; fail=0
ok() { echo "  [OK]   $1"; pass=$((pass+1)); }
bad() { echo "  [FAIL] $1"; fail=$((fail+1)); }
run() { bash "$MOD/opencode-db.sh" "$@" 2>&1; }
grep_run() { # $1=pattern, rest=CLI args: capture output before grep (avoids SIGPIPE/pipefail)
    local pat="$1"; shift
    local out; out=$(run "$@")
    printf '%s' "$out" | grep -q "$pat"
}
last_transcript() { # $1=profile $2=title (newest by mtime)
    find "$OUT" -path "*/$1/*" -name "*$2*.md" -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-
}
last_meta() { # $1=profile (newest by mtime)
    find "$OUT" -path "*/$1/*" -type f \( -name metadata.json -o -name metadatos.json \) -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-
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

echo "== guide (wizard) =="
G=$(run guide --list)
printf '%s' "$G" | grep -q "opencode-db guide" && ok "guide --list header" || bad "guide header"
printf '%s' "$G" | grep -q "Swap the copy manually" && ok "guide lists the manual swap step" || bad "guide steps"
printf '%s' "$G" | grep -q "never modifies the live DB" && ok "guide states the live DB is untouched" || bad "guide safety note"
printf '%s' "$G" | grep -qE "^  [0-9]+\. " && ok "guide numbers the steps" || bad "guide numbering"

echo "== list =="
grep_run "Project" list --root && ok "list --root" || bad "list --root"
grep_run "ORPHAN" list --sub --info && ok "list --sub includes orphan" || bad "list --sub"
grep_run "Project Beta" list --filter 'Project Beta' && ok "list --filter" || bad "list --filter"

echo "== info / compactions =="
I=$(run info ses_A0001); grep_run "Compactions" info ses_A0001 && ok "info" || bad "info"
printf "%s" "$I" | grep -q "1$" && ok "info counts 1 compaction" || bad "info count"
C=$(run compactions ses_A0001); printf "%s" "$C" | grep -vq "no compactions" && ok "compactions detected" || bad "compactions"

echo "== backup =="
grep_run "No backups recorded yet." backups list && ok "backups list w/o manifest" || bad "backups list w/o manifest"
B=$(run backup --yes)
printf "%s" "$B" | grep -qE "opencode-[0-9-]+\.db\.gz" && ok "compressed backup" || bad "backup"
printf "%s" "$B" | grep -q "Backup plan" && ok "backup shows the plan" || bad "backup plan"
printf "%s" "$B" | grep -qE "Est\. size:" && ok "backup shows estimated size" || bad "backup estimate"
printf "%s" "$B" | grep -q "Target:" && ok "backup shows target dir" || bad "backup target"
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
TC=$(cat "$(last_transcript transcript 'Project Alpha')")
echo "$TC" | grep -q "**Tool:**" && ok "transcript keeps tool calls" || bad "transcript no tools"
echo "$TC" | grep -q "Let me think first" && ok "transcript keeps reasoning by default" || bad "transcript reasoning lost"
MT=$(last_meta transcript)
jq -e '.profile == "transcript" and .json == false and .sanitize == false and .reasoning == true and .tool_output == "truncated"' "$MT" >/dev/null \
    && ok "transcript metadata reflects the flags" || bad "transcript metadata: $(jq -c '{profile,json,sanitize,reasoning,tool_output}' "$MT")"

echo "== export transcript --no-reasoning =="
run export transcript --no-reasoning --filter ses_A0001 >/dev/null
TC=$(cat "$(last_transcript transcript 'Project Alpha')")
echo "$TC" | grep -q "Let me think first" && bad "no-reasoning kept reasoning" || ok "no-reasoning omits reasoning"
echo "$TC" | grep -q "I'll look at the files" && ok "no-reasoning keeps the text" || bad "no-reasoning lost text"
MT=$(last_meta transcript)
jq -e '.reasoning == false' "$MT" >/dev/null && ok "no-reasoning recorded in metadata" || bad "no-reasoning metadata"

echo "== export transcript --role user (prompts only, flag not a preset) =="
run export transcript --role user --filter ses_A0001 >/dev/null
TC=$(cat "$(last_transcript transcript 'Project Alpha')")
echo "$TC" | grep -q "Done\." && bad "--role user kept the assistant answer" || ok "--role user excludes assistant messages"
echo "$TC" | grep -q "Still working" && ok "--role user keeps the prompts" || bad "--role user lost prompts"

echo "== compactions show (digest) =="
CS=$(run compactions ses_A0001 show last)
printf '%s' "$CS" | grep -q "Total: 1" && ok "compactions total" || bad "compactions total"
printf '%s' "$CS" | grep -q "DIGEST_A" && ok "compactions show last digest" || bad "compactions show digest"

echo "== compactions show (digest) =="
CS=$(run compactions ses_A0001 show last)
printf '%s' "$CS" | grep -q "Total: 1" && ok "compactions total" || bad "compactions total"
printf '%s' "$CS" | grep -q "DIGEST_A" && ok "compactions show last digest" || bad "compactions show digest"

echo "== export compactions profile =="
run export compactions --filter ses_A0001 >/dev/null
CC=$(cat "$(last_transcript compactions 'Project Alpha')")
echo "$CC" | grep -q "DIGEST_A" && ok "compactions digest exported" || bad "compactions profile digest"
echo "$CC" | grep -q "\*\*Tool:\*\*" && bad "compactions profile has tools" || ok "compactions profile no tools"

echo "== long output truncation =="
run export transcript --filter ses_B0001 >/dev/null
FT=$(cat "$(last_transcript transcript 'Project Beta')")
echo "$FT" | grep -q "truncated:" && ok "long output truncated" || bad "output not truncated"

echo "== transcript toggles: compaction markers + summary diffs =="
run export transcript --mark-compactions --summary-diffs --filter ses_A0001 >/dev/null
TC2=$(cat "$(last_transcript transcript 'Project Alpha')")
echo "$TC2" | grep -q "Context compaction" && ok "compaction marker" || bad "compaction marker"
echo "$TC2" | grep -q "Summary of changes" && ok "summary diffs" || bad "summary diffs"
echo "$TC2" | grep -q "<!-- step-finish -->" && ok "step markers present" || bad "step markers"

echo "== token backfill from step-finish (session row has 0 tokens) =="
run export transcript --filter ses_A0001 >/dev/null
MT=$(last_meta transcript)
jq -e '.tokens_backfilled == 1' "$MT" >/dev/null && ok "metadatos records the backfill" || bad "tokens_backfilled: $(jq '.tokens_backfilled' "$MT")"
run export memory --filter ses_A0001 >/dev/null
MB=$(last_meta memory); MB="${MB%/metadata.json}"
printf '%s' "$(sed -n '1p' "$MB/corpus.jsonl")" | jq -e '.tokens.input == 1100 and .tokens.output == 600 and .tokens.reasoning == 80 and .tokens.cache.read == 50 and .tokens.cache.write == 120 and .tokens.backfilled == true and .cost == 0.05' >/dev/null \
    && ok "memory corpus exposes the backfilled tokens + cost" || bad "memory backfill: $(sed -n '1p' "$MB/corpus.jsonl" | jq -c '.tokens')"

echo "== contract hardening: schema_version / model / null / ISO dates =="
printf '%s' "$(sed -n '1p' "$MB/corpus.jsonl")" | jq -e '.schema_version == 1 and .model == "model-a" and .parent_id == null and .created == "2026-09-10T00:26:40Z"' >/dev/null \
    && ok "corpus line: schema_version, plain model id, null parent, ISO date" \
    || bad "corpus contract: $(sed -n '1p' "$MB/corpus.jsonl" | jq -c '{schema_version,model,parent_id,created}')"
jq -e '.touched_files == false and .files == ["corpus.jsonl", "index.md"] and .profile == "memory"' "$MB/metadata.json" >/dev/null \
    && ok "memory metadata: touched_files false + produced files list" \
    || bad "memory meta contract: $(jq -c '{touched_files,files,profile}' "$MB/metadata.json")"

echo "== faithful JSON archive (--json) =="
run export transcript --json --filter ses_A0001 >/dev/null
JR=$(find "$OUT" -path "*/transcript/*" -name 'Project Alpha.json' -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
[ -n "$JR" ] && ok "faithful JSON file written next to the transcript" || bad "json file missing"
jq -e '.info.id == "ses_A0001" and .info.tokens.input == 1100 and .info.tokens.backfilled == true and .info.cost == 0.05' "$JR" >/dev/null \
    && ok "json info carries the backfilled tokens" || bad "json info tokens"
jq -e '.messages | length == 6' "$JR" >/dev/null && ok "json keeps ALL messages (6)" || bad "json messages: $(jq '.messages | length' "$JR")"
jq -e '.messages[0].parts[0].type == "text"' "$JR" >/dev/null && ok "json message shape {info, parts}" || bad "json shape"
printf '%s' "$(cat "$JR")" | grep -q "sk-test1234567890abcdefghijkl" && ok "faithful JSON keeps raw data when not sanitizing" || bad "json raw data missing"
jq -e '.info.model == "model-a" and .info.parentId == null and .info.agent == "build" and (.info.time.created | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' "$JR" >/dev/null \
    && ok "faithful info: plain model id, null parentId, ISO time" \
    || bad "faithful contract: $(jq -c '.info | {model,parentId,agent,time}' "$JR")"

echo "== --sanitize redacts secrets in markdown and JSON =="
run export transcript --sanitize --filter ses_A0001 >/dev/null
TC=$(cat "$(last_transcript transcript 'Project Alpha')")
printf '%s' "$TC" | grep -q "sk-test1234567890abcdefghijkl" && bad "sanitize leaked the API key" || ok "sanitize redacts the API key"
printf '%s' "$TC" | grep -q "sk-\[REDACTED\]" && ok "sanitize shows the redaction marker" || bad "sanitize marker missing"
run export transcript --json --sanitize --filter ses_A0001 >/dev/null
JR=$(find "$OUT" -path "*/transcript/*" -name 'Project Alpha.json' -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
printf '%s' "$(cat "$JR")" | grep -q "sk-test1234567890abcdefghijkl" && bad "json sanitize leaked" || ok "json sanitize redacts recursively"
MT=$(last_meta transcript)
jq -e '.json == true and .sanitize == true' "$MT" >/dev/null && ok "json+sanitize recorded in metadata" || bad "json sanitize metadata"

echo "== shared-stamp bundle (products share one run folder) =="
BSTAMP="stplug-$(date -u +%s)"
run export transcript --stamp "$BSTAMP" --filter ses_A0001 >/dev/null
run export compactions --stamp "$BSTAMP" --filter ses_A0001 >/dev/null
[ -f "$OUT/$BSTAMP/transcript/metadata.json" ] && [ -f "$OUT/$BSTAMP/compactions/metadata.json" ] \
    && ok "same stamp = one run with two products" || bad "stamp bundle dirs"
ALROW=$(run exports list | awk -v s="$BSTAMP" '$0 ~ s {print; exit}')
printf '%s' "$ALROW" | grep -q "transcript" && printf '%s' "$ALROW" | grep -q "compactions" \
    && ok "exports list aggregates products joined with +" || bad "exports list aggregate: $ALROW"
VIEW=$(run exports view "$BSTAMP")
printf '%s' "$VIEW" | grep -q "transcript" && printf '%s' "$VIEW" | grep -q "compactions" && printf '%s' "$VIEW" | grep -q "totals:" \
    && ok "exports view shows every product of the run" || bad "exports view aggregate: $(printf '%s' "$VIEW" | sed -n '1,6p')"
# Legacy runs wrote metadatos.json; readers must keep aggregating them.
LEGACY="legacy-$(date -u +%s)"
mkdir -p "$OUT/$LEGACY/transcript"
echo '{"profile":"transcript","sessions":{"roots":1,"subagents":0},"messages":2,"compactions":0}' > "$OUT/$LEGACY/transcript/metadatos.json"
EXL=$(run exports list)
printf '%s' "$EXL" | grep -q "$LEGACY" && ok "exports list aggregates legacy metadatos.json runs" || bad "legacy run aggregation"

echo "== filter =="
run export transcript --filter 'Project Beta' >/dev/null
ME=$(last_meta transcript)
jq -e '.filter == "Project Beta"' "$ME" >/dev/null && ok "filter applied in metadata" || bad "filter metadata"
jq -e '.sessions.roots == 1' "$ME" >/dev/null && ok "filter counts in metadata" || bad "filter counts"

echo "== recency selection: --last N / --since DATE (CLI-only) =="
# the fake DB's time_updated order is ORPHAN01 > B0001 > B0002 > A0001 > A0003 > A0002
run export transcript --last 2 >/dev/null
ME=$(last_meta transcript)
jq -e '.selection == {"rule":"last","value":2}' "$ME" >/dev/null \
    && ok "--last N is recorded as the selection rule" || bad "--last metadata: $(jq -c .selection "$ME")"
jq -e '.sessions.roots == 2 and .sessions.subagents == 1 and .sessions.total == 3' "$ME" >/dev/null \
    && ok "--last 2 = 2 newest roots + the subagent that follows one" || bad "--last counts: $(jq -c .sessions "$ME")"
grep -q '^| Selection | last 2 session(s) by last update |' "$(dirname "$ME")/index.md" \
    && ok "index.md states the --last rule" || bad "--last index row: $(grep '^| Selection' "$(dirname "$ME")/index.md")"
# --last counts ROOTS and closes the set over their subagents (like shrink --keep N)
run export transcript --last 1 >/dev/null
jq -e '.sessions.roots == 1 and .sessions.subagents == 0' "$(last_meta transcript)" >/dev/null \
    && ok "--last 1 = the newest root, nothing dragged in" || bad "--last 1 counts: $(jq -c .sessions "$(last_meta transcript)")"
run export transcript --last 4 >/dev/null
jq -e '.sessions.roots == 3 and .sessions.total == 6' "$(last_meta transcript)" >/dev/null \
    && ok "--last 4 (more than the 3 roots) still yields every session" || bad "--last 4 counts: $(jq -c .sessions "$(last_meta transcript)")"

run export transcript --since 2026-08-01 >/dev/null
ME=$(last_meta transcript)
jq -e '.selection == {"rule":"since","value":"2026-08-01"}' "$ME" >/dev/null \
    && ok "--since is recorded as the selection rule" || bad "--since metadata: $(jq -c .selection "$ME")"
jq -e '.sessions.roots == 3 and .sessions.total == 6' "$ME" >/dev/null \
    && ok "--since on a wide window keeps every session" || bad "--since counts: $(jq -c .sessions "$ME")"
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
INL=$(last_transcript transcript 'Project Alpha')
grep -q "Subagent" "$INL" && ok "sub inline included" || bad "sub inline"
run export transcript --sub omit >/dev/null
OMIT=$(last_meta transcript)
jq -e '.sessions.subagents == 0' "$OMIT" >/dev/null && ok "sub omit = 0 subagents" || bad "sub omit: $(jq '.sessions.subagents' "$OMIT")"
run export transcript --sub separate >/dev/null
SEP=$(last_meta transcript)
jq -e '.sessions.subagents == 3' "$SEP" >/dev/null && ok "sub separate = 3 subagents" || bad "sub separate: $(jq '.sessions.subagents' "$SEP")"

echo "== subagent inclusion: --no-subagents (all products) =="
# A subagent selected alone IS exported as a root (the historical behaviour the
# "export only a subagent" use case needs) — pin it before changing it.
run export transcript --sessions ses_A0002 >/dev/null
ORPH=$(last_meta transcript)
jq -e '.sessions.total == 1 and .sessions.roots == 1 and .no_orphan_subagents == false' "$ORPH" >/dev/null \
    && ok "a lone subagent is exported standalone (default)" || bad "lone subagent: $(jq -c .sessions "$ORPH")"
# --no-subagents drops every real subagent from ALL products; the orphan (its
# parent row is gone) survives because it is a root.
for prod in transcript memory compactions; do
    run export "$prod" --no-subagents >/dev/null
    M=$(last_meta "$prod")
    jq -e '.no_subagents == true and .subagents_hidden == 3 and .sessions.subagents == 0
           and .sessions.total == 3' "$M" >/dev/null \
        && ok "--no-subagents: $prod keeps 3 roots, 0 subagents" \
        || bad "--no-subagents $prod: $(jq -c '{n:.no_subagents,h:.subagents_hidden,s:.sessions}' "$M")"
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

echo "== subagent inclusion: --no-orphan-subagents (closed set) =="
run export transcript --sessions ses_A0001,ses_B0002 --no-orphan-subagents >/dev/null
CLOSED=$(last_meta transcript)
jq -e '.no_orphan_subagents == true and .subagents_hidden == 1 and .sessions.total == 1
       and .sessions.subagents == 0' "$CLOSED" >/dev/null \
    && ok "--no-orphan-subagents drops a subagent whose parent is absent" \
    || bad "closed set: $(jq -c '{h:.subagents_hidden,s:.sessions}' "$CLOSED")"
# Root + its own subagent: the pair survives (only orphans are dropped).
run export transcript --sessions ses_A0001,ses_A0002 --no-orphan-subagents >/dev/null
PAIR=$(last_meta transcript)
jq -e '.subagents_hidden == 0 and .sessions.total == 2 and .sessions.subagents == 1' "$PAIR" >/dev/null \
    && ok "--no-orphan-subagents keeps a subagent whose parent IS exported" \
    || bad "pair: $(jq -c '{h:.subagents_hidden,s:.sessions}' "$PAIR")"
# Everything is an orphan subagent -> refuse instead of writing an empty export.
DRO=$(run export transcript --sessions ses_A0002 --no-orphan-subagents); rc=$?
[ "$rc" -ne 0 ] && ok "--no-orphan-subagents exits non-zero when nothing survives" || bad "closed set rc"
printf '%s' "$DRO" | grep -q "nothing left to export" \
    && ok "--no-orphan-subagents explains the empty result" || bad "closed set msg: $(printf '%s' "$DRO" | tail -1)"
# --no-subagents wins when both are given (it already drops every subagent).
run export transcript --no-subagents --no-orphan-subagents >/dev/null
BOTH=$(last_meta transcript)
jq -e '.no_subagents == true and .sessions.total == 3' "$BOTH" >/dev/null \
    && ok "both flags together = the --no-subagents set" || bad "both flags: $(jq -c .sessions "$BOTH")"
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
jq -e '.preset == "roots-only" and .no_subagents == true and .sessions.subagents == 0' "$RP" >/dev/null \
    && ok "preset key no_subagents: true applies" || bad "preset no_subagents: $(jq -c .sessions "$RP")"
OCED_PRESETS="$PRESETS" run export closed >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "preset key no_orphan_subagents: true is validated + applied" || bad "preset no_orphan rc"
OCED_PRESETS="$PRESETS" run export roots-only --sessions ses_A0001,ses_A0002 >/dev/null
RO=$(last_meta transcript)
# Documented precedence: a CLI selection clobbers the preset SELECTION only — the
# preset's own config flags keep applying (so the subagent stays hidden here).
jq -e '.sessions_selected == ["ses_A0001","ses_A0002"] and .no_subagents == true
       and .sessions.total == 1' "$RO" >/dev/null \
    && ok "CLI --sessions wins over the preset selection (preset flags still apply)" \
    || bad "preset+cli: $(jq -c '{sel:.sessions_selected,s:.sessions}' "$RO")"
# A preset may also hide subagents PER PRODUCT inside a bundle.
BPRESETS="$TMP/presets-sub-bundle.json"
cat > "$BPRESETS" <<'JSON'
{"presets": {"mixed": {"products": {"transcript": {"no_subagents": true},
                                      "memory": {"files": true}}}}}
JSON
OCED_PRESETS="$BPRESETS" run export mixed >/dev/null
BM=$(last_meta transcript)
jq -e '.sessions.subagents == 0' "$BM" >/dev/null \
    && ok "bundle per-product no_subagents applies" || bad "bundle no_subagents: $(jq -c .sessions "$BM")"
jq -e '.touched_files == true' "$(last_meta memory)" >/dev/null \
    && ok "bundle sibling product keeps its own flags" || bad "bundle sibling flags"

echo "== shrink (pruned + VACUUMed copy, never touches the live DB) =="
GD=$(run shrink --keep 1 --dry-run)
printf '%s' "$GD" | grep -Eq "Would delete:[[:space:]]+5" && ok "shrink dry-run plan" || bad "shrink dry-run"
run shrink --keep 1 >/dev/null || bad "shrink run"
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
printf '%s' "$(cat "$(dirname "$SKS")/shrink.json")" | jq -e '.selection.rule == "keep_sessions" and (.selection.ids | index("ses_A0001"))' >/dev/null \
    && ok "shrink.json records the keep-sessions selection" || bad "keep-sessions selection in shrink.json"

echo "== shrink session selection: discard-sessions closure =="
run shrink --discard-sessions ses_A0001 >/dev/null || bad "shrink discard run"
SDS=$(find "$BK/shrink" -name opencode.shrunk.db 2>/dev/null | sort | tail -1)
[ "$(sqlite3 "$SDS" "SELECT count(*) FROM session;")" -eq 3 ] \
    && ok "discard-sessions drops the listed session + descendants (kept 3)" || bad "discard kept=$(sqlite3 "$SDS" "SELECT count(*) FROM session;")"
[ "$(sqlite3 "$SDS" "PRAGMA foreign_key_check;" | wc -l)" -eq 0 ] && ok "discard FK clean" || bad "discard FK"
[ "$(sqlite3 "$SDS" "SELECT count(*) FROM session WHERE id LIKE 'ses_A%';")" -eq 0 ] \
    && ok "discard removed the whole ses_A* group" || bad "discard A left"
grep_run "export archive --sessions ses_A0001" shrink --discard-sessions ses_A0001 \
    && ok "discard CLI prints the export-first hint" || bad "discard hint missing"
printf '%s' "$(cat "$(dirname "$SDS")/shrink.json")" | jq -e '.selection.rule == "discard_sessions"' >/dev/null \
    && ok "shrink.json records the discard-sessions selection" || bad "discard selection in shrink.json"

echo "== shrink recipes from OCED_SHRINK_PRESETS (file overrides/extensions) =="
FPRES="$TMP/shrink-presets.json"
cat > "$FPRES" <<'EOF'
{"presets": {"skim": {"strip_reasoning": true},
              "noisy": {"strip_reasoning": false}}}
EOF
export OCED_SHRINK_PRESETS="$FPRES"
run shrink skim >/dev/null || bad "shrink file recipe skim"
printf '%s' "$(cat "$(newest_sj)")" | jq -e '.stripped_reasoning == 1' >/dev/null \
    && ok "file recipe bake -> --strip-reasoning" || bad "skim recipe: $(cat "$(newest_sj)")"
run shrink noisy >/dev/null || bad "shrink file recipe noisy"
printf '%s' "$(cat "$(newest_sj)")" | jq -e '.stripped_reasoning == 0' >/dev/null \
    && ok "file recipe with an explicit false -> no strip" || bad "noisy recipe: $(cat "$(newest_sj)")"
LP=$(run shrink --list-presets)
printf '%s' "$LP" | grep -q '^lean	' && printf '%s' "$LP" | grep -q '^skim	' \
    && ok "shrink --list-presets shows built-ins + file recipes" || bad "list-presets: [$LP]"
run shrink nosuchrecipe >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "unknown shrink recipe -> non-zero rc ($rc)" || bad "unknown recipe rc"
run shrink lean >/dev/null || bad "shrink lean still works with a custom file"
unset OCED_SHRINK_PRESETS
# the shipped example must satisfy the generated schema
python3 "$TESTS_DIR/validate_schema.py" generated/shrink.schema.json shrink-presets.json.example >/dev/null 2>&1 \
    && ok "shipped shrink-presets.json.example satisfies shrink.schema.json" || bad "example vs shrink schema"

# A KEEP RULE inside a recipe is rejected (a recipe carries operations ONLY) and
# the schema rejects it too. It gets its own file: an invalid recipe poisons all.
FBAD="$TMP/shrink-bad.json"
printf '%s' '{"presets": {"raw": {"keep": 3, "strip_reasoning": true}}}' > "$FBAD"
export OCED_SHRINK_PRESETS="$FBAD"
RO=$(run shrink raw 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "a keep rule inside a recipe -> non-zero rc ($rc)" || bad "raw recipe rc"
printf '%s' "$RO" | grep -q -- "--keep" && ok "the rejection points at the CLI selection flag" || bad "rejection hint: $RO"
RO=$(run shrink lean 2>&1); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$RO" | grep -q "selects sessions" \
    && ok "an invalid recipe file is rejected, not silently ignored" || bad "invalid recipe file: $RO"
if python3 "$TESTS_DIR/validate_schema.py" generated/shrink.schema.json "$FBAD" >/dev/null 2>&1; then
    bad "schema accepted a recipe with a keep rule"
else
    ok "a recipe with a keep rule does NOT satisfy shrink.schema.json"
fi
unset OCED_SHRINK_PRESETS

echo "== export memory (RAG corpus) =="
run export memory >/dev/null
MEM=$(last_meta memory); MEM="${MEM%/metadata.json}"
[ -f "$MEM/corpus.jsonl" ] && ok "memory corpus.jsonl" || bad "memory corpus"
NLINE=$(wc -l < "$MEM/corpus.jsonl")
[ "$NLINE" -eq 3 ] && ok "memory one line per root (3 roots)" || bad "memory roots: $NLINE"
LINE=$(sed -n '1p' "$MEM/corpus.jsonl")
printf '%s' "$LINE" | jq -e '.id | startswith("ses_")' >/dev/null && ok "memory entry valid JSON" || bad "memory JSON"
printf '%s' "$LINE" | jq -e '.first_user != ""' >/dev/null && ok "memory first_user" || bad "memory first_user"
printf '%s' "$LINE" | jq -e '.last_assistant != ""' >/dev/null && ok "memory last_assistant" || bad "memory last_assistant"
printf '%s' "$LINE" | jq -e '.compaction_digests | length == 1' >/dev/null \
    && ok "memory records ALL digests" || bad "memory digests count"
printf '%s' "$LINE" | jq -e '.compaction_digests[0].text | contains("DIGEST_A")' >/dev/null \
    && ok "memory digest content" || bad "memory digest text"
printf '%s' "$LINE" | jq -e '.subagents | length == 2' >/dev/null && ok "memory subagents inline" || bad "memory subagents"
printf '%s' "$LINE" | jq -e 'has("files") | not' >/dev/null && ok "memory no files by default" || bad "memory files default"
run export memory --files >/dev/null
MEMF=$(last_meta memory); MEMF="${MEMF%/metadata.json}"
printf '%s' "$(sed -n '1p' "$MEMF/corpus.jsonl")" | jq -e '.files | index("src/a.py") != null' >/dev/null \
    && ok "memory --files lists touched files" || bad "memory --files"
run export memory --cap 20 >/dev/null
MEMC=$(last_meta memory); MEMC="${MEMC%/metadata.json}"
printf '%s' "$(sed -n '1p' "$MEMC/corpus.jsonl")" | jq -e '.first_user | length == 20' >/dev/null \
    && ok "memory --cap truncates to N" || bad "memory --cap"

echo "== index.md present and with links =="
run export transcript --mark-compactions >/dev/null
IX=$(last_meta transcript); IX="${IX%/metadata.json}/index.md"
grep -q "## Sessions" "$IX" && ok "index.md sessions section" || bad "index.md"
grep -q "](" "$IX" && ok "index.md links" || bad "index.md links"

echo "== exports management =="
XL=$(run exports list)
printf '%s' "$XL" | grep -q "^== Exports (" && ok "exports list" || bad "exports list"
printf '%s' "$XL" | grep -qE '^[ ]*[0-9]+\.' && ok "exports list rows" || bad "exports list rows"
STAMP=$(printf '%s' "$XL" | awk '/^[ ]*[0-9]+\./ {print $2; exit}')
run exports remove "$STAMP" --yes >/dev/null
printf '%s' "$(run exports list)" | grep -q "$STAMP" && bad "exports remove" || ok "exports remove"
run exports prune 1 --yes >/dev/null
NX=$(run exports list | grep -cE '^[ ]*[0-9]+\.')
[ "$NX" -eq 1 ] && ok "exports prune keeps 1" || bad "exports prune ($NX)"

echo "== --from-backup reads from the stored snapshot =="
BKF=$(run backups list | grep -oE 'opencode-[0-9-]+\.db\.gz' | head -1)
[ -n "$BKF" ] && ok "found a backup for --from-backup" || bad "no backup for --from-backup"
VOUT=$(run --from-backup "$BKF" version)
printf '%s' "$VOUT" | grep -q "backup (" && ok "--from-backup reports the backup source" || bad "from-backup source"
printf '%s' "$VOUT" | grep -q "All expected tables and columns are present" && ok "--from-backup probes the backup schema" || bad "from-backup probe"
run --from-backup "$BKF" export memory >/dev/null
MB=$(last_meta memory); MB="${MB%/metadata.json}"
printf '%s' "$(cat "$MB/metadata.json")" | jq -e '.db | contains("oced-backup")' >/dev/null \
    && ok "export --from-backup read the decompressed backup" || bad "export from backup: $(jq -r '.db' "$MB/metadata.json")"
# No temp files must be left behind after the command exits.
before=$(find /tmp -maxdepth 1 -name 'oced-backup-*.db' 2>/dev/null | wc -l)
run --from-backup "$BKF" version >/dev/null
after=$(find /tmp -maxdepth 1 -name 'oced-backup-*.db' 2>/dev/null | wc -l)
[ "$after" -le "$before" ] && ok "--from-backup leaves no temp files" || bad "leftover temp files: $before -> $after"

echo "== export presets (JSON file = source of truth) =="
PRESETS="$TMP/presets.json"
cat > "$PRESETS" <<'EOF'
{"presets": {
  "clean": {"product":"transcript","json":true,"sanitize":true,"no_reasoning":true,"filter":"Project Beta"},
  "corpus":  {"product":"memory","cap":400,"files":true,"filter":"ses_%"},
  "dorky":   {"product":"transcript","role":"banana"}
}}
EOF
export OCED_PRESETS="$PRESETS"
run export clean >/dev/null
jq -e '.preset == "clean" and .json == true and .sanitize == true and .reasoning == false' "$(last_meta transcript)" >/dev/null \
    && ok "preset 'clean' applies product + config flags" || bad "preset flags: $(jq -r '.preset,.json,.sanitize,.reasoning' "$(last_meta transcript)")"
jq -e '.filter == "Project Beta"' "$(last_meta transcript)" >/dev/null \
    && ok "preset pins its own filter" || bad "preset filter"
jq -e '.sessions.total == 1' "$(last_meta transcript)" >/dev/null \
    && ok "preset filter selects the matching session" || bad "preset filter sessions: $(jq -r .sessions.total "$(last_meta transcript)")"
# Product keyword still means the product (regression): preset file present but "transcript" is one.
run export transcript --json >/dev/null
jq -e '.preset == null' "$(last_meta transcript)" >/dev/null \
    && ok "product keyword ignores presets (preset=null)" || bad "product keyword leak"
run export memory --sessions ses_A0001 >/dev/null
jq -e '.sessions_selected == ["ses_A0001"] and .sessions.total == 1 and .preset == null' "$(last_meta memory)" >/dev/null \
    && ok "--sessions exports exactly the given sessions" || bad "--sessions: $(jq -r '.sessions_selected,.sessions.total' "$(last_meta memory)")"
run export corpus >/dev/null
jq -e '.preset == "corpus" and .cap == 400 and .filter == "ses_%"' "$(last_meta memory)" >/dev/null \
    && ok "memory preset records preset/cap/filter" || bad "memory preset meta"
MCPF=$(last_meta memory); MCPF="${MCPF%/metadata.json}"
[ "$(wc -l < "$MCPF/corpus.jsonl")" -eq 3 ] && ok "memory preset filter kept all roots" || bad "memory preset roots: $(wc -l < "$MCPF/corpus.jsonl")"
printf '%s' "$(sed -n '1p' "$MCPF/corpus.jsonl")" | jq -e '.files | index("src/a.py") != null' >/dev/null \
    && ok "memory preset --files applies" || bad "memory preset files"
jq -e '.touched_files == true' "$MCPF/metadata.json" >/dev/null \
    && ok "memory metadata records touched_files when --files requested" \
    || bad "memory touched_files: $(jq -c .touched_files "$MCPF/metadata.json")"
# CLI flags override the preset's selection/config.
run export corpus --sessions ses_A0001 --cap 77 >/dev/null
jq -e '.sessions_selected == ["ses_A0001"] and .cap == 77' "$(last_meta memory)" >/dev/null \
    && ok "CLI --sessions/--cap override the preset" || bad "override: $(jq -r '.sessions_selected,.cap' "$(last_meta memory)")"
# Invalid preset value and unknown target must fail with a helpful message.
DOR=$(run export dorky); rc=$?
[ "$rc" -ne 0 ] && ok "invalid preset value exits non-zero" || bad "invalid preset rc"
printf '%s' "$DOR" | grep -q "must be one of all, user, assistant" && ok "invalid preset value explained" || bad "invalid preset message: $(printf '%s' "$DOR" | tail -1)"
UNK=$(run export nope); rc=$?
[ "$rc" -ne 0 ] && ok "unknown export target exits non-zero" || bad "unknown target rc"
printf '%s' "$UNK" | grep -q "unknown export target 'nope'" && ok "unknown target message" || bad "unknown target msg"
printf '%s' "$UNK" | grep -q "presets: clean, corpus, dorky" && ok "unknown target lists the known presets" || bad "unknown target presets: $(printf '%s' "$UNK" | tail -1)"
# No presets file -> raw flags still rule (no presets configured path).
export OCED_PRESETS="$TMP/missing-presets.json"
run export transcript --json >/dev/null
jq -e '.preset == null' "$(last_meta transcript)" >/dev/null \
    && ok "absent presets file is a no-op (preset=null)" || bad "missing presets file"
export OCED_PRESETS="$PRESETS"

echo "== export preset snapshot: fresh -> backup alignment warning =="
SNAP_PRESETS="$TMP/presets-snap.json"
cat > "$SNAP_PRESETS" <<'EOF'
{"presets": {"snap": {"product": "transcript", "json": true, "snapshot": "fresh"}}}
EOF
export OCED_PRESETS="$SNAP_PRESETS"
export OCED_BACKUP_DIR="$TMP/bk-snap"
SOUT=$(run export snap); rc=$?
[ "$rc" -eq 0 ] && ok "snapshot preset export runs" || bad "snapshot export rc"
printf '%s' "$SOUT" | grep -q "no backup exists yet" && ok "snapshot: fresh warns when no backup exists" || bad "snapshot no-backup warn: [$(printf '%s' "$SOUT" | tail -2)]"
SESSES=$(sqlite3 "file:$FAKE?mode=ro" "SELECT count(*) FROM session")
MSGS=$(sqlite3 "file:$FAKE?mode=ro" "SELECT count(*) FROM message")
MUTS=$(sqlite3 "file:$FAKE?mode=ro" "SELECT max(time_updated) FROM session")
mkdir -p "$OCED_BACKUP_DIR"
printf '{"backups":[{"sessions":%s,"messages":%s,"max_updated":%s}]}' "$SESSES" "$MSGS" "$MUTS" > "$OCED_BACKUP_DIR/manifest.json"
SOUT2=$(run export snap)
printf '%s' "$SOUT2" | grep -qE "out of sync|no backups" && bad "aligned snapshot preset warned anyway" || ok "snapshot preset silent when aligned"
printf '{"backups":[{"sessions":%s,"messages":%s,"max_updated":0}]}' "$SESSES" "$MSGS" > "$OCED_BACKUP_DIR/manifest.json"
SOUT3=$(run export snap)
printf '%s' "$SOUT3" | grep -q "out of sync with the live DB" && ok "snapshot: fresh warns when the backup diverged" || bad "snapshot out-of-sync warn: [$(printf '%s' "$SOUT3" | tail -2)]"
export OCED_BACKUP_DIR="$BK"
export OCED_PRESETS="$PRESETS"

echo "== export bundle presets (products: one stamp, per-product flags) =="
cat > "$TMP/presets-bundle.json" <<'EOF'
{"presets": {
  "everything": {"products": {"transcript": {"json": true, "tool_output": "full"},
                              "memory": {"files": true}}},
  "debugmsg":   {"products": {"transcript": {"json": true}, "memory": {"files": true},
                              "compactions": {"json": true}}},
  "badmix":     {"product": "transcript", "products": {"memory": {}}},
  "badprod":    {"products": {"scribble": {}}}
}}
EOF
export OCED_PRESETS="$TMP/presets-bundle.json"
run export everything >/dev/null
BT="$(last_meta transcript)"; BT="${BT%/metadata.json}"; BSTAMP="${BT%/*}"
[ -d "$BSTAMP/transcript" ] && [ -d "$BSTAMP/memory" ] && [ ! -d "$BSTAMP/compactions" ] \
    && ok "bundle 'everything' = one stamp with transcript+memory (no compactions)" \
    || bad "bundle dirs: $BSTAMP"
jq -e '.preset == "everything" and .profile == "transcript" and .json == true and .tool_output == "full"' "$BSTAMP/transcript/metadata.json" >/dev/null \
    && ok "bundle transcript runs with its preset flags + provenance" || bad "bundle transcript meta"
jq -e '.preset == "everything" and .profile == "memory"' "$BSTAMP/memory/metadata.json" >/dev/null \
    && ok "bundle memory records preset + profile" || bad "bundle memory meta"
printf '%s' "$(sed -n '1p' "$BSTAMP/memory/corpus.jsonl")" | jq -e '.files | length >= 1' >/dev/null \
    && ok "bundle memory --files applies" || bad "bundle memory files"
[ -n "$(ls "$BSTAMP"/transcript/*/*.json 2>/dev/null)" ] && ok "bundle transcript writes faithful JSON per session" || bad "bundle transcript json files"
grep -q "transcript + memory" "$BSTAMP/index.md" && ok "bundle stamp has a root index tying the products" || bad "bundle root index"
# A CLI selection/config override applies to every product of the bundle.
run export everything --sessions ses_A0001 --cap 100 --tool-output omit >/dev/null
BT2="$(last_meta transcript)"; BT2="${BT2%/metadata.json}"; BSTAMP2="${BT2%/*}"
[ "$BSTAMP2" != "$BSTAMP" ] && ok "override run used a new shared stamp" || bad "override stamp"
jq -e '.sessions_selected == ["ses_A0001"] and .sessions.total == 1' "$BSTAMP2/transcript/metadata.json" >/dev/null \
    && ok "bundle CLI --sessions clobbers the shared selection" || bad "bundle override sessions"
jq -e '.tool_output == "omit"' "$BSTAMP2/transcript/metadata.json" >/dev/null \
    && ok "bundle CLI flag overrides the per-product preset config" || bad "bundle override flag: $(jq -r .tool_output "$BSTAMP2/transcript/metadata.json")"
jq -e '.cap == 100' "$BSTAMP2/memory/metadata.json" >/dev/null \
    && ok "bundle CLI --cap reaches memory too" || bad "bundle cap: $(jq -r .cap "$BSTAMP2/memory/metadata.json")"
# A bundle may include the standalone compactions product.
run export debugmsg >/dev/null
BT3="$(last_meta transcript)"; BT3="${BT3%/metadata.json}"; BSTAMP3="${BT3%/*}"
[ -d "$BSTAMP3/compactions" ] && ok "bundle with compactions product writes its folder" || bad "bundle compactions dir"
jq -e '.profile == "compactions" and .preset == "debugmsg"' "$BSTAMP3/compactions/metadata.json" >/dev/null \
    && ok "compactions product metadatos records bundle provenance" || bad "compactions meta"
# Error cases, each with a helpful message.
BAD1=$(run export badmix); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$BAD1" | grep -q "use either 'product' or 'products'" \
    && ok "bundle rejects product+products mix" || bad "badmix: $(printf '%s' "$BAD1" | tail -1)"
BAD2=$(run export badprod); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$BAD2" | grep -q "must be transcript, memory or compactions (got 'scribble')" \
    && ok "bundle rejects an invalid product" || bad "badprod: $(printf '%s' "$BAD2" | tail -1)"
export OCED_PRESETS="$PRESETS"

echo "== presets.schema.json contract (generated/) =="
SCHEMA="$TESTS_DIR/../generated/presets.schema.json"
EXAMPLE="$TESTS_DIR/../presets.json.example"
python3 "$TESTS_DIR/validate_schema.py" "$SCHEMA" "$EXAMPLE" >/dev/null 2>&1 \
    && ok "presets.json.example satisfies presets.schema.json" || bad "example vs schema"
# Anti-drift: generated/presets.schema.json + generated/flags-table.md must equal what
# scripts/generate_schema.py produces (imported directly, so stdout stays clean)
python3 -c "
import json, sys, importlib.util
spec = importlib.util.spec_from_file_location('gen', '$TESTS_DIR/../scripts/generate_schema.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
expected = json.dumps(m.generate_schema(), indent=2, ensure_ascii=False)
actual = json.dumps(json.load(open('$SCHEMA')), indent=2, ensure_ascii=False)
sys.exit(0 if expected == actual else 1)
" >/dev/null 2>&1 && ok "generated/presets.schema.json matches scripts/generate_schema.py (no drift)" || bad "schema drift vs generate_schema.py"
python3 -c "
import sys, importlib.util
spec = importlib.util.spec_from_file_location('gen', '$TESTS_DIR/../scripts/generate_schema.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.exit(0 if open('$TESTS_DIR/../generated/flags-table.md').read() == m.flags_table() + '\n' else 1)
" >/dev/null 2>&1 && ok "generated/flags-table.md matches scripts/generate_schema.py --docs (no drift)" || bad "flags-table drift vs generate_schema.py --docs"
cat > "$TMP/schema-bad.json" <<'EOF'
{"presets": {"double": {"product": "transcript", "products": {"memory": {}}}}}
EOF
python3 "$TESTS_DIR/validate_schema.py" "$SCHEMA" "$TMP/schema-bad.json" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "schema rejects a product+products mix" || bad "schema negative"
echo "== shipped presets.json.example end-to-end (archive/quick/share) =="
export OCED_PRESETS="$EXAMPLE"
run export archive >/dev/null
EJ="$(last_meta transcript)"; EJ="${EJ%/metadata.json}"; EJSTAMP="${EJ%/*}"
[ -d "$EJSTAMP/transcript" ] && [ -d "$EJSTAMP/memory" ] && [ ! -d "$EJSTAMP/compactions" ] \
    && ok "example 'archive' runs transcript+memory under one stamp" || bad "example archive dirs"
jq -e '.preset == "archive" and .tool_output == "full"' "$EJSTAMP/transcript/metadata.json" >/dev/null \
    && ok "example archive transcript flags applied" || bad "example archive meta"
run export quick >/dev/null
DBUG="$(last_meta memory)"; DBUG="${DBUG%/metadata.json}"; DBUGSTAMP="${DBUG%/*}"
[ -d "$DBUGSTAMP/transcript" ] && [ -d "$DBUGSTAMP/memory" ] && [ ! -d "$DBUGSTAMP/compactions" ] \
    && ok "example 'quick' is a light transcript+memory bundle (no redundant compactions)" || bad "example quick dirs"
jq -e '.preset == "quick" and .tool_output == "truncated"' "$DBUGSTAMP/transcript/metadata.json" >/dev/null \
    && ok "example quick uses truncated tool output (light variant)" || bad "example quick meta"
run export share >/dev/null
jq -e '.preset == "share" and .reasoning == false and .json == true and .sanitize == false' "$(last_meta transcript)" >/dev/null \
    && ok "example 'share' applies its single-product flags (no sanitize)" || bad "example share meta"
export OCED_PRESETS="$PRESETS"

echo "== shrink --swap (guarded replacement of the live fake DB) =="
# The pgrep guard must not trip in the test box even if a real opencode runs there,
# so shadow pgrep with a stub that reports "no matches" just for this block.
mkdir -p "$TMP/stubbin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/stubbin/pgrep"
chmod +x "$TMP/stubbin/pgrep"
PATH="$TMP/stubbin:$PATH"
SW=$(run shrink --keep 1 --swap --yes)
PATH=${PATH#"$TMP/stubbin:"}
printf '%s' "$SW" | grep -q "\[OK\] Swap complete" && ok "--swap completed" || bad "--swap: $(printf '%s' "$SW" | tail -3)"
[ "$(sqlite3 "file:$FAKE?mode=ro" "PRAGMA integrity_check;")" = "ok" ] \
    && ok "--swap live DB integrity ok" || bad "--swap integrity"
[ "$(sqlite3 "file:$FAKE?mode=ro" "SELECT count(*) FROM session;")" -eq 1 ] \
    && ok "--swap replaced the live DB (1 kept session)" || bad "--swap kept sessions"
# Safety copy is now in $OCED_BACKUP_DIR/pre-shrink/ (which is $BK/pre-shrink/)
PRE=$(ls "$BK/pre-shrink"/opencode.pre-shrink-*.db 2>/dev/null | head -1)
[ -n "$PRE" ] && ok "--swap wrote a pre-shrink safety copy in pre-shrink/" || bad "--swap safety copy missing"
[ "$(sqlite3 "file:$PRE?mode=ro" "SELECT count(*) FROM session;")" -eq 6 ] \
    && ok "pre-shrink holds the original 6 sessions" || bad "pre-shrink sessions"

# shrink.json now records sessions.max_updated so the stale check can run.
LASTSJ=$(find "$BK/shrink" -name shrink.json 2>/dev/null | sort | tail -1)
MU=$(jq -r '.sessions.max_updated // 0' "$LASTSJ" 2>/dev/null)
LIVE_MU=$(sqlite3 "file:$FAKE?mode=ro" "SELECT coalesce(max(time_updated),0) FROM session;")
[ -n "$MU" ] && [ "$MU" != "0" ] && ok "shrink.json records sessions.max_updated ($MU)" || bad "shrink.json max_updated missing: [$MU]"
[ "$MU" = "$LIVE_MU" ] && ok "shrink max_updated == live DB max_updated" || bad "shrink max_updated ($MU) vs live ($LIVE_MU)"

# shrinks verify — clean when the copy is newer than the (swapped) live DB.
VCLEAN=$(run shrinks verify)
printf '%s' "$VCLEAN" | grep -q "All clean" && ok "shrinks verify: up-to-date copy is clean" || bad "shrinks verify clean: [$(printf '%s' "$VCLEAN" | tail -2)]"

# Make the live DB newer than the copy -> verify must flag the stale shrink.
sqlite3 "$FAKE" "UPDATE session SET time_updated=time_updated+1000000;" >/dev/null 2>&1
VSTALE=$(run shrinks verify)
printf '%s' "$VSTALE" | grep -q "has newer sessions" && ok "shrinks verify flags a stale shrink vs live" || bad "shrinks verify stale: [$(printf '%s' "$VSTALE" | tail -2)]"
VT=$(run shrinks verify --tsv)
printf '%s' "$VT" | grep -q '^stale' && ok "shrinks verify --tsv emits a stale row" || bad "shrinks verify tsv stale: [$(printf '%s' "$VT" | tail -2)]"

# A legacy shrink.json without sessions.max_updated is flagged (unverifiable), not silently clean.
jq 'del(.sessions.max_updated)' "$LASTSJ" > "$LASTSJ.bak" && mv "$LASTSJ.bak" "$LASTSJ"
VLEGACY=$(run shrinks verify)
printf '%s' "$VLEGACY" | grep -q "cannot verify freshness" && ok "shrinks verify flags a legacy shrink.json (no max_updated)" || bad "shrinks verify legacy: [$(printf '%s' "$VLEGACY" | tail -2)]"

echo "== shrinks (manager of the produced shrink copies) =="
SL=$(run shrinks list)
NCM=$(printf '%s' "$SL" | grep -oE 'Shrink copies \(([0-9]+)\)' | grep -oE '[0-9]+' | head -1)
[ -n "${NCM:-}" ] && [ "$NCM" -eq "$(printf '%s' "$SL" | grep -cE '^  [0-9]+\.')" ] \
    && ok "shrinks list header matches its rows ($NCM)" || bad "shrinks list rows: header vs rows"
[ "$NCM" -ge 1 ] 2>/dev/null && ok "shrinks list lists the produced runs" || bad "shrinks list empty"

TSV=$(run shrinks list --tsv)
STAMP=$(printf '%s\n' "$TSV" | sed -n '1p' | cut -f1)
case "$STAMP" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) ok "shrinks tsv: stamp key format" ;;
    *) bad "shrinks tsv stamp: '$STAMP'" ;;
esac
[ "$(printf '%s\n' "$TSV" | wc -l)" -eq "$NCM" ] && ok "shrinks tsv: one row per run" || bad "shrinks tsv rows"
printf '%s\n' "$TSV" | sed -n '1p' | grep -qE 'UTC.*sess' && ok "shrinks tsv: human display" || bad "shrinks tsv display: $(printf '%s\n' "$TSV" | sed -n '1p')"

VOUT=$(run shrinks view "$STAMP")
printf '%s' "$VOUT" | grep -q '"criteria"' && ok "shrinks view prints the shrink.json" || bad "shrinks view: [$VOUT]"
run shrinks view "nonesuch-000000" >/dev/null; [ $? -ne 0 ] && ok "shrinks view unknown stamp -> error" || bad "shrinks view unknown rc"
run shrinks remove "nonesuch-000000" >/dev/null; [ $? -ne 0 ] && ok "shrinks remove unknown stamp -> error" || bad "shrinks remove unknown rc"
ROUT=$(run shrinks remove "$STAMP" </dev/null)
printf '%s' "$ROUT" | grep -q 'y/N' && ok "shrinks remove without --yes asks for confirmation" || bad "shrinks remove no --yes: [$ROUT]"
[ -d "$BK/shrink/$STAMP" ] && ok "interactive-cancelled remove kept the run" || bad "remove without --yes deleted"
run shrinks remove "$STAMP" --yes >/dev/null
[ ! -d "$BK/shrink/$STAMP" ] && ok "shrinks remove --yes deletes the run" || bad "shrinks remove --yes"
run shrinks prune 0 >/dev/null; [ $? -ne 0 ] && ok "shrinks prune 0 rejected" || bad "shrinks prune 0 rc"
run shrinks prune 2 --yes >/dev/null
[ "$(find "$BK/shrink" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 2 ] && ok "shrinks prune 2 keeps the 2 newest" || bad "shrinks prune 2"

echo ""
echo "RESULT: $pass OK / $fail FAIL"
[ "$fail" -eq 0 ]