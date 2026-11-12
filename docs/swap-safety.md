# Operational safety of `shrink --swap`

> Destructive-operation safeguards for the optional Bash shrink workflow.

## 6. Operational safety of the swap (`shrink --swap`)

The manual swap published in the README has a real risk: `rm -f` of the `-wal`/`-shm`
while opencode is running can lose the WAL tail. `opencode-db shrink
[recipe] --swap [--yes]` automates the replacement with guards:

1. **Process guard**: aborts if there is a process whose cmdline mentions `opencode`
   (excluding the tool itself / `pgrep`) — `pgrep -af`.
2. **Re-verification** of the copy in `mode=ro` (`integrity_check` + `foreign_key_check`).
3. **Safety copy** of the live DB with `sqlite3 .backup` →
   `$OCED_BACKUP_DIR/pre-shrink/opencode.pre-shrink-<ts>.db` (WAL-safe; never `cp`),
   auto-keeping only the most recent copy. On a successful swap it is registered as
   the manifest's **`.pre_shrink` singleton** — the rollback of the last swap
   (always refreshed, never pruned). It belongs to the **shrink domain**:
   `shrinks preshrink` shows/checks it and `shrinks preshrink remove` deletes it
   (never a `backups` surface), while `--from-backup pre-shrink/<file>` still
   resolves it read-only. `status` reports it with a freshness verdict. Old,
   unregistered pre-shrink files are cleaned by `shrinks verify`.
4. **Atomic swap** with `mv -f` + cleaning of the old DB's `-wal`/`-shm`.
5. **Rollback**: if the new DB does not open/verify in `mode=ro`, the safety copy is
   restored (a rollback consumes the file, so nothing is registered — only a
   successful swap records `.pre_shrink`).

`--dry-run` never writes; combining it with `--swap` is rejected. Confirmation `[y/N]`
can be skipped with `--yes`.

`shrinks verify [--tsv] [--yes]` audits the produced copies: orphan run dirs, old
`pre-shrink/*` copies, **every copy's** freshness vs the live DB, and **every discard's
export coverage**. Freshness is asked once per run, never only for the newest: a
fresh-looking verdict over three unchecked copies is exactly the answer that hides the
other two, so the clean line names the copy count. Coverage is the same shape of question
against a shelf that ages differently: a discard copy stores its closed cascade
(`.selection.cascade`) and the check re-matches it against the exports shelf at verify
time (a root-only export is a different set, so it never clears the flag). The exact
`--tsv` rows, field names and legacy rules are the contract in `schemas.md` §6.

