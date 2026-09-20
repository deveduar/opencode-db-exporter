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
ok() { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }
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

echo "== status =="
grep_run "Sessions:" status && ok "status ready" || bad "status"
grep_run "Tables:" status && ok "status reads tables" || bad "status tables"

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

echo "== deps --check =="
grep_run "All core dependencies present." deps --check && ok "deps --check" || bad "deps --check"

echo "== export text-only =="
grep_run "Exported" export text-only && ok "text-only export" || bad "text-only export"
CONTENT=$(cat "$(last_transcript text-only 'Proyecto Alfa')")
echo "$CONTENT" | grep -q "**Tool:**" && bad "text-only contains tool calls" || ok "text-only no tools"
echo "$CONTENT" | grep -q "Primero pienso" && bad "text-only contains reasoning" || ok "text-only no reasoning"

echo "== export no-calls =="
run export no-calls >/dev/null
SC=$(cat "$(last_transcript no-calls 'Proyecto Alfa')")
echo "$SC" | grep -q "Primero pienso" && ok "no-calls keeps reasoning" || bad "no-calls reasoning lost"
echo "$SC" | grep -q "**Tool:**" && bad "no-calls contains tools" || ok "no-calls no tools"

echo "== export full (truncation + compaction markers + diffs) =="
run export full --mark-compactions --summary-diffs >/dev/null
FC=$(cat "$(last_transcript full 'Proyecto Alfa')")
echo "$FC" | grep -q "**Tool:**" && ok "full with tools" || bad "full no tools"
echo "$FC" | grep -q "Context compaction" && ok "compaction marker" || bad "compaction marker"
echo "$FC" | grep -q "Summary of changes" && ok "summary diffs" || bad "summary diffs"

echo "== long output truncation =="
FT=$(cat "$(last_transcript full 'Proyecto Beta')")
echo "$FT" | grep -q "truncated:" && ok "long output truncated" || bad "output not truncated"

echo "== compactions show (digest) =="
CS=$(run compactions ses_A0001 show last)
printf '%s' "$CS" | grep -q "Total: 1" && ok "compactions total" || bad "compactions total"
printf '%s' "$CS" | grep -q "DIGEST_A" && ok "compactions show last digest" || bad "compactions show digest"

echo "== export compactions profile =="
run export compactions --filter ses_A0001 >/dev/null
CC=$(cat "$(last_transcript compactions 'Proyecto Alfa')")
echo "$CC" | grep -q "DIGEST_A" && ok "compactions digest exported" || bad "compactions profile digest"
echo "$CC" | grep -q "\*\*Tool:\*\*" && bad "compactions profile has tools" || ok "compactions profile no tools"

echo "== export all (4 profiles in one run) =="
ALLOG=$(run export all --filter ses_A0001)
printf '%s' "$ALLOG" | grep -q "Exported" && ok "export all runs" || bad "export all"
ALDIR=$(printf '%s' "$ALLOG" | sed -n 's/^.* to: \(.*\)$/\1/p' | head -1)
ALSTAMP=$(basename "$(dirname "$ALDIR")")
ALL4=1
for p in full no-calls text-only compactions; do
    [ -f "$OUT/$ALSTAMP/$p/metadatos.json" ] || ALL4=0
done
[ "$ALL4" -eq 1 ] && ok "export all = 4 profiles in one run" || bad "export all profiles ($ALSTAMP)"
jq -e '.tool_output == "full" and .summary_diffs == true' "$OUT/$ALSTAMP/full/metadatos.json" >/dev/null \
    && ok "export all maximal flags" || bad "export all flags"
grep -rq "DIGEST_A" "$OUT/$ALSTAMP/compactions" && ok "export all compactions digest" || bad "export all digest"
ALROW=$(run exports list | awk -v s="$ALSTAMP" '$0 ~ s {print; exit}')
ALLP=1
for p in full no-calls text-only compactions; do
    printf '%s' "$ALROW" | grep -q "$p" || ALLP=0
done
[ "$ALLP" -eq 1 ] && ok "exports list aggregates profiles" || bad "exports list aggregate"

echo "== filter =="
run export text-only --filter 'Proyecto Beta' >/dev/null
ME=$(last_meta text-only)
jq -e '.filter == "Proyecto Beta"' "$ME" >/dev/null && ok "filter applied in metadata" || bad "filter metadata"
jq -e '.sessions.roots == 1' "$ME" >/dev/null && ok "filter counts in metadata" || bad "filter counts"

echo "== sub inline / omit / separate =="
run export text-only --sub inline >/dev/null
INL=$(last_transcript text-only 'Proyecto Alfa')
grep -q "Subagent" "$INL" && ok "sub inline included" || bad "sub inline"
run export text-only --sub omit >/dev/null
OMIT=$(last_meta text-only)
jq -e '.sessions.subagents == 0' "$OMIT" >/dev/null && ok "sub omit = 0 subagents" || bad "sub omit: $(jq '.sessions.subagents' "$OMIT")"
run export text-only --sub separate >/dev/null
SEP=$(last_meta text-only)
jq -e '.sessions.subagents == 3' "$SEP" >/dev/null && ok "sub separate = 3 subagents" || bad "sub separate: $(jq '.sessions.subagents' "$SEP")"

echo "== index.md present and with links =="
run export full --mark-compactions >/dev/null
IX=$(last_meta full); IX="${IX%/metadatos.json}/index.md"
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

echo ""
echo "RESULT: $pass OK / $fail FAIL"
[ "$fail" -eq 0 ]