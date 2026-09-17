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
grep_run() { # $1=patrón, resto=arg del CLI: captura la salida antes de grep (evita SIGPIPE/pipefail)
    local pat="$1"; shift
    local out; out=$(run "$@")
    printf '%s' "$out" | grep -q "$pat"
}
last_transcript() { # $1=perfil $2=título (más reciente por mtime)
    find "$OUT" -path "*/$1/*" -name "*$2*.md" -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-
}
last_meta() { # $1=perfil (más reciente por mtime)
    find "$OUT" -path "*/$1/*" -name metadatos.json -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-
}

echo "== status =="
S=$(run status); grep_run "Sesiones:" status && ok "status listo" || bad "status"
grep_run "Tablas:" status && ok "status lee tablas" || bad "status tablas"

echo "== list =="
L=$(run list --root); grep_run "Proyecto" list --root && ok "list --root" || bad "list --root"
LS=$(run list --sub --info); grep_run "ORPHAN" list --sub --info && ok "list --sub incluye huérfana" || bad "list --sub"
LF=$(run list --filter 'Proyecto Beta'); grep_run "Proyecto Beta" list --filter 'Proyecto Beta' && ok "list --filter" || bad "list --filter"

echo "== info / compactaciones =="
I=$(run info ses_A0001); grep_run "Compactaciones" info ses_A0001 && ok "info" || bad "info"
printf "%s" "$I" | grep -q "1$" && ok "info cuenta 1 compactación" || bad "info recuento"
C=$(run compactaciones ses_A0001); printf "%s" "$C" | grep -vq "sin compactaciones" && ok "compactaciones detectadas" || bad "compactaciones"

echo "== backup =="
B=$(run backup); printf "%s" "$B" | grep -qE "opencode-[0-9-]+\.db\.gz" && ok "backup comprimido" || bad "backup"
grep_run "opencode-" backups list && ok "backups list" || bad "backups list"
FNAME=$(run backups list | grep -oE 'opencode-[0-9-]+\.db\.gz' | head -1)
grep_run "OK" backups verify "$FNAME" && ok "backups verify" || bad "backups verify"
grep_run "Alineado" status && ok "status alineado tras backup" || bad "alignment"

echo "== export solo-texto =="
grep_run "Exportado" export solo-texto && ok "solo-texto export" || bad "solo-texto export"
CONTENT=$(cat "$(last_transcript solo-texto 'Proyecto Alfa')")
echo "$CONTENT" | grep -q "**Tool:**" && bad "solo-texto contiene tool calls" || ok "solo-texto sin tools"
echo "$CONTENT" | grep -q "Primero pienso" && bad "solo-texto contiene reasoning" || ok "solo-texto sin reasoning"

echo "== export sin-calls =="
run export sin-calls >/dev/null
SC=$(cat "$(last_transcript sin-calls 'Proyecto Alfa')")
echo "$SC" | grep -q "Primero pienso" && ok "sin-calls conserva reasoning" || bad "sin-calls reasoning perdido"
echo "$SC" | grep -q "**Tool:**" && bad "sin-calls contiene tools" || ok "sin-calls sin tools"

echo "== export completo (truncado + marcado compactaciones + diffs) =="
run export completo --marcar-compactaciones --resumen-diffs >/dev/null
FC=$(cat "$(last_transcript completo 'Proyecto Alfa')")
echo "$FC" | grep -q "**Tool:**" && ok "completo con tools" || bad "completo sin tools"
echo "$FC" | grep -q "Compactación de contexto" && ok "marcador compactación" || bad "marcador compactación"
echo "$FC" | grep -q "Resumen de cambios" && ok "resumen diffs" || bad "resumen diffs"

echo "== truncado de output largo =="
FT=$(cat "$(last_transcript completo 'Proyecto Beta')")
echo "$FT" | grep -q "truncado:" && ok "output largo truncado" || bad "output no truncado"

echo "== filter =="
run export solo-texto --filter 'Proyecto Beta' >/dev/null
ME=$(last_meta solo-texto)
jq -e '.filtro == "Proyecto Beta"' "$ME" >/dev/null && ok "filter aplicado en metadatos" || bad "filter metadatos"
jq -e '.sesiones.raices == 1' "$ME" >/dev/null && ok "filter aplicado en metadatos" || bad "filter metadatos"

echo "== sub separate / inline / omit =="
run export solo-texto --sub inline >/dev/null
INL=$(last_transcript solo-texto 'Proyecto Alfa')
grep -q "Subagente" "$INL" && ok "sub inline incluido" || bad "sub inline"
run export solo-texto --sub omit >/dev/null
OMIT=$(last_meta solo-texto)
jq -e '.sesiones.subagentes == 0' "$OMIT" >/dev/null && ok "sub omit = 0 subagentes" || bad "sub omit: $(jq '.sesiones.subagentes' "$OMIT")"
run export solo-texto --sub separate >/dev/null
SEP=$(last_meta solo-texto)
jq -e '.sesiones.subagentes == 3' "$SEP" >/dev/null && ok "sub separate = 3 subagentes" || bad "sub separate: $(jq '.sesiones.subagentes' "$SEP")"

echo "== index.md presente y con enlaces =="
run export completo --marcar-compactaciones >/dev/null
IX=$(last_meta completo); IX="${IX%/metadatos.json}/index.md"
grep -q "## Sesiones" "$IX" && ok "index.md con sección sesiones" || bad "index.md"
grep -q "](" "$IX" && ok "index.md con enlaces" || bad "index.md enlaces"

echo ""
echo "RESULTADO: $pass OK / $fail FALLO"
[ "$fail" -eq 0 ]