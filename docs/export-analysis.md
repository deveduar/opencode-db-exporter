# Análisis del sistema de exportación — opencode-db-exporter

Documento de diseño: cómo funciona el exportador hoy, qué hace **realmente** el modo
`all` ("4 en 1"), qué hace el resto de la comunidad, y propuestas para simplificar
el modelo conceptual. Este documento **no cambia código**; es la base para decidir.

---

## 1. Cómo funciona hoy (estado real del código)

### 1.1 Punto de entrada

- `modules/export.sh` → `oced_export [profile|all] [flags]` que ejecuta
  `modules/export.py` con `OPENCODE_DB`/`OCED_OUT`/`OCED_BACKUP_DIR` ya resueltos
  (respetando `--from-backup`).
- `export.py` abre la DB **solo lectura** (`file:...?mode=ro`), lee la jerarquía
  root/subagente de `session.parent_id`, y escribe un árbol:
  `OCED_OUT/<stamp>/<profile>/` + `index.md` + `metadatos.json`.

### 1.2 Los 5 profiles + 1 meta-profile

| Profile | Qué emite | Tipo de parte incluida (export.py:83-97) |
|---|---|---|
| `full` | transcript completo | `text`, `reasoning`, `tool` (según `--tool-output`), `patch` (según `--patch`), `file`, `step-*`, `compaction` (solo con `--mark-compactions`) |
| `no-calls` | sin herramientas/parches | `text`, `reasoning` |
| `text-only` | solo texto de mensajes | `text` |
| `compactions` | **resúmenes de compacción** | solo mensajes con `mode=compaction`, parte `text` (el "digest") |
| `memory` | **corpus RAG** (JSONL + index.md) | primer prompt, última respuesta, todos los digests, todos, `--files` |
| `all` (meta) | **4 runs en 1 carpeta** (`full`, `no-calls`, `text-only`, `compactions`), cada uno con "flags máximos" | aplicación de export.py:27-34 |

Las 4 carpetas de `all` comparten un único `--stamp` (`export.sh:21-32`).

### 1.3 Los flags (dimensiones de configuración)

- `--sub separate|inline|omit` — cómo colocar subagentes (por defecto `separate`, una
  carpeta `subagents/` por root).
- `--tool-output full|truncated|omit` + límites `--tool-input-limit` (800) /
  `--tool-output-limit` (500) — verbosidad de las herramientas.
- `--patch full|omit` — incluye/omite los diffs de código.
- `--mark-compactions` — anota en el transcript dónde hubo compacción.
- `--summary-diffs` — incluye `message.data.summary.diffs` (resumen de cambios por
  mensaje).
- `--role all|user|assistant` — **transcript**: solo prompts / solo respuestas.
- `memory`: `--cap N` (0=ilimitado) y `--files`.

### 1.4 Qué es cada parte en la DB (schema)

`part.data.type` ∈ `text | file | step-start | reasoning | tool | step-finish | patch | compaction`.
El digest de una compacción no está en la parte marcadora `type=compaction` sino en el
mensaje siguiente con `data.mode='compaction'` (helper `digests_for`, export.py:228-236,
compartido por `compactions`, `memory` y `view.sh`).

---

## 2. Pregunta 1: ¿el modo "4 en 1" (`all`) hace TODAS las exportaciones posibles?

**No.** Hace 4 de los 5 profiles, con UN solo setting por dimensión (el máximo). Es un
subconjunto muy pequeño del espacio total y —más importante— la mayoría de ese espacio es
**redundante** (ver §3.2).

Lo que `all` **NO** incluye:

1. `memory` — excluido a propósito (es corpus, no transcript), pero a efectos de "todo",
   falta.
2. Roles filtrados (`--role user/assistant`) — `all` solo emite `--role all`.
3. Variantes de verbosidad (`--tool-output omit/truncated`, `--patch omit`).
4. `--sub inline|omit`.
5. `--mark-compactions` desactivado, `--summary-diffs`, etc.

Si se conjuntaran **todas** las combinaciones (5 profiles × 3 tools × 2 patch × 3 sub ×
3 role × …) saldrían cientos de carpetas por sesión, casi toda redundantes. Que `all`
emita `full` + `no-calls` + `text-only` + `compactions` es un compromiso arbitrario sin
una lógica de producto que lo justifique.

---

## 3. Pregunta 2: si eliges `full`, ¿qué sentido tiene poder elegir "solo prompts"?

El usuario tiene razón en que el planteamiento actual confunde ejes. Veamos qué es un
**subconjunto** de qué:

- `no-calls` = `full` − tools − patches → **subconjunto**.
- `text-only` = `no-calls` − reasoning → **subconjunto**.
- `--role user` = `full` ∩ solo mensajes de usuario → **subconjunto**.
- `compactions` = **no es subconjunto**: es un meta-log (qué resumió opencode), con
  formato y finalidad distintos.
- `memory` = **no es subconjunto**: es otro formato (JSONL para RAG) y otro consumidor
  (máquina, no lectura humana).

Es decir: hoy se venden como "profiles" (productos distintos) cosas que son **variantes de
verbosidad de un mismo producto** (el transcript), y se mezclan con otros dos productos
genuinamente distintos (digests de compacción y corpus de memoria). Por eso "perfil full
+ preset 'solo prompts'" suena contradictorio: es coger el producto completo y quitarle
97% de su contenido — un preset legítimo (ej. un resumen de tus intenciones), pero NO un
producto hermano de `full`.

Research (ver §5): ningún exportador de la comunidad hace esto. Todos emiten **UN** markdown
bien hecho por sesión (con opciones de verbosidad), y los avanzados añaden un **JSON fiel**
(loslessness) y/o HTML. Nadie publica 4 markdowns de la misma conversación.

---

## 4. El problema de fondo: dos ejes mezclados

Modelo actual: `profile` = "qué documento", `variant` = "cómo se configura". Pero en
realidad hay que separar **producto** del **nivel de detalle**, porque el transcript es
uno solo:

```
PRODUCTO (qué se obtiene)          NIVEL DE DETALLE (para el transcript)
─────────────────────────         ─────────────────────────────────────
1. Transcript (markdown)      ⇐    herramientas: full|truncated|omit
2. Memory corpus (jsonl)            parches: full|omit
3. Compactions digests (md)         subagentes: separate|inline|omit
                                    rol: all|user|assistant
                                    (razonamiento: sí/no)
```

- `full` vs `no-calls` vs `text-only` NO son productos: son **tres marcas del nivel de
  detalle del mismo producto** (Transcript).
- El commit ciudadano promedio quiere: "1 marcar la conversación, con herramientas y sin
  razonamiento" → eso es UNA exportación de Transcript con ciertas opciones.
- `all` como "todo" naturalmente significaría **todas las sesiones** (su significado
  coloquial), no "4 duplicados verbosos de cada sesión".

### 4.1 Propuesta (a debatir)

1. **Refactorizar la entrada de menú/CLI alrededor de PRODUCTO + opciones**, no de
   "profile → variant":
   - `Transcript` (md): opciones tools/patches/sub/role/reasoning → 1 árbol por run.
   - `Memory` (jsonl): opciones cap/files → 1 corpus por run.
   - `Compactions` (md): digests → 1 índice por run (o se deja solo en `info`/`status`,
     que ya lo muestran).
   - Un presete "todo" = `Transcript` + `Memory` bajo un mismo `--stamp` (el "bundle"
   `__FULLMEM__` del menú ya hace esto), descartando los 3 markdowns redundantes.
2. **Añadir exportación JSON fiel** (formato nativo de opencode, `{"info", "messages"}`)
   como acompañamiento "archivo" del Transcript — la vía lossless para no perder nada,
   complementando el markdown legible. opencode ya lo ofrece de serie
   (`opencode export <id> --sanitize`).
3. **Sanitización/redacción** al compartir (patrón de opencode `--sanitize` y de
   `opencode-export` con 18 patrones de secretos) — de momento el exporter no redacta
   nada.
4. **`--role user|assistant`** sigue siendo un toggle del Transcript (válido), pero ya no
   se duplica como "profile"; **`compactions`** como "profile" de markdown desaparecería
   o quedaría como comodidad bajo Transcript (sección de digests al pie) — elimina el
   tercer producto redundante del menú.

### 4.2 Qué ganamos

- Un menú con 3 entradas en vez de 6 con combinaciones cruzadas.
- `all` deja de ser "4 duplicados" y pasa a ser "todo lo útil en un run".
- El usuario ya no se pregunta "si full lo tiene todo, ¿para qué solo prompts?" — la
  respuesta ("es un toggle de transcript para quedarte solo tus prompts") queda clara en
  la UI (un checkbox), no como un producto paralelo.

---

## 5. Qué hace el resto del mundo (research, sep 2026)

| Proyecto | Formato | Enfoque | Lecciones |
|---|---|---|---|
| **opencode oficial** (`opencode export <id>`) | **JSON** `{"info", "messages":[{info, parts}]}` + `--sanitize` | fiel/lossless + redacción para compartir | el estándar de la casa es JSON; el markdown es un extra |
| **opencode-export** (ZelinZhou-THU) | HTML + `data/sessions.json` | archivo offline navegable, redacción recursiva, subagentes inline, backfill de tokens desde `step-finish` | redacción + subagentes inline + backfill de tokens para sesiones viejas |
| **opencode_session_exporter** (weshu) | Markdown | usa `opencode export --format json` como fuente; reasoning en `<details>`, tools resumidas | vuelve al markdown clásico: un formato, reasoning colapsable, tools resumidas |
| **opencode-db** (VasilevNStas / PyPI) | Markdown + Obsidian | metadata header + mensajes; `--full` (sin truncar); nota en `log.md` | Obsidian export oficial del PyPI; `--full` es el equivalente a `--tool-output full` |
| **opencode-session-extractor** (PyPI) | JSON + Markdown + HTML | 3 formatos al llamar | formatos multiplataforma, pero siempre el MISMO contenido |
| **opencode-session-toolkit** (skill) | consultas + export MD | lee la DB read-only, exporta sesiones | confirma el patrón read-only directo a SQLite |

**Observaciones transversales:**

- El markdown de todos es **un formato con opciones**, nunca N markdowns del mismo evento.
- Los que "lo hacen todo" añaden **formatos** (JSON/HTML) sobre el MISMO contenido, no
  recortes de contenido.
- La opción más solicitada en comunidad: **redacción de secretos** al exportar
  (opencode oficial `--sanitize`, opencode-export redaction engine).
- El contrato de opencode (partes/formatos) incluye tipos que hoy ignoramos: `snapshot`,
  `event`, `retry`, `subtask` (los subagentes los tratamos por `parent_id`, no por
  `subtask`), y token por `step-finish`. "Exportarlo todo" de verdad debería contemplar
  el **JSON fiel** para no perder esos.

---

## 6. Preguntas abiertas para decidir

1. ¿`all` pasa a significar "todas las sesiones" (cada sesión = 1 transcript) en vez de
   "4 perfiles"? (Mi recomendación, pero rompe la semántica actual.)
2. ¿Se queda el markdown como formato principal y el JSON fiel como opción (`--json`)?
3. ¿Implementamos redacción de secretos (patrón `--sanitize` de opencode)?
4. ¿`--role` se mantiene como toggle del Transcript (sí seguro) y "solo prompts" se
   elimina como preset del menú?
5. ¿`compactions` como markdown se mantiene, o solo vive en `info`/`memory`?
6. ¿Añadimos backfill de tokens desde `step-finish` para sesiones viejas con 0 tokens
   (gap real de nuestra DB: `tokens_*` puede estar vacío en sesiones antiguas)?

---

## 7. Decisiones tomadas (respuestas del usuario)

1. **Sí** — `all` pasa a significar "todas las sesiones". Se elimina el meta-perfil
   `all` (4-en-1) y los perfiles `no-calls` / `text-only`.
2. **Sí** — markdown principal + `--json` fiel (archivo por sesión).
3. **Sí** — se implementa `--sanitize` (redacción recursiva de secretos).
4. **Sí** — `--role` queda como toggle de `transcript`/`compactions`; los presets
   "solo prompts"/"solo answers" se **eliminan** del menú.
5. **Sí** — `compactions` se mantiene como producto markdown independiente (no se
   mezcla con `info`/`memory`).
6. **Sí** — backfill de tokens desde `step-finish` (suma in-memory, flag
   `tokens_backfilled`).

Modelo final: **productos** `transcript | memory | compactions` (sin meta-perfil,
`full` aceptado como alias de `transcript`), variantes por producto en el menú, y la
bundle `__FULLMEM__` = transcript + memory en un `--stamp` compartido.