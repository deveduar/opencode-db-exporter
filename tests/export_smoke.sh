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
    find "$OUT" -path "*/$1/*" -name metadatos.json -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-
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
grep_run "Proyecto" list --root && ok "list --root" || bad "list --root"
grep_run "ORPHAN" list --sub --info && ok "list --sub includes orphan" || bad "list --sub"
grep_run "Proyecto Beta" list --filter 'Proyecto Beta' && ok "list --filter" || bad "list --filter"

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
TC=$(cat "$(last_transcript transcript 'Proyecto Alfa')")
echo "$TC" | grep -q "**Tool:**" && ok "transcript keeps tool calls" || bad "transcript no tools"
echo "$TC" | grep -q "Primero pienso" && ok "transcript keeps reasoning by default" || bad "transcript reasoning lost"
MT=$(last_meta transcript)
jq -e '.profile == "transcript" and .json == false and .sanitize == false and .reasoning == true and .tool_output == "truncated"' "$MT" >/dev/null \
    && ok "transcript metadata reflects the flags" || bad "transcript metadata: $(jq -c '{profile,json,sanitize,reasoning,tool_output}' "$MT")"

echo "== export transcript --no-reasoning =="
run export transcript --no-reasoning --filter ses_A0001 >/dev/null
TC=$(cat "$(last_transcript transcript 'Proyecto Alfa')")
echo "$TC" | grep -q "Primero pienso" && bad "no-reasoning kept reasoning" || ok "no-reasoning omits reasoning"
echo "$TC" | grep -q "Voy a mirar los archivos" && ok "no-reasoning keeps the text" || bad "no-reasoning lost text"
MT=$(last_meta transcript)
jq -e '.reasoning == false' "$MT" >/dev/null && ok "no-reasoning recorded in metadata" || bad "no-reasoning metadata"

echo "== export transcript --role user (prompts only, flag not a preset) =="
run export transcript --role user --filter ses_A0001 >/dev/null
TC=$(cat "$(last_transcript transcript 'Proyecto Alfa')")
echo "$TC" | grep -q "Hecho\." && bad "--role user kept the assistant answer" || ok "--role user excludes assistant messages"
echo "$TC" | grep -q "Sigo trabajando" && ok "--role user keeps the prompts" || bad "--role user lost prompts"

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
CC=$(cat "$(last_transcript compactions 'Proyecto Alfa')")
echo "$CC" | grep -q "DIGEST_A" && ok "compactions digest exported" || bad "compactions profile digest"
echo "$CC" | grep -q "\*\*Tool:\*\*" && bad "compactions profile has tools" || ok "compactions profile no tools"

echo "== long output truncation =="
run export transcript --filter ses_B0001 >/dev/null
FT=$(cat "$(last_transcript transcript 'Proyecto Beta')")
echo "$FT" | grep -q "truncated:" && ok "long output truncated" || bad "output not truncated"

echo "== transcript toggles: compaction markers + summary diffs =="
run export transcript --mark-compactions --summary-diffs --filter ses_A0001 >/dev/null
TC2=$(cat "$(last_transcript transcript 'Proyecto Alfa')")
echo "$TC2" | grep -q "Context compaction" && ok "compaction marker" || bad "compaction marker"
echo "$TC2" | grep -q "Summary of changes" && ok "summary diffs" || bad "summary diffs"
echo "$TC2" | grep -q "<!-- step-finish -->" && ok "step markers present" || bad "step markers"

echo "== token backfill from step-finish (session row has 0 tokens) =="
run export transcript --filter ses_A0001 >/dev/null
MT=$(last_meta transcript)
jq -e '.tokens_backfilled == 1' "$MT" >/dev/null && ok "metadatos records the backfill" || bad "tokens_backfilled: $(jq '.tokens_backfilled' "$MT")"
run export memory --filter ses_A0001 >/dev/null
MB=$(last_meta memory); MB="${MB%/metadatos.json}"
printf '%s' "$(sed -n '1p' "$MB/corpus.jsonl")" | jq -e '.tokens.input == 1100 and .tokens.output == 600 and .tokens.reasoning == 80 and .tokens.cache.read == 50 and .tokens.cache.write == 120 and .tokens.backfilled == true and .cost == 0.05' >/dev/null \
    && ok "memory corpus exposes the backfilled tokens + cost" || bad "memory backfill: $(sed -n '1p' "$MB/corpus.jsonl" | jq -c '.tokens')"

echo "== faithful JSON archive (--json) =="
run export transcript --json --filter ses_A0001 >/dev/null
JR=$(find "$OUT" -path "*/transcript/*" -name 'Proyecto Alfa.json' -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
[ -n "$JR" ] && ok "faithful JSON file written next to the transcript" || bad "json file missing"
jq -e '.info.id == "ses_A0001" and .info.tokens.input == 1100 and .info.tokens.backfilled == true and .info.cost == 0.05' "$JR" >/dev/null \
    && ok "json info carries the backfilled tokens" || bad "json info tokens"
jq -e '.messages | length == 6' "$JR" >/dev/null && ok "json keeps ALL messages (6)" || bad "json messages: $(jq '.messages | length' "$JR")"
jq -e '.messages[0].parts[0].type == "text"' "$JR" >/dev/null && ok "json message shape {info, parts}" || bad "json shape"
printf '%s' "$(cat "$JR")" | grep -q "sk-test1234567890abcdefghijkl" && ok "faithful JSON keeps raw data when not sanitizing" || bad "json raw data missing"

echo "== --sanitize redacts secrets in markdown and JSON =="
run export transcript --sanitize --filter ses_A0001 >/dev/null
TC=$(cat "$(last_transcript transcript 'Proyecto Alfa')")
printf '%s' "$TC" | grep -q "sk-test1234567890abcdefghijkl" && bad "sanitize leaked the API key" || ok "sanitize redacts the API key"
printf '%s' "$TC" | grep -q "sk-\[REDACTED\]" && ok "sanitize shows the redaction marker" || bad "sanitize marker missing"
run export transcript --json --sanitize --filter ses_A0001 >/dev/null
JR=$(find "$OUT" -path "*/transcript/*" -name 'Proyecto Alfa.json' -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
printf '%s' "$(cat "$JR")" | grep -q "sk-test1234567890abcdefghijkl" && bad "json sanitize leaked" || ok "json sanitize redacts recursively"
MT=$(last_meta transcript)
jq -e '.json == true and .sanitize == true' "$MT" >/dev/null && ok "json+sanitize recorded in metadata" || bad "json sanitize metadata"

echo "== shared-stamp bundle (products share one run folder) =="
BSTAMP="stplug-$(date -u +%s)"
run export transcript --stamp "$BSTAMP" --filter ses_A0001 >/dev/null
run export compactions --stamp "$BSTAMP" --filter ses_A0001 >/dev/null
[ -f "$OUT/$BSTAMP/transcript/metadatos.json" ] && [ -f "$OUT/$BSTAMP/compactions/metadatos.json" ] \
    && ok "same stamp = one run with two products" || bad "stamp bundle dirs"
ALROW=$(run exports list | awk -v s="$BSTAMP" '$0 ~ s {print; exit}')
printf '%s' "$ALROW" | grep -q "transcript" && printf '%s' "$ALROW" | grep -q "compactions" \
    && ok "exports list aggregates products joined with +" || bad "exports list aggregate: $ALROW"

echo "== filter =="
run export transcript --filter 'Proyecto Beta' >/dev/null
ME=$(last_meta transcript)
jq -e '.filter == "Proyecto Beta"' "$ME" >/dev/null && ok "filter applied in metadata" || bad "filter metadata"
jq -e '.sessions.roots == 1' "$ME" >/dev/null && ok "filter counts in metadata" || bad "filter counts"

echo "== sub inline / omit / separate =="
run export transcript --sub inline >/dev/null
INL=$(last_transcript transcript 'Proyecto Alfa')
grep -q "Subagent" "$INL" && ok "sub inline included" || bad "sub inline"
run export transcript --sub omit >/dev/null
OMIT=$(last_meta transcript)
jq -e '.sessions.subagents == 0' "$OMIT" >/dev/null && ok "sub omit = 0 subagents" || bad "sub omit: $(jq '.sessions.subagents' "$OMIT")"
run export transcript --sub separate >/dev/null
SEP=$(last_meta transcript)
jq -e '.sessions.subagents == 3' "$SEP" >/dev/null && ok "sub separate = 3 subagents" || bad "sub separate: $(jq '.sessions.subagents' "$SEP")"

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

echo "== shrink recipes (named presets) =="
newest_sj() { find "$BK/shrink" -name shrink.json 2>/dev/null | sort | tail -1; }
run shrink lean >/dev/null || bad "shrink lean run"
printf '%s' "$(cat "$(newest_sj)")" | jq -e '.sessions.kept == 6 and .stripped_reasoning == 1 and (.criteria | contains("keep the 10 most recent") and contains("strip reasoning"))' >/dev/null \
    && ok "shrink lean = keep 10 + strip reasoning" || bad "shrink lean: $(cat "$(newest_sj)")"
run shrink bare >/dev/null || bad "shrink bare run"
SB=$(find "$BK/shrink" -name opencode.shrunk.db 2>/dev/null | sort | tail -1)
[ "$(sqlite3 "$SB" "SELECT count(*) FROM part WHERE json_extract(data, '$.type') = 'reasoning';")" -eq 1 ] \
    && ok "shrink bare keeps reasoning" || bad "shrink bare reasoning lost"
run shrink full >/dev/null || bad "shrink full run"
printf '%s' "$(cat "$(newest_sj)")" | jq -e '.sessions.kept == 6 and .stripped_reasoning == 1' >/dev/null \
    && ok "shrink full = keep all + strip reasoning" || bad "shrink full: $(cat "$(newest_sj)")"
run shrink recent >/dev/null || bad "shrink recent run"
printf '%s' "$(cat "$(newest_sj)")" | jq -e '.sessions.kept == 6 and (.criteria | contains("last 90 day"))' >/dev/null \
    && ok "shrink recent = sessions updated in the last 90 days" || bad "shrink recent: $(cat "$(newest_sj)")"

echo "== export memory (RAG corpus) =="
run export memory >/dev/null
MEM=$(last_meta memory); MEM="${MEM%/metadatos.json}"
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
MEMF=$(last_meta memory); MEMF="${MEMF%/metadatos.json}"
printf '%s' "$(sed -n '1p' "$MEMF/corpus.jsonl")" | jq -e '.files | index("src/a.py") != null' >/dev/null \
    && ok "memory --files lists touched files" || bad "memory --files"
run export memory --cap 20 >/dev/null
MEMC=$(last_meta memory); MEMC="${MEMC%/metadatos.json}"
printf '%s' "$(sed -n '1p' "$MEMC/corpus.jsonl")" | jq -e '.first_user | length == 20' >/dev/null \
    && ok "memory --cap truncates to N" || bad "memory --cap"

echo "== index.md present and with links =="
run export transcript --mark-compactions >/dev/null
IX=$(last_meta transcript); IX="${IX%/metadatos.json}/index.md"
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
MB=$(last_meta memory); MB="${MB%/metadatos.json}"
printf '%s' "$(cat "$MB/metadatos.json")" | jq -e '.db | contains("oced-backup")' >/dev/null \
    && ok "export --from-backup read the decompressed backup" || bad "export from backup: $(jq -r '.db' "$MB/metadatos.json")"
# No temp files must be left behind after the command exits.
before=$(find /tmp -maxdepth 1 -name 'oced-backup-*.db' 2>/dev/null | wc -l)
run --from-backup "$BKF" version >/dev/null
after=$(find /tmp -maxdepth 1 -name 'oced-backup-*.db' 2>/dev/null | wc -l)
[ "$after" -le "$before" ] && ok "--from-backup leaves no temp files" || bad "leftover temp files: $before -> $after"

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
PRE=$(ls "$FAKE".pre-shrink-* 2>/dev/null | head -1)
[ -n "$PRE" ] && ok "--swap wrote a .pre-shrink safety copy" || bad "--swap safety copy missing"
[ "$(sqlite3 "file:$PRE?mode=ro" "SELECT count(*) FROM session;")" -eq 6 ] \
    && ok ".pre-shrink holds the original 6 sessions" || bad ".pre-shrink sessions"

echo ""
echo "RESULT: $pass OK / $fail FAIL"
[ "$fail" -eq 0 ]