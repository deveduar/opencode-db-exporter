# opencode-db-exporter

Un tool standalone (estilo [byok-manager](https://github.com/.../byok-manager)) para **leer, respaldar y exportar** la base de datos SQLite local de opencode (`~/.local/share/opencode/opencode.db`) a Markdown legible, sin modificar nunca la DB de opencode.

Reemplaza los scripts antiguos `exportar_opencode.py`, `exportar_sin_calls.py` y `exportar_solo_texto.py`.

## Instalación

```bash
./install.sh            # + symlink ~/.local/bin/opencode-db (si ~/.local/bin no está en el PATH: export PATH="$HOME/.local/bin:$PATH")
opencode-db status     # primera prueba
```

Dependencias: `sqlite3`, `python3`, `jq`, `gzip`.

## Comandos

```
opencode-db status            # estado de la DB y alineación con el último backup
opencode-db list [--root] [--sub] [--info] [--filter PATRÓN] [--grouped]
opencode-db info <session>    # detalle de una sesión (tokens, coste, compactaciones)
opencode-db compactaciones <session>
opencode-db backup            # snapshot consistente (sqlite .backup), gzip + sha256 + manifest.json
opencode-db backups [list|verify <file>|prune <N>]
opencode-db export <perfil> [OPCIONES]   # perfiles: completo | sin-calls | solo-texto
opencode-db help
```

### export — perfiles y opciones

| Perfil       | Contenido                                                            |
|--------------|---------------------------------------------------------------------|
| `completo`   | Todo: texto + reasoning + tool calls (input/output truncados) + diffs |
| `sin-calls`  | Texto + reasoning, sin tool calls                                    |
| `solo-texto` | Solo texto del usuario/asistente                                     |

Opciones:
- `--filter `LIKE`` — filtra por id o título (patrón SQL `%...%`).
- `--sub separate|inline|omit` — cómo incluir los subagentes (lo habitual: `separate`, cada uno en su carpeta).
- `--marcar-compactaciones` — inserta un aviso `⚙️ Compactación de contexto` donde hubo compactación.
- `--resumen-diffs` — incluye el resumen de cambios (`summary.diffs`) que opencode guarda por mensaje.
- `--tool-output` — por defecto el output de las tool calls se trunca; con esta flag se muestra completo.

Cada run genera una carpeta `exportes/<timestamp>/<perfil>/` con un `index.md` y un `metadatos.json` (resumen exportable/máquina-legible).

## Arquitectura

```
modules/
  opencode-db.sh   dispatcher CLI (sourcea los módulos)
  common.sh        configuración y helpers (lectura SIEMPRE en modo ro)
  view.sh          status / list / info / compactaciones (SQL de solo lectura)
  backup.sh        snapshot consistente + gzip + sha256 + manifest.json
  export.sh        puente bash → python
  export.py        renderizador Markdown (perfiles, subagentes, index.md, metadatos)
tests/
  make_fake_db.sh  genera una DB falsa para los smoke tests
  export_smoke.sh  smoke tests end-to-end (no toca datos reales)
install.sh / opencode-db.conf.example / AGENTS.md
```

## Notas de diseño

- **La DB usa modo WAL** (`opencode.db-wal`). El backup usa `sqlite3 .backup` (snapshot consistente), nunca `cp`; si hay un `.wal` pendiente se checkpointea implícitamente.
- **Lectura siempre en modo `ro`** (`file:...?mode=ro`): nunca se modifica ni lockea la DB de opencode.
- Los **subagentes** se detectan por `session.parent_id`; si su padre no está en el resultado se exportan como raíz etiquetada `Subagente de: <padre>`.
- Verificación: `bash tests/export_smoke.sh` (debe dar `28 OK / 0 FALLO`) y comprobaciones previas; ver `AGENTS.md`.