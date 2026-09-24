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
export OCED_DISPATCHER="$MOD/opencode-db.sh"
bash "$TESTS_DIR/make_fake_db.sh" "$FAKE" >/dev/null

. "$MOD/common.sh"
. "$MOD/export.sh"
. "$MOD/exports.sh"

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

echo "== product picker: exactly 3 products, NO variants/custom/bundle =="
reset
oc_fzf_sel() { cat; }   # pass-through: expose the generated rows
PROD=$(oc_pick_product)
unset -f oc_fzf_sel
rows_with_label() { local n=0 line; while IFS= read -r line; do
    [[ "$line" == *$'\t'* ]] || continue
    [ -n "${line%%$'\t'*}" ] && [ -n "${line#*$'\t'}" ] && n=$((n + 1))
done; echo "$n"; }
[ "$(printf '%s\n' "$PROD" | rows_with_label)" = "3" ] && ok "product picker rows (3) have key+label" || bad "product rows: $PROD"
printf '%s' "$PROD" | grep -qE '^(transcript|memory|compactions)' && ok "product rows are transcript/memory/compactions" || bad "product keys: $PROD"
printf '%s' "$PROD" | grep -q '__FULLMEM__' && bad "bundle variant leaked into the product picker" || ok "product picker has NO transcript+memory bundle"
printf '%s' "$PROD" | grep -q '__CUSTOM__' && bad "custom checklist leaked into the product picker" || ok "product picker has NO custom checklist"
printf '%s' "$PROD" | grep -q -- "--tool-output" && bad "variant rows leaked into the product picker" || ok "product picker has NO variant rows"

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

echo "== backups rows: create first, shrink second, no mode toggle =="
reset
ROWS=$(oc_backups_rows)
printf '%s\n' "$ROWS" | sed -n '1p' | grep -q '^__CREATE__' && ok "create backup is the first row" || bad "create not first"
printf '%s\n' "$ROWS" | sed -n '2p' | grep -q '^__SHRINK__' && ok "shrink is the second row" || bad "shrink not second"
printf '%s\n' "$ROWS" | grep -q '__TOGGLE__' && bad "mode toggle leaked into backups" || ok "backups picker has a single mode (no toggle)"

: > "$CALLS"; call_log
confirm_action() { return 0; }
qset "__CREATE__"
oc_backups_picker >/dev/null
grep -qx "backup" "$CALLS" && ok "backups picker offers create backup" || bad "backups create: $(cat "$CALLS")"

: > "$CALLS"
qset "__SHRINK__" "lean: keep 10 most recent + strip reasoning|shrink|lean"
oc_backups_picker >/dev/null
grep -qx "shrink lean" "$CALLS" && ok "shrink runs from the backups picker (own LIVE-DB snapshot)" || bad "backups shrink: $(cat "$CALLS")"

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

echo "== export picker (independent entry: session or ALL -> product) =="
reset
: > "$CALLS"; call_log
confirm_action() { return 0; }
qset "ses_A0001" "transcript"
oc_export_picker >/dev/null
grep -qx "export transcript --filter ses_A0001" "$CALLS" && ok "export picker ran the flow with the session filter" || bad "export picker flow: $(cat "$CALLS")"
grep -q "sessions (export)" "$FZF_HIST" && ok "export picker reached its own picker" || bad "export picker title"

: > "$CALLS"
qset "__ALL__" "compactions"
oc_export_picker >/dev/null
grep -qx "export compactions" "$CALLS" && ok "export picker ALL runs the flow with no filter" || bad "export picker ALL: $(cat "$CALLS")"

: > "$CALLS"
printf '%s\n' "$(oc_export_rows)" | grep -q '^__ALL__' && ok "export picker lists ALL SESSIONS first" || bad "export rows ALL missing"

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

echo "== export flow: product -> runner with defaults =="
reset
: > "$CALLS"; call_log
confirm_action() { :; return 0; }
qset "transcript"
oc_export_flow "ses_A0001" >/dev/null
grep -qx "export transcript --filter ses_A0001" "$CALLS" && ok "flow runs the product with the session filter" || bad "flow product: $(cat "$CALLS")"

: > "$CALLS"
qset "transcript"
oc_export_flow "" >/dev/null
grep -qx "export transcript" "$CALLS" && ok "flow + ALL sessions: no filter" || bad "flow ALL: $(cat "$CALLS")"

echo "== export flow: ESC cancels without creating a run =="
reset
before=$(count_meta transcript)
FZF_FAIL="export product"
oc_export_flow "ses_A0001" >/dev/null 2>&1
rc=$?
after=$(count_meta transcript)
[ "$rc" -ne 0 ] && ok "ESC cancels the product picker ($rc)" || bad "ESC did not cancel"
[ "$before" -eq "$after" ] && ok "cancelled flow created no export" || bad "cancelled flow exported"

echo "== export flow: confirmation gates the run =="
reset
: > "$CALLS"; call_log
CONFIRME="$TMP/confirm.txt"
confirm_action() { printf '%s\n' "$1" >> "$CONFIRME"; return 1; }
before=$(count_meta transcript)
qset "transcript"
oc_export_flow "ses_A0001" >/dev/null
after=$(count_meta transcript)
[ -s "$CONFIRME" ] && grep -q "Start this export" "$CONFIRME" && ok "confirmation asked with the plan" || bad "no confirmation asked"
[ "$before" -eq "$after" ] && ok "declined confirmation -> no export" || bad "declined but exported"

echo "== export flow: real runs against the fake DB =="
reset
confirm_action() { return 0; }
before=$(count_meta transcript)
qset "transcript"
oc_export_flow "ses_A0001" >/dev/null
[ "$(count_meta transcript)" -eq $((before + 1)) ] && ok "flow exports the transcript" || bad "flow export transcript missing"
ME=$(newest_meta transcript)
jq -e '.filter == "ses_A0001"' "$ME" >/dev/null && ok "real run applied the session filter" || bad "real run filter"

qset "transcript"
oc_export_flow "" >/dev/null
MA=$(newest_meta transcript)
jq -e '.filter == null' "$MA" >/dev/null && ok "ALL sessions -> no filter" || bad "ALL filter not null"
jq -e '.sessions.total == 6' "$MA" >/dev/null && ok "ALL exported 6 sessions" || bad "ALL sessions count: $(jq '.sessions.total' "$MA")"

qset "memory"
oc_export_flow "" >/dev/null
MEM=$(newest_meta memory); MEM="${MEM%/metadata.json}"
[ -f "$MEM/corpus.jsonl" ] && ok "memory flow wrote a corpus" || bad "memory flow corpus"
[ "$(wc -l < "$MEM/corpus.jsonl")" -eq 3 ] && ok "memory corpus: one line per root (3 roots)" || bad "memory corpus roots"

echo "== shrink in the menu: recipes / custom / dry-run / ESC / confirm =="
reset
: > "$CALLS"; call_log
confirm_action() { return 0; }
FZF_FAIL="shrink recipe"
oc_pick_shrink >/dev/null
unset FZF_FAIL
[ ! -s "$CALLS" ] && ok "ESC cancels shrink picker" || bad "ESC still ran shrink"

qset "lean: keep 10 most recent + strip reasoning|shrink|lean"
oc_pick_shrink >/dev/null
grep -qx "shrink lean" "$CALLS" && ok "shrink recipe lean reaches the dispatcher" || bad "shrink lean: $(cat "$CALLS")"

: > "$CALLS"
qset "dry-run (no file)|shrink|lean --dry-run"
oc_pick_shrink >/dev/null
grep -qx "shrink lean --dry-run" "$CALLS" && ok "shrink dry-run reaches the dispatcher (no confirm)" || bad "shrink dry-run: $(cat "$CALLS")"

: > "$CALLS"
qset "custom (choose exactly what to keep)...|shrink|custom" "keep sessions since a date (real range)"
printf '20260115\n' | oc_pick_shrink >/dev/null
grep -qx "shrink --since 2026-01-15" "$CALLS" && ok "shrink custom since-date reaches the dispatcher" || bad "shrink custom since-date: $(cat "$CALLS")"

: > "$CALLS"
confirm_action() { return 1; }
qset "bare: keep 10 most recent, keep reasoning|shrink|bare"
oc_pick_shrink >/dev/null
[ ! -s "$CALLS" ] && ok "shrink rejected on 'n'" || bad "shrink ran on 'n'"
confirm_action() { return 0; }

echo ""
echo "RESULT: $pass OK / $fail FAIL"
[ "$fail" -eq 0 ]