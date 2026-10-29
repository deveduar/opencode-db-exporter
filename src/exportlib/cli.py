# CLI entry: argument parsing, read-only DB access and run orchestration.
# Products (transcript | memory | digest | faithful):
#   transcript  markdown transcript with verbosity toggles
#   memory      RAG corpus (corpus.jsonl, one entry per root session)
#   digest      the compacted-context digests (markdown)
#   faithful    native {info, messages} JSON, one file per session (the lossless copy)
# Global flags: --filter, --sanitize (redact secrets), --stamp. Transcript toggles:
# --sub, --tool-output, --patch, --no-reasoning, --mark-compactions,
# --summary-diffs, --role.
import argparse
import json
import os
import sqlite3
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# Self-bootstrapping entry (like shrinklib/plan.py): running this file directly
# adds src/ to sys.path so the `exportlib` imports below resolve. The old
# src/export.py shim existed only for this; it has been removed.
MODULES_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if MODULES_DIR not in sys.path:
    sys.path.insert(0, MODULES_DIR)

from exportlib import TOOL_VERSION
from exportlib.config import default_bkp_dir, default_db, default_out, default_presets
from exportlib.db import (
    all_session_ids,
    backfill_session_tokens,
    filter_subagent_policy,
    load_sessions,
    since_ms,
)
from exportlib.faithful import faithful_export
from exportlib.memory import memory_export
from exportlib.presets import bundle_child_argv, resolve_profile, scope_meta
from exportlib.render import Renderer
from exportlib.transcript import append_transcript_inline, write_transcript
from exportlib.util import (
    die,
    safe_filename,
    selection_label,
    selection_meta,
    selection_phrase,
    session_record,
    sha256_file,
)
from exportlib.writers import last_backup_info, make_outdir_final, write_index
from exportlib.flags import FLAGS, effective_flags


def _pos_int(v: str) -> int:
    """argparse type for --last: a plain positive number, so 'abc' and '0'
    fail at the command line instead of silently selecting everything."""
    try:
        n = int(v.strip())
    except ValueError:
        raise argparse.ArgumentTypeError(f"{v!r} is not a number")
    if n < 1:
        raise argparse.ArgumentTypeError(f"must be >= 1 (got {n})")
    return n


def _iso_date(v: str) -> str:
    """argparse type for --since: YYYY-MM-DD, UTC. Same parser the engine
    queries with, so the CLI and the SELECT can never disagree."""
    s = v.strip()
    if since_ms(s) is None:
        raise argparse.ArgumentTypeError(f"{v!r} is not a date (YYYY-MM-DD, UTC)")
    return s


def _write_bundle_index(idx_dir, args, stamp: str, products, db_path) -> None:
    sel = selection_label(args)
    scope = scope_meta(args)
    lines = [
        "# opencode-db export bundle",
        "",
        "| Field | Value |",
        "|---|---|",
        f"| Preset | `{args.preset or '-'}` |",
        f"| Date | {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')} |",
        f"| Source DB | `{db_path}` |",
        f"| Selection | {sel} |",
        *([f"| Scope | {selection_phrase({'selection': scope})} |"]
          if selection_meta(args) != scope else []),
        # Same provenance row the per-product index.md writes for a refreshed
        # run (exports update): the base run and the axis it used.
        *([f"| Updated from | `{args.update_from}` "
           f"({getattr(args, 'update_mode', None) or 'delta'}) |"]
          if getattr(args, "update_from", None) else []),
        f"| Products | {' + '.join(products)} |",
        "",
        "Each product ran in its own subdirectory (own index.md + metadata.json):",
        "",
    ]
    lines += [f"- [`{p}/`]({p}/index.md)" for p in sorted(products)]
    lines += ["", f"Bundle: `opencode-db export {args.preset}` (stamp `{stamp}`)", ""]
    (idx_dir / "index.md").write_text("\n".join(lines), encoding="utf-8")


def _free_bundle_stamp(out_base, stamp: str, products) -> str:
    """Shared stamp for all bundle products (bumps to stamp@N the same way
    make_outdir_final does, but only when ANY product dir already exists, so the
    whole bundle lands under one prefix)."""
    cand = stamp
    n = 2
    while any((out_base / cand / p).exists() for p in products):
        cand = f"{stamp}@{n}"
        n += 1
    return cand


def run_bundle(args) -> None:
    """Bundle preset: run each product as its own single-product export under one
    shared stamp. The single-product pipeline is reused unchanged (a child process
    gets the product keyword, the shared stamp and the preset provenance), so every
    subfolder is byte-identical to a normal run of that product."""
    db_path = Path(default_db())
    if not db_path.exists():
        die(f"Database not found: {db_path}")
    out_base = Path(args.out) if args.out else Path(default_out())
    base_stamp = args.stamp or datetime.now(timezone.utc).strftime("%Y-%m-%d_%H-%M")
    products = list(args.bundle)
    stamp = _free_bundle_stamp(out_base, base_stamp, products)
    entry = Path(__file__).resolve()  # this same file IS the CLI entry (no shim)
    for product in products:
        argv = bundle_child_argv(args, product)
        cmd = [sys.executable, str(entry)] + argv + ["--stamp", stamp]
        res = subprocess.run(cmd)
        if res.returncode:
            sys.exit(res.returncode)
    idx_dir = out_base / stamp
    if idx_dir.is_dir():
        _write_bundle_index(idx_dir, args, stamp, products, db_path)


def build_argparser() -> argparse.ArgumentParser:
    """Build argparse.ArgumentParser from FLAGS registry (single source of truth)."""
    ap = argparse.ArgumentParser(
        prog="opencode-db export",
        description="Export opencode sessions (read-only).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("profile", nargs="?", default="transcript",
                    help="product or named preset: transcript | memory | digest | faithful | full | <preset from the presets file>")

    # Selection + output root come from FLAGS (single source of truth): exactly
    # ONE selection rule per run (--filter | --sessions | --last | --since, all in
    # one mutex group); --out/--last/--since are CLI-only (never preset keys).
    sel_group = ap.add_mutually_exclusive_group()
    for flag in FLAGS:
        if flag.name == "filter":
            sel_group.add_argument(f"--{flag.cli_name}", help=flag.cli_help)
        elif flag.name == "sessions":
            sel_group.add_argument(f"--{flag.cli_name}", action="append", metavar="SESSION_ID",
                                   help=flag.cli_help)
        elif flag.name in ("last", "since"):
            if flag.name == "last":
                sel_group.add_argument(f"--{flag.cli_name}", metavar="N", type=_pos_int,
                                       help=flag.cli_help)
            else:
                sel_group.add_argument(f"--{flag.cli_name}", metavar="DATE", type=_iso_date,
                                       help=flag.cli_help)
        elif flag.name == "out":
            ap.add_argument(f"--{flag.cli_name}", help=flag.cli_help)
        else:
            ap.add_argument(f"--{flag.cli_name}", **flag.argparse_args())

    # Hidden/internal args
    ap.add_argument("--stamp", help=argparse.SUPPRESS)
    ap.add_argument("--title", help="Short human label for this export run")
    ap.add_argument("--notes", help="Optional freeform context for this export run")
    ap.add_argument("--preset-name", help=argparse.SUPPRESS)
    # `exports update` hand-off: the target set is materialized as --sessions, but
    # the run's provenance stays the base run's scope; the update itself is named
    # so the index/metadata can say where it came from. Never preset keys.
    ap.add_argument("--scope-json", help=argparse.SUPPRESS)
    ap.add_argument("--update-from", help=argparse.SUPPRESS)
    ap.add_argument("--update-mode", help=argparse.SUPPRESS)

    # CLI-only workflow controls (never preset keys, like --stamp). They do not
    # enter FLAGS: they act on the run itself, not on its content.
    ap.add_argument("--list-presets", action="store_true",
                    help="list the named presets in the presets file and exit (no DB)")
    ap.add_argument("--list-products", action="store_true",
                    help="list the products (document kinds) and exit (no DB)")
    ap.add_argument("--show", action="store_true",
                    help="print the resolved plan for <profile> and exit (static, no DB)")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the plan + the sessions the selection would match; write nothing")
    ap.add_argument("--explain", action="store_true",
                    help="catalog every preset: what it produces and an example file tree (no DB)")
    return ap


def _session_records(written: list, sessions: dict) -> list[dict]:
    """One record per session actually WRITTEN, in export order.

    Derived from `written` — the very list of `(root, subs, folder)` tuples that
    created the directories — so the records cannot disagree with what is on
    disk, and a run that cascaded or dropped subagents records exactly the
    result. Requested explicit ids belong to `.selection.ids`; all other rules
    are represented by their `.selection.rule` and value.
    """
    out: list[dict] = []
    for root, subs, _folder in written:
        out.append(session_record(root, "root"))
        for sid in subs:
            out.append(session_record(sessions[sid], "subagent"))
    return out


def _scope_excluded(con, args, written_ids: set, db_ids: set):
    """metadata `.scope` + `.excluded`: what the run was DRAWN FROM versus what
    it actually WRITES. `.excluded` is the SELECTION gap
    `effective_scope - written` (the menu's marks / a narrower `--sessions`); a
    subagent removed by the run's own no_subagents/orphan policy is recorded by
    those flags + `subagents_hidden`, never here. `exports update` re-opens the
    gap. Recorded once at creation, because a run's scope cannot be re-derived
    later (a preset's file, and the DB, both move on)."""
    scope = scope_meta(args)
    rule = scope.get("rule")
    scope_sessions = load_sessions(
        con,
        scope.get("value") if rule == "filter" else None,
        scope.get("ids") if rule == "sessions" else None,
        scope.get("value") if rule == "last" else None,
        scope.get("value") if rule == "since" else None,
    )
    # `.excluded` is the SELECTION gap: the run's own subagent policy is applied
    # here too, so a `--no-subagents` drop is recorded by `no_subagents` /
    # `subagents_hidden` instead of masquerading as a hand-picked exclusion (and
    # `exports update` can never try to revive one). See docs/schemas.md.
    scope_sessions = filter_subagent_policy(
        scope_sessions, db_ids,
        getattr(args, "no_subagents", False),
        getattr(args, "no_orphan_subagents", False),
        getattr(args, "sub", None),
    )

    def _sub(v: dict) -> bool:
        p = v.get("parent_id") or ""
        return bool(p) and p in db_ids

    excluded = [
        session_record(v, "subagent" if _sub(v) else "root")
        for sid, v in scope_sessions.items()
        if sid not in written_ids
    ]
    return scope, excluded


def _backup_aligned(db_path: Path) -> str:
    """'aligned' | 'out of sync' | 'no backups' — last manifest entry vs LIVE db
    (read-only): sessions count, message count and max(time_updated) must match
    (the same triple the menu's o_backup_aligned uses)."""
    manifest = Path(default_bkp_dir()) / "manifest.json"
    if not manifest.exists():
        return "no backups"
    try:
        data = json.loads(manifest.read_text(encoding="utf-8"))
        backups = data.get("backups") or []
        last = backups[-1]
        msess, mmess, mu = last.get("sessions"), last.get("messages"), last.get("max_updated")
    except Exception:
        return "no backups"
    if msess is None or mmess is None or mu is None:
        return "no backups"
    try:
        con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        tsess = con.execute("SELECT count(*) FROM session").fetchone()[0]
        tmess = con.execute("SELECT count(*) FROM message").fetchone()[0]
        tu = con.execute("SELECT max(time_updated) FROM session").fetchone()[0] or 0
        con.close()
    except sqlite3.Error:
        return "no backups"
    if msess == tsess and mmess == tmess and mu == tu:
        return "aligned"
    return "out of sync"


def _print_presets() -> int:
    """`export --list-presets`: the named recipes of the presets file, one per
    line (name + derived verdict + its own `description`; a preset without one
    prints the name alone). No DB, no profile."""
    from exportlib.plan import (
        PRESET_DESCRIPTION_KEY,
        fidelity_parts,
        load_presets,
        preset_names,
        resolve,
    )
    presets = load_presets()
    names = preset_names(presets)
    if not names:
        print(
            f"No presets found at {default_presets()}.\n"
            "Create one (see the shipped presets.json for the contract) or set OCED_PRESETS.",
            file=sys.stderr,
        )
        return 1
    for n in names:
        plan = resolve(n, presets)
        verdict = fidelity_parts(
            plan["products"],
            plan["has_sanitize"],
            [item["config"] for item in plan["items"]],
        )[0]
        line = presets[n].get(PRESET_DESCRIPTION_KEY, "")
        print(f"{n:<16} {verdict:<9} {line}".rstrip())
    print()
    print(f"Details for one plan: opencode-db export <name> --show  (file: {default_presets()})")
    return 0


def _print_products() -> int:
    """`export --list-products`: the document kinds (the raw CLI nouns), their
    aliases and a pointer at the named plans. No DB, no profile."""
    from exportlib.plan import product_listing
    print("== Products (the document kinds; raw CLI) ==")
    print()
    print(product_listing())
    return 0


def _plan_block(profile: str) -> str:
    """The plan text for a profile, dying cleanly on an unknown name."""
    from exportlib.plan import plan_text
    try:
        return plan_text(profile)
    except ValueError as e:
        die(str(e))


def _show_plan(profile: str) -> int:
    """`export <name> --show`: the resolved plan only, static (no DB read)."""
    print(f"== Export plan: {profile} ==")
    print()
    print(_plan_block(profile))
    print()
    print("(plan only: the database was not read and nothing was written)")
    return 0


def _matched_sessions(con, args) -> dict:
    """The selection's matched set, AFTER subagent inclusion — the same set the
    real run writes, so a count taken here cannot disagree with the pipeline."""
    sessions = load_sessions(con, args.filter, args.sessions,
                             getattr(args, "last", None), getattr(args, "since", None))
    if not sessions:
        return {}
    return filter_subagent_policy(
        sessions, all_session_ids(con),
        getattr(args, "no_subagents", False),
        getattr(args, "no_orphan_subagents", False),
        getattr(args, "sub", None),
    )


def _counts(sessions: dict) -> str:
    """`N session(s) = R root(s) + S subagent(s)` for a matched set."""
    ids = set(sessions)
    roots = sum(1 for v in sessions.values() if v["parent_id"] not in ids)
    return f"{len(sessions)} session(s) = {roots} root(s) + {len(sessions) - roots} subagent(s)"


def _dry_run(args, profile: str) -> int:
    """`export <name> --dry-run`: the plan plus the sessions the current
    selection would match (read-only), and nothing is written."""
    text = _plan_block(profile)
    print(f"== Export plan: {profile} ==")
    print()
    print(text)
    print()
    print(f"Selection: {selection_label(args)}")

    db_path = Path(default_db())
    if not db_path.exists():
        print(f"(database not found at {db_path}; nothing was read or written)")
        return 0

    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    try:
        sessions = _matched_sessions(con, args)
    finally:
        con.close()
    if not sessions:
        print(f"Matched: 0 sessions — nothing would be exported ({selection_label(args)}).")
        return 0
    print(f"Matched: {_counts(sessions)}")
    print("(dry run: nothing was written)")
    return 0


def _explain() -> int:
    """`export --explain`: a static catalog of every preset — its description,
    the flags it sets and an example of the files it writes. Never reads the DB:
    the plan shown before a preset runs already accounts for any selection, so
    the catalog stays about the recipes themselves."""
    from exportlib.plan import explain_text, load_presets, preset_names
    presets = load_presets()
    if not preset_names(presets):
        print(
            f"No presets found at {default_presets()}.\n"
            "Create one (see the shipped presets.json for the contract) or set OCED_PRESETS.",
            file=sys.stderr,
        )
        return 1
    print(explain_text(presets).rstrip("\n"))
    return 0


def main() -> None:
    ap = build_argparser()
    args = ap.parse_args()

    # Discovery short-circuits before any profile resolution or DB access.
    if args.list_presets:
        sys.exit(_print_presets())
    if args.list_products:
        sys.exit(_print_products())
    if args.explain:
        sys.exit(_explain())

    profile_arg = args.profile
    resolve_profile(args, ap)

    if args.profile == "full":
        args.profile = "transcript"  # alias

    # Preview short-circuits before the write pipeline (`--show` never reads the DB).
    if args.show:
        sys.exit(_show_plan(profile_arg))

    if args.dry_run:
        sys.exit(_dry_run(args, profile_arg))

    if args.sessions:
        flat = []
        for part_ in args.sessions:  # preset may already hold a list of ids
            flat.extend((p.strip() for p in part_.split(",")) if isinstance(part_, str) else (str(p) for p in part_))
        args.sessions = [s for s in flat if s]
        if not args.sessions:
            die("--sessions received no ids")

    if args.bundle:
        run_bundle(args)
        return

    if args.preset_name:
        args.preset = args.preset_name

    db_path = Path(default_db())
    if not db_path.exists():
        die(f"Database not found: {db_path}")
    out_base = Path(args.out) if args.out else Path(default_out())

    if args.snapshot == "fresh" and not os.environ.get("OCED_FROM_BACKUP"):
        align = _backup_aligned(db_path)
        if align == "no backups":
            print(
                "warning: --snapshot fresh but no backup exists yet\n"
                "         (run: opencode-db backup, or the Backups menu, first)",
                file=sys.stderr,
            )
        elif align == "out of sync":
            print(
                "warning: --snapshot fresh but the last backup is out of sync with the live DB\n"
                "         (the export reads the live DB; run opencode-db backup to align\n"
                "         the reference archive before a snapshot export)",
                file=sys.stderr,
            )

    out_dir = make_outdir_final(out_base, args.profile, args.stamp)
    try:
        con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        con.row_factory = sqlite3.Row
    except sqlite3.Error as e:
        die(f"Could not open the DB read-only: {e}")

    sessions = load_sessions(con, args.filter, args.sessions,
                             getattr(args, "last", None), getattr(args, "since", None))
    if not sessions:
        die(f"No sessions to export ({selection_label(args)} matched nothing).")

    # ------- subagent inclusion (BEFORE the hierarchy) -------
    # `load_sessions` returns exactly what the selection matched, so a subagent is
    # in the set only when it was selected (or matched a --filter) itself. A
    # session is a REAL subagent when its parent_id is non-empty AND the parent
    # row still exists; a session whose parent row is gone is an orphan, i.e. a
    # root for every purpose here (its parent can never be exported, so there is
    # nothing to hide it behind). Filtering here — not after the hierarchy — keeps
    # the index, the metadata and the printed counts describing the SAME set.
    db_ids = all_session_ids(con)

    # Closed set: a selected subagent survives only while its parent survives, so
    # a nested chain collapses one level per pass (fixpoint). See the helper for
    # the one definition of a real subagent (an orphan is a root).
    before = len(sessions)
    sessions = filter_subagent_policy(
        sessions, db_ids, args.no_subagents, args.no_orphan_subagents)
    n_hidden = before - len(sessions)
    sessions = filter_subagent_policy(sessions, db_ids, sub=args.sub)
    if not sessions:
        if args.no_subagents:
            die("--no-subagents: every matched session is a subagent — nothing left to export.")
        if args.no_orphan_subagents:
            die(
                "--no-orphan-subagents: every matched session is a subagent whose "
                "parent is not exported — nothing left to export."
            )

    n_backfilled = backfill_session_tokens(con, sessions)
    renderer = Renderer(args)

    # ------- resolve hierarchy -------
    ids = set(sessions)
    parent_in = {k: v for k, v in sessions.items() if v["parent_id"] in ids}
    roots = []
    for k, v in sessions.items():
        if v["parent_id"] not in ids:  # root or orphan
            roots.append(k)
    roots.sort(key=lambda k: sessions[k]["time_created"])
    children_of = {}
    for k, v in parent_in.items():
        children_of.setdefault(v["parent_id"], []).append(k)
    for c in children_of.values():
        c.sort(key=lambda k: sessions[k]["time_created"])

    # The written set is predictable here (the same roots + children_of every
    # product writes), so `.scope`/`.excluded` can be computed ONCE, before the
    # product branches, and handed to a product that writes its own metadata.
    written_ids = set(roots)
    for rid in roots:
        written_ids.update(children_of.get(rid, []))
    scope, excluded = _scope_excluded(con, args, written_ids, db_ids)

    if args.profile == "memory":
        memory_export(con, sessions, roots, children_of, out_dir, args, db_path,
                      hidden=n_hidden, scope=scope, excluded=excluded)
        return

    if args.profile == "faithful":
        faithful_export(con, sessions, roots, children_of, out_dir, args, db_path,
                        hidden=n_hidden, scope=scope, excluded=excluded)
        return

    # ------- write sessions -------
    written = []
    total_comp = 0
    total_digest = 0
    total_msgs = 0
    for root_id in roots:
        root = sessions[root_id]
        subs = children_of.get(root_id, [])
        rfolder = out_dir / f"{len(written) + 1:02d}-{safe_filename(root['title'] or root['slug'])}_{root_id[:8]}"
        rfolder.mkdir()

        stem = safe_filename(root['title'] or root['slug'])
        rfile = rfolder / f"{stem}.md"
        n_msgs, n_comp = write_transcript(con, renderer, root, rfile)
        total_msgs += n_msgs
        total_comp += n_comp
        total_digest += root.get("digests") or 0

        if args.sub == "separate":
            for sid_ in subs:
                sub = sessions[sid_]
                subdir = rfolder / "subagents"
                subdir.mkdir(exist_ok=True)
                sfile = subdir / f"{safe_filename(sub['title'] or sub['slug'])}_{sid_[:8]}.md"
                sn, sc = write_transcript(con, renderer, sub, sfile)
                total_msgs += sn
                total_comp += sc
                total_digest += sub.get("digests") or 0
        elif args.sub == "inline":
            for sid_ in subs:
                sub = sessions[sid_]
                block_head = f"### Subagent: {sub['title'] or sub['slug']}  (`{sid_[:8]}`)\n\n"
                m, c = append_transcript_inline(con, renderer, sub, rfile, block_head=block_head)
                total_msgs += m
                total_comp += c
                total_digest += sub.get("digests") or 0

        written.append((root, subs, rfolder))

    # ------- index -------
    index_path = out_dir / "index.md"
    write_index(index_path, out_dir, args, db_path, sessions, written, total_msgs, total_comp,
                total_digest, n_backfilled, scope=scope)

    # ------- metadata -------
    meta_sha = sha256_file(db_path)
    last_bkp = last_backup_info()
    meta = {
        "tool": "opencode-db/exportlib",
        "version": TOOL_VERSION,
        "date": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "id": (args.stamp or Path(out_dir).name),
        "stamp": (args.stamp or Path(out_dir).name),
        "title": getattr(args, "title", None) or None,
        "notes": getattr(args, "notes", None) or None,
        "db": str(db_path),
        "db_sha256": meta_sha,
        "session_records": _session_records(written, sessions),
        "selection": selection_meta(args),
        "scope": scope,
        "excluded": excluded,
        "flags": effective_flags(args),
        **({"updated_from": args.update_from, "update_mode": args.update_mode or "delta"}
           if getattr(args, "update_from", None) else {}),
        "profile": args.profile,
        "preset": args.preset,
        "subagents_hidden": n_hidden,
        "tokens_backfilled": n_backfilled,
        # Two different things, never interchangeable: `compactions` counts the
        # markers opencode wrote (part.data.type='compaction'), `digests` the
        # summary texts it produced for them (message.data.mode='compaction').
        "compactions": total_comp,
        "digests": total_digest,
        "messages": total_msgs,
        "last_backup": last_bkp,
        "artifacts": [str(p.relative_to(out_dir)) for p in sorted(out_dir.rglob("*")) if p.is_file()],
    }
    (out_dir / "metadata.json").write_text(
        json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    print(f"[OK] Exported ({'preset ' + args.preset + ' → ' if args.preset else ''}{args.profile}) to: {out_dir}")
    print(f"   Root sessions : {len(written)}")
    print(f"   Subagents     : {sum(len(s[1]) for s in written)}")
    if n_hidden:
        flag = "--no-subagents" if args.no_subagents else "--no-orphan-subagents"
        print(f"   Excluded      : {n_hidden} subagent(s) ({flag})")
    print(f"   Compaction markers: {total_comp} · digests: {total_digest}")
    if n_backfilled:
        print(f"   Tokens        : {n_backfilled} session(s) backfilled from step-finish")
    print(f"   Last backup   : {last_bkp['file'] if last_bkp else 'none'}")


if __name__ == "__main__":
    main()
