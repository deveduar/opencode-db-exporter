# CLI entry: argument parsing, read-only DB access and run orchestration.
# Products (transcript | memory | compactions):
#   transcript  markdown transcript with verbosity toggles (+ optional faithful JSON)
#   memory      RAG corpus (corpus.jsonl, one entry per root session)
#   compactions the compacted-context digests (markdown)
# Global flags: --filter, --json (faithful archive alongside), --sanitize (redact
# secrets), --stamp. Transcript toggles: --sub, --tool-output, --patch,
# --no-reasoning, --mark-compactions, --summary-diffs, --role.
import argparse
import json
import sqlite3
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from exportlib import TOOL_VERSION
from exportlib.config import default_db, default_out
from exportlib.db import backfill_session_tokens, load_sessions
from exportlib.faithful import write_session_json
from exportlib.memory import memory_export
from exportlib.presets import bundle_child_argv, resolve_profile
from exportlib.render import Renderer
from exportlib.transcript import append_transcript_inline, write_transcript
from exportlib.util import die, safe_filename, sha256_file
from exportlib.writers import last_backup_info, make_outdir_final, write_index
from exportlib.flags import FLAGS


def _write_bundle_index(idx_dir, args, stamp: str, products, db_path) -> None:
    if args.sessions:
        sel = ", ".join(args.sessions)
    elif args.filter:
        sel = f"filter: {args.filter}"
    else:
        sel = "ALL sessions"
    lines = [
        "# opencode-db export bundle",
        "",
        "| Field | Value |",
        "|---|---|",
        f"| Preset | `{args.preset or '-'}` |",
        f"| Date | {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')} |",
        f"| Source DB | `{db_path}` |",
        f"| Selection | {sel} |",
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
    shim = Path(__file__).resolve().parent.parent / "export.py"
    for product in products:
        argv = bundle_child_argv(args, product)
        cmd = [sys.executable, str(shim)] + argv + ["--stamp", stamp]
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
                    help="product or named preset: transcript | memory | compactions | full | <preset from the presets file>")

    # Selection + output root come from FLAGS (single source of truth): --filter
    # and --sessions are mutually exclusive; --out is CLI-only (never a preset key).
    sel_group = ap.add_mutually_exclusive_group()
    for flag in FLAGS:
        if flag.name == "filter":
            sel_group.add_argument(f"--{flag.cli_name}", help=flag.cli_help)
        elif flag.name == "sessions":
            sel_group.add_argument(f"--{flag.cli_name}", action="append", metavar="SESSION_ID",
                                   help=flag.cli_help)
        elif flag.name == "out":
            ap.add_argument(f"--{flag.cli_name}", help=flag.cli_help)
        else:
            ap.add_argument(f"--{flag.cli_name}", **flag.argparse_args())

    # Hidden/internal args
    ap.add_argument("--stamp", help=argparse.SUPPRESS)
    ap.add_argument("--preset-name", help=argparse.SUPPRESS)
    return ap


def main() -> None:
    ap = build_argparser()
    args = ap.parse_args()
    resolve_profile(args, ap)

    if args.profile == "full":
        args.profile = "transcript"  # alias

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

    out_dir = make_outdir_final(out_base, args.profile, args.stamp)
    try:
        con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        con.row_factory = sqlite3.Row
    except sqlite3.Error as e:
        die(f"Could not open the DB read-only: {e}")

    sessions = load_sessions(con, args.filter, args.sessions)
    if not sessions:
        die("No sessions to export (check --filter/--sessions/preset selection).")

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

    if args.sub == "omit":
        children_of = {}

    if args.profile == "memory":
        memory_export(con, sessions, roots, children_of, out_dir, args, db_path)
        return

    # ------- write sessions -------
    written = []
    total_comp = 0
    total_msgs = 0
    for root_id in roots:
        root = sessions[root_id]
        subs = children_of.get(root_id, [])
        rfolder = out_dir / f"{len(written) + 1:02d}-{safe_filename(root['title'] or root['slug'])}_{root_id[:8]}"
        rfolder.mkdir()

        stem = safe_filename(root['title'] or root['slug'])
        rfile = rfolder / f"{stem}.md"
        n_msgs, n_comp = write_transcript(con, renderer, root, rfile)
        if renderer.json_mode:
            write_session_json(con, root, rfolder / f"{stem}.json", renderer.sanitize)
        total_msgs += n_msgs
        total_comp += n_comp

        if args.sub == "separate":
            for sid_ in subs:
                sub = sessions[sid_]
                subdir = rfolder / "subagents"
                subdir.mkdir(exist_ok=True)
                sfile = subdir / f"{safe_filename(sub['title'] or sub['slug'])}_{sid_[:8]}.md"
                sn, sc = write_transcript(con, renderer, sub, sfile)
                if renderer.json_mode:
                    write_session_json(con, sub, sfile.with_suffix(".json"), renderer.sanitize)
                total_msgs += sn
                total_comp += sc
        elif args.sub == "inline":
            for sid_ in subs:
                sub = sessions[sid_]
                block_head = f"### Subagent: {sub['title'] or sub['slug']}  (`{sid_[:8]}`)\n\n"
                m, c = append_transcript_inline(con, renderer, sub, rfile, block_head=block_head)
                if renderer.json_mode:
                    write_session_json(con, sub, rfolder / f"{stem}.sub-{sid_[:8]}.json", renderer.sanitize)
                total_msgs += m
                total_comp += c

        written.append((root, subs, rfolder))

    # ------- index -------
    index_path = out_dir / "index.md"
    write_index(index_path, out_dir, args, db_path, sessions, written, total_msgs, total_comp)

    # ------- metadata -------
    meta_sha = sha256_file(db_path)
    last_bkp = last_backup_info()
    meta = {
        "tool": "opencode-db/exportlib",
        "version": TOOL_VERSION,
        "date": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "db": str(db_path),
        "db_sha256": meta_sha,
        "filter": args.filter,
        "sessions_selected": args.sessions,
        "profile": args.profile,
        "preset": args.preset,
        "sub": args.sub,
        "tool_output": args.tool_output,
        "reasoning": renderer.reasoning,
        "summary_diffs": args.summary_diffs,
        "json": bool(args.json),
        "sanitize": bool(args.sanitize),
        "role": args.role,
        "tokens_backfilled": n_backfilled,
        "sessions": {
            "total": len(sessions),
            "roots": len(written),
            "subagents": sum(len(s[1]) for s in written),
        },
        "compactions": total_comp,
        "messages": total_msgs,
        "last_backup": last_bkp,
        "files": [str(p.relative_to(out_dir)) for p in sorted(out_dir.rglob("*")) if p.is_file()],
    }
    (out_dir / "metadata.json").write_text(
        json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    print(f"[OK] Exported ({'preset ' + args.preset + ' → ' if args.preset else ''}{args.profile}) to: {out_dir}")
    print(f"   Root sessions : {len(written)}")
    print(f"   Subagents     : {sum(len(s[1]) for s in written)}")
    print(f"   Compactions   : {total_comp}")
    if n_backfilled:
        print(f"   Tokens        : {n_backfilled} session(s) backfilled from step-finish")
    print(f"   Last backup   : {last_bkp['file'] if last_bkp else 'none'}")


if __name__ == "__main__":
    main()