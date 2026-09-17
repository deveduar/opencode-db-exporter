#!/usr/bin/env python3
# export.py — Markdown renderer for the opencode database.
# Profiles (full | no-calls | text-only), session filter, subagent grouping,
# tool-output truncation, compaction markers, summary.diffs and a top-level index.md.
import argparse
import hashlib
import json
import os
import re
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

TOOL_VERSION = "0.1.0"


def die(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def default_db() -> str:
    return os.environ.get("OPENCODE_DB", str(Path.home() / ".local/share/opencode/opencode.db"))


def default_out() -> str:
    return os.environ.get("OCED_OUT", str(Path.home() / ".local/share/opencode-db-exporter/exports"))


def default_bkp_dir() -> str:
    return os.environ.get("OCED_BACKUP_DIR", str(Path.home() / ".local/share/opencode-db-exporter/backups"))


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def ts_iso(ms: int) -> str:
    if not ms:
        return ""
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


def safe_filename(name: str, fallback: str = "session") -> str:
    s = re.sub(r"[^A-Za-z0-9_\- ]+", "", name or "").strip()
    s = re.sub(r"\s+", " ", s)[:80]
    return s or fallback


def truncate(text: str, limit: int) -> str:
    text = str(text)
    if len(text) <= limit:
        return text
    return text[:limit] + f"\n[… truncated: {len(text) - limit} bytes more …]"


ROLE_HEADER = {"user": "## 👤 User", "assistant": "## 🤖 Assistant"}


class Renderer:
    def __init__(self, args):
        self.profile = args.profile
        self.sub = args.sub
        self.tool_output = args.tool_output
        self.tool_out_limit = args.tool_output_limit
        self.tool_in_limit = args.tool_input_limit
        self.patch_mode = args.patch
        self.mark_compactions = args.mark_compactions
        self.diffs = args.summary_diffs
        self.filter = args.filter

    # ---- part inclusion ----
    def include_part(self, ptype: str) -> bool:
        if self.profile == "text-only":
            return ptype == "text"
        if self.profile == "no-calls":
            return ptype in ("text", "reasoning")
        # full
        if ptype == "tool":
            return self.tool_output != "omit"
        if ptype == "patch":
            return self.patch_mode == "full"
        if ptype in ("compaction",):
            return self.mark_compactions
        return True

    def render_part(self, p: dict, out: list) -> None:
        t = p.get("type")
        if not self.include_part(t):
            return
        if t == "text":
            txt = (p.get("text") or "").rstrip()
            if txt.strip():
                out.append(txt)
        elif t == "reasoning":
            txt = (p.get("text") or p.get("reasoning") or "").rstrip()
            if txt.strip():
                out.append("> _Reasoning:_\n>\n> " + txt.strip().replace("\n", "\n> "))
        elif t == "tool":
            tool = p.get("tool", "?")
            state = p.get("state") or {}
            status = state.get("status", "")
            inp = state.get("input", {})
            outp = state.get("output", "")
            title = state.get("title") or ""
            line = f"**Tool:** `{tool}` ({status})"
            if title:
                line += f" — {title}"
            out.append(line)
            if inp not in (None, {}):
                block = json.dumps(inp, indent=2, ensure_ascii=False)
                if self.tool_output == "truncated":
                    block = truncate(block, self.tool_in_limit)
                out.append("```json\n" + block.rstrip() + "\n```")
            if outp:
                if self.tool_output == "truncated":
                    outp = truncate(outp, self.tool_out_limit)
                out.append("**Output:**\n\n```\n" + str(outp).rstrip() + "\n```")
        elif t == "patch":
            patch = p.get("patch") or json.dumps(p, ensure_ascii=False)
            out.append("**Patch:**\n\n```diff\n" + patch.rstrip() + "\n```")
        elif t == "file":
            out.append("```json\n" + json.dumps(p, indent=2, ensure_ascii=False) + "\n```")
        elif t in ("step-start", "step-finish"):
            out.append(f"<!-- {t} -->")
        elif t == "compaction":
            tail = p.get("tail_start_id", "")
            auto = p.get("auto", True)
            extra = " (auto)" if auto else ""
            out.append(
                "---\n\n> ⚙️ **Context compaction**" + extra
                + (f" — new queue from `{tail}`" if tail else "")
                + "\n"
            )

    def summary_diffs(self, mdata: dict) -> str:
        summary = mdata.get("summary")
        diffs = (summary.get("diffs") if isinstance(summary, dict) else None) or []
        if not diffs:
            return ""
        lines = ["**Summary of changes:**\n"]
        for d in diffs:
            f = d.get("file", "?")
            add = d.get("additions", 0)
            dele = d.get("deletions", 0)
            status = d.get("status", "")
            lines.append(f"- `{f}`  (+{add} −{dele})  {status}")
        return "\n".join(lines)

    def render_message(self, mdata: dict, parts: list[dict], diffs_html: str) -> str:
        role = mdata.get("role", "unknown")
        header = ROLE_HEADER.get(role, f"## {role}")
        created = (mdata.get("time") or {}).get("created")
        if created:
            header += f"  ·  {ts_iso(created)}"

        body: list[str] = []
        for p in parts:
            self.render_part(p, body)

        if self.diffs and diffs_html:
            if body:
                body.append(diffs_html)
            else:
                body.append(diffs_html)

        if not body:
            return ""
        rendered = "\n\n".join(x.rstrip() for x in body if x.rstrip())
        if not rendered.strip():
            return ""
        return header + "\n\n" + rendered + "\n"


def load_sessions(con: sqlite3.Connection, filt: str | None):
    q = """
        SELECT s.id, s.title, s.slug, s.project_id, s.parent_id, s.directory, s.agent, s.model,
               s.time_created, s.time_updated, s.cost,
               s.tokens_input, s.tokens_output, s.tokens_reasoning,
               (SELECT count(*) FROM part pt WHERE pt.session_id = s.id
                    AND json_extract(pt.data,'$.type')='compaction') AS compactions
        FROM session s
    """
    params: list[str] = []
    where = ""
    if filt:
        where = " WHERE (s.id LIKE ? OR s.title LIKE ?)"
        params = [filt, filt]
    q += where + " ORDER BY s.time_created"
    rows = con.execute(q, params).fetchall()
    return {r["id"]: dict(r) for r in rows}


def load_messages(con: sqlite3.Connection, sid: str):
    msgs = con.execute(
        "SELECT id, data FROM message WHERE session_id=? ORDER BY time_created", (sid,)
    ).fetchall()
    out = []
    for m in msgs:
        mdata = json.loads(m["data"])
        parts = [
            json.loads(p["data"])
            for p in con.execute(
                "SELECT data FROM part WHERE message_id=? ORDER BY time_created",
                (m["id"],),
            )
        ]
        out.append((mdata, parts))
    return out


def make_outdir_final(base: Path, profile: str) -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    target = base / stamp / profile
    n = 2
    while target.exists():
        target = base / f"{stamp}@{n}" / profile
        n += 1
    target.mkdir(parents=True, exist_ok=False)
    return target


def main() -> None:
    ap = argparse.ArgumentParser(prog="opencode-db export", description="Export opencode sessions to Markdown.")
    ap.add_argument("profile", nargs="?", default="full", choices=["full", "no-calls", "text-only"])
    ap.add_argument("--filter", help="SQL LIKE on session id/title, e.g. 'ses_f7%'")
    ap.add_argument("--out", help="output root dir")
    ap.add_argument("--sub", default="separate", choices=["separate", "inline", "omit"])
    ap.add_argument("--tool-output", default="truncated", choices=["full", "truncated", "omit"])
    ap.add_argument("--tool-input-limit", type=int, default=800)
    ap.add_argument("--tool-output-limit", type=int, default=500)
    ap.add_argument("--patch", default="full", choices=["full", "omit"])
    ap.add_argument("--mark-compactions", action="store_true")
    ap.add_argument("--summary-diffs", action="store_true")
    args = ap.parse_args()

    db_path = Path(default_db())
    if not db_path.exists():
        die(f"Database not found: {db_path}")
    out_base = Path(args.out) if args.out else Path(default_out())

    out_dir = make_outdir_final(out_base, args.profile)
    try:
        con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        con.row_factory = sqlite3.Row
    except sqlite3.Error as e:
        die(f"Could not open the DB read-only: {e}")

    sessions = load_sessions(con, args.filter)
    if not sessions:
        die("No sessions match the filter (e.g. 'ses_f7%').")

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

    # ------- escribir sesiones -------
    written = []
    total_comp = 0
    total_msgs = 0
    for root_id in roots:
        root = sessions[root_id]
        subs = children_of.get(root_id, [])
        rfolder = out_dir / f"{len(written) + 1:02d}-{safe_filename(root['title'] or root['slug'])}_{root_id[:8]}"
        rfolder.mkdir()

        rfile = rfolder / f"{safe_filename(root['title'] or root['slug'])}.md"
        n_msgs, n_comp = write_transcript(con, renderer, root, rfile)
        total_msgs += n_msgs
        total_comp += n_comp

        if args.sub == "separate":
            for sid_ in subs:
                sub = sessions[sid_]
                subdir = rfolder / "subagents"
                subdir.mkdir(exist_ok=True)
                sfile = subdir / f"{safe_filename(sub['title'] or sub['slug'])}_{sid_[:8]}.md"
                sn, sc = write_transcript(con, renderer, sub, sfile)
                total_msgs += sn
                total_comp += sc
        elif args.sub == "inline":
            for sid_ in subs:
                sub = sessions[sid_]
                block_head = f"### Subagent: {sub['title'] or sub['slug']}  (`{sid_[:8]}`)\n\n"
                m, c = append_transcript_inline(con, renderer, sub, rfile, block_head=block_head)
                total_msgs += m
                total_comp += c

        written.append((root, subs, rfolder))

    # ------- index -------
    index_path = out_dir / "index.md"
    write_index(index_path, out_dir, args, db_path, sessions, written, total_msgs, total_comp)

    # ------- metadatos -------
    meta_sha = sha256_file(db_path)
    last_bkp = last_backup_info()
    meta = {
        "tool": "opencode-db/export.py",
        "version": TOOL_VERSION,
        "date": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "db": str(db_path),
        "db_sha256": meta_sha,
        "filter": args.filter,
        "profile": args.profile,
        "sub": args.sub,
        "tool_output": args.tool_output,
        "summary_diffs": args.summary_diffs,
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
    (out_dir / "metadatos.json").write_text(
        json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    print(f"✅ Exported ({args.profile}) to: {out_dir}")
    print(f"   Root sessions : {len(written)}")
    print(f"   Subagents     : {sum(len(s[1]) for s in written)}")
    print(f"   Compactions   : {total_comp}")
    print(f"   Last backup   : {last_bkp['file'] if last_bkp else 'none'}")


def write_transcript(con, renderer, session: dict, fpath: Path):
    title = session["title"] or session["slug"]
    msgs = load_messages(con, session["id"])
    n_comp = session["compactions"]
    n_msgs = len(msgs)
    model = session["model"]
    if model:
        try:
            model = json.dumps(json.loads(model), ensure_ascii=False)
        except (ValueError, TypeError):
            pass
    with fpath.open("w", encoding="utf-8") as f:
        f.write(f"# {title}\n\n")
        f.write(f"- **Session ID:** `{session['id']}`\n")
        f.write(f"- **Agent:** `{session['agent'] or '?'}`\n")
        f.write(f"- **Model:** `{model or '?'}`\n")
        f.write(f"- **Directory:** `{session['directory'] or '?'}`\n")
        f.write(f"- **Created:** {ts_iso(session['time_created'])}\n")
        f.write(f"- **Messages:** {n_msgs} · **Compaction parts:** {n_comp}\n")
        if session["parent_id"]:
            f.write(f"- **Subagent of:** `{session['parent_id']}`\n")
        f.write("\n---\n\n")
        for mdata, parts in msgs:
            diffs_html = renderer.summary_diffs(mdata) if renderer.diffs else ""
            rendered = renderer.render_message(mdata, parts, diffs_html)
            if rendered:
                f.write(rendered + "\n\n---\n\n")
    return n_msgs, n_comp


def append_transcript_inline(con, renderer, session: dict, fpath: Path, block_head: str):
    msgs = load_messages(con, session["id"])
    with fpath.open("a", encoding="utf-8") as f:
        f.write("\n\n---\n\n")
        f.write(block_head)
        f.write(f"*Subagent of `{session.get('id','')}` — agent `{session.get('agent') or '?'}`*\n\n")
        for mdata, parts in msgs:
            diffs_html = renderer.summary_diffs(mdata) if renderer.diffs else ""
            rendered = renderer.render_message(mdata, parts, diffs_html)
            if rendered:
                f.write(rendered + "\n\n---\n\n")
    return len(msgs), session["compactions"]


def write_index(index_path: Path, out_dir: Path, args, db_path: Path, sessions, written, total_msgs, total_comp):
    with index_path.open("w", encoding="utf-8") as f:
        f.write("# opencode session export\n\n")
        f.write("| Field | Value |\n|---|---|\n")
        f.write(f"| Profile | `{args.profile}` |\n")
        f.write(f"| Date | {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')} |\n")
        f.write(f"| Source DB | `{db_path}` |\n")
        if args.filter:
            f.write(f"| Filter | `{args.filter}` |\n")
        f.write(f"| Sessions (roots/subagents/total) | {len(written)} / {sum(len(s[1]) for s in written)} / {len(sessions)} |\n")
        f.write(f"| Messages | {total_msgs} |\n")
        f.write(f"| Compactions | {total_comp} |\n")
        f.write(f"| Tool output | `{args.tool_output}` |\n")
        f.write("| Extraction | Python `export.py` (read `mode=ro`) from `~/.local/share/opencode/opencode.db` |\n")
        f.write(f"| Full metadata | [`metadatos.json`](metadatos.json) |\n\n")
        f.write("## Sessions\n\n")
        for i, (root, subs, rfolder) in enumerate(written, 1):
            rt = root["title"] or root["slug"]
            root_md = rfolder / f"{safe_filename(rt)}.md"
            rel_d = root_md.relative_to(out_dir)
            f.write(f"{i}. **[{rt}]({rel_d})**  — `{root['id']}`  · agent `{root.get('agent') or '?'}`\n")
            if subs:
                f.write("   \n   Subagents:\n")
                for sid_ in subs:
                    sub = sessions[sid_]
                    st = sub["title"] or sub["slug"]
                    rel_s = (rfolder / "subagents" / f"{safe_filename(st)}_{sub['id'][:8]}.md").relative_to(out_dir)
                    f.write(f"   - [{st}]({rel_s})  `{sub['id'][:8]}`\n")
            f.write("\n")
        f.write("---\n")
        f.write(f"\nGenerated by `opencode-db` v{TOOL_VERSION}.\n")


def last_backup_info():
    manifest = Path(default_bkp_dir()) / "manifest.json"
    if not manifest.exists():
        return None
    try:
        data = json.loads(manifest.read_text(encoding="utf-8"))
        b = data.get("backups") or []
        if not b:
            return None
        b = sorted(b, key=lambda x: x.get("date", ""))
        last = b[-1]
        return {"file": last.get("file"), "date": last.get("date")}
    except Exception:
        return None


if __name__ == "__main__":
    main()