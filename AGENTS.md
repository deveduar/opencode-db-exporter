# AGENTS.md — opencode-db-exporter

Tool bash+python para leer, respaldar y exportar la DB SQLite local de opencode. Nunca modificar
(escribir) la DB de opencode: todos los accesos usan `mode=ro` (bash: `file:$DB?mode=ro`; python: `sqlite3.connect(f"file:{db}?mode=ro", uri=True)`).

## Comandos que SIEMPRE hay que correr tras editar código

```bash
# Sintaxis de los shells (no hay scripts sin definir; todos con #!/usr/bin/env bash)
for f in modules/*.sh install.sh tests/*.sh; do bash -n "$f"; done

# Python
python3 -m py_compile modules/export.py

# Smoke tests sobre una DB falsa (no toca datos reales)
bash tests/export_smoke.sh        # debe dar: 28 OK / 0 FALLO
```

## Estructura

- `modules/opencode-db.sh` — dispatcher CLI: `status | list | info | compactaciones | backup | backups | export | help`. Sourcea common.sh + view.sh + backup.sh + export.sh.
- `modules/common.sh` — config (`OPENCODE_DB`, `OCED_OUT`, `OCED_BACKUP_DIR`, `OCED_CONF`) y helpers `o_q`, `o_die`, `o_ts`, `o_now_utc`, `o_check_deps`. `o_q` SIEMPRE ro: `sqlite3 "$(o_db_uri)"`.
- `modules/view.sh` — status/list/info/compactaciones (solo lecturas).
- `modules/backup.sh` — `sqlite3 "$DB" ".backup <snap>"` (WAL-safe), opcional gzip, sha256, `manifest.json` atómico (jq), `backups list/verify/prune`.
- `modules/export.sh` + `modules/export.py` — perfiles `completo|sin-calls|solo-texto`; `--filter`, `--sub separate|inline|omit`, `--tool-output`, `--patch`, `--marcar-compactaciones`, `--resumen-diffs`; genera `index.md` + `metadatos.json` por run.
- `tests/make_fake_db.sh` — DB falsa (6 sesiones, subagentes huérfanos/nesteados, compactaciones, tool outputs largos).
- `tests/export_smoke.sh` — aserciones end-to-end.

## Reglas del esquema (opencode.db)

- `session`: `parent_id` (subagente si no vacío), `agent` (build/explore/plan), `model`, `directory`, `time_compacting`, `tokens_*`, `cost`, `share_url`.
- `part.data.type` ∈ `text | file | step-start | reasoning | tool | step-finish | patch | compaction`.
- Tool call: `part.data` → `state.input.command` (tool), `state.input.arguments`, `state.output` (truncable).
- `message.data.summary.diffs` — resumen de cambios por mensaje (`--resumen-diffs`).
- Compactaciones: partes `type='compaction'` (o eventos con `time.compact`).

## Trampas conocidas

- **SIGPIPE/pipefail**: nunca hacer `cmd | grep -q PATRÓN` en tests o módulos si `cmd` es un subprocess largo; grep cierra la tubería al matchear y el productor muere con 141. Capturar antes: `out=$(cmd); printf '%s' "$out" | grep -q PATRÓN`.
- `model` puede venir ya serializado como JSON (no doble-encodear).
- Newlines dentro de JSON tras `json_each`/diagonales se escapan antes de `data:json_each`; para volcados raw usar `json_quote`.
- `set -euo pipefail` en bash: los pipelines con `grep -q` pueden devolver 141 (ver arriba).
- `trap` EXIT local en funciones: limpiar con `trap - EXIT` antes de `return` para no cancelar el trap del llamador.
- paths y nombres de archivo: `safe_filename` quita caracteres `@()[]` etc.

## Deploy

- `install.sh` — copia modules+tests a `~/.local/share/opencode-db-exporter`, enlaza `~/.local/bin/opencode-db` → `modules/opencode-db.sh`, crea conf desde `opencode-db.conf.example` si falta (permisos 600).
- Config: `~/.config/opencode-db/opencode-db.conf` (600).