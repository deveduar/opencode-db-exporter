#!/usr/bin/env bash
# menu_flow.sh — logic tests for the fzf menu (fzf is stubbed; no TTY needed).
# Usage: tests/menu_flow.sh
# NOTE: FZF_QUEUE is ALWAYS assigned on its own line, never as a command prefix:
# with `set -u`, `VAR=("a") fn` makes the array invisible inside fn (bash quirk).
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$TESTS_DIR/../modules"
TMP="$(mktemp -d /tmp/opencode-db-menu-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

FAKE="$TMP/fake.db"
OUT="$TMP/out"
export OPENCODE_DB="$FAKE"
export OCED_OUT="$OUT"
export OCED_BACKUP_DIR="$TMP/backups"
export OCED_PRESETS="$TMP/no-presets.json" # hermetic: ignore any real ~/.config presets
export OCED_SHRINK_PRESETS="$TMP/no-shrink-presets.json" # hermetic: built-in shrink recipes only
export OCED_DISPATCHER="$MOD/opencode-db.sh"
bash "$TESTS_DIR/make_fake_db.sh" "$FAKE" >/dev/null

. "$MOD/common.sh"
. "$MOD/export.sh"
. "$MOD/exports.sh"
. "$MOD/shrink.sh"

pass=0; fail=0
ok() { echo "  [OK]   $1"; pass=$((pass+1)); }
bad() { echo "  [FAIL] $1"; fail=$((fail+1)); }
FZF_HIST="$TMP/fzf.log"
# reset -> restore real function definitions (undo test overrides).
# menu_pause is neutralised: its real body would block on a TTY stdin.
reset() { unset FZF_QUEUE FZF_FAIL; . "$MOD/menu.sh"; menu_pause() { return 0; }; : > "$FZF_HIST"; }
count_meta() { find "$OUT" -path "*/$1/*" -type f \( -name metadata.json -o -name metadatos.json \) 2>/dev/null | wc -l; }
newest_meta() { find "$OUT" -path "*/$1/*" -type f \( -name metadata.json -o -name metadatos.json \) -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-; }
CALLS="$TMP/calls.txt"
call_log() { run_oced_tool() { printf '%s\n' "$*" >> "$CALLS"; }; }
# FZF queue lives in a FILE: fzf() runs inside $(...) pipelines (subshells), so
# shell-side mutation would never reach the caller. qset/qempty manage the file.
FZF_QUEUE_FILE="$TMP/fzf.queue"
qset()  { printf '%s\n' "$@" > "$FZF_QUEUE_FILE"; }
qempty(){ : > "$FZF_QUEUE_FILE"; }

# ---- fzf stub: pops one item from the queue file (like real fzf selections) ----
# Logs each invocation's args (prompt) for mode-toggle assertions.
# Empty queue -> return 130 (ESC). FZF_FAIL -> return 1 (cancelled picker).
fzf() {
    local args="$*" item
    printf '%s\n' "$args" >> "$FZF_HIST"
    cat >/dev/null  # drain the piped rows like real fzf (avoids SIGPIPE under pipefail)
    if [ -n "${FZF_FAIL:-}" ] && [[ "$args" == *"$FZF_FAIL"* ]]; then
        return 1
    fi
    if [ ! -s "$FZF_QUEUE_FILE" ]; then
        return 130
    fi
    IFS= read -r item < "$FZF_QUEUE_FILE"
    tail -n +2 "$FZF_QUEUE_FILE" > "$FZF_QUEUE_FILE.tmp" && mv "$FZF_QUEUE_FILE.tmp" "$FZF_QUEUE_FILE"
    printf '%s\n' "$item"
    return 0
}
. "$MOD/menu.sh"
# menu_pause with a real function but a non-TTY stdin returns immediately.
# (Inside the picker tests menu_pause is neutralised by reset().)
menu_pause "test" </dev/null; [ $? -eq 0 ] && echo "  [OK]   menu_pause returns immediately off-TTY" || echo "  [FAIL] menu_pause TTY handling"

echo "== session picker excludes the sqlite separator row =="
ROWS=$(session_rows)
printf '%s' "$ROWS" | grep -qE '^[[:space:]]*-' && bad "separator row leaked into picker" || ok "separator rows excluded"
printf '%s' "$ROWS" | grep -q '^ses_' && ok "session rows present" || bad "session rows missing"

echo "== small helpers =="
reset
[ "$(oc_sel_key $'keyX\tlabel')" = "keyX" ] && ok "oc_sel_key extracts the hidden key" || bad "oc_sel_key"
[ "$(oc_toggle_row verify delete)" = "__TOGGLE__	[mode: verify]  switch to delete" ] && ok "oc_toggle_row builds the toggle row" || bad "oc_toggle_row"
[ "$(oc_stamp_human '2026-09-21_08-30')" = "2026-09-21 08:30 UTC" ] && ok "oc_stamp_human formats a stamp" || bad "oc_stamp_human"
mkdir -p "$OUT/aaa" "$OUT/bbb" "$OUT/ccc"
[ "$(exports_run_count)" = "3" ] && ok "exports_run_count counts runs" || bad "exports_run_count: $(exports_run_count)"

echo "== product rows come from plan.py (no product-only menu flow anymore) =="
reset
oc_fzf_sel() { cat; }   # pass-through: expose the generated rows
PROD=$(oc_plan_py products)
unset -f oc_fzf_sel
rows_with_label() { local n=0 line; while IFS= read -r line; do
    [[ "$line" == *$'\t'* ]] || continue
    [ -n "${line%%$'\t'*}" ] && [ -n "${line#*$'\t'}" ] && n=$((n + 1))
done; echo "$n"; }
[ "$(printf '%s\n' "$PROD" | rows_with_label)" = "3" ] && ok "plan.py products rows (3) have key+label" || bad "product rows: $PROD"
printf '%s' "$PROD" | grep -qE '^(transcript|memory|compactions)' && ok "product rows are transcript/memory/compactions" || bad "product keys: $PROD"
printf '%s' "$PROD" | grep -q '^full\b' && bad "full leaked as a picker row (CLI alias only)" || ok "full is NOT a picker row"
printf '%s' "$PROD" | grep -q -- "--tool-output" && bad "variant rows leaked into the product rows" || ok "product rows have NO variant rows"

echo "== help exports block stays in sync with FLAGS (flags.py --help-exports) =="
HELPEXPORTS=$(python3 "$SCRIPT_DIR/exportlib/flags.py" --help-exports) || bad "flags.py --help-exports exited non-zero"
printf '%s' "$HELPEXPORTS" | grep -q "^export products (default: transcript):" && ok "help block: products header" || bad "help block missing products header"
for cli in filter sessions out sub tool-output patch mark-compactions no-reasoning summary-diffs role json sanitize cap; do
    printf '%s' "$HELPEXPORTS" | grep -q -- "--$cli" && ok "help block covers --$cli" || bad "help block missing --$cli"
done

echo "== oc_read_int (interactive integer input) =="
reset
V=$(printf '5\n' | oc_read_int "Count" 2>/dev/null); [ "$V" = "5" ] && ok "oc_read_int reads a number" || bad "oc_read_int number: '$V'"
printf '\n' | oc_read_int "Count" >/dev/null 2>&1; [ $? -ne 0 ] && ok "oc_read_int cancel on Enter alone" || bad "oc_read_int Enter"
printf '\033' | oc_read_int "Count" >/dev/null 2>&1; [ $? -ne 0 ] && ok "oc_read_int cancels on ESC" || bad "oc_read_int ESC"
printf 'ab\n' | oc_read_int "Count" >/dev/null 2>&1; [ $? -ne 0 ] && ok "oc_read_int rejects non-numeric" || bad "oc_read_int non-numeric"

echo "== root status header =="
reset
oc_root_status
printf '%s' "$ACTION_STATUS" | grep -q "Sessions:" && printf '%s' "$ACTION_STATUS" | grep -q "DB:" && ok "root status header set" || bad "root status: '$ACTION_STATUS'"

echo "== root status header refreshes after a state change (--refresh-cb) =="
reset
oc_root_status
B=$(printf '%s' "$ACTION_STATUS" | grep -oE 'Exports: [0-9]+')
mkdir -p "$OUT/refresh-run"
echo '{"profile":"x"}' > "$OUT/refresh-run/metadata.json"
oc_root_status
A=$(printf '%s' "$ACTION_STATUS" | grep -oE 'Exports: [0-9]+')
rm -rf "$OUT/refresh-run"
[ -n "$A" ] && [ "$A" != "$B" ] && ok "oc_root_status recomputes Exports on refresh ($B -> $A)" || bad "root status refresh: before='$B' after='$A'"

echo "== run_menu dispatches actions, builtin exit, ESC climbs =="
reset
oc_test_entries=(
    "alpha|Action alpha|tool:backups list"
    "beta|Action beta|builtin:exit"
)
: > "$CALLS"; call_log
qset "alpha" "beta"
run_menu --cat "test" --entries oc_test_entries >/dev/null
[ $? -eq 0 ] && grep -qx "backups list" "$CALLS" && ok "run_menu dispatches a tool action and exits on builtin" || bad "run_menu dispatch: $(cat "$CALLS")"
qempty
run_menu --cat "test" --entries oc_test_entries >/dev/null; [ $? -eq 2 ] && ok "run_menu ESC climbs a level (rc 2)" || bad "run_menu ESC climb"

echo "== backups picker (single mode: create / shrink / bulk / per-file delete) =="
reset
mkdir -p "$OCED_BACKUP_DIR"
jq -n '{backups: [
    {"file": "fake-0.db", "date": "2026-01-01T00:00:00Z", "size": 100, "sessions": 1, "messages": 2, "sha256": "aaa"},
    {"file": "fake-1.db", "date": "2026-01-02T00:00:00Z", "size": 100, "sessions": 1, "messages": 2, "sha256": "bbb"},
    {"file": "fake-2.db", "date": "2026-01-03T00:00:00Z", "size": 100, "sessions": 1, "messages": 2, "sha256": "ccc"},
    {"file": "fake-3.db", "date": "2026-01-04T00:00:00Z", "size": 100, "sessions": 1, "messages": 2, "sha256": "ddd"},
    {"file": "fake-4.db", "date": "2026-01-05T00:00:00Z", "size": 100, "sessions": 1, "messages": 2, "sha256": "eee"}
]}' > "$OCED_BACKUP_DIR/manifest.json"
confirm_action() { return 0; }

: > "$CALLS"; call_log
qset "fake-2.db"
oc_backups_picker >/dev/null
grep -qx "backups remove fake-2.db --yes" "$CALLS" && ok "selecting a backup row deletes it (confirmed)" || bad "backups delete: $(cat "$CALLS")"

echo "== backups rows: create first, bulk rows, no mode toggle, no shrink =="
reset
ROWS=$(oc_backups_rows)
printf '%s\n' "$ROWS" | sed -n '1p' | grep -q '^__CREATE__' && ok "create backup is the first row" || bad "create not first"
printf '%s\n' "$ROWS" | grep -q '__SHRINK__' && bad "shrink row leaked into backups" || ok "backups rows have NO shrink row (dedicated shrinks entry)"
printf '%s\n' "$ROWS" | grep -q '__TOGGLE__' && bad "mode toggle leaked into backups" || ok "backups picker has a single mode (no toggle)"

: > "$CALLS"; call_log
confirm_action() { return 0; }
qset "__CREATE__"
oc_backups_picker >/dev/null
grep -qx "backup" "$CALLS" && ok "backups picker offers create backup" || bad "backups create: $(cat "$CALLS")"

: > "$CALLS"
qset "__DELETE_ALL__"
oc_backups_picker >/dev/null
grep -qx "backups remove fake-0.db --yes" "$CALLS" && grep -qx "backups remove fake-4.db --yes" "$CALLS" && ok "backups delete-all removes every backup (confirmed)" || bad "backups delete-all: $(cat "$CALLS")"

: > "$CALLS"
qset "__KEEP_NEWEST__"
oc_backups_picker >/dev/null
grep -qx "backups remove fake-3.db --yes" "$CALLS" && ! grep -qx "backups remove fake-4.db --yes" "$CALLS" && ok "backups keep-newest removes all but the newest" || bad "backups keep-newest: $(cat "$CALLS")"

: > "$CALLS"
confirm_action() { return 1; }
qset "__DELETE_ALL__"
oc_backups_picker >/dev/null
[ ! -s "$CALLS" ] && ok "backups delete-all cancelled on 'n'" || bad "backups delete-all ran on 'n'"
confirm_action() { return 0; }

echo "== sessions details picker (independent, no toggle) =="
reset
: > "$CALLS"; call_log
qset "ses_A0001"
oc_sessions_picker >/dev/null
grep -qx "info ses_A0001" "$CALLS" && ok "sessions details dispatches info for the session" || bad "sessions details: $(cat "$CALLS")"
grep -q "sessions (details)" "$FZF_HIST" && ok "sessions picker is details-only" || bad "sessions title"
printf '%s\n' "$(oc_sessions_rows)" | grep -q '__TOGGLE__' && bad "toggle leaked into sessions" || ok "sessions details has no mode toggle"

echo "== export picker needs presets (no-pass manual fallback: guidance instead) =="
reset
: > "$CALLS"; call_log
confirm_action() { return 0; }
export OCED_PRESETS="$TMP/no-presets.json"
rm -f "$OCED_PRESETS"
GUIDE=$(oc_export_picker)
[ ! -s "$CALLS" ] && ok "no-presets export picker dispatches nothing" || bad "no-presets export picker ran a command: $(cat "$CALLS")"
printf '%s' "$GUIDE" | grep -q 'presets.json.example' && ok "no-presets export picker prints setup guidance" || bad "guidance: $GUIDE"
printf '%s' "$GUIDE" | grep -q 'export transcript|memory|compactions' && ok "guidance points to the raw CLI as fallback" || bad "guidance CLI tip: $GUIDE"
[ -z "$(oc_export_rows)" ] && ok "export rows empty without presets (no manual fallback)" || bad "export rows: $(oc_export_rows)"
printf '%s\n' "$(oc_selection_rows)" | sed -n '1p' | grep -q '^__ALL__' && ok "selection rows list ALL SESSIONS first" || bad "selection rows ALL missing"

echo "== export presets picker (preset-first when OCED_PRESETS exists) =="
export OCED_PRESETS="$TMP/presets.json"
cat > "$OCED_PRESETS" <<'EOF'
{"presets": {
   "clean": {"product": "transcript", "json": true, "sanitize": true, "no_reasoning": true, "filter": "Project Beta"},
   "everything": {"products": {"transcript": {"json": true, "tool_output": "full"}, "memory": {"files": true}}},
   "archive": {"products": {"transcript": {"json": true, "tool_output": "full"}, "memory": {"files": true}}},
   "notes": {"product": "transcript"},
   "rag": {"product": "memory"},
   "digest": {"product": "compactions"},
   "snappy": {"product": "transcript", "snapshot": "fresh"},
   "share": {"product": "transcript", "json": true, "sanitize": true, "no_reasoning": true}
}}
EOF
reset
: > "$CALLS"; call_log
confirm_action() { return 0; }
printf '%s\n' "$(oc_export_rows)" | grep -q '^__PRESET_clean' && ok "presets mode lists the named preset" || bad "preset rows missing"
printf '%s\n' "$(oc_export_rows)" | grep -qv '__MANUAL__' && ok "presets mode does NOT list Manual… (plans cover it)" || bad "preset manual should be gone"
printf '%s\n' "$(oc_export_rows)" | grep -q '^__PRESET_everything.*\[transcript+memory\]' \
    && ok "presets mode lists a bundle preset as [transcript+memory]" || bad "bundle preset row: $(printf '%s\n' "$(oc_export_rows)")"
printf '%s\n' "$(oc_export_rows)" | grep -q '^__PRESET_notes.*\[transcript\]' \
    && ok "presets mode lists default plan notes [transcript]" || bad "notes row missing"
printf '%s\n' "$(oc_export_rows)" | grep -q '^__PRESET_rag.*\[memory\]' \
    && ok "presets mode lists default plan rag [memory]" || bad "rag row missing"
printf '%s\n' "$(oc_export_rows)" | grep -q '^__PRESET_digest.*\[compactions\]' \
    && ok "presets mode lists default plan digest [compactions]" || bad "digest row missing"
printf '%s' "$(oc_preset_descr everything)" | grep -q 'products transcript+memory' \
    && ok "oc_preset_descr names the bundle products" || bad "bundle descr: $(oc_preset_descr everything)"
[ -n "$(oc_preset_purpose archive)" ] && [ -z "$(oc_preset_purpose unknownname || true)" ] \
    && ok "oc_preset_purpose annotates shipped plans only" || bad "preset purpose"
printf '%s\n' "$(oc_export_rows)" | grep '^__PRESET_archive' | grep -q 'lossless' \
    && ok "preset rows include purpose tag (archive shows lossless)" || bad "preset rows missing purpose: $(printf '%s\n' "$(oc_export_rows)" | grep '^__PRESET_archive')"
printf '%s\n' "$(oc_preset_legend)" | grep -q 'lossless full backup' \
    && ok "oc_preset_legend explains each shipped plan in the header" || bad "preset legend: $(printf '%s\n' "$(oc_preset_legend)")"
# New helper tests
[ "$(oc_annotate_flags "json=true,tool_output=full")" = " +faithful JSON (raw, unfiltered) · full tool outputs" ] \
    && ok "oc_annotate_flags json+tool_output" || bad "annotate: [$(oc_annotate_flags "json=true,tool_output=full")]"
[ "$(oc_annotate_flags "sanitize=true,no_reasoning=true")" = " sanitize ON (safe prefixes: sk-, ghp_, AKIA, JWT, PEM…) · reasoning omitted" ] \
    && ok "oc_annotate_flags sanitize+no_reasoning" || bad "annotate: [$(oc_annotate_flags "sanitize=true,no_reasoning=true")]"
[ "$(oc_annotate_flags "cap=500")" = " cap 500 chars" ] && ok "oc_annotate_flags cap" || bad "annotate cap: [$(oc_annotate_flags "cap=500")]"
# oc_export_plan produces lines for a preset (check archive)
printf '%s\n' "$(oc_export_plan archive)" | grep -q '+faithful JSON (raw, unfiltered)' && ok "oc_export_plan archive notes raw JSON" || bad "plan archive: $(oc_export_plan archive)"
printf '%s\n' "$(oc_export_plan archive)" | grep -q 'full tool outputs' && ok "oc_export_plan archive notes full outputs" || bad "plan archive: $(oc_export_plan archive)"
# share plan NO LONGER has sanitize (removed from preset)
printf '%s\n' "$(oc_export_plan share)" | grep -qv 'sanitize' && ok "oc_export_plan share has no sanitize" || bad "plan share should not have sanitize: $(oc_export_plan share)"
# transcript default plan
printf '%s\n' "$(oc_export_plan transcript)" | grep -q 'default options' && ok "oc_export_plan transcript default" || bad "plan transcript: $(oc_export_plan transcript)"
export OCED_PRESETS="$TMP/no-presets.json"

echo "== exports picker (view / toggle to remove / bulk) =="
reset
mkdir -p "$OUT/aaa" "$OUT/bbb" "$OUT/ccc"
for d in aaa bbb ccc; do
    echo '{"profile":"full","sessions":{"roots":1,"subagents":0},"messages":3}' > "$OUT/$d/metadata.json"
done
: > "$CALLS"; call_log
confirm_action() { return 0; }
qset "ccc"
oc_exports_picker >/dev/null
grep -qx "exports view ccc" "$CALLS" && ok "exports view dispatches for the run" || bad "exports view: $(cat "$CALLS")"
grep -q "exports (view)" "$FZF_HIST" && ok "exports picker starts in view mode" || bad "exports initial mode"

: > "$CALLS"
qset "__TOGGLE__" "aaa"
oc_exports_picker >/dev/null
grep -qx "exports remove aaa --yes" "$CALLS" && ok "exports picker toggles to remove and removes the run" || bad "exports remove: $(cat "$CALLS")"
grep -q "exports (remove)" "$FZF_HIST" && ok "exports picker reached remove mode" || bad "exports remove mode not reached"

: > "$CALLS"
qset "__TOGGLE__" "__DELETE_ALL__"
oc_exports_picker >/dev/null
grep -qx "exports remove aaa --yes" "$CALLS" && grep -qx "exports remove ccc --yes" "$CALLS" && ok "exports delete-all removes every run (confirmed)" || bad "exports delete-all: $(cat "$CALLS")"

: > "$CALLS"
qset "__TOGGLE__" "__KEEP_NEWEST__"
oc_exports_picker >/dev/null
grep -qx "exports remove aaa --yes" "$CALLS" && grep -qx "exports remove bbb --yes" "$CALLS" && ! grep -qx "exports remove ccc --yes" "$CALLS" && ok "exports keep-newest removes all but the newest" || bad "exports keep-newest: $(cat "$CALLS")"

: > "$CALLS"
confirm_action() { return 1; }
qset "__TOGGLE__" "__DELETE_ALL__"
oc_exports_picker >/dev/null
[ ! -s "$CALLS" ] && ok "exports delete-all cancelled on 'n'" || bad "exports delete-all ran on 'n'"
confirm_action() { return 0; }

echo "== export flow: preset + session/ALL selection -> runner =="
reset
export OCED_PRESETS="$TMP/presets.json"
: > "$CALLS"; call_log
confirm_action() { :; return 0; }
qset "ses_A0001"
oc_preset_run "notes" "product transcript" >/dev/null
grep -qx "export notes --filter ses_A0001" "$CALLS" && ok "preset run overrides the selection with the session filter" || bad "preset session: $(cat "$CALLS")"

: > "$CALLS"
qset "__ALL__"
oc_preset_run "notes" "product transcript" >/dev/null
grep -qx "export notes" "$CALLS" && ok "preset ALL runs as configured (no override)" || bad "preset ALL: $(cat "$CALLS")"

echo "== export flow: ESC cancels without creating a run =="
reset
export OCED_PRESETS="$TMP/presets.json"
before=$(count_meta transcript)
FZF_FAIL="sessions (preset)"
oc_preset_run "notes" "x" >/dev/null 2>&1
rc=$?
after=$(count_meta transcript)
[ "$rc" -ne 0 ] && ok "ESC cancels the session picker of a preset ($rc)" || bad "ESC did not cancel"
[ "$before" -eq "$after" ] && ok "cancelled flow created no export" || bad "cancelled flow exported"

echo "== export flow: confirmation gates the run =="
reset
export OCED_PRESETS="$TMP/presets.json"
: > "$CALLS"; call_log
CONFIRME="$TMP/confirm.txt"
confirm_action() { printf '%s\n' "$1" >> "$CONFIRME"; return 1; }
before=$(count_meta transcript)
qset "__ALL__"
oc_preset_run "notes" "x" >/dev/null
after=$(count_meta transcript)
[ -s "$CONFIRME" ] && grep -q "Start this export" "$CONFIRME" && ok "confirmation asked with the plan" || bad "no confirmation asked"
[ "$before" -eq "$after" ] && ok "declined confirmation -> no export" || bad "declined but exported"

echo "== export flow: real runs against the fake DB =="
reset
export OCED_PRESETS="$TMP/presets.json"
confirm_action() { return 0; }
before=$(count_meta transcript)
qset "ses_A0001"
oc_preset_run "notes" "x" >/dev/null
[ "$(count_meta transcript)" -eq $((before + 1)) ] && ok "preset flow exports the transcript" || bad "preset flow export transcript missing"
ME=$(newest_meta transcript)
jq -e '.filter == "ses_A0001"' "$ME" >/dev/null && ok "real run applied the session filter" || bad "real run filter"

qset "__ALL__"
oc_preset_run "notes" "x" >/dev/null
MA=$(newest_meta transcript)
jq -e '.filter == null' "$MA" >/dev/null && ok "preset ALL -> no filter" || bad "ALL filter not null"
jq -e '.sessions.total == 6' "$MA" >/dev/null && ok "ALL exported 6 sessions" || bad "ALL sessions count: $(jq '.sessions.total' "$MA")"

qset "__ALL__"
oc_preset_run "rag" "x" >/dev/null
MEM=$(newest_meta memory); MEM="${MEM%/metadata.json}"
[ -f "$MEM/corpus.jsonl" ] && ok "preset flow wrote a corpus" || bad "preset flow corpus"
[ "$(wc -l < "$MEM/corpus.jsonl")" -eq 3 ] && ok "memory corpus: one line per root (3 roots)" || bad "memory corpus roots"
export OCED_PRESETS="$TMP/no-presets.json"

echo "== export flow: snapshot: fresh -> backup alignment offer =="
reset
export OCED_PRESETS="$TMP/presets.json"
: > "$CALLS"; call_log
confirm_action() { return 0; }
[ "$(oc_plan_py snapshot snappy 2>/dev/null)" = "fresh" ] && ok "plan.py snapshot exposes the snapshot flag" || bad "plan snapshot"
qset "__ALL__"
oc_preset_run "snappy" "product transcript" >/dev/null
grep -qx "backup" "$CALLS" && ok "snapshot preset offers a fresh backup (no backups yet)" || bad "snap backup offer: $(cat "$CALLS")"
grep -qx "export snappy" "$CALLS" && ok "snapshot preset exports after the fresh backup" || bad "snap export: $(cat "$CALLS")"

: > "$CALLS"
# With a backup present + aligned, the snapshot preset must NOT re-offer.
ALIGNED="$OCED_BACKUP_DIR"
mkdir -p "$ALIGNED"
SESSES=$(sqlite3 "file:$FAKE?mode=ro" "SELECT count(*) FROM session" 2>/dev/null)
MSGS=$(sqlite3 "file:$FAKE?mode=ro" "SELECT count(*) FROM message" 2>/dev/null)
MUTS=$(sqlite3 "file:$FAKE?mode=ro" "SELECT max(time_updated) FROM session" 2>/dev/null)
printf '{"backups": [{"sessions": %s, "messages": %s, "max_updated": %s}]}' "$SESSES" "$MSGS" "$MUTS" > "$ALIGNED/manifest.json"
qset "__ALL__"
oc_preset_run "snappy" "product transcript" >/dev/null
grep -qx "backup" "$CALLS" && bad "aligned snapshot preset re-offered a backup" || ok "aligned snapshot preset does NOT re-offer a backup"
export OCED_PRESETS="$TMP/no-presets.json"

echo "== shrink create flow: sessions (roots) -> recipe -> plan =="
reset
: > "$CALLS"; call_log
confirm_action() { return 0; }
qempty
oc_pick_shrink >/dev/null
[ ! -s "$CALLS" ] && ok "ESC cancels the shrink create flow" || bad "ESC still ran shrink"

# all marked -> --keep-all; a recipe goes straight to the plan
: > "$CALLS"
qset "__MAKE__" "__PRESET_quiet"
oc_pick_shrink >/dev/null
grep -qx "shrink --keep-all" "$CALLS" && ok "sessions(all marked) -> recipe 'quiet' -> shrink --keep-all" || bad "sessions keep-all: $(cat "$CALLS")"

# a recipe applies ITS operations (there is no toggle and no 'continue' row)
: > "$CALLS"
qset "__MAKE__" "__PRESET_lean"
oc_pick_shrink >/dev/null
grep -qx "shrink --keep-all --strip-reasoning" "$CALLS" && ok "recipe 'lean' applies strip_reasoning" || bad "recipe lean: $(cat "$CALLS")"

OROWS=$(oc_shrink_rows)
printf '%s\n' "$OROWS" | grep -q '__STRIP__\|__GO__' && bad "the operation toggle/continue rows leaked into the recipe list" || ok "recipe list has no toggle and no 'continue' row"
[ "$(printf '%s\n' "$OROWS" | grep -c '__PRESET_')" -ge 2 ] \
    && ok "the recipe list is the built-ins (lean/quiet) + the file recipes" || bad "recipe rows: $OROWS"

echo "== shrink sessions picker: ROOT sessions only, marked = survive =="
# the fake DB has 6 sessions but 3 roots (ses_A0001, ses_B0001, ses_ORPHAN01 —
# the orphan's parent is gone, so it IS a root); subagents never get a row.
reset
: > "$CALLS"; call_log
confirm_action() { return 0; }
RROWS=$(session_rows --root)
[ "$(printf '%s\n' "$RROWS" | grep -c '^ses_')" = "3" ] && ok "sessions picker lists only the 3 root sessions" || bad "root rows: $RROWS"
printf '%s\n' "$RROWS" | grep -q '^ses_A0002' && bad "a subagent leaked into the picker rows" || ok "no subagent rows in the picker"
SUBS=$(oc_shrink_sub_counts)
printf '%s' "$SUBS" | grep -q "$(printf 'ses_A0001\t2')" && ok "the root row can show its subagent count (A0001 -> 2)" || bad "sub counts: [$SUBS]"

# the picker sorts by time_updated (newest first), and the two axes really
# disagree: in the fake DB B was used more recently than A, while A is older.
ord_ids() { session_rows --root --order "$1" | awk '{print $1}' | paste -sd, -; }
[ "$(ord_ids updated-desc)" = "ses_ORPHAN01,ses_B0001,ses_A0001" ] \
    && ok "list --order updated-desc: most recently used first" || bad "updated-desc: $(ord_ids updated-desc)"
[ "$(ord_ids updated-asc)" = "ses_A0001,ses_B0001,ses_ORPHAN01" ] \
    && ok "list --order updated-asc: the reverse" || bad "updated-asc: $(ord_ids updated-asc)"
[ "$(ord_ids created-asc)" = "ses_A0001,ses_B0001,ses_ORPHAN01" ] \
    && ok "list --order created-asc is the default order (unchanged)" || bad "created-asc: $(ord_ids created-asc)"
oced_out list --order nope >/dev/null 2>&1 && bad "an invalid --order was accepted" || ok "an invalid --order is rejected"

# the picker opens in newest-first and the order row flips it, keeping the marks
: > "$CALLS"
qset "__TOGGLE__" "__NONE__" "ses_A0001" "__TOGGLE__" "__MAKE__" "__PRESET_quiet"
oc_pick_shrink > "$TMP/order.txt"
grep -q 'Sorted: newest first' "$FZF_HIST" && ok "the sessions picker opens sorted newest first" || bad "order mode: $(grep -o 'Sorted: [a-z ]*' "$FZF_HIST" | head -2 | tr '\n' '/')"
grep -q 'Sorted: oldest first' "$FZF_HIST" && ok "the order row switches to oldest first (header follows)" || bad "order toggle label missing"
[ "$(grep -c '^-> shrink plan' "$TMP/order.txt")" = "1" ] && ok "re-ordering keeps the picker usable (one plan)" || bad "plan count after re-order"
grep -qx "shrink --discard-sessions ses_ORPHAN01,ses_B0001" "$CALLS" \
    && ok "the marks survive the order switch (2nd __TOGGLE__ did not reset them)" || bad "marks after re-order: $(cat "$CALLS")"

# the order row itself (the fzf prompt only carries the header, so log the rows)
reset
qempty
: > "$TMP/sessions_rows.txt"
( oc_fzf_sel() { tee -a "$TMP/sessions_rows.txt" | fzf "$@"; }
  oc_shrink_sessions_pick >/dev/null )
reset
: > "$CALLS"; call_log
confirm_action() { return 0; }
grep -q 'shrink — order: newest first' "$TMP/sessions_rows.txt" \
    && ok "the order row advertises the current mode (newest first)" || bad "order row missing"
grep -q 'switch to oldest first' "$TMP/sessions_rows.txt" \
    && ok "the order row offers the reverse sort" || bad "order row label missing"
: > "$CALLS"
qset "__NONE__" "ses_A0001" "__MAKE__" "__PRESET_quiet"
oc_pick_shrink >/dev/null
grep -q '^export archive --sessions ' "$CALLS" && ok "unmarked roots are offered for export first (archive bundle)" || bad "sessions export offer: $(cat "$CALLS")"
grep -q '^shrink --discard-sessions ' "$CALLS" && ok "unmarked roots -> --discard-sessions" || bad "sessions discard: $(cat "$CALLS")"
[ "$(grep '^shrink --discard-sessions ' "$CALLS" | tail -1 | grep -o ',' | wc -l)" = "1" ] \
    && ok "sessions picker: 2 unmarked roots (1 kept of 3) -> 1 comma" || bad "sessions discard csv count"

# the plan prints the exact read-only counts before the y/N gate
: > "$CALLS"
qset "__NONE__" "ses_A0001" "__MAKE__" "__PRESET_quiet"
oc_pick_shrink > "$TMP/plan.txt"
grep -q "Rows to remove:" "$TMP/plan.txt" && ok "the plan lists the rows to remove" || bad "plan rows block missing"
# ses_A0001 survives with its 2 subagents; ses_B0001 (+ its subagent) and the
# orphan root ses_ORPHAN01 are discarded (the descendant-closed cascade).
grep -qE "Keep: +1 root\(s\) \+ 2 subagent\(s\) = 3 session\(s\)" "$TMP/plan.txt" \
    && ok "the plan counts the kept roots + subagents" || bad "plan keep line: $(grep -E 'Keep:|Discard:' "$TMP/plan.txt")"
grep -qE "Discard: +2 root\(s\) \+ 1 subagent\(s\) = 3 session\(s\) \(cascade\)" "$TMP/plan.txt" \
    && ok "the plan counts the discarded cascade (roots + their subagent)" || bad "plan discard line: $(grep -E 'Keep:|Discard:' "$TMP/plan.txt")"
grep -qE "^     part +[0-9]+$" "$TMP/plan.txt" && ok "the plan counts rows per table" || bad "plan per-table rows missing"
grep -q "read-only counts" "$TMP/plan.txt" && ok "the plan says it is read-only" || bad "plan read-only note missing"
grep -qE "Recipe: +quiet - prune \+ vacuum only" "$TMP/plan.txt" \
    && ok "the plan names the recipe picked in the previous step (with its purpose)" || bad "plan recipe line: $(grep -E 'Recipe:|Command:' "$TMP/plan.txt")"
grep -qE "Command: +shrink --discard-sessions" "$TMP/plan.txt" \
    && ok "the plan shows the effective command the engine will run" || bad "plan command line missing"

: > "$CALLS"
qset "__LAST__" "__MAKE__" "__PRESET_quiet"
printf '2\n' | oc_pick_shrink >/dev/null
grep -q '^shrink --discard-sessions ' "$CALLS" && ok "sessions picker: LAST-N keeps only the N most recent" || bad "sessions LAST: $(cat "$CALLS")"
[ "$(grep '^shrink --discard-sessions ' "$CALLS" | tail -1 | grep -o ',' | wc -l)" = "0" ] \
    && ok "sessions LAST-2: 1 of 3 roots unmarked -> no comma" || bad "sessions LAST-2 csv count"

: > "$CALLS"
qset "__DAYS__" "__MAKE__" "__PRESET_quiet"
printf '3650\n' | oc_pick_shrink >/dev/null
grep -qx "shrink --keep-all" "$CALLS" && ok "sessions DAYS-N (a wide window) marks every root" || bad "sessions DAYS: $(cat "$CALLS")"

: > "$CALLS"
qset "__NONE__" "__MAKE__"
oc_pick_shrink > "$TMP/sessions-empty.txt"
[ ! -s "$CALLS" ] && ok "sessions picker: nothing marked -> no shrink (guard)" || bad "sessions empty ran: $(cat "$CALLS")"
grep -q 'EMPTY database' "$TMP/sessions-empty.txt" && ok "sessions picker prints the empty-copy warning" || bad "sessions empty warning missing"

echo "== shrink flow navigation: ESC climbs one level, 'n' aborts =="
reset
: > "$CALLS"; call_log
confirm_action() { return 0; }
# ESC at the recipe step returns to the sessions picker with the marks intact
# (the queue: NONE, mark A0001, continue -> recipe (ESC), continue -> recipe -> lean)
: > "$CALLS"
qset "__NONE__" "ses_A0001" "__MAKE__" "__MAKE__" "__MAKE__" "__PRESET_lean"
oc_pick_shrink >/dev/null
grep -qx "shrink --discard-sessions ses_ORPHAN01,ses_B0001 --strip-reasoning" "$CALLS" \
    && ok "ESC at the recipe step keeps the marks (back to sessions, then continue)" || bad "ESC ops: $(cat "$CALLS")"

: > "$CALLS"
confirm_action() { return 1; }
qset "__MAKE__" "__PRESET_lean"
oc_pick_shrink >/dev/null
[ ! -s "$CALLS" ] && ok "shrink plan rejected on 'n' (nothing ran)" || bad "shrink ran on 'n'"
confirm_action() { return 0; }

# declining the plan re-renders the RECIPE list to pick another one (the session
# selection is untouched). --keep-all keeps the export offer out of the way, so
# the first confirm_action call IS the build gate.
: > "$CALLS"
CONFIRM_N=0
confirm_action() { CONFIRM_N=$((CONFIRM_N+1)); [ "$CONFIRM_N" -eq 1 ] && return 1; return 0; }
qset "__MAKE__" "__PRESET_lean" "__PRESET_quiet"
oc_pick_shrink > "$TMP/decline.txt"
grep -q "declined — back to the recipe step" "$TMP/decline.txt" \
    && ok "the plan says a decline goes back to the recipe step" || bad "decline hint missing"
[ "$(grep -c '^-> shrink plan' "$TMP/decline.txt")" = "2" ] \
    && ok "declining the plan re-renders the recipes (plan shown again)" || bad "decline plan count"
grep -qx "shrink --keep-all" "$CALLS" \
    && ok "after a decline another recipe can be chosen (quiet, not lean)" \
    || bad "decline -> recipe: $(cat "$CALLS")"
confirm_action() { return 0; }

echo "== shrink rows/bake come from shrinklib (recipes = operations only) =="
reset
FPRES="$TMP/shrink-presets.json"
cat > "$FPRES" <<'EOF'
{"presets": {
   "skim": {"strip_reasoning": true},
   "keep-text": {"strip_reasoning": false}
}}
EOF
export OCED_SHRINK_PRESETS="$FPRES"
printf '%s\n' "$(oc_shrink_rows)" | grep -q '^__PRESET_lean' && ok "shrink rows list the built-in recipes" || bad "built-ins missing"
printf '%s\n' "$(oc_shrink_rows)" | grep -q '^__PRESET_skim' && ok "shrink rows list file recipes from OCED_SHRINK_PRESETS" || bad "file preset missing"
[ "$(oc_shrink_py bake skim)" = "--strip-reasoning" ] && ok "shrink bake emits only the operation flag" || bad "shrink bake skim: $(oc_shrink_py bake skim)"
[ "$(oc_shrink_py bake "keep-text")" = "" ] && ok "a recipe with an explicit false bakes nothing" || bad "bake keep-text: $(oc_shrink_py bake "keep-text")"
# a keep rule inside a recipe is rejected (the selection is a CLI flag)
[ "$(oc_shrink_py bake lean)" = "--strip-reasoning" ] && ok "a built-in recipe still bakes its operation" || bad "bake lean: $(oc_shrink_py bake lean)"
# the recipe step lists the recipes and NOTHING else (log every row it renders,
# then answer ESC)
reset
: > "$TMP/ops_rows.txt"
( oc_fzf_sel() { cat > "$TMP/ops_rows.txt"; return 130; }
  oc_shrink_ops_pick --keep-all >/dev/null )
reset
: > "$CALLS"; call_log
confirm_action() { return 0; }
OROWS=$(cat "$TMP/ops_rows.txt")
printf '%s\n' "$OROWS" | grep -q '^__PRESET_lean' && ok "the recipe step lists the built-in recipes" || bad "ops recipe rows missing"
printf '%s\n' "$OROWS" | grep -q '^__PRESET_skim' && ok "the recipe step lists the file recipes too" || bad "file recipe row missing"
printf '%s\n' "$OROWS" | grep -q '__STRIP__\|__GO__' \
    && bad "a toggle/continue row leaked into the recipe step" || ok "the recipe step has no toggle and no 'continue' row (only recipes)"
printf '%s\n' "$OROWS" | grep -q '__CUSTOM__\|__DRYRUN__\|__SESSIONS__' && bad "the old custom/dry-run rows leaked" || ok "no custom/dry-run/sessions rows (the flow is fixed)"
: > "$CALLS"
qset "__PRESET_skim"
oc_shrink_ops_pick "--keep-all" >/dev/null
grep -qx "shrink --keep-all --strip-reasoning" "$CALLS" && ok "the recipe step forwards the baked operation flags" || bad "ops flags: $(cat "$CALLS")"
unset OCED_SHRINK_PRESETS

echo "== shrinks picker (create + manage, toggle view/remove) =="
reset
SHR="$OCED_BACKUP_DIR/shrink"
mkdir -p "$SHR/20260101-090000" "$SHR/20260102-100000" "$SHR/20260103-110000"
for d in 20260101-090000 20260102-100000 20260103-110000; do
    jq -n --arg c "keep 10 + strip reasoning" --argjson t 6 --argjson k 2 --argjson del 4 \
        --argjson b 100000 --argjson a 30000 --argjson st 0 --argjson mu 0 \
        '{criteria:$c, sessions:{total:$t, kept:$k, deleted:$del, max_updated:$mu}, size:{before:$b, after:$a}, stripped_reasoning:$st, date:"2026-01-01T00:00:00Z"}' \
        > "$SHR/$d/shrink.json"
done
mkdir -p "$SHR/20251231-120000"
jq -n --arg c "keep 10 + strip reasoning" --argjson t 6 --argjson k 2 --argjson del 4 \
    --argjson b 100000 --argjson a 30000 --argjson st 0 --argjson mu 9999999999999 \
    '{criteria:$c, sessions:{total:$t, kept:$k, deleted:$del, max_updated:$mu}, size:{before:$b, after:$a}, stripped_reasoning:$st, date:"2026-01-04T00:00:00Z"}' \
    > "$SHR/20251231-120000/shrink.json"
: > "$SHR/20251231-120000/opencode.shrunk.db"
: > "$SHR/20260101-090000/opencode.shrunk.db"
ROWS=$(oc_shrinks_rows view)
printf '%s\n' "$ROWS" | sed -n '1p' | grep -q '^__CREATE__' && ok "shrinks rows: create first" || bad "shrinks create not first"
printf '%s\n' "$ROWS" | grep -q '__TOGGLE__' && ok "shrinks rows: view/remove toggle" || bad "shrinks toggle missing"
printf '%s\n' "$ROWS" | grep -q '2026-01-03 11:00:00' && ok "shrinks rows list the produced runs (human stamp)" || bad "shrinks run rows missing"
printf '%s\n' "$ROWS" | grep -q '2 sess / 4 del' && ok "shrinks rows show the shrunken counts" || bad "shrinks counts in row"
printf '%s\n' "$ROWS" | grep -q '^__VERIFY__' && ok "shrinks rows offer verify" || bad "shrinks verify row missing"
printf '%s\n' "$ROWS" | grep -q '^__SWAP__' && ok "shrinks rows offer the swap entry" || bad "shrinks swap row missing"

: > "$CALLS"; call_log
qset "__VERIFY__"
oc_shrinks_picker >/dev/null
grep -qx "shrinks verify" "$CALLS" && ok "shrinks picker dispatches verify" || bad "shrinks verify: $(cat "$CALLS")"

: > "$CALLS"; call_log
confirm_action() { return 0; }
qset "20260103-110000"
oc_shrinks_picker >/dev/null
grep -qx "shrinks view 20260103-110000" "$CALLS" && ok "shrinks view dispatches for the run" || bad "shrinks view: $(cat "$CALLS")"
grep -q "shrinks (view)" "$FZF_HIST" && ok "shrinks picker starts in view mode" || bad "shrinks initial mode"

echo "== shrinks SWAP (destructive, typed confirm; fresh + stale copy) =="
reset
: > "$CALLS"; call_log
oced_shrink_swap() { printf '%s\n' "$*" >> "$CALLS"; }   # stub the real swap engine
confirm_action() { return 0; }
: > "$CALLS"
qset "__SWAP__" "20251231-120000"
printf 'confirm\n' | oc_shrinks_picker > "$TMP/swap-fresh.txt" 2>&1
grep -q 'opencode.shrunk.db 1$' "$CALLS" && ok "shrinks SWAP swaps the picked copy (typed confirm)" || bad "shrinks swap: $(cat "$CALLS")"
grep -q "swap (pick a copy)" "$FZF_HIST" && ok "shrinks SWAP uses the pick-a-copy picker" || bad "shrinks swap picker prompt missing"

: > "$CALLS"
qset "__SWAP__" "20260101-090000"   # stale/unverifiable copy (max_updated=0)
printf 'confirm\n' | oc_shrinks_picker > "$TMP/swap-stale.txt" 2>&1
grep -q 'opencode.shrunk.db 1$' "$CALLS" && ok "shrinks SWAP proceeds after the stale warning + confirm" || bad "shrinks stale swap: $(cat "$CALLS")"
grep -Eqi 'stale|freshness' "$TMP/swap-stale.txt" && ok "shrinks SWAP warns on a stale/unverifiable copy" || bad "shrinks stale warning missing"

: > "$CALLS"
qset "__SWAP__" "20251231-120000"
printf 'noperd\n' | oc_shrinks_picker > "$TMP/swap-nope.txt" 2>&1
[ ! -s "$CALLS" ] && ok "shrinks SWAP aborts when 'confirm' is not typed" || bad "shrinks swap ran without confirm: $(cat "$CALLS")"

: > "$CALLS"
qset "__TOGGLE__" "20260102-100000"
oc_shrinks_picker >/dev/null
grep -qx "shrinks remove 20260102-100000 --yes" "$CALLS" && ok "shrinks picker toggles to remove and removes the run" || bad "shrinks remove: $(cat "$CALLS")"
grep -q "shrinks (remove)" "$FZF_HIST" && ok "shrinks picker reached remove mode" || bad "shrinks remove mode not reached"

: > "$CALLS"
qset "__TOGGLE__" "__DELETE_ALL__"
oc_shrinks_picker >/dev/null
grep -qx "shrinks remove 20260101-090000 --yes" "$CALLS" && grep -qx "shrinks remove 20260103-110000 --yes" "$CALLS" && ok "shrinks delete-all removes every run (confirmed)" || bad "shrinks delete-all: $(cat "$CALLS")"

: > "$CALLS"
qset "__TOGGLE__" "__KEEP_NEWEST__"
oc_shrinks_picker >/dev/null
grep -qx "shrinks remove 20260101-090000 --yes" "$CALLS" && grep -qx "shrinks remove 20260102-100000 --yes" "$CALLS" && ! grep -qx "shrinks remove 20260103-110000 --yes" "$CALLS" && ok "shrinks keep-newest removes all but the newest" || bad "shrinks keep-newest: $(cat "$CALLS")"

: > "$CALLS"
confirm_action() { return 1; }
qset "__TOGGLE__" "__DELETE_ALL__"
oc_shrinks_picker >/dev/null
[ ! -s "$CALLS" ] && ok "shrinks delete-all cancelled on 'n'" || bad "shrinks delete-all ran on 'n'"
confirm_action() { return 0; }

echo "== shrinks picker: empty state + create reaches the dispatcher =="
reset
confirm_action() { return 0; }
rm -rf "$SHR"
printf '%s\n' "$(oc_shrinks_rows view)" | grep -q '__NONE__' && ok "shrinks rows show (none) when empty" || bad "shrinks none missing"
oc_shrinks_swap_pick > "$TMP/swap-none.txt" 2>&1 || true
grep -q 'no shrink copies' "$TMP/swap-none.txt" && ok "shrinks SWAP with no copies prints guidance" || bad "shrinks swap empty-state guidance missing"
: > "$CALLS"; call_log
qset "__CREATE__" "__MAKE__" "__PRESET_lean"
oc_shrinks_picker >/dev/null
grep -qx "shrink --keep-all --strip-reasoning" "$CALLS" \
    && ok "shrinks picker: __CREATE__ walks sessions -> recipe -> the dispatcher" || bad "shrinks create: $(cat "$CALLS")"

echo ""
echo "RESULT: $pass OK / $fail FAIL"
[ "$fail" -eq 0 ]