# Arquitectura — opencode-db-exporter

> Documento de diseño y racional. Para el uso práctico (comandos, flags, instalación)
> ver [`README.md`](../README.md). Las decisiones de producto confirmadas del rediseño
> de exportación están registradas en [`export-analysis.md`](export-analysis.md) (§7).

## 1. Filosofía: nunca escribir en la DB viva

El principio rector es que `opencode-db` es una herramienta de **auditoría**: lee, respalda
y exporta, pero jamás modifica la base de datos que opencode usa en vivo.

- Todos los accesos usan `mode=ro`: bash `sqlite3 "file:$DB?mode=ro"` (`o_db_uri` en
  `common.sh`), python `sqlite3.connect(f"file:{db}?mode=ro", uri=True)`.
- La DB de opencode va en modo **WAL** (`opencode.db-wal`): un `cp` del archivo principal
  no captura la cola WAL. Por eso los backups y el snapshot de `shrink` usan
  `sqlite3 .backup <dest>` (snapshot consistente), nunca `cp`.
- `shrink` construye una **copia** podada + VACUUMeda y verifica
  (`integrity_check` = ok, `foreign_key_check` = 0 filas) **antes** de almacenarla. El
  reemplazo de la DB en vivo es manual — o el nuevo `shrink --swap` (ver §6), que es el
  único camino que toca la DB viva, y de forma explícita y blindada.
- `--from-backup` (flag global, antes del subcomando) apunta toda lectura a un backup
  almacenado; un `.gz` se descomprime a un único archivo temporal memoizado
  (`o_resolve_db`/`o_effective_db` en el shell padre, limpiado con `trap ... EXIT`);
  nunca se resuelve un backup dentro de `$(...)` (subshell) porque crearía un temp por
  llamada que nunca se limpia.

## 2. Modelo de datos de opencode (schema real)

Información verificada sobre el schema que esta herramienta consume (no es genérico:
otras fuentes pueden describir un schema inventado):

- Tabla `session` (singular), con: `id`, `parent_id` (subagente si no vacío), `agent`,
  `model`, `directory`, `title`, `version`, `time_created`/`time_updated` (epoch ms),
  `cost`, `tokens_*` (`input/output/reasoning/cache_read/cache_write`), `share_url`.
- Tabla `part`: `part.data` es JSON con `type ∈ text | file | step-start | reasoning |
  tool | step-finish | patch | compaction`.
- Llamada a herramienta: `part.data.state.input.command` (tool), `.state.input.arguments`,
  `.state.output` (truncable).
- `message.data.summary.diffs`: resumen de cambios por mensaje (`--summary-diffs`);
  `summary` puede ser `true` (bool), no solo un objeto.
- **Compaction**: los `part.data.type = 'compaction'` son solo marcadores (`auto`,
  `overflow`, `tail_start_id`); el **digest** del contexto compactado es el `text` del
  siguiente mensaje con `data.mode='compaction'`. `digests_for` (en `export.py`) es la
  fuente única de este digest, compartida por el producto `compactions` y por `memory`.
- Precedencia de config: **env > conf file > default** (`load_conf` en `common.sh`
  captura las variables antes de sourcear `$OCED_CONF`).

## 3. Pipeline de exportación

`export.sh` es un puente "bash → python": valida dependencias/DB y delega en `export.py`
(único lector de SQLite). No hay ninguna bifurcación hacia el CLI de opencode (el CLI no
ofrece `session export` y sus filtros de entorno ocultarían sesiones; leer la DB directa
en `mode=ro` es lo que garantiza verlo todo).

### Productos

| Producto | Documento |
|---|---|
| `transcript` | la conversación en markdown (texto + razonamiento + tools + patches + marcadores). `full` es alias aceptado |
| `compactions` | solo los digests de `mode=compaction` |
| `memory` | corpus RAG: un objeto JSON por sesión **root** (metadatos, `first_user`, `last_assistant`, todos los digests) |

No existe meta-perfil `all`; "todas las sesiones" es seleccionar ALL en el picker (o
`--filter` vacío). `--role` es un flag (`all|user|assistant`), no un preset; `memory` lo
ignora (documentado en su `index.md`).

### JSON fiel (`--json`)

Cada sesión escribe un archivo `.json` junto al `.md` con la forma nativa
`{"info": {...}, "messages": [{"info": {...}, "parts": [...]}]}` (paridad
`session_faithful`). Los subagentes inline van a `<stem>.sub-<id8>.json`. `info.tokens`
incluye `backfilled`.

### Token backfill

Sesiones antiguas con `tokens_*`/`cost` a 0/NULL se reconstruyen en memoria sumando los
`part.data.type='step-finish'` (`tokens.input/output/reasoning/cache.{read,write}` +
`cost`). El resultado se marca `tokens_backfilled` en `metadatos.json`/JSON/corpus. No
migra nada en la DB.

### Sanitización (`--sanitize`, opt-in)

**En memoria, sobre tipos nativos, antes de serializar**: `sanitize_json()` recorre
recursivamente el dict/lista y aplica las regex solo a valores `str`; luego se serializa
JSON limpio. En markdown, la sanitización se aplica a cada string en el punto de render
(`Renderer.w`), nunca sobre el archivo final ya escrito. Los bloques de display
(```` ```json ```` de `state.input`, `patch`, `file`) se sanitizan sobre su texto
serializado — es contenido de código markdown que nadie vuelve a parsear, sin riesgo.

Patrones cubiertos (regex): `sk-`/`sk-ant-`, `ghp_`, `github_pat_`, `xox[baprs]-`,
`AIza…`, `AKIA…`, JWT (`eyJ…`), claves privadas PEM multilínea (`re.S`), nombres de
variables `*_API_KEY`, y pares `key=value` sensibles (`password|token|api[_-]?key|…`).

Límites asumidos y documentados: la regex es un *baseline*, no un filtro semántico — un
secreto contextual (una password en prosa sin `=`/`:`) puede escaparse; no sustituye a
rotar claves reales. La tensión "sanitize vs faithful JSON" se resuelve siendo `--sanitize`
opt-in.

### `memory`: corpus en streaming

`corpus.jsonl` puede pesar más que la propia DB (texto sin truncar + todos los digests +
`--files`). Por eso `memory_export` **escribe línea a línea** (un root + sus subagentes =
una línea JSON) con `flush()`, sin acumular el corpus en memoria; el pico de RAM queda
acotado a una sesión root a la vez. `--cap N` acota cada valor de texto (guard opcional);
si el corpus supera ~50 MB sin `--cap`, se sugiere acotar.

### index.md / metadatos.json

Cada run escribe `index.md` (resumen/índice) + `metadatos.json` (tool/version/fecha,
`db` + `db_sha256` para correlacionar el export con un snapshot, `profile`, flags como
`role`/`json`/`sanitize`/`reasoning`/`tokens_backfilled`, counts). `exports.sh` agrega
estos `metadatos.json` por stamp para `exports list/remove/prune`.

## 4. Diseño del menú

Picker-driven con fzf real: filas TSV `key<TAB>display` (`--with-nth=2..`), **sin
multi-selección por TAB** — el cambio de modo y las operaciones masivas son filas
propias. El wizard de export es product → variant (producto = documento, variante =
configuración, bundle = varios productos por run); `transcript` tiene 14 variantes (incl.
`--json`, `--json --sanitize`, `--no-reasoning`, el bundle `__FULLMEM__` = transcript +
memory con un `--stamp` compartido, `__CUSTOM__` = checklist `OC_CK_*`), `compactions` 5,
`memory` 3. No existen presets "solo prompts"/"solo answers" — `--role` solo en el
checklist custom. Detalles de uso: `README.md` (Menú).

## 5. `shrink`

Objective: la DB solo crece (el grueso es el event store); borrar sesiones reutiliza
páginas pero no reduce el archivo (solo `VACUUM`, que exige lock exclusivo). `oced_shrink`
sobre una copia:

1. Snapshot `.backup` de la DB viva (WAL-safe).
2. Keep-set **cerrado** por CTE recursiva (padres y subagentes de una sesión conservada
   también se conservan; sin huérfanos).
3. Borrado en orden FK-seguro de tablas ligadas a sesión + agregados `event`/
   `event_sequence` (`aggregate_id LIKE 'ses_%'`).
4. `--strip-reasoning` opcional (los `part` con `data.type='reasoning'`).
5. `integrity_check` + `foreign_key_check` **antes** de guardar `opencode.shrunk.db` +
   `shrink.json` (criterios/conteos/por-tabla).
6. Swap manual — o `--swap`, ver §6.

## 6. Seguridad operativa del swap (`shrink --swap`)

El swap manual publicado en el README tiene un riesgo real: `rm -f` del `-wal`/`-shm`
mientras opencode está en ejecución puede perder la cola WAL. `opencode-db shrink
[recipe] --swap [--yes]` automatiza el reemplazo con guardas:

1. **Guardia de proceso**: aborta si hay un proceso cuyo cmdline menciona `opencode`
   (excluyendo el propio tool / `pgrep`) — `pgrep -af`.
2. **Re-verificación** de la copia en `mode=ro` (`integrity_check` + `foreign_key_check`).
3. **Safety copy** de la DB viva con `sqlite3 .backup` → `opencode.db.pre-shrink-<ts>`
   (WAL-safe; nunca `cp`).
4. **Swap atómico** con `mv -f` + limpieza del `-wal`/`-shm` de la DB vieja.
5. **Rollback**: si la nueva DB no abre/verifica en `mode=ro`, se restaura la safety copy.

`--dry-run` nunca escribe; se rechaza combinarlo con `--swap`. Confirmación `[y/N]`
salvable con `--yes`.

## 7. Enlaces

- `../README.md` — guía de uso (instalación, comandos, flag, tests, layout).
- `export-analysis.md` — análisis previo al rediseño y §7 con las decisiones confirmadas.