#!/usr/bin/env bash
# menu_flow.sh — logic tests for the fzf menu (fzf is stubbed; no TTY needed).
# Usage: tests/menu_flow.sh
# NOTE: FZF_QUEUE is ALWAYS assigned on its own line, never as a command prefix:
# with `set -u`, `VAR=("a") fn` makes the array invisible inside fn (bash quirk).
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$TESTS_DIR/../modules"
TMP="$(mktemp -d /tmp/opencode-db-menu-XXXXXX)"
# Only the TOP-LEVEL shell may delete $TMP. bash runs an inherited EXIT trap in
# EVERY subshell, so one dying subshell (an unbound variable under `set -u`, an
# early return, `set -e`) used to fire `rm -rf $TMP` mid-run and wipe the
# fixture: the suite kept going with a deleted TMP and 100 asserts failed for
# reasons that had nothing to do with the code under test.
menu_cleanup() { [ "${BASH_SUBSHELL:-0}" -eq 0 ] && rm -rf -- "$TMP"; return 0; }
trap menu_cleanup EXIT

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
# Pristine copy of the stub: a section that WRAPS fzf to record the renders (see
# the hide-subagents toggle section) restores it from here with `. "$FZF_PRISTINE"`.
FZF_PRISTINE="$TMP/fzf.pristine"
declare -f fzf > "$FZF_PRISTINE"
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
ARROW=$'\u2192'
[ "$(oc_toggle_row view remove)" = "__TOGGLE__"$'\t'"[*] view  ${ARROW}  remove" ] && ok "oc_toggle_row builds the [*] toggle row" || bad "oc_toggle_row: $(oc_toggle_row view remove)"
[ "$(oc_toggle_row 'subagents: shown' hidden __SUBS__ | cut -f1)" = "__SUBS__" ] && ok "oc_toggle_row takes an optional key" || bad "oc_toggle_row key"
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

echo "== backups picker (create / view-remove toggle / bulk / per-file) =="
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

# view mode: a listed backup shows its details (the CLI also runs the sha check)
: > "$CALLS"; call_log
qset "fake-2.db"
oc_backups_picker >/dev/null
grep -qx "backups view fake-2.db" "$CALLS" && ok "selecting a backup row shows its details" || bad "backups view: $(cat "$CALLS")"
grep -q "backups (view)" "$FZF_HIST" && ok "backups picker opens in view mode" || bad "backups initial mode"

# remove mode: the same row deletes it, behind the confirmation
: > "$CALLS"
qset "__TOGGLE__" "fake-2.db"
oc_backups_picker >/dev/null
grep -qx "backups remove fake-2.db --yes" "$CALLS" && ok "in remove mode a backup row deletes it (confirmed)" || bad "backups delete: $(cat "$CALLS")"
grep -q "backups (remove)" "$FZF_HIST" && ok "the toggle reaches remove mode" || bad "backups remove mode not reached"

echo "== backups rows: [>] create first, [*] toggle, destructive rows only in remove =="
reset
VROWS=$(oc_backups_rows view)
RROWS=$(oc_backups_rows remove)
TAB=$(printf '\t')
printf '%s\n' "$VROWS" | head -1 | grep -qxF "__CREATE__${TAB}[>] create backup" \
    && ok "create backup is the first row" || bad "create not first: $(printf '%s\n' "$VROWS" | head -1)"
printf '%s\n' "$VROWS" | grep -q '__SHRINK__' && bad "shrink row leaked into backups" || ok "backups rows have NO shrink row (dedicated shrinks entry)"
printf '%s\n' "$VROWS" | grep -qxF "__TOGGLE__${TAB}[*] view  ${ARROW}  remove" \
    && ok "view mode has the [*] view -> remove toggle" || bad "toggle row: $(printf '%s\n' "$VROWS" | grep __TOGGLE__)"
printf '%s\n' "$RROWS" | grep -qxF "__TOGGLE__${TAB}[*] remove  ${ARROW}  view" \
    && ok "the toggle follows the mode" || bad "remove toggle: $(printf '%s\n' "$RROWS" | grep __TOGGLE__)"
printf '%s\n' "$VROWS" | grep -q '__DELETE_ALL__\|__KEEP_NEWEST__' && bad "view mode offers destructive rows" || ok "view mode has NO delete rows"
printf '%s\n' "$RROWS" | grep -qxF "__DELETE_ALL__${TAB}[delete all]" \
    && ok "remove mode has [delete all]" || bad "delete all row: $(printf '%s\n' "$RROWS" | grep __DELETE_ALL__)"
printf '%s\n' "$RROWS" | grep -qxF "__KEEP_NEWEST__${TAB}[delete olds]" \
    && ok "remove mode has [delete olds]" || bad "delete olds row: $(printf '%s\n' "$RROWS" | grep __KEEP_NEWEST__)"

: > "$CALLS"; call_log
confirm_action() { return 0; }
qset "__CREATE__"
oc_backups_picker >/dev/null
# The create flow is plan -> OUR gate -> run: the command must never be the one
# asking (a captured command hides its own prompt and blocks on stdin forever).
[ "$(sed -n 1p "$CALLS")" = "backup --dry-run" ] && [ "$(sed -n 2p "$CALLS")" = "backup --yes" ] \
    && [ "$(wc -l < "$CALLS")" -eq 2 ] \
    && ok "backups create: prints the plan (--dry-run), THEN runs --yes (2 calls)" \
    || bad "backups create: $(cat "$CALLS")"
grep -qx "backup" "$CALLS" && bad "backups create still calls a bare backup (it would ask on stdin)" \
    || ok "backups create: no bare 'backup' call left (no hidden prompt)"

: > "$CALLS"
qset "__CREATE__" "fake-0.db"
confirm_action() { return 1; }
oc_backups_picker >/dev/null
[ "$(sed -n 1p "$CALLS")" = "backup --dry-run" ] && ! grep -qx "backup --yes" "$CALLS" \
    && ok "backups create declined: the plan is shown, nothing is created" \
    || bad "backups create declined: $(cat "$CALLS")"

: > "$CALLS"
confirm_action() { return 0; }
qset "__TOGGLE__" "__DELETE_ALL__"
oc_backups_picker >/dev/null
grep -qx "backups remove fake-0.db --yes" "$CALLS" && grep -qx "backups remove fake-4.db --yes" "$CALLS" && ok "backups delete-all removes every backup (confirmed)" || bad "backups delete-all: $(cat "$CALLS")"

: > "$CALLS"
confirm_action() { return 0; }
qset "__TOGGLE__" "__KEEP_NEWEST__"
oc_backups_picker >/dev/null
grep -qx "backups remove fake-3.db --yes" "$CALLS" && ! grep -qx "backups remove fake-4.db --yes" "$CALLS" && ok "backups delete olds removes all but the newest" || bad "backups keep-newest: $(cat "$CALLS")"

: > "$CALLS"
confirm_action() { return 1; }
qset "__TOGGLE__" "__DELETE_ALL__"
oc_backups_picker >/dev/null
[ ! -s "$CALLS" ] && ok "backups delete-all cancelled on 'n'" || bad "backups delete-all ran on 'n'"
confirm_action() { return 0; }

echo "== sessions browse picker (details-only: the generic picker in view mode) =="
reset
: > "$CALLS"; call_log
qset "ses_A0001"
oc_sessions_picker >/dev/null
grep -qx "info ses_A0001" "$CALLS" && ok "sessions browse dispatches info for the session" || bad "sessions details: $(cat "$CALLS")"
grep -q "sessions (details)" "$FZF_HIST" && ok "sessions picker is details-only" || bad "sessions title"

# Rows are recorded PER RENDER in their own file: the stub runs in a pipeline
# subshell, so the render number has to live in a FILE, not in a shell variable.
BROWSE_ROWS="$TMP/browse_rows.tsv"; BROWSE_HDR="$TMP/browse_header.txt"
browse_recorder() {
    printf '0' > "$TMP/bn"
    fzf() {
        local args="$*" item n h
        n=$(( $(cat "$TMP/bn") + 1 )); printf '%s' "$n" > "$TMP/bn"
        cat > "$BROWSE_ROWS.$n"
        h="$args"; h="${h#*--header=}"; h="${h%% --delimiter=*}"; printf '%s\n' "$h" > "$BROWSE_HDR.$n"
        if [ ! -s "$FZF_QUEUE_FILE" ]; then return 130; fi
        IFS= read -r item < "$FZF_QUEUE_FILE"
        tail -n +2 "$FZF_QUEUE_FILE" > "$FZF_QUEUE_FILE.tmp" && mv "$FZF_QUEUE_FILE.tmp" "$FZF_QUEUE_FILE"
        printf '%s\n' "$item"
        return 0
    }
}
TAB="$(printf '\t')"
# Render 1 pops the queued session (a detail row), render 2 hits ESC.
qset "ses_A0001"
browse_recorder
oc_sessions_picker >/dev/null
. "$FZF_PRISTINE"
BR="$BROWSE_ROWS.1"; BH="$BROWSE_HDR.1"
grep -q "__MAKE__$TAB" "$BR" && bad "browse screen offers a continue row" || ok "browse screen has no continue row"
printf '%s' "$BR" | grep -qE "^__(ALL|NONE)__$TAB" && bad "browse screen offers mark all/unmark all" || ok "browse screen has no bulk marks"
# NO symbol at all on a browse row: it is not a flow (nothing to open) and not a
# mark (nothing to select). A stray [>] or [x] would promise the wrong thing.
printf '%s' "$BR" | grep -qE "^ses_[A-Za-z0-9]+$TAB\\[" && bad "browse rows carry a symbol" || ok "browse rows carry no symbol"
# The ID is shown SHORTENED (ses_ prefix dropped) while the KEY stays complete:
# dropping the prefix from the key would break run_oced_tool info <id>.
grep -qE "^ses_A0001$TAB[A-Z0-9]" "$BR" && ok "browse rows show the id shortened" || bad "browse row id: $(grep -m1 '^ses_A0001' "$BR")"
# Toggles and the explicit 'show all' action lead the screen in a fixed order.
TOGPOS=$(grep -nE "^__(TOGGLE|TOGGLE_COMP|SUBS|REPORT_ALL)__$TAB" "$BR" | cut -d: -f1 | paste -sd, -)
[ "$TOGPOS" = "1,2,3,4" ] && ok "the four control rows lead the screen, in order" || bad "toggle rows at: $TOGPOS"
grep -q "__TOGGLE__$TAB" "$BR" && ok "browse screen has the order toggle" || bad "order toggle"
grep -q "__TOGGLE_COMP__$TAB" "$BR" && ok "browse screen has the compactions report toggle" || bad "compactions toggle"
grep -q "__SUBS__$TAB" "$BR" && ok "browse screen can hide subagents" || bad "subagents toggle"
grep -q "__REPORT_ALL__$TAB" "$BR" && ok "browse screen has an explicit show-all action" || bad "show all action"

# The order toggle MUST do something in view mode (it used to be a no-op there).
qset "__TOGGLE__"
browse_recorder
oc_sessions_picker >/dev/null
. "$FZF_PRISTINE"
grep -q "old first" "$BROWSE_HDR.2" && ok "the order toggle flips to old first in browse mode" \
    || bad "order toggle is a no-op: $(cat "$BROWSE_HDR.2" 2>/dev/null)"
# Hiding subagents really removes their rows (a hidden session cannot be read).
qset "__SUBS__"
browse_recorder
oc_sessions_picker >/dev/null
. "$FZF_PRISTINE"
# The toggle is selected on render 1, so its EFFECT is render 2.
NB=$(grep -cE "^ses_" "$BROWSE_ROWS.2")
[ "$NB" -eq 3 ] && ok "hiding subagents drops their rows ($NB left)" || bad "hidden subagents: $NB rows"
# A browse screen selects nothing, so its header must not talk about marks.
grep -qE "session\(s\)" "$BH" && ! grep -q "marked" "$BH" \
    && ok "browse header reports sessions, not a selection" || bad "browse header: $(cat "$BH")"
# A detail row RE-RENDERS the same screen instead of leaving it.
qset "ses_A0001"
browse_recorder
oc_sessions_picker >/dev/null
. "$FZF_PRISTINE"
[ -f "$BROWSE_ROWS.2" ] && grep -qE "^ses_.*$TAB[A-Z0-9]" "$BROWSE_ROWS.2" \
    && ok "a detail row re-renders the browse screen" || bad "browse re-render: $(ls "$TMP" | grep browse_rows)"
# Every session in the DB gets a row (the old hand-rolled list showed the same set).
[ "$(grep -cE "^ses_" "$BR")" -eq "$(session_rows | wc -l)" ] \
    && ok "browse lists every session" || bad "browse row count"

# The two REPORT toggles are exclusive to browse mode. In a SELECT picker they
# would be dead keys (nothing is reported there), so their absence there is part
# of the contract: the export and shrink pickers must not show them.
reset
probe_make() { return 0; }
declare -A pick_cfg=(
    [title]="probe" [header]="probe" [order]="updated-desc"
    [get_sub_ids]="oc_export_sub_ids"
    [make_action]="probe_make"
)
qset "__MAKE__"
browse_recorder
oc_session_picker pick_cfg >/dev/null
. "$FZF_PRISTINE"
SELROWS=$(cat "$BROWSE_ROWS.1")
printf '%s' "$SELROWS" | grep -q "__TOGGLE_COMP__$TAB" && bad "a select picker offers the compactions toggle" \
    || ok "a select picker has no compactions toggle"

printf '%s' "$SELROWS" | grep -q "__SUBS__$TAB" && ok "a select picker still offers subagents" \
    || bad "a select picker lost the subagents toggle"
printf '%s' "$SELROWS" | grep -q "__MAKE__$TAB" && ok "a select picker still offers its continue row" \
    || bad "a select picker lost __MAKE__"

echo "== sessions browse: compactions toggle and single/all mode =="
reset
: > "$CALLS"; call_log
# Toggle compactions OFF, then pick a session: the report must ask info to drop
# the digest block. A second `digest` call is the bug this replaced: `info`
# already ends with that block, so both printed it twice.
qset "__TOGGLE_COMP__" "ses_A0001"
oc_sessions_picker >/dev/null
grep -qx "info ses_A0001 --no-digest" "$CALLS" && ! grep -q "digest ses_" "$CALLS" \
    && ok "compactions hidden drops the digest block" || bad "compactions toggle: $(cat "$CALLS")"
# Same flow with compactions ON: the plain report keeps it.
: > "$CALLS"
qset "ses_A0001"
oc_sessions_picker >/dev/null
grep -qx "info ses_A0001" "$CALLS" && ! grep -q -- "--no-digest" "$CALLS" \
    && ok "compactions shown keeps the digest block" || bad "compactions on: $(cat "$CALLS")"
# 'show all sessions' is an EXPLICIT action (not a toggle that affects a click).
: > "$CALLS"
DUMP="$TMP/dump.txt"; : > "$DUMP"
qset "__REPORT_ALL__"
oc_sessions_picker > "$DUMP"
NVIS=$(session_rows | wc -l)
NDUMP=$(grep -c "^info ses_" "$CALLS")
[ "$NDUMP" -eq "$NVIS" ] && ok "reports all dumps every session ($NDUMP)" || bad "reports all: $NDUMP of $NVIS"
grep -q "^== Details of all sessions ==" "$DUMP" && ok "details of all prints the group header" \
    || bad "details of all has no group header"
# The group header is printed ONCE by the picker (it owns the iteration), not
# once per session by the callback, which cannot know the first call.
NH=$(grep -c "^== Details of all sessions ==" "$DUMP")
[ "$NH" -eq 1 ] && ok "the group header appears once ($NH)" || bad "group header x$NH"
# Regression: the header must not depend on a variable that only exists in the
# test harness. It once used $TMP and died with "TMP: unbound variable" in the
# real menu, where the suites cannot catch it because they DO define TMP.
( unset TMP; oc_sessions_view_one ses_A0001 >/dev/null 2>&1; oc_sessions_view_all ses_A0001 >/dev/null 2>&1 ) \
    && ok "the report callbacks need no harness variable" || bad "report callback depends on the harness"
# Hiding subagents narrows the dump too (the filters apply to the dump).
: > "$CALLS"; DUMP="$TMP/dump2.txt"; : > "$DUMP"
qset "__SUBS__" "__REPORT_ALL__"
oc_sessions_picker > "$DUMP"
[ "$(grep -c "^info ses_" "$CALLS")" -eq 3 ] \
    && ok "reports all honours hidden subagents" || bad "reports all with hidden subs: $(grep -c '^info ses_' "$CALLS")"
# The explicit all action does NOT change the behaviour of clicking a single row.
: > "$CALLS"
qset "ses_A0001"
oc_sessions_picker >/dev/null
N1=$(grep -c "^info ses_" "$CALLS")
[ "$N1" -eq 1 ] && ok "clicking a session row shows it once (single mode)" || bad "single row count: $N1"


echo "== export picker needs presets (no-pass manual fallback: guidance instead) =="
reset
: > "$CALLS"; call_log
confirm_action() { return 0; }
export OCED_PRESETS="$TMP/no-presets.json"
rm -f "$OCED_PRESETS"
GUIDE=$(oc_export_picker)
[ ! -s "$CALLS" ] && ok "no-presets export picker dispatches nothing" || bad "no-presets export picker ran a command: $(cat "$CALLS")"
printf '%s' "$GUIDE" | grep -q 'presets.json.example' && ok "no-presets export picker prints setup guidance" || bad "guidance: $GUIDE"
printf '%s' "$GUIDE" | grep -q 'export transcript|memory|digest' && ok "guidance points to the raw CLI as fallback" || bad "guidance CLI tip: $GUIDE"
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
   "share": {"product": "transcript", "json": true, "sanitize": true, "no_reasoning": true},
   "nosub": {"product": "transcript", "no_subagents": true}
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
# New helper tests. One phrase per LINE: no separator, no leading marker, because
# a joined string rendered as an expression (`+faithful JSON... · full tool
# outputs`) instead of a list of things the export adds.
[ "$(oc_annotate_flags "json=true,tool_output=full")" = "faithful JSON, raw and unfiltered
full tool outputs" ] \
    && ok "oc_annotate_flags json+tool_output, one phrase per line" || bad "annotate: [$(oc_annotate_flags "json=true,tool_output=full")]"
[ "$(oc_annotate_flags "sanitize=true,no_reasoning=true")" = "sanitize ON (safe prefixes: sk-, ghp_, AKIA, JWT, PEM…)
reasoning omitted" ] \
    && ok "oc_annotate_flags sanitize+no_reasoning" || bad "annotate: [$(oc_annotate_flags "sanitize=true,no_reasoning=true")]"
[ "$(oc_annotate_flags "cap=500")" = "cap 500 chars" ] && ok "oc_annotate_flags cap" || bad "annotate cap: [$(oc_annotate_flags "cap=500")]"
# oc_export_plan produces lines for a preset (check archive)
printf '%s\n' "$(oc_export_plan archive)" | grep -q '^faithful JSON, raw and unfiltered$' && ok "oc_export_plan archive notes raw JSON" || bad "plan archive: $(oc_export_plan archive)"
printf '%s\n' "$(oc_export_plan archive)" | grep -q '^full tool outputs$' && ok "oc_export_plan archive notes full outputs" || bad "plan archive: $(oc_export_plan archive)"
# No operator symbology anywhere in the block: no '+' marker, no ' · ' joiner,
# no em dash. Each thing is its own line of prose.
PLAN_SYM=$(oc_export_plan archive)
grep -qE '^[+*-] | · |—| +$' <<<"$PLAN_SYM" \
    && bad "the plan reintroduced operator symbology: [$(grep -nE '^[+*-] | · |—| +$' <<<"$PLAN_SYM" | head -2)]" \
    || ok "no '+' marker, no ' · ' joiner, no em dash in the plan"
# Every added flag is on its OWN line, so each one is assertable on its own.
for bit in "faithful JSON, raw and unfiltered" "full tool outputs" "touched files"; do
    grep -qxF "$bit" <<<"$PLAN_SYM" \
        && ok "its own line: $bit" || bad "not on its own line: $bit"
done
# share plan NO LONGER has sanitize (removed from preset)
printf '%s\n' "$(oc_export_plan share)" | grep -qv 'sanitize' && ok "oc_export_plan share has no sanitize" || bad "plan share should not have sanitize: $(oc_export_plan share)"
# transcript default plan
printf '%s\n' "$(oc_export_plan transcript)" | grep -qx 'Default options, no flags set' \
    && ok "oc_export_plan transcript default (a caption, not a parenthetical)" || bad "plan transcript: $(oc_export_plan transcript)"
# Notes are an ANNOTATION of the plan, not another thing it produces: they come
# from the preset's own flags, so they live in their own '-> Notes' block.
N_ARCH=$(oc_export_notes archive); N_NOTES=$(oc_export_notes notes)
grep -q 'faithful JSON keeps everything' <<<"$N_ARCH" \
    && ok "oc_export_notes archive reports the raw-JSON caveat" || bad "notes archive: $N_ARCH"
[ -n "$N_NOTES" ] && bad "a preset with no json/sanitize must have no notes: $N_NOTES" \
    || ok "a plan with nothing to warn about prints no notes"
# The notes must never leak into the product block (that was the old 'Notes:'
# line inside the tree, which read like a third product).
oc_export_plan archive | grep -q 'Notes' \
    && bad "the notes leaked back into the product block" || ok "the product block carries no notes"
export OCED_PRESETS="$TMP/no-presets.json"

echo "== exports picker (view / toggle to remove / bulk) ==
== exports rows: [>] create export first, toggle and bulk rows =="
reset
TAB=$(printf '\t')
ER_VIEW=$(oc_exports_rows view)
ER_REM=$(oc_exports_rows remove)
printf '%s\n' "$ER_VIEW" | head -1 | grep -qxF "__CREATE__${TAB}[>] create export" \
    && ok "exports rows have [>] create export first" || bad "exports create first: $(printf '%s\n' "$ER_VIEW" | head -1)"
printf '%s\n' "$ER_VIEW" | grep -qxF "__TOGGLE__${TAB}[*] view  ${ARROW}  remove" \
    && ok "exports rows have view/remove toggle" || bad "exports toggle: $(printf '%s\n' "$ER_VIEW" | grep __TOGGLE__)"
printf '%s\n' "$ER_REM" | grep -qxF "__TOGGLE__${TAB}[*] remove  ${ARROW}  view" \
    && ok "exports rows toggle flips in remove mode" || bad "exports toggle rem: $(printf '%s\n' "$ER_REM" | grep __TOGGLE__)"
printf '%s\n' "$ER_REM" | grep -qE "^__(DELETE_ALL|KEEP_NEWEST)__" && ok "exports remove mode has bulk rows" || bad "exports bulk rows"
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

# [>] details of all runs: ONE header + one `exports view` per run + ONE pause.
# The row and the per-row branch must run the SAME command, or the two screens
# can drift; that is why the assertion is on the dispatched calls.
printf '%s\n' "$ER_VIEW" | grep -qxF "__REPORT_ALL__${TAB}[>] details of all runs" \
    && ok "exports rows have the [>] details of all runs row" || bad "exports all-report row: $(printf '%s\n' "$ER_VIEW" | grep -c .)"
printf '%s\n' "$ER_REM" | grep -q '^__REPORT_ALL__' \
    && bad "exports REMOVE mode renders the all-report row" || ok "exports remove mode has no all-report row"
: > "$CALLS"; call_log
qset "__REPORT_ALL__"
oc_exports_picker > "$TMP/exports-view-all.txt"
grep -qx "exports view aaa" "$CALLS" && grep -qx "exports view bbb" "$CALLS" && grep -qx "exports view ccc" "$CALLS" \
    && ok "the all-report views every run, newest first" || bad "exports all-report calls: $(cat "$CALLS")"
[ "$(grep -c '^== Details of all export runs ==$' "$TMP/exports-view-all.txt")" -eq 1 ] \
    && ok "the all-report prints ONE header, not one per run" || bad "exports all-report header count"

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
qset "__NONE__" "ses_A0001" "__MAKE__" "__PRESET_notes"
oc_export_sessions_pick >/dev/null
grep -qx "export notes --sessions ses_A0001" "$CALLS" && ok "preset run overrides the selection with the session filter" || bad "preset session: $(cat "$CALLS")"

: > "$CALLS"
qset "__ALL__" "__MAKE__" "__PRESET_notes"
oc_export_sessions_pick >/dev/null
grep -qx "export notes" "$CALLS" && ok "preset ALL runs as configured (no override)" || bad "preset ALL: $(cat "$CALLS")"

echo "== export flow: ESC cancels without creating a run =="
reset
export OCED_PRESETS="$TMP/presets.json"
before=$(count_meta transcript)
FZF_FAIL="export (presets)"
qset "__ALL__" "__MAKE__"
oc_export_sessions_pick >/dev/null 2>&1
rc=$?
after=$(count_meta transcript)
[ "$rc" -ne 0 ] && ok "ESC cancels the preset picker ($rc)" || bad "ESC did not cancel"
[ "$before" -eq "$after" ] && ok "cancelled flow created no export" || bad "cancelled flow exported"

echo "== export flow: confirmation gates the run =="
reset
export OCED_PRESETS="$TMP/presets.json"
: > "$CALLS"; call_log
CONFIRME="$TMP/confirm.txt"
confirm_action() { printf '%s\n' "$1" >> "$CONFIRME"; return 1; }
before=$(count_meta transcript)
qset "__ALL__" "__MAKE__" "__PRESET_notes"
oc_export_sessions_pick >/dev/null
after=$(count_meta transcript)
[ -s "$CONFIRME" ] && grep -q "Start this export" "$CONFIRME" && ok "confirmation asked with the plan" || bad "no confirmation asked"
[ "$before" -eq "$after" ] && ok "declined confirmation -> no export" || bad "declined but exported"

echo "== export flow: real runs against the fake DB =="
reset
export OCED_PRESETS="$TMP/presets.json"
confirm_action() { return 0; }
before=$(count_meta transcript)
qset "__NONE__" "ses_A0001" "__MAKE__" "__PRESET_notes"
oc_export_sessions_pick >/dev/null
[ "$(count_meta transcript)" -eq $((before + 1)) ] && ok "preset flow exports the transcript" || bad "preset flow export transcript missing"
ME=$(newest_meta transcript)
jq -e '.sessions_selected[0] == "ses_A0001"' "$ME" >/dev/null && ok "real run applied the session filter" || bad "real run filter"

qset "__ALL__" "__MAKE__" "__PRESET_notes"
oc_export_sessions_pick >/dev/null
MA=$(newest_meta transcript)
jq -e '.sessions_selected == null' "$MA" >/dev/null && ok "preset ALL -> no filter" || bad "ALL filter not null"
jq -e '.sessions.total == 6' "$MA" >/dev/null && ok "ALL exported 6 sessions" || bad "ALL sessions count: $(jq '.sessions.total' "$MA")"

qset "__ALL__" "__MAKE__" "__PRESET_rag"
oc_export_sessions_pick >/dev/null
MEM=$(newest_meta memory); MEM="${MEM%/metadata.json}"
[ -f "$MEM/corpus.jsonl" ] && ok "preset flow wrote a corpus" || bad "preset flow corpus"
[ "$(wc -l < "$MEM/corpus.jsonl")" -eq 3 ] && ok "memory corpus: one line per root (3 roots)" || bad "memory corpus roots"
export OCED_PRESETS="$TMP/no-presets.json"

echo "== export sessions picker: hide-subagents toggle =="
reset
export OCED_PRESETS="$TMP/presets.json"
XROWS="$TMP/xrows.tsv"; XHEAD="$TMP/xheader.txt"
# Like the real stub (pops the queue, ESC on empty) but RECORDS every render in
# its own file, so a test can assert on the rows/header of any render.
xstub() {
    printf '0' > "$TMP/xn"
    fzf() {
        local args="$*" item n h
        n=$(( $(cat "$TMP/xn") + 1 )); printf '%s' "$n" > "$TMP/xn"
        cat > "$XROWS.$n"
        h="$args"; h="${h#*--header=}"; printf '%s\n' "$h" > "$XHEAD.$n"
        if [ ! -s "$FZF_QUEUE_FILE" ]; then return 130; fi
        IFS= read -r item < "$FZF_QUEUE_FILE"
        tail -n +2 "$FZF_QUEUE_FILE" > "$FZF_QUEUE_FILE.tmp" && mv "$FZF_QUEUE_FILE.tmp" "$FZF_QUEUE_FILE"
        printf '%s\n' "$item"
        return 0
    }
}
call_log; confirm_action() { return 0; }
rows_n() { grep '^ses_' "$XROWS.$1" | cut -f1 | sort | paste -sd, -; }

# Render 1 (nothing selected yet): the row exists, everything is shown.
qset "__SUBS__"
xstub
oc_export_sessions_pick >/dev/null 2>&1
grep -q 'subagents: shown' "$XROWS.1" && ok "the visibility row starts in the shown state" || bad "row state: $(grep '__SUBS__' "$XROWS.1")"
[ "$(grep -c '^ses_' "$XROWS.1")" = "6" ] && ok "shown: all 6 sessions get a row" || bad "rows shown: $(grep -c '^ses_' "$XROWS.1")"
[ "$(rows_n 1)" = "ses_A0001,ses_A0002,ses_A0003,ses_B0001,ses_B0002,ses_ORPHAN01" ] \
    && ok "shown lists every session" || bad "shown ids: $(rows_n 1)"
# Render 2 is the one after the __SUBS__ selection: subagents hidden.
grep -q 'subagents: hidden' "$XROWS.2" && ok "selecting the row flips it to hidden" || bad "row not flipped: $(grep '__SUBS__' "$XROWS.2")"
[ "$(grep -c '^ses_' "$XROWS.2")" = "3" ] && ok "hidden: only the 3 root sessions keep a row" || bad "rows hidden: $(grep -c '^ses_' "$XROWS.2")"
[ "$(rows_n 2)" = "ses_A0001,ses_B0001,ses_ORPHAN01" ] \
    && ok "hidden rows are exactly the roots (the orphan stays a root)" || bad "hidden rows: $(rows_n 2)"
grep -q 'subagents hidden, never exported' "$XHEAD.2" && ok "the status line states the subagents are not exported" || bad "header: $(cat "$XHEAD.2")"
# The shown header must NOT promise the hidden mode's cascade: a shown subagent
# has its own mark, so unmarking its session does not drop it.
grep -q 'does not remove them' "$XHEAD.1" && ok "the shown status line warns unmarking a session keeps its subagents" \
    || bad "shown header: $(cat "$XHEAD.1")"
# Flip back: the rows (and their marks) are restored.
reset; call_log; confirm_action() { return 0; }
qset "__SUBS__" "__SUBS__"
xstub
oc_export_sessions_pick >/dev/null 2>&1
grep -q 'subagents: shown' "$XROWS.3" && ok "the row flips back to shown" || bad "row not restored: $(grep '__SUBS__' "$XROWS.3")"
[ "$(grep -c '^ses_' "$XROWS.3")" = "6" ] && ok "re-showing restores the 3 subagent rows" || bad "rows restored: $(grep -c '^ses_' "$XROWS.3")"

# A hidden run: CSV expanded to include ALL subagents of marked roots (cascade).
reset; call_log; confirm_action() { return 0; }
: > "$CALLS"
qset "__SUBS__" "__MAKE__" "__PRESET_notes"
oc_export_sessions_pick >/dev/null
grep -q -- "--no-subagents" "$CALLS" && bad "a hidden run should NOT pin --no-subagents" || ok "a hidden run does NOT pin --no-subagents"
# CSV should include roots + their subagents (A1,A2,A3,B1,B2,orphan)
grep -oE -- "--sessions [^ ]+" "$CALLS" | cut -d' ' -f2 | tr ',' '\n' | sort | paste -sd, - \
    | grep -qx "ses_A0001,ses_A0002,ses_A0003,ses_B0001,ses_B0002,ses_ORPHAN01" \
    && ok "the CSV holds roots + their subagents (full cascade)" || bad "hidden csv: $(cat "$CALLS")"
# The cascade: un-marking a root while hidden leaves its subagents out entirely.
: > "$CALLS"
qset "__SUBS__" "__NONE__" "ses_A0001" "__MAKE__" "__PRESET_notes"
oc_export_sessions_pick >/dev/null
# Subagents of UNMARKED roots (B1, B2) should NOT appear.
grep -oE -- "--sessions [^ ]+" "$CALLS" | cut -d' ' -f2 | grep -q "ses_B0002" \
    && bad "a subagent of an unmarked root reached the CSV" || ok "unmarked root: its subagents never reach the CSV"
# With hide=1, the marked root's subagents ARE expanded into the CSV.
[ "$(grep -oE -- '--sessions [^ ]+' "$CALLS" | cut -d' ' -f2 | tr ',' '\n' | sort | paste -sd, -)" = "ses_A0001,ses_A0002,ses_A0003" ] \
    && ok "the cascade expands the marked root with its subagents" || bad "cascade csv: $(cat "$CALLS")"
# A SHOWN run is explicit: un-marking ONE root keeps its subagents selected, and
# the engine then exports them standalone — the case --no-orphan-subagents fixes.
: > "$CALLS"
qset "ses_A0001" "__MAKE__" "__PRESET_notes"
oc_export_sessions_pick >/dev/null
grep -oE -- "--sessions [^ ]+" "$CALLS" | cut -d' ' -f2 | grep -q "ses_A0002" \
    && ok "shown + unmarked root: its subagents stay selected (orphan export)" || bad "shown csv: $(cat "$CALLS")"
grep -q -- "--no-subagents" "$CALLS" && bad "a shown run pinned --no-subagents" || ok "a shown run does NOT pin --no-subagents"

# The confirm must NAME the standalone outcome before the gate, not just print a
# CSV that looks like a bug. ses_A0001's two subagents stay marked, its parent does
# not -> 2 standalone subagents.
reset; call_log; confirm_action() { return 0; }
: > "$CALLS"
qset "ses_A0001" "__MAKE__" "__PRESET_notes"
oc_export_sessions_pick > "$TMP/conf.txt" 2>&1
grep -q "2 subagent(s) will be exported standalone" "$TMP/conf.txt" \
    && ok "the confirm names the 2 subagents that export standalone" \
    || bad "no standalone note: $(grep -i 'Note:' "$TMP/conf.txt")"
grep -q -- "--no-orphan-subagents would drop them" "$TMP/conf.txt" \
    && ok "the note points at the flag that would drop them" || bad "no hint: $(grep -i 'Note:' "$TMP/conf.txt")"
# The ORPHAN is a root, not a standalone subagent: marked alone it exports as
# itself, so the note must stay silent. Catches a missing EXISTS guard.
reset; call_log; confirm_action() { return 0; }
: > "$CALLS"
qset "__NONE__" "ses_ORPHAN01" "__MAKE__" "__PRESET_notes"
oc_export_sessions_pick > "$TMP/conf.txt" 2>&1
grep -q "standalone" "$TMP/conf.txt" && bad "the orphan was reported as a standalone subagent" \
    || ok "the orphan (parent row gone) is a root, not a standalone subagent"
# Hidden mode: no subagent can reach the CSV, so there is nothing to warn about.
reset; call_log; confirm_action() { return 0; }
: > "$CALLS"
qset "__SUBS__" "__MAKE__" "__PRESET_notes"
oc_export_sessions_pick > "$TMP/conf.txt" 2>&1
grep -q "standalone" "$TMP/conf.txt" && bad "a hidden run warned about standalone subagents" \
    || ok "a hidden run never warns about standalone subagents"
# Everything marked: every parent is selected, so nothing is standalone.
reset; call_log; confirm_action() { return 0; }
: > "$CALLS"
qset "__MAKE__" "__PRESET_notes"
oc_export_sessions_pick > "$TMP/conf.txt" 2>&1
grep -q "standalone" "$TMP/conf.txt" && bad "an all-marked run warned about standalone subagents" \
    || ok "an all-marked run has no standalone subagent to warn about"
# The helper itself, against the live fake DB (roots A1/B1 + orphan, subs A2/A3/B2).
[ "$(oc_export_standalone_subs 'ses_A0002')" = "1" ] && ok "helper: a subagent without its parent counts" \
    || bad "helper lone subagent: $(oc_export_standalone_subs 'ses_A0002')"
[ "$(oc_export_standalone_subs 'ses_A0001,ses_A0002,ses_A0003')" = "0" ] && ok "helper: a closed set counts 0" \
    || bad "helper closed set: $(oc_export_standalone_subs 'ses_A0001,ses_A0002,ses_A0003')"
[ "$(oc_export_standalone_subs 'ses_ORPHAN01')" = "0" ] && ok "helper: the orphan never counts" \
    || bad "helper orphan: $(oc_export_standalone_subs 'ses_ORPHAN01')"
[ "$(oc_export_standalone_subs '')" = "0" ] && ok "helper: an empty CSV is 0" \
    || bad "helper empty: $(oc_export_standalone_subs '')"

# A real hidden run (no tool logger): 3 roots + 3 subagents on disk.
reset; confirm_action() { return 0; }
before=$(count_meta transcript)
qset "__SUBS__" "__MAKE__" "__PRESET_notes"
oc_export_sessions_pick >/dev/null
[ "$(count_meta transcript)" -eq $((before + 1)) ] && ok "hidden run created exactly one export" || bad "hidden run count"
MH=$(newest_meta transcript)
# Hidden mode now expands CSV to include all subagents of selected roots.
# The flag --no-subagents is NOT used; all 6 sessions are exported.
jq -e '.no_subagents == false and .sessions.total == 6
       and .sessions.subagents == 3' "$MH" >/dev/null \
    && ok "real hidden run exports 3 roots + 3 subagents (cascade)" || bad "hidden run: $(jq -c '{n:.no_subagents,h:.subagents_hidden,s:.sessions}' "$MH")"
MH="${MH%/metadata.json}"
# Subagents folder IS expected now (we export subagents in hidden mode).
[ -d "$(find "$MH" -type d -name subagents 2>/dev/null | head -1)" ] && ok "subagents/ folder exists in a hidden run (cascade exported)" || bad "subagents folder missing"
# The confirmation tells the user subagents are cascaded.
reset; confirm_action() { return 0; }
XOUT="$TMP/xconfirm.txt"
qset "__SUBS__" "__MAKE__" "__PRESET_notes"
oc_export_sessions_pick > "$XOUT" 2>&1
grep -q 'Menu adds: subagents cascaded from selected roots' "$XOUT" \
    && ok "the plan says subagents are cascaded" || bad "plan menu-adds row: $(grep 'Menu adds' "$XOUT")"
grep -qE '^Sessions: +the 3 sessions you marked' "$XOUT" \
    && ok "the plan says which sessions are selected" || bad "plan sessions row: $(grep 'Sessions:' "$XOUT")"
# The plan block is FLAT: product name at the left margin, its description
# BELOW it. No "Will produce:" label, no bullets, no leading indentation.
grep -q 'Will produce' "$XOUT" && bad "the old 'Will produce:' label is still there" \
    || ok "the plan dropped the 'Will produce:' label"
grep -qE '^transcript$' "$XOUT" \
    && ok "the product name sits at the left margin" || bad "plan product margin: $(grep -nE 'transcript' "$XOUT" | head -3)"
grep -qE '^[-*] ' "$XOUT" && bad "the plan grew a bullet again" || ok "the plan has no bullets"
# The 'notes' preset sets no json/sanitize, so the confirm must show NO
# '-> Notes' block at all (a note is an annotation, not a product). $XOUT above
# is exactly that preset, so it is already the negative case.
grep -q '^-> Notes' "$XOUT" \
    && bad "a note-less plan still printed '-> Notes'" \
    || ok "no '-> Notes' block when the plan has nothing to warn about"
# A preset that DOES set json gets the block, once, after the products.
# NOTE: grep PATTERN "$VAR" would treat the variable as a FILENAME; these
# guards pipe / use a here-string so the content is really the input.
CARC=$(oc_export_confirm archive "all 6 sessions in the DB" "nothing" "")
grep -q '^-> Notes' <<<"$CARC" \
    && ok "'-> Notes' marks the caveats as an annotation of the plan" || bad "missing '-> Notes' in: $(tr '\n' '|' <<<"$CARC")"
[ "$(grep -c '^-> Notes' <<<"$CARC")" = "1" ] \
    && ok "'-> Notes' appears exactly once" || bad "'-> Notes' repeated"
# The standalone-subagent note stays in the header rows.
CSUB=$(oc_export_confirm notes "the 2 sessions you marked" "nothing" "the preset drops every subagent")
grep -qE '^Note: +the preset drops every subagent' <<<"$CSUB" \
    && ok "the standalone-subagent note stays in the header rows" || bad "note row: [$(grep '^Note:' <<<"$CSUB")]"
# Scoped to the plan helper itself: $XOUT also holds the picker rows, which DO
# carry a leading space, so a blanket '^ +' over it proves nothing.
PLANOUT=$(oc_export_plan archive)
grep -qE '^ +' <<<"$PLANOUT" \
    && bad "the plan is not flush left: [$(grep -nE '^ +' <<<"$PLANOUT" | head -1)]" \
    || ok "the plan is flush left"
grep -qE '^[-*] |^ +' <<<"$PLANOUT" \
    && bad "the plan reintroduced a level or a bullet" || ok "the plan has no levels and no bullets"
# Nothing is hidden: the wrap may split a line but never a word, and no line
# runs past the fixed width.
# The contract is the LITERAL 72, not "$OCED_PLAN_WIDTH": comparing against the
# same knob would still pass if both the width and the expectation moved.
WIDEST=$(printf '%s\n' "$PLANOUT" | awk '{ n=length($0); if (n>m) m=n } END { print m+0 }')
[ "$WIDEST" -le 72 ] \
    && ok "every plan line fits the fixed width ($WIDEST <= 72)" || bad "plan line too long: $WIDEST"
[ "$OCED_PLAN_WIDTH" = "72" ] \
    && ok "the menu pins the plan width to 72" || bad "OCED_PLAN_WIDTH is $OCED_PLAN_WIDTH, not 72"
[ "$(python3 "$MOD/exportlib/plan.py" rows >/dev/null 2>&1; python3 -c "
import sys; sys.path.insert(0, '$MOD')
import importlib.util as u
spec = u.spec_from_file_location('pl', '$MOD/exportlib/plan.py'); m = u.module_from_spec(spec); spec.loader.exec_module(m)
print(m.PLAN_WIDTH)")" = "72" ] \
    && ok "plan.py PLAN_WIDTH default is 72" || bad "plan.py PLAN_WIDTH drifted"
printf '%s\n' "$PLANOUT" | grep -q 'RAG corpus in corpus.jsonl' \
    && ok "the plan keeps the full product intros (nothing hidden)" || bad "plan intro missing"
# The bits are emitted verbatim: every one of them is present, in order.
for bit in "faithful JSON, raw and unfiltered" "full tool outputs" "touched files"; do
    printf '%s\n' "$PLANOUT" | grep -qF "$bit" \
        && ok "the plan keeps the effective flag: $bit" || bad "plan flag missing: $bit"
done
# Every line of the description must be under its product, never beside it.
grep -qE '^Markdown conversation per session' "$XOUT" \
    && ok "the description goes BELOW its product" || bad "plan description placement"

echo "== the confirmation is honest about the EFFECTIVE selection =="
# 'clean' pins filter "Project Beta"; 'notes' pins no selection at all.
ALL_IDS="ses_A0001,ses_A0002,ses_A0003,ses_B0001,ses_B0002,ses_ORPHAN01"
# 1) everything marked + a preset that pins a filter -> the filter wins and the
#    confirmation says the marks are ignored (no silent surprise).
: > "$CALLS"; call_log
confirm_action() { return 0; }
oc_preset_run clean "" "$ALL_IDS" 0 > "$TMP/c1.txt" 2>&1
grep -qE '^Sessions: +filter "Project Beta" \(from the preset\) — your 6 marks are not used' "$TMP/c1.txt" \
    && ok "all marked + pinned filter: the preset wins and says so" || bad "c1: $(grep 'Sessions:' "$TMP/c1.txt")"
grep -qx 'export clean' "$CALLS" && ok "all marked passes no --sessions (the preset selection applies)" || bad "c1 cmd: $(cat "$CALLS")"
# 2) a partial selection always overrides the preset, and says it does.
: > "$CALLS"
oc_preset_run clean "" "ses_A0001,ses_B0001" 0 > "$TMP/c2.txt" 2>&1
grep -qE '^Sessions: +the 2 sessions you marked \(the menu overrides the preset: filter "Project Beta"\)' "$TMP/c2.txt" \
    && ok "partial marks override the preset filter, and the plan says so" || bad "c2: $(grep 'Sessions:' "$TMP/c2.txt")"
grep -qx 'export clean --sessions ses_A0001,ses_B0001' "$CALLS" && ok "partial marks pass --sessions" || bad "c2 cmd: $(cat "$CALLS")"
# 3) everything marked + a preset that pins nothing -> the marks really are all.
: > "$CALLS"
oc_preset_run notes "" "$ALL_IDS" 0 > "$TMP/c3.txt" 2>&1
grep -qE '^Sessions: +all 6 sessions in the DB' "$TMP/c3.txt" \
    && ok "all marked + no pinned selection = every session" || bad "c3: $(grep 'Sessions:' "$TMP/c3.txt")"
grep -qx 'export notes' "$CALLS" && ok "no --sessions when every session is marked" || bad "c3 cmd: $(cat "$CALLS")"
# 4) a preset that already drops subagents: the switch cannot widen it, and the
#    plan says that instead of letting the user toggle in vain.
#    Use ALL_IDS (roots + subagents) so "explicitly unmarked" doesn't trigger.
: > "$CALLS"
oc_preset_run nosub "" "$ALL_IDS" 0 > "$TMP/c4.txt" 2>&1
grep -q 'the preset drops every subagent' "$TMP/c4.txt" \
    && ok "a subagent-dropping preset is called out in the plan" || bad "c4: $(grep 'Note:' "$TMP/c4.txt")"
grep -qE '^Menu adds: +nothing' "$TMP/c4.txt" \
    && ok "the menu claims no flag when it adds none" || bad "c4 menu-adds: $(grep 'Menu adds' "$TMP/c4.txt")"
# The shrink picker is roots-only: it must NOT grow the visibility row.
reset; call_log; confirm_action() { return 0; }
: > "$CALLS"
qset "__NONE__" "ses_A0001" "__MAKE__" "__PRESET_quiet"
oc_shrink_sessions_pick >/dev/null
grep -q 'subagents' "$FZF_HIST" && bad "the shrink picker grew a subagents row" \
    || ok "the shrink picker keeps no subagents row"
. "$FZF_PRISTINE"   # hand the real stub back to the rest of the suite
export OCED_PRESETS="$TMP/no-presets.json"

echo "== export flow: snapshot: fresh -> backup alignment offer =="
reset
export OCED_PRESETS="$TMP/presets.json"
: > "$CALLS"; call_log
confirm_action() { return 0; }
[ "$(oc_plan_py snapshot snappy 2>/dev/null)" = "fresh" ] && ok "plan.py snapshot exposes the snapshot flag" || bad "plan snapshot"
qset "__ALL__" "__MAKE__" "__PRESET_snappy"
oc_export_sessions_pick >/dev/null
grep -qx "backup --dry-run" "$CALLS" && grep -qx "backup --yes" "$CALLS" \
    && ok "snapshot preset offers a fresh backup (plan + non-interactive run)" \
    || bad "snap backup offer: $(cat "$CALLS")"
grep -qx "export snappy" "$CALLS" && ok "snapshot preset exports after the fresh backup" || bad "snap export: $(cat "$CALLS")"

: > "$CALLS"
# With a backup present + aligned, the snapshot preset must NOT re-offer.
ALIGNED="$OCED_BACKUP_DIR"
mkdir -p "$ALIGNED"
SESSES=$(sqlite3 "file:$FAKE?mode=ro" "SELECT count(*) FROM session" 2>/dev/null)
MSGS=$(sqlite3 "file:$FAKE?mode=ro" "SELECT count(*) FROM message" 2>/dev/null)
MUTS=$(sqlite3 "file:$FAKE?mode=ro" "SELECT max(time_updated) FROM session" 2>/dev/null)
printf '{"backups": [{"sessions": %s, "messages": %s, "max_updated": %s}]}' "$SESSES" "$MSGS" "$MUTS" > "$ALIGNED/manifest.json"
qset "__ALL__" "__MAKE__" "__PRESET_snappy"
oc_export_sessions_pick >/dev/null
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
grep -q 'newest first' "$FZF_HIST" && ok "the sessions picker opens sorted newest first" || bad "order mode: $(grep -o '[0-9]*/[0-9]* marked . [a-z ]*' "$FZF_HIST" | head -2 | tr '\n' '/')"
grep -q 'old first' "$FZF_HIST" && ok "the order row switches to old first (status follows)" || bad "order toggle label missing"
grep -q 'oldest first' "$FZF_HIST" && bad "the long 'oldest first' label is back" || ok "the order states are short in both the row and the status"
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
grep -q '^__TOGGLE__.*\[\*\] newest first  →  old first$' "$TMP/sessions_rows.txt" \
    && ok "the order row advertises the current mode and the reverse sort" || bad "order row missing"
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

# the recency "mark-only" rows are gone (recency lives on the CLI/preset layer)
: > "$TMP/nobulk.txt"
qempty
( oc_fzf_sel() { tee -a "$TMP/nobulk.txt" | fzf "$@"; }
  oc_shrink_sessions_pick >/dev/null )
reset
for row in __LAST__ __OLDEST__ __DAYS__; do
    grep -q "^$row	" "$TMP/nobulk.txt" && bad "the sessions picker still offers $row" \
        || ok "the sessions picker dropped the $row row"
done
# what remains is only the two state rows (no recency, no counts)
[ "$(cut -f2 "$TMP/nobulk.txt" | grep -cE '^\[(un)?mark all\]$')" = "2" ] \
    && ok "the only bulk rows left are [mark all] / [unmark all]" || bad "bulk rows: $(cut -f2 "$TMP/nobulk.txt" | grep -E '^\[(un)?mark all\]$' | tr '\n' '/')"

# The symbol system is a CONTRACT, not a style: one bracket, and the token says
# what the row does. Guarded here so a new row cannot invent its own marker.
echo "== symbol system: [>] flow · [?] inspect · [*] toggle · [word] bulk =="
reset
: > "$TMP/symbols.txt"
( oc_fzf_sel() { tee -a "$TMP/symbols.txt" | fzf "$@"; }
  qempty
  # the *pickers* pipe their rows through oc_fzf_sel (captured by the stub);
  # the row producers are called directly, so their stdout IS the capture.
  { oc_backups_rows view; oc_backups_rows remove;
    oc_exports_rows view; oc_exports_rows remove;
    oc_shrinks_rows view; oc_shrinks_rows remove; } >> "$TMP/symbols.txt" 2>/dev/null
  # The sessions BROWSE is in the sample on purpose: its __REPORT_ALL__ row is
  # the same vocabulary as the exports/shrinks ones, and until now nothing
  # sampled it, so a [>]/[*] leak there could not fail this guard.
  oc_sessions_picker >/dev/null 2>&1
  oc_export_sessions_pick >/dev/null 2>&1
  oc_shrink_sessions_pick >/dev/null 2>&1 )
reset
ALLOWED='\[>\]|\[\?\]|\[\*\]|\[delete all\]|\[delete olds\]|\[mark all\]|\[unmark all\]|\[x\]|\[ \]'
SEEN=$(cut -f2- "$TMP/symbols.txt" | grep -oE '^\[[^]]*\]' | sort -u | tr '\n' ' ')
for tok in '[>]' '[?]' '[*]' '[delete all]' '[delete olds]' '[mark all]' '[x]'; do
    case "$SEEN" in *"$tok"*) ;; *) bad "the symbol sample never rendered a $tok row" ;; esac
done
ok "the symbol sample covers $SEEN"
BADTOKEN=$(cut -f2- "$TMP/symbols.txt" | grep -oE '^\[[^]]*\]' | sort -u | grep -vxE "$ALLOWED")
[ -z "$BADTOKEN" ] && ok "no invented bracket tokens ($(cut -f2- "$TMP/symbols.txt" | grep -oE '^\[[^]]*\]' | sort -u | tr '\n' ' '))" \
    || bad "unknown bracket tokens: $BADTOKEN"
BADFLOW=$(grep -F '[>]' "$TMP/symbols.txt" | cut -f1 | grep -vxE '__CREATE__|__SWAP__|__MAKE__|__REPORT_ALL__')
[ -z "$BADFLOW" ] && ok "[>] only on flow rows (create/swap/choose preset/all-report)" || bad "[>] leaked onto: $BADFLOW"
BADINSPECT=$(grep -F '[?]' "$TMP/symbols.txt" | cut -f1 | grep -vxE '__VERIFY__')
[ -z "$BADINSPECT" ] && ok "[?] only on inspect rows (verify)" || bad "[?] leaked onto: $BADINSPECT"
NOTOGGLE=$(grep -E '^__TOGGLE__|^__SUBS__' "$TMP/symbols.txt" | cut -f2- | grep -cvE '^\[\*\] ')
[ "$NOTOGGLE" = "0" ] && ok "every toggle row carries [*]" || bad "toggle rows without [*]: $NOTOGGLE"

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

# [>] details of all copies: ONE header + one `shrinks view` per copy + ONE pause.
printf '%s\n' "$ROWS" | grep -qxF "__REPORT_ALL__${TAB}[>] details of all copies" \
    && ok "shrinks rows have the [>] details of all copies row" || bad "shrinks all-report row missing"
ROWS_REM=$(oc_shrinks_rows remove)
printf '%s\n' "$ROWS_REM" | grep -q '^__REPORT_ALL__' \
    && bad "shrinks REMOVE mode renders the all-report row" || ok "shrinks remove mode has no all-report row"
: > "$CALLS"; call_log
qset "__REPORT_ALL__"
oc_shrinks_picker > "$TMP/shrinks-view-all.txt"
NCOPY=$(find "$SHR" -mindepth 1 -maxdepth 1 -type d | wc -l)
grep -c '^shrinks view ' "$CALLS" | grep -qx "$NCOPY" \
    && ok "the all-report views every copy ($NCOPY)" || bad "shrinks all-report calls ($(cat "$CALLS"))"
grep -qx "shrinks view 20251231-120000" "$CALLS" \
    && ok "the all-report covers the stale copy too, not just the newest" || bad "shrinks all-report skipped a copy"
[ "$(grep -c '^== Details of all shrink copies ==$' "$TMP/shrinks-view-all.txt")" -eq 1 ] \
    && ok "the all-report prints ONE header, not one per copy" || bad "shrinks all-report header count"

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

#-----------------------------------------------------------------------
# The id column in a LABEL is short; the row KEY stays the full id.
#-----------------------------------------------------------------------
echo "== session rows: short id in the label, full id as the key =="
reset
[ "$(oc_short_id ses_f72115a9b3c4d5e6f708192a3b4c5d6e)" = "f72115a_" ] \
    && ok "oc_short_id cuts ses_<32 hex> to f72115a_" || bad "oc_short_id: $(oc_short_id ses_f72115a9b3c4d5e6f708192a3b4c5d6e)"
[ "$(oc_short_id ses_A0001)" = "A0001_" ] \
    && ok "oc_short_id leaves a short id alone (plus the marker)" || bad "oc_short_id short id"
[ "$(oc_short_id f72115a9b3c4d5e6f708192a3b4c5d6e | wc -c)" -eq "$ID_LABEL_W" ] \
    && ok "the id column is a fixed ID_LABEL_W-wide field" || bad "id column not fixed width"

# BROWSE (details) and SELECT (shrink/export create) render the id through the
# SAME helper, so both rows must show the short form while the key keeps the
# real id: the CSV/marks/commands all depend on it.
reset
browse_recorder
qset "ses_A0001"
oc_sessions_picker >/dev/null
. "$FZF_PRISTINE"
grep -q "^ses_A0001${TAB}A0001_" "$BROWSE_ROWS.1" \
    && ok "browse row: full id as key, A0001_ as label" || bad "browse id label: $(grep -e A0001 -- "$BROWSE_ROWS.1")"

reset
browse_recorder
qset "__MAKE__"
oc_shrink_sessions_pick >/dev/null
. "$FZF_PRISTINE"
grep -q "^ses_B0001${TAB}\[x\] B0001_" "$BROWSE_ROWS.1" \
    && ok "shrink row: full id as key, B0001_ as label" || bad "shrink id label: $(grep -e B0001 -- "$BROWSE_ROWS.1")"
grep -q "^ses_ORPHAN01${TAB}\[x\] ORPHAN0_" "$BROWSE_ROWS.1" \
    && ok "the orphan root is shortened too" || bad "orphan id label: $(grep -e ORPHAN -- "$BROWSE_ROWS.1")"
# The short label must never leak into what the engine receives.
reset
export OCED_PRESETS="$TMP/presets.json"
: > "$CALLS"; call_log
confirm_action() { return 0; }   # accept the run: we only care about the CSV
qset "__NONE__" "ses_A0001" "__MAKE__" "__PRESET_notes"
oc_export_sessions_pick >/dev/null
grep -qx "export notes --sessions ses_A0001" "$CALLS" \
    && ok "the CSV still carries the FULL id, not the label" || bad "short id leaked into the CSV: $(cat "$CALLS")"
export OCED_PRESETS="$TMP/no-presets.json"

#-----------------------------------------------------------------------
# Navigation contract: a report/pause NEVER leaves the picker on Enter
# (it redraws the list), and ESC at the pause closes the submenu.
# run_menu has no back-stack, so a picker that RETURNS lands on the root.
#-----------------------------------------------------------------------
echo "== navigation: Enter after a report stays in the list, ESC leaves the submenu =="
grep -q 'Enter: back to the list' "$MOD/menu/core.sh" \
    && ok "menu_pause advertises 'Enter: back to the list · Esc: main menu'" || bad "menu_pause label"

# Own fixtures: the sections above REMOVE backups and shrink runs for real, so
# this one rebuilds both manifests instead of trusting the leftovers.
nav_fixtures() {
    mkdir -p "$OCED_BACKUP_DIR"
    jq -n '{backups: [
        {"file":"nav-0.db","date":"2026-01-01T00:00:00Z","size":100,"sessions":1,"messages":2,"sha256":"a"},
        {"file":"nav-1.db","date":"2026-01-02T00:00:00Z","size":100,"sessions":1,"messages":2,"sha256":"b"},
        {"file":"nav-2.db","date":"2026-01-03T00:00:00Z","size":100,"sessions":1,"messages":2,"sha256":"c"}
    ]}' > "$OCED_BACKUP_DIR/manifest.json"
    mkdir -p "$OCED_BACKUP_DIR/shrink/nav-0" "$OCED_BACKUP_DIR/shrink/nav-1"
    for d in nav-0 nav-1; do
        jq -n '{criteria:"keep 10", sessions:{total:6,kept:2,deleted:4,max_updated:0},
                size:{before:100000,after:30000}, stripped_reasoning:0, date:"2026-01-01T00:00:00Z"}' \
            > "$OCED_BACKUP_DIR/shrink/$d/shrink.json"
        : > "$OCED_BACKUP_DIR/shrink/$d/opencode.shrunk.db"
    done
}
# The fzf stub pops ONE selection per render, so a picker that survives the
# pause must consume the next queued row too. A picker that RETURNS after the
# pause (the old bug) would dispatch only the first one.
reset; nav_fixtures
: > "$CALLS"; call_log
qset "aaa" "bbb"
oc_exports_picker >/dev/null
grep -qx "exports view aaa" "$CALLS" && grep -qx "exports view bbb" "$CALLS" \
    && ok "exports: Enter after a report redraws the exports list" || bad "exports view stays: $(cat "$CALLS")"

reset; nav_fixtures
: > "$CALLS"; call_log
qset "nav-0.db" "nav-1.db"
oc_backups_picker >/dev/null
grep -qx "backups view nav-0.db" "$CALLS" && grep -qx "backups view nav-1.db" "$CALLS" \
    && ok "backups: Enter after a report redraws the backups list" || bad "backups view stays: $(cat "$CALLS")"

reset; nav_fixtures
: > "$CALLS"; call_log
qset "nav-1" "nav-0"
oc_shrinks_picker >/dev/null
grep -qx "shrinks view nav-1" "$CALLS" && grep -qx "shrinks view nav-0" "$CALLS" \
    && ok "shrinks: Enter after a report redraws the shrinks list" || bad "shrinks view stays: $(cat "$CALLS")"

# ESC at the pause: the picker closes the submenu (rc 0) WITHOUT redrawing, so
# the queued second row is never consumed.
reset; nav_fixtures
: > "$CALLS"; call_log
menu_pause() { return 2; }
qset "aaa" "bbb"
oc_exports_picker >/dev/null
rc=$?
[ "$rc" -eq 0 ] && [ "$(wc -l < "$FZF_HIST")" -eq 1 ] && ! grep -q 'exports view bbb' "$CALLS" \
    && ok "exports: ESC at the pause closes the submenu (no redraw)" \
    || bad "exports ESC pause (rc=$rc, renders=$(wc -l < "$FZF_HIST")): $(cat "$CALLS")"

reset; nav_fixtures
: > "$CALLS"; call_log
menu_pause() { return 2; }
qset "nav-0.db" "nav-1.db"
oc_backups_picker >/dev/null
rc=$?
[ "$rc" -eq 0 ] && [ "$(wc -l < "$FZF_HIST")" -eq 1 ] && ! grep -q 'nav-1' "$CALLS" \
    && ok "backups: ESC at the pause closes the submenu (no redraw)" \
    || bad "backups ESC pause (rc=$rc, renders=$(wc -l < "$FZF_HIST")): $(cat "$CALLS")"

reset; nav_fixtures
: > "$CALLS"; call_log
menu_pause() { return 2; }
qset "nav-1" "nav-0"
oc_shrinks_picker >/dev/null
rc=$?
[ "$rc" -eq 0 ] && [ "$(wc -l < "$FZF_HIST")" -eq 1 ] && ! grep -q 'shrinks view nav-0' "$CALLS" \
    && ok "shrinks: ESC at the pause closes the submenu (no redraw)" \
    || bad "shrinks ESC pause (rc=$rc, renders=$(wc -l < "$FZF_HIST")): $(cat "$CALLS")"

# Same rule for the all-details report: it pauses ONCE, and its ESC closes the
# submenu like any other report. It returned 0 unconditionally at first, so an
# ESC silently redrew the list — the bug the pause-rc rule exists to prevent.
reset; nav_fixtures
: > "$CALLS"; call_log
menu_pause() { return 2; }
qset "__REPORT_ALL__" "nav-0"
oc_shrinks_picker >/dev/null
rc=$?
grep -qx "shrinks view nav-0" "$CALLS" || grep -qx "shrinks view nav-1" "$CALLS"
seen=$?
[ "$rc" -eq 0 ] && [ "$(wc -l < "$FZF_HIST")" -eq 1 ] && [ "$seen" -eq 0 ] && ! grep -qx 'shrinks view __REPORT_ALL__' "$CALLS" \
    && ok "shrinks all-report: ESC at its single pause closes the submenu" \
    || bad "shrinks all-report ESC (rc=$rc, renders=$(wc -l < "$FZF_HIST")): $(cat "$CALLS")"

reset; nav_fixtures
: > "$CALLS"; call_log
menu_pause() { return 2; }
qset "__REPORT_ALL__" "aaa"
oc_exports_picker >/dev/null
rc=$?
[ "$rc" -eq 0 ] && [ "$(wc -l < "$FZF_HIST")" -eq 1 ] \
    && ok "exports all-report: ESC at its single pause closes the submenu" \
    || bad "exports all-report ESC (rc=$rc, renders=$(wc -l < "$FZF_HIST")): $(cat "$CALLS")"

echo "== navigation: a finished create/swap pauses, then returns to its own list =="
# The pause (and its ESC) belong to the frame that OWNS the list, so a deep
# wizard only reports "did it run?" through its rc: 0 = ran (pause), 130 = ESC
# out of the wizard (no pause). Each create pause carries its OWN label
# ("Export"/"New backup"/"Shrink copy") so it can never be confused with the
# report pause of the list it returns to.
reset; nav_fixtures
: > "$CALLS"; call_log
menu_pause() { printf 'pause:%s\n' "$1" >> "$CALLS"; return 0; }
oc_export_picker() { printf 'flow:ran\n' >> "$CALLS"; return "${EXPORT_RC:-0}"; }
qset "__CREATE__" "aaa"
oc_exports_picker >/dev/null
grep -qx "flow:ran" "$CALLS" && grep -qx "pause:Export" "$CALLS" && grep -qx "exports view aaa" "$CALLS" \
    && ok "export: a finished run pauses and lands back in the exports list" || bad "export create nav: $(cat "$CALLS")"

reset; nav_fixtures
: > "$CALLS"; call_log
menu_pause() { printf 'pause:%s\n' "$1" >> "$CALLS"; return 0; }
oc_export_picker() { printf 'flow:ran\n' >> "$CALLS"; return "${EXPORT_RC:-0}"; }
EXPORT_RC=130
qset "__CREATE__" "aaa"
oc_exports_picker >/dev/null
! grep -qx "pause:Export" "$CALLS" && grep -qx "exports view aaa" "$CALLS" \
    && ok "export: ESC out of the wizard skips the pause and stays in the list" || bad "export ESC nav: $(cat "$CALLS")"

reset; nav_fixtures
: > "$CALLS"; call_log
oc_export_picker() { printf 'flow:ran\n' >> "$CALLS"; return 0; }
menu_pause() { return 2; }
qset "__CREATE__" "aaa"
oc_exports_picker >/dev/null
rc=$?
[ "$rc" -eq 0 ] && ! grep -qx "exports view aaa" "$CALLS" \
    && ok "export: ESC at the post-run pause closes the submenu" || bad "export pause ESC (rc=$rc): $(cat "$CALLS")"

reset; nav_fixtures
: > "$CALLS"; call_log
confirm_action() { return 0; }
menu_pause() { printf 'pause:%s\n' "$1" >> "$CALLS"; return 0; }
qset "__CREATE__" "nav-0.db"
oc_backups_picker >/dev/null
grep -qx "backup --dry-run" "$CALLS" && grep -qx "backup --yes" "$CALLS" \
    && grep -qx "pause:New backup" "$CALLS" && grep -qx "backups view nav-0.db" "$CALLS" \
    && ok "backups: a created backup pauses, then stays in the list" || bad "backups create nav: $(cat "$CALLS")"

reset; nav_fixtures
: > "$CALLS"; call_log
menu_pause() { printf 'pause:%s\n' "$1" >> "$CALLS"; return 0; }
oc_pick_shrink() { printf 'flow:ran\n' >> "$CALLS"; return "${SHRINK_RC:-0}"; }
qset "__CREATE__" "nav-1"
oc_shrinks_picker >/dev/null
grep -qx "flow:ran" "$CALLS" && grep -qx "pause:Shrink copy" "$CALLS" && grep -qx "shrinks view nav-1" "$CALLS" \
    && ok "shrink: a finished run pauses, then stays in the shrinks list" || bad "shrink create nav: $(cat "$CALLS")"

reset; nav_fixtures
: > "$CALLS"; call_log
menu_pause() { printf 'pause:%s\n' "$1" >> "$CALLS"; return 0; }
oc_pick_shrink() { printf 'flow:ran\n' >> "$CALLS"; return 130; }
qset "__CREATE__" "nav-1"
oc_shrinks_picker >/dev/null
! grep -qx "pause:Shrink copy" "$CALLS" && grep -qx "shrinks view nav-1" "$CALLS" \
    && ok "shrink: ESC out of the wizard skips the pause" || bad "shrink ESC nav: $(cat "$CALLS")"

# The swap already owned its pause; its rc now travels to __SWAP__ so an ESC
# there closes the submenu instead of silently redrawing the list.
reset; nav_fixtures
: > "$CALLS"; call_log
oced_shrink_swap() { printf 'swap:%s\n' "$*" >> "$CALLS"; }
menu_pause() { return 2; }
qset "__SWAP__" "nav-0"
printf 'confirm\n' | oc_shrinks_picker >/dev/null 2>&1
rc=$?
grep -q 'swap:' "$CALLS" && [ "$rc" -eq 0 ] \
    && ok "swap: ESC at the post-swap pause closes the submenu" || bad "swap pause ESC (rc=$rc): $(cat "$CALLS")"

echo "== run_oced_tool must STREAM: a captured command hides its own questions =="
# The bug this section exists for: run_oced_tool used `out=$(dispatcher 2>&1)`,
# so `backup`'s "Create this backup? [y/N]" went into the capture buffer, the
# command blocked on read, and the menu showed NOTHING until a blind keypress
# arrived — which, being empty, cancelled the backup. run_oced_tool now tees.
# No behavioural test in this suite can see it: run_oced_tool is stubbed here, and
# the real prompt is behind `[ -t 0 ]`. Hence a structural guard + a pty test.
CAPTURE=$(grep -n 'out=\$(bash "\$OC_DISPATCHER"' "$MOD/menu/core.sh")
[ -z "$CAPTURE" ] && ok "run_oced_tool does not capture the dispatcher output" \
    || bad "run_oced_tool captures the dispatcher output again (line $(cut -d: -f1 <<<"$CAPTURE")): prompts would be invisible"

BARE=$(grep -rn 'run_oced_tool backup\s*\($\|;\)' "$MOD/menu/" | grep -v -- '--yes\|--dry-run')
[ -z "$BARE" ] && ok "no bare 'run_oced_tool backup' in the menu (it would ask on stdin)" \
    || bad "menu calls a bare backup: $BARE"

if ! command -v script >/dev/null 2>&1; then
    echo "  [SKIP] pty streaming test: util-linux 'script' not available"
else
    # A pty is the ONLY way to test this: without a TTY the fake dispatcher cannot
    # ask anything, and with a pipe the capture bug is invisible. `script -t<file>`
    # records WHEN each output chunk reached the terminal, so streaming (first
    # chunk at ~0s) is distinguishable from capturing (everything at exit, ~2s).
    PTY_TS="$TMP/pty.ts"; PTY_TM="$TMP/pty.timing"
    printf '#!/usr/bin/env bash\necho "PTY_MARK_1 plan visible"\nread -r a\necho "PTY_GOT:$a"\n' > "$TMP/fake-dispatcher"
    chmod +x "$TMP/fake-dispatcher"
    printf '#!/usr/bin/env bash\nset -uo pipefail\nexport OCED_DISPATCHER=%s\n. %s\nrun_oced_tool probe\n' \
        "$TMP/fake-dispatcher" "$MOD/menu/core.sh" > "$TMP/pty-probe.sh"
    chmod +x "$TMP/pty-probe.sh"
    rm -f "$PTY_TS" "$PTY_TM"
    ( sleep 2; printf 'y\n' ) | script -q -t"$PTY_TM" -e -c "$TMP/pty-probe.sh" "$PTY_TS" >/dev/null 2>&1
    FIRST=$(awk 'NR==1{print $1; exit}' "$PTY_TM" 2>/dev/null)
    GOT=$(grep -c 'PTY_GOT:y' "$PTY_TS" 2>/dev/null)
    if [ -n "$FIRST" ] && [ "${FIRST%.*}" -lt 1 ] 2>/dev/null && [ "$GOT" -eq 1 ]; then
        ok "run_oced_tool streams: the plan reached the screen at ${FIRST}s, before the answer"
    else
        bad "run_oced_tool does NOT stream (first chunk at ${FIRST:-?}s, got=$GOT): the question is invisible"
    fi
fi

echo ""
echo "RESULT: $pass OK / $fail FAIL"
[ "$fail" -eq 0 ]