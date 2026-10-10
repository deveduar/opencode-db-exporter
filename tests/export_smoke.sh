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
# Hermetic config: a missing OCED_CONF keeps the suite independent of the
# developer's ~/.config AND of the repo-shipped portable conf (env > conf; the
# portable-detection tests below override this with env -u OCED_CONF ...).
export OCED_CONF="$TMP/missing-conf.conf"

pass=0; fail=0
ok() { echo "  [OK]   $1"; pass=$((pass+1)); }
bad() { echo "  [FAIL] $1"; fail=$((fail+1)); }
run() { bash "$MOD/opencode-db.sh" "$@" 2>&1; }
# stamp_of <run-output> -> the stamp the run itself reported.
# NOT "newest metadata by mtime": two exports inside the same sub-second tick tie
# on %T@, and the sort then picks by path, which can hand back the PREVIOUS run.
# Every test that reads back what it just ran must use the run's own answer.
# The reported path is <OUT>/<stamp>/<profile>; take THAT path verbatim instead
# of rebuilding it (no basename round-trip, no mtime, no name mangling).
out_dir_of() {   # $1 = run output -> the <OUT>/<stamp>/<profile> dir it wrote
    printf '%s' "$1" | sed -n 's/.* to: //p' | tail -1 | sed 's:/*$::'
}
stamp_of() { out_dir_of "$1" | sed 's:/[^/]*$::' | xargs -r basename; }
# The metadata sits INSIDE the reported profile dir: <OUT>/<stamp>/<profile>/metadata.json
meta_of() { out_dir_of "$1" | xargs -r -I{} printf '%s/metadata.json' "{}"; }
grep_run() { # $1=pattern, rest=CLI args: capture output before grep (avoids SIGPIPE/pipefail)
    local pat="$1"; shift
    local out; out=$(run "$@")
    printf '%s' "$out" | grep -q "$pat"
}
last_transcript() { # $1=profile $2=title (newest by mtime)
    find "$OUT" -path "*/$1/*" -name "*$2*.md" -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-
}
last_meta() { # $1=profile (newest by mtime, path breaks a tie)
    # `sort -n` compares the WHOLE line numerically, so an equal %T@ left the
    # order to chance and two exports in the same tick could hand back the older
    # run. Sort by mtime first and by PATH second: deterministic.
    find "$OUT" -path "*/$1/*" -type f -name metadata.json -printf '%T@ %p\n' \
        | sort -k1,1n -k2,2 | tail -1 | cut -d' ' -f2-
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

# End-to-end: the repo presets are actually usable — `archive` exists only in the
# shipped presets.json, so resolving it proves the portable default kicked in.
PO="$TMP/po"
mkdir -p "$PO"
PORT_RUN=$(HOME="$FAKEHOME" env -u OCED_CONF -u OCED_OUT -u OCED_BACKUP_DIR -u OCED_PRESETS -u OCED_SHRINK_PRESETS \
    OPENCODE_DB="$FAKE" OCED_OUT="$PO" bash "$MOD/opencode-db.sh" export archive --sessions ses_A0001 2>&1)
[ -n "$(find "$PO" -name metadata.json 2>/dev/null | head -1)" ] \
    && ok "portable export resolves the repo presets (archive)" \
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
CC=$(cat "$(out_dir_of "$DIGRUN")"/*/'Project Alpha'*.md)
echo "$CC" | grep -q "DIGEST_A" && ok "digest profile exported" || bad "digest profile"
echo "$CC" | grep -q "\*\*Tool:\*\*" && bad "digest profile has tools" || ok "digest profile no tools"

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
jq -e '.tokens_backfilled == 1' "$MT" >/dev/null && ok "metadata records the backfill" || bad "tokens_backfilled: $(jq '.tokens_backfilled' "$MT")"
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
SELRUN="selrun-$(date -u +%s)"
run export transcript --stamp "$BSTAMP" --filter ses_A0001 >/dev/null
run export digest --stamp "$BSTAMP" --filter ses_A0001 >/dev/null
[ -f "$OUT/$BSTAMP/transcript/metadata.json" ] && [ -f "$OUT/$BSTAMP/digest/metadata.json" ] \
    && ok "same stamp = one run with two products" || bad "stamp bundle dirs"
ALROW=$(run exports list | awk -v s="$BSTAMP" '$0 ~ s {print; exit}')
printf '%s' "$ALROW" | grep -q "transcript" && printf '%s' "$ALROW" | grep -q "digest" \
    && ok "exports list aggregates products joined with +" || bad "exports list aggregate: $ALROW"
VIEW=$(run exports view "$BSTAMP")
printf '%s' "$VIEW" | grep -q "transcript" && printf '%s' "$VIEW" | grep -q "digest" && printf '%s' "$VIEW" | grep -q "totals:" \
    && ok "exports view shows every product of the run" || bad "exports view aggregate: $(printf '%s' "$VIEW" | sed -n '1,6p')"
# A detail screen must lead with a banner, like info/backups/shrinks.
printf '%s' "$VIEW" | sed -n '1p' | grep -q "^== Export run: $BSTAMP ==" \
    && ok "exports view leads with a run header" || bad "exports view header: $(printf '%s' "$VIEW" | sed -n '1p')"
printf '%s' "$VIEW" | grep -c "== Export run:" | grep -qx "1" \
    && ok "exports view repeats the run header once (per product)" || bad "exports view header repeated"
VJSON=$(run exports view "$BSTAMP" --json)
printf '%s' "$VJSON" | jq -e 'type == "array" and (map(.profile) | sort) == ["digest","transcript"]' >/dev/null \
    && ok "exports view --json is one metadata record per product" || bad "exports view --json: $VJSON"
printf '%s' "$VJSON" | grep -q "== Export run" && bad "exports view --json header" || ok "exports view --json has no header"
# sessions_selected is an ARRAY: the Selection line must join it, never concat it.
mkdir -p "$OUT/$SELRUN/transcript"
jq -n '{profile:"transcript",filter:null,sessions_selected:["ses_A0001","ses_B0001"],preset:"archive",
        sessions:{total:2,roots:2,subagents:0},messages:2,compactions:0,files:["index.md"]}' \
    > "$OUT/$SELRUN/transcript/metadata.json"
SELV=$(run exports view "$SELRUN")
printf '%s' "$SELV" | grep -q "jq: error" && bad "exports view selection array: jq error" || ok "exports view renders an array sessions_selected"
# The selection is read from `.selection` (the inverse of selection_meta), so an
# array sessions_selected WITHOUT .selection degrades to a legacy record.
printf '%s' "$SELV" | grep -qE "selection: +2 explicit session id\(s\) \(legacy record\)" \
    && ok "exports view joins an array sessions_selected" || bad "exports view selection array: $(printf '%s' "$SELV" | grep -i 'selection')"
# It must NOT be printed per product: it is a run-level fact.
[ "$(printf '%s' "$SELV" | grep -ci 'selection:')" -eq 1 ] \
    && ok "exports view prints the selection once per run" || bad "exports view repeats the selection"
# Keys a product does not have must not be invented: `cap`/`touched_files` are
# memory-only, and this fixture is a transcript.
printf '%s' "$SELV" | grep -qE "^  (Cap|Touched files):" \
    && bad "exports view invents memory-only keys: $(printf '%s' "$SELV" | grep -E "^  (Cap|Touched)")" \
    || ok "exports view omits keys the product does not have"
# Field labels must align on one column.
BADALIGN=$(printf '%s' "$SELV" | sed -n '/== Details per product ==/,$p' | grep -E '^  [A-Za-z].*[A-Za-z]+: ' | grep -vcE '^  [A-Za-z][A-Za-z ()]*: {2,}')
[ "$BADALIGN" -eq 0 ] && ok "exports view field labels align" || bad "exports view label alignment ($BADALIGN ragged)"
# The legacy `metadatos.json` file name is gone: a run dir that only has it is
# ignored (one name, English). The shape fallbacks for OLD metadata.json CONTENT
# (no .sessions.total, no .session_records) still apply.
LEGACY="legacy-$(date -u +%s)"
mkdir -p "$OUT/$LEGACY/transcript"
echo '{"profile":"transcript","sessions":{"roots":1,"subagents":0},"messages":2,"compactions":0}' > "$OUT/$LEGACY/transcript/metadatos.json"
LEGACYV=$(run exports view "$LEGACY" 2>&1)
[ $? -ne 0 ] && printf '%s' "$LEGACYV" | grep -q "No metadata.json found" \
    && ok "exports view refuses a legacy-only metadatos.json run dir" \
    || bad "exports view legacy: $(printf '%s' "$LEGACYV" | head -1)"
EXL=$(run exports list)
LEGRO=$(printf '%s' "$EXL" | grep "$LEGACY" || true)
printf '%s' "$LEGRO" | grep -qv transcript \
    && ok "exports list stops aggregating metadatos.json runs" \
    || bad "legacy list row: $(printf '%s' "$LEGRO" | head -1)"

# Same minimal record as metadata.json: the content fallbacks stay.
NOSHAPE="noshape-$(date -u +%s)"
mkdir -p "$OUT/$NOSHAPE/transcript"
echo '{"profile":"transcript","sessions_selected":["ses_A0001"],"sessions":{"roots":1,"subagents":0},"messages":2,"compactions":0}' > "$OUT/$NOSHAPE/transcript/metadata.json"
NOSS=$(run exports view "$NOSHAPE")
# No sessions.total: totals must come from roots + subagents.
printf '%s' "$NOSS" | grep -qE "^  totals: +1 roots \(0 subagent\)" \
    && ok "exports view derives totals from roots + subagents" || bad "noshape totals: $(printf '%s' "$NOSS" | grep -i 'totals:')"
printf '%s' "$NOSS" | grep -q "legacy record" \
    && ok "exports view labels a pre-session_records run's selection" || bad "noshape selection label"

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
for prod in transcript memory digest; do
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

echo "== shrink discard hint: the CASCADE, not the roots =="
# `--discard-sessions` drops the listed roots AND every descendant, but
# `export --sessions` matches EXACT ids (pinned earlier: --sessions ses_A0001
# exports 1 session and 0 subagents). Handing over only the roots exported 2 of
# the 7 sessions the copy was about to drop — silently, because the export still
# succeeded with plausible counts. So the hint (and the menu offer) must carry
# the closed set. OCED_PRESETS is pinned to the shipped presets so `archive`
# resolves deterministically instead of depending on ~/.config.
EX_PRESETS="$TESTS_DIR/../presets.json"
drun() { # drun <profile|-> <args...> -> shrink run output with that profile
    local p="$1"; shift
    if [ "$p" = "-" ]; then
        bash "$MOD/opencode-db.sh" "$@" 2>&1
    else
        OCED_SHRINK_DISCARD_EXPORT_PROFILE="$p" bash "$MOD/opencode-db.sh" "$@" 2>&1
    fi
}
DH=$(OCED_PRESETS="$EX_PRESETS" drun - shrink --discard-sessions ses_A0001)
printf '%s' "$DH" | grep -q "export archive --sessions ses_A0001,ses_A0002,ses_A0003" \
    && ok "discard hint exports the whole cascade (root + its 2 subagents)" || bad "hint cascade: $DH"
printf '%s' "$DH" | grep -q "3 session(s) listed above" \
    && ok "discard hint counts the cascade, not the listed roots" || bad "hint count: $DH"
printf '%s' "$DH" | grep -q "will NOT survive in this copy" \
    && ok "discard hint says the copy is already built (not 'before building')" || bad "hint wording: $DH"
DH2=$(OCED_PRESETS="$EX_PRESETS" drun memory shrink --discard-sessions ses_A0001)
printf '%s' "$DH2" | grep -q "export memory --sessions ses_A0001,ses_A0002,ses_A0003" \
    && ok "OCED_SHRINK_DISCARD_EXPORT_PROFILE picks the profile both call sites print" || bad "profile var: $DH2"
DH3=$(OCED_PRESETS="$EX_PRESETS" drun archve shrink --discard-sessions ses_A0001)
printf '%s' "$DH3" | grep -q "is not a valid export profile" \
    && printf '%s' "$DH3" | grep -q "Valid: archive" \
    && printf '%s' "$DH3" | grep -q "Using 'archive' instead" \
    && printf '%s' "$DH3" | grep -q "export archive --sessions ses_A0001,ses_A0002,ses_A0003" \
    && ok "an invalid profile is reported with the valid names, then falls back" || bad "invalid profile: $DH3"
DH4=$(OCED_PRESETS="$TMP/no-such-presets.json" drun - shrink --discard-sessions ses_A0001)
printf '%s' "$DH4" | grep -q "Using 'transcript' instead" \
    && ok "no presets file -> the always-valid transcript product is used" || bad "no-presets fallback: $DH4"
# the exact-ids contract that forces the caller-side expansion (guard against a
# future "--sessions closes over descendants": the menu expands, the engine does not)
RO=$(OCED_PRESETS="$EX_PRESETS" run export archive --sessions ses_A0001)
jq -e '.sessions.total == 1 and .sessions.subagents == 0' "$(meta_of "$RO")" >/dev/null \
    && ok "--sessions stays EXACT (1 root, 0 subagents) — the menu expands instead" || bad "--sessions is no longer exact"

# ...and the other half of the same contract: handed the CASCADE, the export must
# really write the subagents, NESTED under their own root. The two assertions above
# pin each half separately (the hint prints the cascade; --sessions is exact), so
# without this one nothing proved that the cascade the offer hands over is the set
# the engine actually drops — which is the bug: 2 of 7 sessions exported, silently.
CAS=$(OCED_PRESETS="$EX_PRESETS" run export archive --sessions ses_A0001,ses_A0002,ses_A0003)
CMETA="$(meta_of "$CAS")"
jq -e '.sessions.total == 3 and .sessions.subagents == 2' "$CMETA" >/dev/null \
    && ok "the cascade export writes the root AND its 2 subagents (3 sessions)" \
    || bad "cascade export: $(jq -c '.sessions' "$CMETA")"
# `archive` is a BUNDLE, so out_dir_of lands on the LAST product (memory). Read the
# transcript subdir from the stamp — that is where the per-session files live, and
# the nesting question ("under their own root, or as extra roots?") is asked there.
CSTAMP="$OUT/$(stamp_of "$CAS")"
CDIR="$CSTAMP/transcript"
# 1 root folder + subagents/ with 2 files: the subagents are written under their
# OWN root (children_of), not flattened as extra roots and not dropped
[ "$(find "$CDIR" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 ] \
    && [ "$(find "$CDIR" -path "*/subagents/*.md" | wc -l)" -eq 2 ] \
    && ok "the subagents land in <root>/subagents/, nested (not extra roots)" \
    || bad "cascade layout: $(cd "$CDIR" && find . -maxdepth 2 | sort | tr '\n' ' ')"
# the index.md row is what a human reads: roots/subagents/total must agree
grep -qE '^\| Sessions \(roots/subagents/total\) \| 1 / 2 / 3 \|$' "$CDIR/index.md" \
    && ok "index.md reports 1 root / 2 subagents / 3 total" || bad "index row: $(grep 'Sessions (roots' "$CDIR/index.md")"
jq -e '[.session_records[].id] | sort == ["ses_A0001","ses_A0002","ses_A0003"]' "$CMETA" >/dev/null \
    && ok "metadata .session_records lists all 3 exported sessions" || bad "records: $(jq -c '.session_records|map(.id)' "$CMETA")"
# memory (the other half of archive) must reference the subagents on its one line
printf '%s' "$(sed -n '1p' "$CSTAMP/memory/corpus.jsonl")" | jq -e '(.subagents | length) == 2' >/dev/null \
    && ok "memory's corpus line references the 2 subagents of its root" || bad "corpus refs: $(sed -n '1p' "$CSTAMP/memory/corpus.jsonl" | jq -c '.subagents')"

echo "== the discard cascade export is linked into shrink.json =="
# The offer/hint exports EXACTLY the closed cascade (`--sessions root,sub,sub`),
# so the engine auto-detects the NEWEST export run whose .sessions_selected equals
# it and records .discard_exported — one link shared by the CLI path (this run)
# and the menu offer, with no flag and no menu-side state. This shrink runs AFTER
# the cascade export above, which is the order the offer/hint enforces.
DLINK=$(OCED_PRESETS="$EX_PRESETS" run shrink --discard-sessions ses_A0001)
DSJ=$(newest_sj)
DSTAMP=$(basename "$(dirname "$DSJ")")
DE=$(jq -r '.discard_exported // ""' "$DSJ")
[ "$DE" = "$(stamp_of "$CAS")" ] \
    && ok "the cascade export is auto-linked into shrink.json (.discard_exported = $DE)" \
    || bad "discard_exported: [${DE:-absent}] want [$(stamp_of "$CAS")]"
printf '%s' "$DLINK" | grep -q "recorded: the cascade export is $(stamp_of "$CAS")" \
    && ok "the shrink hint names the recorded export run" || bad "hint-recorded line: $DLINK"
printf '%s' "$(run shrinks view "$DSTAMP")" | grep -qE "^  discard export: +$DE \(the discarded cascade was exported" \
    && ok "shrinks view shows the discard export line for this copy" \
    || bad "shrinks view lacks the discard export line: [$(printf '%s' "$(run shrinks view "$DSTAMP")" | grep 'discard export')]"
# No matching cascade export -> the key stays absent (deterministic negative: the
# B cascade [root+1 sub] has never been exported with its exact closed set).
DNO=$(OCED_PRESETS="$EX_PRESETS" run shrink --discard-sessions ses_B0001)
DSJ2=$(newest_sj)
jq -e 'has("discard_exported") | not' "$DSJ2" >/dev/null \
    && ok "no matching cascade export -> no discard_exported key" \
    || bad "discard_exported set without a matching cascade export: $(jq -c '.discard_exported // ""' "$DSJ2")"

echo "== the discard profile must not silently drop the subagents it is handed =="
# The offer's whole promise is "this export keeps what the shrink drops", and it
# hands over a CLOSED set. Two flags break that while the export still succeeds
# with plausible counts: no_subagents drops the sessions themselves, and
# `sub: omit` empties children_of so no subagent body is written at all. A
# product keyword can never gap, so only a preset needs the warning.
GAP="$TMP/gap-presets.json"
cat > "$GAP" <<'EOF'
{"presets": {
  "narrow":   {"product": "transcript", "sub": "omit"},
  "dropall":  {"product": "transcript", "no_subagents": true},
  "droporph": {"products": {"transcript": {}, "memory": {"no_orphan_subagents": true}}}
}}
EOF
DG=$(OCED_PRESETS="$GAP" drun narrow shrink --discard-sessions ses_A0001)
printf '%s' "$DG" | grep -q "the export profile 'narrow' does not preserve subagents (sub_omit)" \
    && ok "a preset with 'sub: omit' is warned about before its y/N gate" || bad "sub_omit warning: $DG"
# a warning, not a veto: the command is still printed (the user may want it)
printf '%s' "$DG" | grep -q "export narrow --sessions ses_A0001,ses_A0002,ses_A0003" \
    && ok "the subagent gap warns but does not block the offered command" || bad "sub_omit blocks: $DG"
DG2=$(OCED_PRESETS="$GAP" drun dropall shrink --discard-sessions ses_A0001)
printf '%s' "$DG2" | grep -q "does not preserve subagents (no_subagents)" \
    && ok "a preset with no_subagents is warned about too" || bad "no_subagents warning: $DG2"
DG3=$(OCED_PRESETS="$GAP" drun droporph shrink --discard-sessions ses_A0001)
printf '%s' "$DG3" | grep -q "does not preserve subagents (no_orphan_subagents)" \
    && ok "the gap is read across a bundle's products (memory drops them)" || bad "bundle gap: $DG3"
DG4=$(OCED_PRESETS="$EX_PRESETS" drun - shrink --discard-sessions ses_A0001)
printf '%s' "$DG4" | grep -q "does not preserve subagents" \
    && bad "a gap-free profile (archive) must be silent" || ok "a profile that keeps subagents warns nothing (no noise)"

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
# the shipped shrink-presets.json must satisfy the generated schema
python3 "$TESTS_DIR/validate_schema.py" generated/shrink.schema.json "$TESTS_DIR/../shrink-presets.json" >/dev/null 2>&1 \
    && ok "shipped shrink-presets.json satisfies shrink.schema.json" || bad "shipped shrink presets vs schema"

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

echo "== metadata: compactions (markers) vs digests (summaries) =="
# The two are different things and must never share a number: a marker is the
# event opencode records (part.data.type='compaction'), a digest is the summary
# text it wrote for it (message.data.mode='compaction').
DIGOUT=$(run export digest --filter "%" --stamp "meta-digests")
DM=$(meta_of "$DIGOUT")
jq -e '.compactions | type == "number"' "$DM" >/dev/null \
    && ok "metadata.compactions counts the markers" || bad "metadata.compactions"
jq -e '.digests | type == "number" and . > 0' "$DM" >/dev/null \
    && ok "metadata.digests counts the summaries" || bad "metadata.digests"
# The transcript header must name both, not call the marker count a digest.
DT=$(cat "$(last_transcript digest 'Project Alpha')")
echo "$DT" | grep -q "Digests:" && echo "$DT" | grep -q "Compaction markers:" \
    && ok "transcript header separates digests from markers" || bad "transcript header"
DT2=$(cat "$(last_transcript transcript 'Project Alpha')")
echo "$DT2" | grep -q "Compaction markers:" \
    && ok "transcript header reports markers too" || bad "transcript markers"

echo "== exports view: the selection comes from .selection, not from .filter =="
# THE BUG THIS FIXES: reading `.filter`/`.sessions_selected` reported a
# `--last N` / `--since DATE` run as "sessions: all", i.e. the detail screen of
# a run lied about the rule that produced it. Both rules are CLI-only, so no
# preset key could cover them -- only `.selection` can.
# NOTE: each run reads its OWN stamp back (stamp_of), never "newest by mtime":
# two exports in the same sub-second tick tie on %T@ and the sort hands back the
# previous run, which made this block fail intermittently.
SELOUT=$(run export transcript --last 2 --stamp "sel-last")
LASTV=$(run exports view "$(stamp_of "$SELOUT")")
printf '%s' "$LASTV" | grep -qE "selection: +last 2 session\(s\) by last update" \
    && ok "exports view reports a --last run as --last" || bad "exports view --last: $(printf '%s' "$LASTV" | grep -i 'selection:')"
printf '%s' "$LASTV" | grep -q "ALL sessions" \
    && bad "exports view reports a --last run as ALL sessions" || ok "exports view never collapses a rule into ALL"
SELOUT=$(run export transcript --since 2026-09-10 --stamp "sel-since")
SINCEV=$(run exports view "$(stamp_of "$SELOUT")")
printf '%s' "$SINCEV" | grep -qE "selection: +updated on or after 2026-09-10" \
    && ok "exports view reports a --since run as --since" || bad "exports view --since: $(printf '%s' "$SINCEV" | grep -i 'selection:')"
SELOUT=$(run export transcript --filter "%Alpha%" --stamp "sel-filter")
FILV=$(run exports view "$(stamp_of "$SELOUT")")
printf '%s' "$FILV" | grep -qE "selection: +filter %Alpha%" \
    && ok "exports view reports a --filter run as --filter" || bad "exports view --filter: $(printf '%s' "$FILV" | grep -i 'selection:')"

echo "== exports view: WHICH sessions the run contains =="
RECOUT=$(run export transcript --filter "%" --stamp "view-recs")
RECV=$(run exports view "$(stamp_of "$RECOUT")")
printf '%s' "$RECV" | grep -q "== Sessions ==" && ok "exports view lists the sessions" || bad "exports view sessions block"
printf '%s' "$RECV" | grep -q "ses_ORPHAN01.*root" \
    && ok "an orphan session is listed as a root" || bad "exports view orphan kind"
printf '%s' "$RECV" | grep -q "ses_A0002.*subagent" \
    && ok "a subagent is listed as a subagent" || bad "exports view subagent kind"
printf '%s' "$RECV" | grep -q "Project Alpha" \
    && ok "exports view shows the session title" || bad "exports view session title"
# The titles are the only free-text column: they must line up on one column, so
# a `subagent` (8) kind cannot shift the date of a `root` (4) row.
SESSROW=$(printf '%s' "$RECV" | sed -n '/== Sessions ==/,$p' | tail -n +3 | grep -E "^  ses_" | wc -l)
SESSCOL=$(printf '%s' "$RECV" | sed -n '/== Sessions ==/,$p' | tail -n +3 | grep -E "^  ses_" | awk '{print index($0,"2026-")}' | sort -u | wc -l)
[ "$SESSROW" -gt 0 ] && [ "$SESSCOL" -eq 1 ] \
    && ok "exports view session rows share one column ($SESSROW rows)" || bad "exports view session alignment ($SESSCOL distinct columns)"
# A run that dropped a subagent must NOT list it.
NOSUBOUT=$(run export transcript --no-subagents --filter "%" --stamp "view-nosub")
NOSUBV=$(run exports view "$(stamp_of "$NOSUBOUT")")
printf '%s' "$NOSUBV" | grep -q "ses_A0002" \
    && bad "exports view lists a subagent that was not exported" || ok "exports view session list matches the run"

echo "== metadata.session_records (WHICH sessions the run actually contains) =="
# NOTE: the UNFILTERED run is the meaningful one. A title filter like
# "%Project Alpha%" matches NO subagent (their titles differ), so a filtered run
# has zero subagents and every subagent assertion below would pass vacuously.
run export transcript --filter "%" >/dev/null
SR=$(last_meta transcript)
jq -e '.session_records | type == "array"' "$SR" >/dev/null \
    && ok "session_records is an array" || bad "session_records type"
# .sessions stays the untouched AGGREGATE object (nothing was repurposed).
jq -e '.sessions | (has("total") and has("roots") and has("subagents"))' "$SR" >/dev/null \
    && ok ".sessions is still the aggregate {total,roots,subagents}" || bad ".sessions shape"
# The aggregate is the SUMMARY of the records, so the two cannot disagree.
NREC=$(jq '.session_records | length' "$SR")
[ "$NREC" = "$(jq '.sessions.total' "$SR")" ] \
    && ok "records == sessions.total ($NREC)" || bad "records $NREC != total $(jq '.sessions.total' "$SR")"
[ "$(jq '[.session_records[] | select(.kind == "root")] | length' "$SR")" = "$(jq '.sessions.roots' "$SR")" ] \
    && ok "record roots == sessions.roots" || bad "root count mismatch"
NSUB=$(jq '[.session_records[] | select(.kind == "subagent")] | length' "$SR")
[ "$NSUB" = "$(jq '.sessions.subagents' "$SR")" ] \
    && ok "record subagents == sessions.subagents ($NSUB)" || bad "subagent count mismatch"
[ "$NSUB" -gt 0 ] \
    && ok "the run really did include subagents (assertions are not vacuous)" || bad "no subagents in the set"
# IDENTITY only: no per-session counts duplicated (the totals live at top level).
jq -e '[.session_records[] | keys[]] | unique - ["id","title","kind","parent_id","created","updated"] | length == 0' "$SR" >/dev/null \
    && ok "records carry identity only (no duplicated counts)" || bad "record fields: $(jq -c '[.session_records[0]|keys]' "$SR")"
# Absent parent is null, never "" (the machine-artifact rule).
jq -e '[.session_records[] | select(.parent_id == null)] | length > 0' "$SR" >/dev/null \
    && ok "a root parent_id is null (not an empty string)" || bad "parent_id null rule"
jq -e '[.session_records[] | select(.kind == "subagent") | .parent_id | type == "string"] | all' "$SR" >/dev/null \
    && ok "every subagent record names its parent" || bad "subagent parent_id"
# An ORPHAN (parent row gone) is a root, and keeps its dangling parent_id.
jq -e '[.session_records[] | select(.id == "ses_ORPHAN01") | .kind] == ["root"]' "$SR" >/dev/null \
    && ok "the orphan is recorded as a root, not a subagent" || bad "orphan kind: $(jq -c '[.session_records[] | select(.id == "ses_ORPHAN01")]' "$SR")"
jq -e '[.session_records[] | select(.id == "ses_ORPHAN01") | .parent_id] == ["ses_MISSING"]' "$SR" >/dev/null \
    && ok "the orphan keeps its dangling parent_id verbatim" || bad "orphan parent_id"
# ISO-8601 UTC dates, one form.
jq -e '[.session_records[] | .created, .updated] | all(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' "$SR" >/dev/null \
    && ok "record dates are ISO-8601 UTC" || bad "record date format"
# It tracks the EXPORTED set, not the requested one: --no-subagents drops rows.
run export transcript --filter "%" --no-subagents >/dev/null
SR2=$(last_meta transcript)
[ "$(jq '.session_records | length' "$SR2")" = "$(jq '.sessions.total' "$SR2")" ] \
    && ok "no-subagents: records == total ($(jq '.sessions.total' "$SR2"))" || bad "no-subagents: records $(jq '.session_records|length' "$SR2") != total $(jq '.sessions.total' "$SR2")"
jq -e '[.session_records[] | select(.kind == "subagent")] | length == 0' "$SR2" >/dev/null \
    && ok "no-subagents: every dropped subagent is absent from the records" || bad "no-subagents records leak"
# It is NOT sessions_selected, which stays the REQUESTED ids (and only when asked).
jq -e '.sessions_selected == null' "$SR" >/dev/null \
    && ok "sessions_selected untouched (no --sessions was passed)" || bad "sessions_selected changed"
run export transcript --sessions ses_A0001,ses_B0001 >/dev/null
SR3=$(last_meta transcript)
[ "$(jq '.session_records | length' "$SR3")" = 2 ] \
    && ok "an explicit --sessions run records exactly what it exported" || bad "records with --sessions: $(jq -c '.session_records|map(.id)' "$SR3")"
jq -e '.sessions_selected | type == "array"' "$SR3" >/dev/null \
    && ok "sessions_selected keeps its own meaning (requested ids)" || bad "sessions_selected type"
# exports view --json carries them through (it returns the raw metadata). It
# aggregates EVERY run of the stamp, so assert "at least one has records" rather
# than reading [0]: older runs predate the key.
NV=$(run exports view "$(basename "$(dirname "$(dirname "$SR3")")")" --json \
     | jq '[.[] | select(.session_records != null) | .session_records | length] | add // 0')
[ "$NV" -gt 0 ] && ok "exports view --json carries session_records ($NV total)" || bad "exports view --json records ($NV)"

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
                              "digest": {"json": true}}},
  "badmix":     {"product": "transcript", "products": {"memory": {}}},
  "badprod":    {"products": {"scribble": {}}}
}}
EOF
export OCED_PRESETS="$TMP/presets-bundle.json"
run export everything >/dev/null
BT="$(last_meta transcript)"; BT="${BT%/metadata.json}"; BSTAMP="${BT%/*}"
[ -d "$BSTAMP/transcript" ] && [ -d "$BSTAMP/memory" ] && [ ! -d "$BSTAMP/digest" ] \
    && ok "bundle 'everything' = one stamp with transcript+memory (no digest)" \
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
# A bundle may include the standalone digest product.
run export debugmsg >/dev/null
BT3="$(last_meta transcript)"; BT3="${BT3%/metadata.json}"; BSTAMP3="${BT3%/*}"
[ -d "$BSTAMP3/digest" ] && ok "bundle with digest product writes its folder" || bad "bundle digest dir"
jq -e '.profile == "digest" and .preset == "debugmsg"' "$BSTAMP3/digest/metadata.json" >/dev/null \
    && ok "digest product metadata records bundle provenance" || bad "digest meta"
# Error cases, each with a helpful message.
BAD1=$(run export badmix); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$BAD1" | grep -q "use either 'product' or 'products'" \
    && ok "bundle rejects product+products mix" || bad "badmix: $(printf '%s' "$BAD1" | tail -1)"
BAD2=$(run export badprod); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$BAD2" | grep -q "must be transcript, memory or digest (got 'scribble')" \
    && ok "bundle rejects an invalid product" || bad "badprod: $(printf '%s' "$BAD2" | tail -1)"
export OCED_PRESETS="$PRESETS"

echo "== presets.schema.json contract (generated/) =="
SCHEMA="$TESTS_DIR/../generated/presets.schema.json"
EXAMPLE="$TESTS_DIR/../presets.json"
python3 "$TESTS_DIR/validate_schema.py" "$SCHEMA" "$EXAMPLE" >/dev/null 2>&1 \
    && ok "shipped presets.json satisfies presets.schema.json" || bad "shipped presets vs schema"
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
# Anti-drift #3: the presets snippet the README prints must EQUAL the shipped
# presets.json. The README claimed `share` was sanitized for months after the file
# dropped `sanitize` (docs/export-analysis.md §33): a user could have published
# secrets believing they were redacted. A doc cannot be allowed to lie about a
# flag, so the two files are compared instead of trusted.
python3 -c "
import json, re, sys
md = open('$TESTS_DIR/../README.md').read()
blocks = [b for b in re.findall(r'\`\`\`json\n(.*?)\`\`\`', md, re.S) if '\"presets\"' in b]
sys.exit(0 if len(blocks) == 1 and json.loads(blocks[0]) == json.load(open('$EXAMPLE')) else 1)
" >/dev/null 2>&1 && ok "the README presets snippet equals the shipped presets.json (no doc drift)" || bad "README presets snippet drifted from the shipped presets.json"
cat > "$TMP/schema-bad.json" <<'EOF'
{"presets": {"double": {"product": "transcript", "products": {"memory": {}}}}}
EOF
python3 "$TESTS_DIR/validate_schema.py" "$SCHEMA" "$TMP/schema-bad.json" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "schema rejects a product+products mix" || bad "schema negative"
echo "== shipped presets.json end-to-end (archive/quick/share) =="
export OCED_PRESETS="$EXAMPLE"
run export archive >/dev/null
EJ="$(last_meta transcript)"; EJ="${EJ%/metadata.json}"; EJSTAMP="${EJ%/*}"
[ -d "$EJSTAMP/transcript" ] && [ -d "$EJSTAMP/memory" ] && [ ! -d "$EJSTAMP/digest" ] \
    && ok "shipped 'archive' runs transcript+memory under one stamp" || bad "shipped archive dirs"
jq -e '.preset == "archive" and .tool_output == "full"' "$EJSTAMP/transcript/metadata.json" >/dev/null \
    && ok "shipped archive transcript flags applied" || bad "shipped archive meta"
run export quick >/dev/null
DBUG="$(last_meta memory)"; DBUG="${DBUG%/metadata.json}"; DBUGSTAMP="${DBUG%/*}"
[ -d "$DBUGSTAMP/transcript" ] && [ -d "$DBUGSTAMP/memory" ] && [ ! -d "$DBUGSTAMP/digest" ] \
    && ok "shipped 'quick' is a light transcript+memory bundle (no redundant digest)" || bad "shipped quick dirs"
jq -e '.preset == "quick" and .tool_output == "truncated"' "$DBUGSTAMP/transcript/metadata.json" >/dev/null \
    && ok "shipped quick uses truncated tool output (light variant)" || bad "shipped quick meta"
run export share >/dev/null
jq -e '.preset == "share" and .reasoning == false and .json == true and .sanitize == false' "$(last_meta transcript)" >/dev/null \
    && ok "shipped 'share' applies its single-product flags (no sanitize)" || bad "shipped share meta"
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

# shrinks verify — EVERY copy is asked, not just the newest.
# This check gets its OWN backup dir on purpose. The shelf the selection tests
# above built cannot answer it: those copies are genuinely OLDER than the DB the
# --swap test just installed (keeping 1 root makes the live DB newer than every
# copy that kept more), so "no copy is stale" is not a property that shelf has.
# Two aligned copies make every count below deterministic, and the stamps are
# forced 1s apart because the stamp is second-resolution: two shrinks inside the
# same second would SHARE one dir and halve the copy count.
CBK="$TMP/verify-bk"; rm -rf "$CBK"; mkdir -p "$CBK"
OCED_BACKUP_DIR="$CBK" run shrink --keep-all >/dev/null
sleep 1
OCED_BACKUP_DIR="$CBK" run shrink --keep-all >/dev/null
NCOPIES=$(find "$CBK/shrink" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
[ "$NCOPIES" -eq 2 ] && ok "verify fixture: 2 shrink copies, 1s apart" || bad "verify fixture: $NCOPIES copies (stamp collision?)"

VCLEAN=$(OCED_BACKUP_DIR="$CBK" run shrinks verify)
printf '%s' "$VCLEAN" | grep -q "All clean" && ok "shrinks verify: up-to-date copies are clean" || bad "shrinks verify clean: [$(printf '%s' "$VCLEAN" | tail -2)]"
printf '%s' "$VCLEAN" | grep -q "all $NCOPIES shrink copies are up to date" \
    && ok "shrinks verify: 'All clean' names every copy ($NCOPIES), not just the last" \
    || bad "shrinks verify clean wording: [$(printf '%s' "$VCLEAN" | tail -2)]"

# Make the live DB newer than the copies -> verify must flag BOTH, one row each,
# keyed by that copy's own stamp (the row used to be the literal live_vs_shrink).
sqlite3 "$FAKE" "UPDATE session SET time_updated=time_updated+1000000;" >/dev/null 2>&1
VSTALE=$(OCED_BACKUP_DIR="$CBK" run shrinks verify)
printf '%s' "$VSTALE" | grep -q "has newer sessions" && ok "shrinks verify flags a stale shrink vs live" || bad "shrinks verify stale: [$(printf '%s' "$VSTALE" | tail -2)]"
printf '%s' "$VSTALE" | grep -q "2 of 2 vs the live DB" \
    && ok "shrinks verify counts BOTH copies as stale (2 of 2), not just the newest" \
    || bad "shrinks verify stale count: [$(printf '%s' "$VSTALE" | tail -3)]"
VT=$(OCED_BACKUP_DIR="$CBK" run shrinks verify --tsv)
printf '%s' "$VT" | grep -q '^stale' && ok "shrinks verify --tsv emits a stale row" || bad "shrinks verify tsv stale: [$(printf '%s' "$VT" | tail -2)]"

NSTALE=$(printf '%s' "$VT" | grep -c '^stale')
[ "$NSTALE" -eq "$NCOPIES" ] \
    && ok "shrinks verify flags ALL $NCOPIES copies as stale, not just the newest" \
    || bad "shrinks verify stale rows: $NSTALE of $NCOPIES copies"
BADKEY=0
while IFS=$'\t' read -r k st _; do
    [ "$k" = stale ] || continue
    [ -d "$CBK/shrink/$st" ] || BADKEY=1
done <<< "$VT"
[ "$BADKEY" -eq 0 ] \
    && ok "every stale row is keyed by its OWN copy's stamp" \
    || bad "a stale row is not keyed by a real stamp: [$(printf '%s' "$VT" | grep '^stale')]"

# The same verdict must reach the LIST column as a compact tag (a row cannot carry
# the sentence, only the verdict): the live max is read ONCE for the whole list.
LSTALE=$(OCED_BACKUP_DIR="$CBK" run shrinks list --tsv)
STALE_COUNT=$(printf '%s\n' "$LSTALE" | grep -c ' (stale)')
[ "$STALE_COUNT" -eq "$NCOPIES" ] \
    && ok "shrinks list tags every stale copy '(stale)' ($STALE_COUNT/$NCOPIES) in the column" \
    || bad "shrinks list stale tags: $STALE_COUNT of $NCOPIES: [$(printf '%s\n' "$LSTALE" | tr '\n' '|')]"
printf '%s\n' "$LSTALE" | grep -qE ' kept  (stale)' \
    && bad "the stale tag must follow the size delta, not replace it" \
    || ok "the stale tag rides on the size column, never alone"
# A legacy copy (no sessions.max_updated) is UNVERIFIABLE, and that must be the
# tag too — a list that silently called it clean would violate the one-helper rule.
CBKNEW=$(find "$CBK/shrink" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)
CBKNEWSJ="$CBKNEW/shrink.json"
MU_RESTORE=$(jq -r '.sessions.max_updated' "$CBKNEWSJ")
jq 'del(.sessions.max_updated)' "$CBKNEWSJ" > "$CBKNEWSJ.bak" && mv "$CBKNEWSJ.bak" "$CBKNEWSJ"
LUNV=$(OCED_BACKUP_DIR="$CBK" run shrinks list --tsv)
[ "$(printf '%s\n' "$LUNV" | grep -c ' (unverifiable)')" -eq 1 ] \
    && [ "$(printf '%s\n' "$LUNV" | grep -c ' (stale)')" -eq "$((NCOPIES-1))" ] \
    && ok "a legacy copy is tagged '(unverifiable)', the other still '(stale)'" \
    || bad "unverifiable tag: [$(printf '%s\n' "$LUNV" | tr '\n' '|')]"
jq --argjson m "$MU_RESTORE" '.sessions.max_updated = $m' "$CBKNEWSJ" > "$CBKNEWSJ.bak" && mv "$CBKNEWSJ.bak" "$CBKNEWSJ"

# An orphan dir (no valid shrink.json) is reported ONCE, as an orphan: never
# re-listed as a stale copy, which is what o_shrink_stale would answer for a
# missing file (and that duplication is exactly why the loop skips orphans).
ORPH="$CBK/shrink/20990101-000000"
mkdir -p "$ORPH"
printf 'junk\n' > "$ORPH/shrink.json"
VORPH=$(OCED_BACKUP_DIR="$CBK" run shrinks verify --tsv)
printf '%s' "$VORPH" | grep -q "^orphan	20990101-000000	" \
    && ok "shrinks verify: an invalid shrink.json is an orphan row" \
    || bad "shrinks verify orphan row: [$(printf '%s' "$VORPH" | tail -3)]"
[ "$(printf '%s' "$VORPH" | grep -c '^stale	20990101-000000	')" -eq 0 ] \
    && ok "shrinks verify: an orphan dir is never also a stale copy" \
    || bad "shrinks verify reported the orphan dir twice"
rm -rf "$ORPH"

# A legacy shrink.json without sessions.max_updated is flagged (unverifiable), not silently clean.
LASTSTAMP=$(basename "$(dirname "$LASTSJ")")
LASTMAXU=$(jq -r '.sessions.max_updated' "$LASTSJ")
jq 'del(.sessions.max_updated)' "$LASTSJ" > "$LASTSJ.bak" && mv "$LASTSJ.bak" "$LASTSJ"
VLEGACY=$(run shrinks verify)
printf '%s' "$VLEGACY" | grep -q "cannot verify freshness" && ok "shrinks verify flags a legacy shrink.json (no max_updated)" || bad "shrinks verify legacy: [$(printf '%s' "$VLEGACY" | tail -2)]"
printf '%s' "$VLEGACY" | grep -q "  $LASTSTAMP  —  cannot verify freshness" \
    && ok "a per-copy warning carries the stamp it belongs to ($LASTSTAMP)" \
    || bad "per-copy stale line has no stamp: [$(printf '%s' "$VLEGACY" | grep -A3 'Stale shrink' | head -4)]"

# The same unverifiable state must reach the DETAIL screen (one helper, both screens):
# a `view` that showed ok/clean while `verify` warned would be the half-verification
# AGENTS.md forbids.
VLEG=$(run shrinks view "$LASTSTAMP" 2>&1)
printf '%s' "$VLEG" | grep -q "^  freshness: .*cannot verify freshness" \
    && ok "shrinks view reports the same unverifiable freshness as verify" \
    || bad "shrinks view freshness (legacy): [$(printf '%s' "$VLEG" | grep -i fresh)]"
# restore what the test removed, so the manager section below runs on a normal copy
jq --argjson m "$LASTMAXU" '.sessions.max_updated = $m' "$LASTSJ" > "$LASTSJ.bak" && mv "$LASTSJ.bak" "$LASTSJ"

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
ROW1=$(printf '%s\n' "$TSV" | sed -n '1p')
printf '%s' "$ROW1" | grep -qE 'UTC.*kept' && ok "shrinks tsv: human display" || bad "shrinks tsv display: $ROW1"
# A list row is a COLUMN: the criteria sentence is 100+ chars of parentheticals and
# used to reach 225/row, burying the kept count and the size delta. It belongs in
# `shrinks view` (asserted below), never here.
MAXW=$(printf '%s\n' "$TSV" | awk -F'\t' '{ if (length($2) > w) w = length($2) } END { print w+0 }')
[ "${MAXW:-0}" -le 100 ] && ok "shrinks list rows stay compact (max ${MAXW} cols)" || bad "shrinks list row too wide: ${MAXW}"
printf '%s\n' "$TSV" | grep -qE 'listed session\(s\)|their subagents|dropped too' \
    && bad "shrinks list leaks the criteria sentence into a column: $(printf '%s\n' "$TSV" | sed -n '1p')" \
    || ok "shrinks list shows the tag, not the criteria sentence"
# the tag itself (plan.py rule-tag is the SSoT), and one size expression instead of
# the before/after/freed/percent repetition the row used to print
printf '%s\n' "$TSV" | grep -qE '(keep all|keep [0-9]+ newest|last [0-9]+d|since [0-9-]+|keep [0-9]+ ids|discard [0-9]+ ids)' \
    && ok "shrinks list renders a selection tag" || bad "shrinks list tag: $ROW1"
COPYROWS=$(printf '%s\n' "$TSV" | grep -v 'swapped/no copy')
BADROWS=$(printf '%s\n' "$COPYROWS" | grep -vE '[0-9]+/[0-9]+ kept  [0-9,.]+[KMGTP]?i?B -> [0-9,.]+[KMGTP]?i?B' | cut -f1)
[ -z "$BADROWS" ] && ok "shrinks list: kept/total + one size delta on every copy that has one" \
    || bad "shrinks list row shape: $(printf '%s' "$BADROWS" | tr '\n' ' ')"
printf '%s\n' "$TSV" | grep -qE 'freed' && bad "shrinks list repeats the size three times" || ok "shrinks list prints the size once"
# keep 1 and keep 10 are the same rule and different facts: the tag must carry the value
# the engine recorded in .selection.value, never a default.
KEEPROW=$(printf '%s\n' "$TSV" | grep -E 'keep [0-9]+ newest' | sed -n '1p')
if [ -n "$KEEPROW" ]; then
    KSTAMP=$(printf '%s' "$KEEPROW" | cut -f1)
    KVAL=$(jq -r '.selection.value' "$BK/shrink/$KSTAMP/shrink.json")
    printf '%s' "$KEEPROW" | cut -f2 | grep -qE "keep $KVAL newest" \
        && ok "shrinks list tag carries the rule's own value (keep $KVAL, not a default)" \
        || bad "shrinks list keep tag: [$(printf '%s' "$KEEPROW" | cut -f2)] want [keep $KVAL newest]"
else
    ok "shrinks list keep tag (skipped: no numeric-keep run on the shelf)"
fi

VOUT=$(run shrinks view "$STAMP")
printf '%s' "$VOUT" | grep -qF "== Shrink copy: $STAMP ==" && ok "shrinks view leads with the copy banner" || bad "shrinks view banner: [$(printf '%s' "$VOUT" | head -2)]"
# one fact per line, and the criteria sentence the list row had to leave out.
# NO `selection:` line: the rule + `· N id(s)` repeated what `criteria:` says in
# words and `ids (N):` says as a count (N appeared three times on one screen).
for F in "sessions:" "size:" "criteria:" "date:" "db:" "integrity:" "freshness:" "files:"; do
    printf '%s' "$VOUT" | grep -qE "^  $F" && ok "shrinks view: $F field" || bad "shrinks view missing $F"
done
printf '%s' "$VOUT" | grep -qE '^  freshness: +(ok|STALE)' \
    && ok "shrinks view always answers freshness (ok or STALE)" || bad "shrinks view freshness: [$(printf '%s' "$VOUT" | grep -i fresh)]"
VCRIT=$(printf '%s' "$VOUT" | sed -n 's/^  criteria: *//p')
JCRIT=$(jq -r '.criteria // "?"' "$BK/shrink/$STAMP/shrink.json")
[ "$VCRIT" = "$JCRIT" ] && ok "shrinks view prints the full criteria sentence, verbatim from shrink.json" || bad "shrinks view criteria: [$VCRIT] vs [$JCRIT]"
VIT=$(printf '%s' "$VOUT" | sed -n 's/^  integrity: *//p')
JINT=$(jq -r '.integrity_check' "$BK/shrink/$STAMP/shrink.json")
printf '%s' "$VIT" | grep -q "$JINT" && ok "shrinks view reports the recorded integrity_check" || bad "shrinks view integrity: [$VIT] vs [$JINT]"
printf '%s' "$VOUT" | sed -n '/^  files:/,$p' | grep -q 'shrink.json' && ok "shrinks view lists the produced files" || bad "shrinks view files: [$(printf '%s' "$VOUT" | tail -5)]"
# --json is the machine view: the file, byte for byte (the pretty screen is IN FRONT
# of it, never in place of it)
VJSON=$(run shrinks view "$STAMP" --json)
printf '%s' "$VJSON" | jq -e . >/dev/null 2>&1 && ok "shrinks view --json is valid json" || bad "shrinks view --json invalid"
[ "$VJSON" = "$(cat "$BK/shrink/$STAMP/shrink.json")" ] && ok "shrinks view --json is shrink.json verbatim" || bad "shrinks view --json differs from the file"
cp "$BK/shrink/$STAMP/shrink.json" "$TMP/syn-base.json"
printf '%s' "$VJSON" | grep -q '== Shrink copy:' && bad "shrinks view --json carries the human banner" || ok "shrinks view --json carries no banner"
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

# A synthetic run dir (12 selected ids, no .db): the view caps the id list and the
# list row says the copy is gone, so a swapped-out copy cannot look healthy.
SYN="$BK/shrink/20991231-235959"
mkdir -p "$SYN"
jq '.selection.ids = [range(0;12) | "ses_synthetic" + (tostring|("00"+.)[-2:])] | .selection.rule = "discard_sessions"' \
    "$TMP/syn-base.json" > "$SYN/shrink.json"
VSYN=$(run shrinks view 20991231-235959)
[ "$(printf '%s\n' "$VSYN" | grep -c '^    ses_')" -eq 8 ] && ok "shrinks view caps the id list at 8" || bad "shrinks view id cap: $(printf '%s\n' "$VSYN" | grep -c '^    ses_')"
printf '%s' "$VSYN" | grep -qE '^    … 4 more' && ok "shrinks view says how many ids it left out (4 more)" || bad "shrinks view id overflow line: [$(printf '%s' "$VSYN" | grep more)]"
printf '%s' "$VSYN" | grep -qE '^  ids \(12\):' && ok "shrinks view states the real id count in the ids header" || bad "shrinks view id count: [$(printf '%s' "$VSYN" | grep 'ids (')]"
printf '%s' "$VSYN" | grep -qE '^  selection:' && bad "shrinks view still prints the redundant selection: line" || ok "shrinks view has no selection: line (criteria + ids header carry it)"
run shrinks list | grep -q '2099-12-31 23:59:59 UTC' && ok "shrinks list renders a synthetic stamp" || bad "shrinks list synthetic stamp"
run shrinks list | grep -q 'swapped/no copy' && ok "shrinks list flags a run whose copy is gone" || bad "shrinks list no-copy state"
run shrinks remove 20991231-235959 --yes >/dev/null

echo "== shrinks verify: a discard's cascade export coverage is checked LIVE =="
# The --swap test above REPLACED the shared fake DB with a 1-session copy (and
# bumped its time_updated), so a discard of ses_B0001 would match nothing there
# (deleted=0, cascade falls back to the listed ids). This section needs the full
# fixture: regenerate it — it is the last section of the suite, nothing below
# depends on the swapped-down live DB.
rm -f "$FAKE" "$FAKE-wal" "$FAKE-shm"
bash "$TESTS_DIR/make_fake_db.sh" "$FAKE" >/dev/null
# OWN shelf + OWN export dir: o_shrink_unexported re-asks the exports shelf at
# VERIFY time (the stored cascade vs o_shrink_discard_export), so these
# assertions drive the shelf itself — an export made AFTER the shrink must clear
# the flag, and removing that run must bring it back. An isolated shelf also
# keeps the CBK fixture's "2 of 2" counts pinned above.
UMK="$TMP/umk"; UOU="$TMP/umk-out"
rm -rf "$UMK" "$UOU"; mkdir -p "$UMK" "$UOU"
# 1) a discard copy whose cascade was never exported anywhere -> flagged.
OCED_BACKUP_DIR="$UMK" OCED_OUT="$UOU" OCED_PRESETS="$EX_PRESETS" \
    run shrink --discard-sessions ses_B0001 >/dev/null
USJ=$(ls -t "$UMK"/shrink/*/shrink.json | head -1)
USTAMP=$(basename "$(dirname "$USJ")")
jq -r '.selection.cascade | join(",")' "$USJ" | grep -qx 'ses_B0001,ses_B0002' \
    && ok "a discard run stores its closed cascade in .selection.cascade" \
    || bad "cascade: $(jq -c '.selection' "$USJ" 2>/dev/null)"
jq -e 'has("discard_exported") | not' "$USJ" >/dev/null \
    && ok "with no export yet the fresh discard copy records no link" \
    || bad "discard_exported present on a never-exported discard"
UV=$(OCED_BACKUP_DIR="$UMK" OCED_OUT="$UOU" run shrinks verify)
printf '%s' "$UV" | grep -q "Shrinks without a discard export (1 of 1)" \
    && printf '%s' "$UV" | grep -q "no export run covers the 2 discarded session(s)." \
    && ok "verify flags a discard whose cascade no export covers" \
    || bad "verify unexported: $UV"
printf '%s' "$UV" | grep -q "opencode-db export <profile> --sessions <the csv>" \
    && ok "the flag comes with the exact command that fixes it" \
    || bad "missing fix-it line: $UV"
UVT=$(OCED_BACKUP_DIR="$UMK" OCED_OUT="$UOU" run shrinks verify --tsv)
[ "$(printf '%s\n' "$UVT" | grep -c '^unexported')" -eq 1 ] \
    && [ "$(printf '%s\n' "$UVT" | grep '^unexported' | cut -f1,2)" = "unexported"$'\t'"$USTAMP" ] \
    && ok "verify --tsv keys the flag by the copy's stamp" \
    || bad "unexported tsv: [$UVT]"
# 2) a ROOT-ONLY export of the same root is a DIFFERENT set: exact ids, so it
# must never clear the flag (the whole reason the offer hands the full cascade).
OSTAB=$(OCED_PRESETS="$EX_PRESETS" OCED_OUT="$UOU" run export archive --sessions ses_B0001)
SSTAB=$(stamp_of "$OSTAB")
UVT2=$(OCED_BACKUP_DIR="$UMK" OCED_OUT="$UOU" run shrinks verify --tsv)
[ "$(printf '%s\n' "$UVT2" | grep -c '^unexported')" -eq 1 ] \
    && printf '%s\n' "$UVT2" | grep -q "^unexported	$USTAMP" \
    && ok "a root-only export is a different set: the discard stays flagged" \
    || bad "root-only export cleared the flag: [$UVT2]"
# 3) the CASCADE exported AFTER the shrink -> the live re-check finds it: clean.
OCAS=$(OCED_PRESETS="$EX_PRESETS" OCED_OUT="$UOU" run export archive --sessions ses_B0001,ses_B0002)
SCAS=$(stamp_of "$OCAS")
UV2=$(OCED_BACKUP_DIR="$UMK" OCED_OUT="$UOU" run shrinks verify)
printf '%s' "$UV2" | grep -q "All clean: no orphan dirs, no old pre-shrinks, no unexported discards" \
    && ok "an export made AFTER the shrink clears the flag (the check is live)" \
    || bad "post-export verify: $UV2"
# 4) legacy copies (no .selection.cascade): only the stamp they DID record can
# condemn them. Built from C1's json: live recorded run -> silent, recorded run
# that vanished -> flagged, no record at all -> unknown = never a false charge.
LEG_OK="$UMK/shrink/20990101-000001"; LEG_HUNG="$UMK/shrink/20990101-000002"
LEG_NONE="$UMK/shrink/20990101-000003"
mkdir -p "$LEG_OK" "$LEG_HUNG" "$LEG_NONE"
jq 'del(.selection.cascade) | .discard_exported = $s' --arg s "$SSTAB" "$USJ" \
    > "$LEG_OK/shrink.json"
jq 'del(.selection.cascade) | .discard_exported = "19990101-000000"' "$USJ" \
    > "$LEG_HUNG/shrink.json"
jq 'del(.selection.cascade) | del(.discard_exported)' "$USJ" \
    > "$LEG_NONE/shrink.json"
UVT3=$(OCED_BACKUP_DIR="$UMK" OCED_OUT="$UOU" run shrinks verify --tsv)
[ "$(printf '%s\n' "$UVT3" | grep -c '^unexported')" -eq 1 ] \
    && printf '%s\n' "$UVT3" | grep -q "^unexported	20990101-000002" \
    && ok "legacy: only the vanished record is flagged (live record and unknown stay silent)" \
    || bad "legacy unexported rows: [$(printf '%s\n' "$UVT3" | grep '^unexported')]"
printf '%s\n' "$UVT3" | grep '^unexported' | cut -f3 | grep -qF "no longer exists" \
    && ok "the legacy reason names the export that vanished" \
    || bad "legacy reason: $(printf '%s\n' "$UVT3" | grep '^unexported')"
rm -rf "$LEG_OK" "$LEG_HUNG" "$LEG_NONE"
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

echo ""
echo "RESULT: $pass OK / $fail FAIL"
[ "$fail" -eq 0 ]