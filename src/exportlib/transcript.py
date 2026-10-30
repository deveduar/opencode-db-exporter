# Transcript / digest writers (markdown files).
from exportlib.chunking import chunk_markdown_file
from exportlib.db import count_messages, iter_messages
from exportlib.util import model_str, ts_iso


def _transcript_msgs(renderer, con, session: dict):
    for mdata, parts in iter_messages(con, session["id"]):
        if renderer.profile == "digest" and mdata.get("mode") != "compaction":
            continue
        if renderer.role != "all" and not renderer.include_message(mdata):
            continue
        yield mdata, parts


def write_transcript(con, renderer, session: dict, fpath, chunk=True):
    title = session["title"] or session["slug"]
    msgs = _transcript_msgs(renderer, con, session)
    n_comp = session["compactions"]
    n_digest = session.get("digests") or 0
    n_msgs = count_messages(con, session["id"], renderer.profile, renderer.role)
    model = model_str(session["model"])
    with fpath.open("w", encoding="utf-8") as f:
        f.write(f"# {title}\n\n")
        f.write(f"- **Session ID:** `{session['id']}`\n")
        f.write(f"- **Agent:** `{session['agent'] or '?'}`\n")
        f.write(f"- **Model:** `{model or '?'}`\n")
        f.write(f"- **Directory:** `{session['directory'] or '?'}`\n")
        f.write(f"- **Created:** {ts_iso(session['time_created'])}\n")
        if renderer.profile == "digest":
            f.write(
                f"- **Digests:** {n_msgs} written · **Compaction markers:** {n_comp}\n"
            )
        else:
            f.write(
                f"- **Messages:** {n_msgs} · **Digests:** {n_digest}"
                f" · **Compaction markers:** {n_comp}\n"
            )
        if session["parent_id"]:
            f.write(f"- **Subagent of:** `{session['parent_id']}`\n")
        f.write("\n---\n\n")
        for mdata, parts in msgs:
            diffs_html = renderer.summary_diffs(mdata) if renderer.diffs else ""
            rendered = renderer.render_message(mdata, parts, diffs_html)
            if rendered:
                f.write(rendered + "\n\n---\n\n")
    chunk_mb = getattr(renderer, "chunk_mb", 0)
    if chunk and renderer.profile == "transcript" and chunk_mb > 0:
        chunk_markdown_file(fpath, chunk_mb, title, session["id"])
    return n_msgs, n_comp


def append_transcript_inline(con, renderer, session: dict, fpath, block_head: str):
    msgs = _transcript_msgs(renderer, con, session)
    n_msgs = count_messages(con, session["id"], renderer.profile, renderer.role)
    with fpath.open("a", encoding="utf-8") as f:
        f.write("\n\n---\n\n")
        f.write(block_head)
        f.write(f"*Subagent of `{session.get('id','')}` — agent `{session.get('agent') or '?'}`*\n\n")
        for mdata, parts in msgs:
            diffs_html = renderer.summary_diffs(mdata) if renderer.diffs else ""
            rendered = renderer.render_message(mdata, parts, diffs_html)
            if rendered:
                f.write(rendered + "\n\n---\n\n")
    return n_msgs, session["compactions"]
