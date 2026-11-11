# Transcript / digest writers (markdown files).
from exportlib.chunking import chunk_markdown_file
from exportlib.db import count_messages, iter_messages
from exportlib.util import model_str, ts_iso, yaml_frontmatter


def _transcript_msgs(renderer, con, session: dict):
    for mdata, parts in iter_messages(con, session["id"]):
        if renderer.profile == "digest" and mdata.get("mode") != "compaction":
            continue
        if renderer.role != "all" and not renderer.include_message(mdata):
            continue
        yield mdata, parts


def _record_message(f, rendered: str, message_sizes: list[int]) -> None:
    message_text = rendered.rstrip("\n") + "\n\n"
    f.write(message_text)
    message_sizes.append(len(message_text.encode("utf-8")))


def session_frontmatter(session: dict, profile: str, messages: int,
                        compactions: int, digests: int, title: str,
                        con=None) -> dict:
    agent_value = session["agent"]
    model_value = session["model"]
    if con is not None and (not agent_value or not model_value):
        stored = con.execute(
            """
            SELECT
                (SELECT json_extract(data, '$.agent')
                 FROM message
                 WHERE session_id = ?
                   AND json_extract(data, '$.agent') IS NOT NULL
                 ORDER BY time_created DESC
                 LIMIT 1) AS agent,
                (SELECT COALESCE(
                     NULLIF(json_extract(data, '$.model'), ''),
                     json_extract(data, '$.modelID'))
                 FROM message
                 WHERE session_id = ?
                   AND (json_extract(data, '$.model') IS NOT NULL
                        OR json_extract(data, '$.modelID') IS NOT NULL)
                 ORDER BY time_created DESC
                 LIMIT 1) AS model
            """,
            (session["id"], session["id"]),
        ).fetchone()
        if stored:
            agent_value = agent_value or stored["agent"]
            model_value = model_value or stored["model"]
    model = model_str(model_value)
    fields = {
        "title": title,
        "profile": profile,
        "session_id": session["id"],
        "agent": agent_value or "?",
        "model": model or "?",
        "directory": session["directory"] or "?",
        "created": ts_iso(session["time_created"]),
    }
    if profile == "digest":
        fields["digests"] = messages
        fields["compaction_markers"] = compactions
    else:
        fields["messages"] = messages
        fields["digests"] = digests
        fields["compaction_markers"] = compactions
    if session.get("parent_id"):
        fields["parent_id"] = session["parent_id"]
    return fields


def write_transcript(con, renderer, session: dict, fpath, chunk=True, message_sizes=None):
    title = session["title"] or session["slug"]
    msgs = _transcript_msgs(renderer, con, session)
    n_comp = session["compactions"]
    n_digest = session.get("digests") or 0
    n_msgs = count_messages(con, session["id"], renderer.profile, renderer.role)
    metadata = session_frontmatter(
        session, renderer.profile, n_msgs, n_comp, n_digest, title, con
    )
    message_sizes = message_sizes if message_sizes is not None else []
    with fpath.open("w", encoding="utf-8", newline="") as f:
        f.write(yaml_frontmatter(metadata))
        f.write(f"# {title}\n\n")
        for mdata, parts in msgs:
            diffs_html = renderer.summary_diffs(mdata) if renderer.diffs else ""
            rendered = renderer.render_message(mdata, parts, diffs_html)
            if rendered:
                _record_message(f, rendered, message_sizes)
    chunk_mb = getattr(renderer, "chunk_mb", 0)
    if chunk and renderer.profile == "transcript" and chunk_mb > 0:
        chunk_markdown_file(
            fpath, chunk_mb, title, session["id"], message_sizes, metadata
        )
    return n_msgs, n_comp


def append_transcript_inline(
    con, renderer, session: dict, fpath, block_head: str, message_sizes=None
):
    msgs = _transcript_msgs(renderer, con, session)
    n_msgs = count_messages(con, session["id"], renderer.profile, renderer.role)
    with fpath.open("a", encoding="utf-8", newline="") as f:
        prefix = block_head
        prefix += (
            f"*Subagent of `{session.get('parent_id') or '?'}` — "
            f"agent `{session.get('agent') or '?'}`*\n\n"
        )
        first_rendered = True
        sizes = message_sizes if message_sizes is not None else []
        for mdata, parts in msgs:
            diffs_html = renderer.summary_diffs(mdata) if renderer.diffs else ""
            rendered = renderer.render_message(mdata, parts, diffs_html)
            if rendered:
                _record_message(f, (prefix if first_rendered else "") + rendered, sizes)
                first_rendered = False
    return n_msgs, session["compactions"]
