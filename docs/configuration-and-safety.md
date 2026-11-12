# Shared configuration and safety

> This applies to both interfaces unless a subsection explicitly names Python or Bash. Python reads the DB and exports; Bash also manages backups and shrink copies.

## 1. Philosophy: never write to the live DB

The guiding principle is that `opencode-db` is an **audit** tool: it reads, backs up and
exports, but never modifies the database opencode uses live.

- All access uses `mode=ro`: bash `sqlite3 "file:$DB?mode=ro"` (`o_db_uri` in
  `common.sh`), python `sqlite3.connect(f"file:{db}?mode=ro", uri=True)`.
- The opencode DB runs in **WAL** mode (`opencode.db-wal`): a `cp` of the main file does
  not capture the WAL tail. That is why backups and the `shrink` snapshot use
  `sqlite3 .backup <dest>` (consistent snapshot), never `cp`.
- `shrink` builds a **copy** that is pruned + VACUUMed and verifies
  (`integrity_check` = ok, `foreign_key_check` = 0 rows) **before** storing it. Replacing
  the live DB is manual — or the new `shrink --swap` (see [swap safety](swap-safety.md)), the only path that touches
  the live DB, and always explicitly and guarded.
- `--from-backup` (global flag, before the subcommand) points every read at a stored
  backup; a `.gz` is decompressed to a single memoized temp file
  (`o_resolve_db`/`o_effective_db` in the parent shell, cleaned with `trap ... EXIT`);
  a backup is never resolved inside `$(...)` (subshell) because that would create one
  temp per call that never gets cleaned.

Reading the raw DB is also why this tool can export what `opencode export` cannot: the
native command writes a **projected** transcript (post-compaction, context-epoch cutoffs,
bounded tool output) and truncates piped output at 64 KiB boundaries (opencode issue
#2803). The `mode=ro` read sees the full history and complete tool output regardless.

## 8. Precedence and safety

- Environment > conf file > defaults for paths/options; **the CLI wins over a plan**
  (`opencode-db export complete --filter ses_X` overrides the plan's selection; an
  explicit flag overrides the plan's value).
- The DB is always opened **read-only**; exports never mutate opencode data. The only
  path that writes the live DB is the opt-in `shrink --swap`.
- `exports update` refreshes an existing run **from** the live DB (read-only) and rewrites
  only the stored run: it re-renders into a temp dir and swaps it in with two `rename`s, so
  a failed refresh leaves the original run intact. `--keep-history` keeps the previous state
  as a hardlinked `<stamp>~<date>` copy. A default (delta) refresh can never turn a run the
  menu deliberately narrowed into a full export — what it left out is recorded as
  `.excluded` and stays out unless `--sticky`/`--include-excluded ID,ID` re-opens it (or
  `--mode accumulative` reopens the whole gap).
- Every export's `metadata.json` carries a `db_sha256`, so you can correlate a run with
  the exact snapshot that produced it.
- **`--sanitize` is best-effort**: it redacts high-confidence secret prefixes
  (sk-, ghp_, Bearer, JWT, PEM…) but is not a guarantee; always review the output
  before sharing.
