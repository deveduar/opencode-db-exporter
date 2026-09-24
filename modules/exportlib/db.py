# Read-only SQLite access: session/message/part/todo queries, compaction
# digests, touched files and the token backfill (step-finish totals).
import json
import re
import sqlite3

from exportlib.util import ts_iso


# ---- token backfill -----------------------------------------------------------
# Old sessions carry 0/NULL tokens_* on the session row but the per-step usage is
# present in the `step-finish` parts: `{type:"step-finish", tokens:{input,output,
# reasoning,cache:{read,write}}, cost}`. Backfill those at export time (in-memory).
def step_finish_totals(con: sqlite3.Connection, sid: str) -> dict:
    rows = con.execute(
        "SELECT data FROM part WHERE session_id=? AND json_extract(data,'$.type')='step-finish'",
        (sid,),
    ).fetchall()
    t = {"input": 0, "output": 0, "reasoning": 0, "cache_read": 0, "cache_write": 0, "cost": 0.0}
    for r in rows:
        try:
            d = json.loads(r["data"])
        except (ValueError, TypeError):
            continue
        toks = d.get("tokens") or {}
        t["input"] += toks.get("input") or 0
        t["output"] += toks.get("output") or 0
        t["reasoning"] += toks.get("reasoning") or 0
        c = toks.get("cache") or {}
        t["cache_read"] += c.get("read") or 0
        t["cache_write"] += c.get("write") or 0
        t["cost"] += d.get("cost") or 0
    return t


def backfill_session_tokens(con: sqlite3.Connection, sessions: dict) -> int:
    """Fill tokens_*/cost for sessions where the row keeps none, from step-finish."""
    n = 0
    for s in sessions.values():
        if s["tokens_input"]:
            continue
        t = step_finish_totals(con, s["id"])
        if not (t["input"] or t["output"] or t["cost"]):
            continue
        s["tokens_input"] = t["input"]
        s["tokens_output"] = t["output"]
        s["tokens_reasoning"] = t["reasoning"]
        s["tokens_cache_read"] = t["cache_read"]
        s["tokens_cache_write"] = t["cache_write"]
        s["cost"] = t["cost"]
        s["tokens_backfilled"] = True
        n += 1
    return n


def load_sessions(con: sqlite3.Connection, filt: str | None, ids: list[str] | None = None):
    q = """
        SELECT s.id, s.title, s.slug, s.project_id, s.parent_id, s.directory, s.agent, s.model,
               s.time_created, s.time_updated, s.cost,
               s.tokens_input, s.tokens_output, s.tokens_reasoning,
               s.tokens_cache_read, s.tokens_cache_write,
               (SELECT count(*) FROM part pt WHERE pt.session_id = s.id
                    AND json_extract(pt.data,'$.type')='compaction') AS compactions
        FROM session s
    """
    params: list[str] = []
    where = ""
    if ids:
        ph = ",".join("?" * len(ids))
        where = f" WHERE s.id IN ({ph})"
        params = ids
    elif filt:
        where = " WHERE (s.id LIKE ? OR s.title LIKE ?)"
        params = [filt, filt]
    q += where + " ORDER BY s.time_created"
    rows = con.execute(q, params).fetchall()
    return {r["id"]: dict(r) for r in rows}


def load_messages(con: sqlite3.Connection, sid: str):
    """-> list[(mdata, parts)] with raw part dicts."""
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


def load_faithful(con: sqlite3.Connection, sid: str):
    """-> list[(mid, mdata, raw_parts)] for the faithful JSON archive."""
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
        out.append((m["id"], mdata, parts))
    return out


# Shared compaction-digest extraction: the digest of a compaction is the `text`
# part of the next message with data.mode='compaction' (the marker parts with
# data.type='compaction' carry no content). Both the `compactions` product and
# the `memory` product consume this same source.
def digests_for(con: sqlite3.Connection, sid: str) -> list[dict]:
    out = []
    for mdata, parts in load_messages(con, sid):
        if mdata.get("mode") != "compaction":
            continue
        t = "\n".join((p.get("text") or "") for p in parts if p.get("type") == "text").strip()
        if t:
            out.append({"created": (mdata.get("time") or {}).get("created"), "text": t})
    return out


_FILE_KEYS = {"path", "filePath", "file_path"}
_PATCH_RE = re.compile(r"^\+\+\+ b/(.+)$", re.M)


def _walk_file_keys(obj, acc) -> None:
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k in _FILE_KEYS and isinstance(v, str) and v.strip():
                acc.append(v.strip())
            else:
                _walk_file_keys(v, acc)
    elif isinstance(obj, list):
        for it in obj:
            _walk_file_keys(it, acc)


def touched_files(con: sqlite3.Connection, sid: str) -> list[str]:
    acc: list[str] = []
    for _mdata, parts in load_messages(con, sid):
        for p in parts:
            t = p.get("type")
            if t == "tool":
                _walk_file_keys((p.get("state") or {}).get("input") or {}, acc)
            elif t == "patch":
                patch = p.get("patch") or ""
                acc += list(_PATCH_RE.findall(patch))
    seen: set[str] = set()
    out = []
    for p in acc:
        if p not in seen:
            seen.add(p)
            out.append(p)
    return out


def load_todos(con: sqlite3.Connection, sid: str) -> dict:
    """Load todos for a session, returning open and done lists."""
    rows = con.execute(
        "SELECT content, status, priority, position, time_created, time_updated "
        "FROM todo WHERE session_id=? ORDER BY time_created",
        (sid,),
    ).fetchall()
    open_todos = []
    done_todos = []
    for r in rows:
        todo = {
            "content": r["content"],
            "status": r["status"],
            "priority": r["priority"],
            "position": r["position"],
            "created": ts_iso(r["time_created"]) or None,
            "updated": ts_iso(r["time_updated"]) or None,
        }
        if r["status"] == "done":
            done_todos.append(todo)
        else:
            open_todos.append(todo)
    return {"open": open_todos, "done": done_todos}