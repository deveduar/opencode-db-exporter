#!/usr/bin/env bash
# menu_flow.sh — logic tests for the fzf menu (fzf is stubbed; no TTY needed).
# Usage: tests/menu_flow.sh
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
bash "$TESTS_DIR/make_fake_db.sh" "$FAKE" >/dev/null

. "$MOD/common.sh"
. "$MOD/export.sh"
. "$MOD/exports.sh"

pass=0; fail=0
ok() { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }
# reset → restore real function definitions (undo test overrides)
reset() { . "$MOD/menu.sh"; }
count_meta() { find "$OUT" -path "*/$1/*" -name metadatos.json 2>/dev/null | wc -l; }
newest_meta() { find "$OUT" -path "*/$1/*" -name metadatos.json -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-; }

# ---- fzf stub: keys off --prompt, drains stdin (like real fzf) ----
fzf() {
    local args="$*"
    cat >/dev/null
    if [ -n "${FZF_FAIL:-}" ] && [[ "$args" == *"$FZF_FAIL"* ]]; then
        return 1
    fi
    case "$args" in
        *"Export recipes"*)     [ -n "${FZF_RECIPES:-}" ] && printf '%s\n' "$FZF_RECIPES"; return 0 ;;
        *"Sessions to export"*|*"Session details"*|*"Compactions of session"*)
                               [ -n "${FZF_SESSION:-}" ] && printf '%s' "$FZF_SESSION"; return 0 ;;
    esac
    return 1
}
. "$MOD/menu.sh"

echo "== session picker excludes the sqlite separator row =="
ROWS=$(session_rows)
printf '%s' "$ROWS" | grep -qE '^[[:space:]]*-' && bad "separator row leaked into picker" || ok "separator rows excluded"
printf '%s' "$ROWS" | grep -q '^ses_' && ok "session rows present" || bad "session rows missing"

echo "== ESC cancels the export flow =="
reset
before=$(count_meta full)
FZF_FAIL="Export recipes" oc_export_flow >/dev/null 2>&1
rc=$?
after=$(count_meta full)
[ "$rc" -ne 0 ] && ok "ESC returns non-zero ($rc)" || bad "ESC did not cancel"
[ "$before" -eq "$after" ] && ok "ESC created no export" || bad "ESC created an export"

echo "== each selected recipe becomes its own export run =="
reset
before_full=$(count_meta full); before_text=$(count_meta text-only)
FZF_RECIPES=$'full (default)|full|\ntext-only (default)|text-only|' \
FZF_SESSION="ses_A0001  Proyecto Alfa  2026-09-10 00:00:00  build" \
    oc_export_flow >/dev/null
[ "$(count_meta full)" -eq $((before_full + 1)) ] && ok "recipe full exported" || bad "recipe full missing"
[ "$(count_meta text-only)" -eq $((before_text + 1)) ] && ok "recipe text-only exported" || bad "recipe text-only missing"
ME=$(newest_meta full)
jq -e '.filter == "ses_A0001"' "$ME" >/dev/null && ok "recipe applied the session filter" || bad "recipe filter"

echo "== ALL sessions loops info over every session =="
reset
CALLS="$TMP/calls.txt"; : > "$CALLS"
run_oced_tool() { printf '%s\n' "$*" >> "$CALLS"; }
FZF_SESSION="ALL SESSIONS (no filter)" oc_pick_info >/dev/null
n_calls=$(wc -l < "$CALLS")
n_sessions=$(session_rows | wc -l)
[ "$n_calls" -eq "$n_sessions" ] && ok "info ran for all $n_calls sessions" || bad "info loop: $n_calls vs $n_sessions"

echo "== ALL sessions export means no filter =="
reset
FZF_RECIPES="full (default)|full|" FZF_SESSION="ALL SESSIONS (no filter)" \
    oc_export_flow >/dev/null
MA=$(newest_meta full)
jq -e '.filter == null' "$MA" >/dev/null && ok "no filter applied for ALL" || bad "ALL filter not null"
jq -e '.sessions.total == 6' "$MA" >/dev/null && ok "ALL exported 6 sessions" || bad "ALL sessions count: $(jq '.sessions.total' "$MA")"

echo ""
echo "RESULT: $pass OK / $fail FAIL"
[ "$fail" -eq 0 ]