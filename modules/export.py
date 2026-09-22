#!/usr/bin/env python3
# export.py — Export renderer for the opencode database (read-only).
# Products (transcript | memory | compactions):
#   transcript  markdown transcript with verbosity toggles (+ optional faithful JSON)
#   memory      RAG corpus (corpus.jsonl, one entry per root session)
#   compactions the compacted-context digests (markdown)
# Global flags: --filter, --json (faithful archive alongside), --sanitize (redact
# secrets), --stamp. Transcript toggles: --sub, --tool-output, --patch,
# --no-reasoning, --mark-compactions, --summary-diffs, --role.
import argparse
import hashlib
import json
import os
import re
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

TOOL_VERSION = "1.1.0"


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


# ---- secret redaction (--sanitize) --------------------------------------------
# Redaction only rewrites export output, never the DB. Patterns cover the common
# leak classes; recursive so nested tool state is caught too.
_SANITIZE_PATTERNS = [
    (re.compile(r"-----BEGIN [A-Z ]+PRIVATE KEY-----.*?-----END [A-Z ]+PRIVATE KEY-----", re.S),
     "-----BEGIN PRIVATE KEY-----[REDACTED]-----END PRIVATE KEY-----"),
    (re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=\-]{12,}\b", re.I), "Bearer [REDACTED]"),
    (re.compile(r"\b(sk-[A-Za-z0-9]{16,})\b"), "sk-[REDACTED]"),
    (re.compile(r"\b(ghp_[A-Za-z0-9]{20,})\b"), "ghp_[REDACTED]"),
    (re.compile(r"\b(gho_[A-Za-z0-9]{20,})\b"), "gho_[REDACTED]"),
    (re.compile(r"\b(github_pat_[A-Za-z0-9_]{20,})\b"), "github_pat_[REDACTED]"),
    (re.compile(r"\b(xox[baprs]-[A-Za-z0-9-]{8,})\b"), "xox-[REDACTED]"),
    (re.compile(r"\b(AIza[0-9A-Za-z_\-]{20,})\b"), "AIza[REDACTED]"),
    (re.compile(r"\b(AKIA[0-9A-Z]{16})\b"), "AKIA[REDACTED]"),
    (re.compile(r"\b(eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,})\b"), "eyJ[REDACTED]"),
    (re.compile(r"\b(sk-ant-[A-Za-z0-9_\-]{20,})\b"), "sk-ant-[REDACTED]"),
    (re.compile(r"(?i)OPENAI_API_KEY|ANTHROPIC_API_KEY|OPENROUTER_API_KEY|AI_KEYS|API_KEY\b"), "API_KEY"),
    (re.compile(r"(?i)\b(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|authorization)\b\s*[:=]\s*[\"']?[^\s\"'&,;]{8,}"),
     r"\1: [REDACTED]"),
]


def sanitize(text: str) -> str:
    text = str(text)
    for rx, rep in _SANITIZE_PATTERNS:
        text = rx.sub(rep, text)
    return text


def sanitize_json(obj):
    if isinstance(obj, dict):
        return {k: sanitize_json(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [sanitize_json(v) for v in obj]
    if isinstance(obj, str):
        return sanitize(obj)
    return obj


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


# ------------------------------------------------------------------------------
ROLE_HEADER = {"user": "## User", "assistant": "## Assistant"}


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
        self.role = args.role
        self.reasoning = not args.no_reasoning
        self.json_mode = args.json
        self.sanitize = args.sanitize

    def w(self, s: str) -> str:
        return sanitize(s) if self.sanitize else s

    # ---- message inclusion (role filter) ----
    def include_message(self, mdata: dict) -> bool:
        return self.role == "all" or mdata.get("role") == self.role

    # ---- part inclusion ----
    def include_part(self, ptype: str) -> bool:
        if self.profile == "compactions":
            return ptype == "text"
        # transcript
        if ptype == "tool":
            return self.tool_output != "omit"
        if ptype == "patch":
            return self.patch_mode == "full"
        if ptype == "reasoning":
            return self.reasoning
        if ptype == "compaction":
            return self.mark_compactions
        return True

    def render_part(self, p: dict, out: list) -> None:
        t = p.get("type")
        if not self.include_part(t):
            return
        if t == "text":
            txt = (p.get("text") or "").rstrip()
            if txt.strip():
                out.append(self.w(txt))
        elif t == "reasoning":
            txt = (p.get("text") or p.get("reasoning") or "").rstrip()
            if txt.strip():
                txt = self.w(txt.strip().replace("\n", "\n> "))
                out.append("> _Reasoning:_\n>\n> " + txt)
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
                if self.sanitize:
                    block = sanitize(block)
                if self.tool_output == "truncated":
                    block = truncate(block, self.tool_in_limit)
                out.append("```json\n" + block.rstrip() + "\n```")
            if outp:
                if self.sanitize:
                    outp = sanitize(str(outp))
                if self.tool_output == "truncated":
                    outp = truncate(outp, self.tool_out_limit)
                out.append("**Output:**\n\n```\n" + str(outp).rstrip() + "\n```")
        elif t == "patch":
            patch = p.get("patch") or json.dumps(p, ensure_ascii=False)
            if self.sanitize:
                patch = sanitize(patch)
            out.append("**Patch:**\n\n```diff\n" + patch.rstrip() + "\n```")
        elif t == "file":
            block = json.dumps(p, indent=2, ensure_ascii=False)
            if self.sanitize:
                block = sanitize(block)
            out.append("```json\n" + block.rstrip() + "\n```")
        elif t in ("step-start", "step-finish"):
            out.append(f"<!-- {t} -->")
        elif t == "compaction":
            tail = p.get("tail_start_id", "")
            auto = p.get("auto", True)
            extra = " (auto)" if auto else ""
            out.append(
                "---\n\n> **Context compaction**" + extra
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
            lines.append(self.w(f"- `{f}`  (+{add} −{dele})  {status}"))
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
            body.append(diffs_html)

        if not body:
            return ""
        rendered = "\n\n".join(x.rstrip() for x in body if x.rstrip())
        if not rendered.strip():
            return ""
        return header + "\n\n" + rendered + "\n"


# ------------------------------------------------------------------------------
def load_sessions(con: sqlite3.Connection, filt: str | None):
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
    if filt:
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


def model_str(model) -> str:
    if not model:
        return ""
    try:
        return json.dumps(json.loads(model), ensure_ascii=False)
    except (ValueError, TypeError):
        return str(model)


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
            "created": ts_iso(r["time_created"]),
            "updated": ts_iso(r["time_updated"]),
        }
        if r["status"] == "done":
            done_todos.append(todo)
        else:
            open_todos.append(todo)
    return {"open": open_todos, "done": done_todos}


def memory_session_entry(con, s: dict, cap: int = 0, files: bool = False, sanitize_on: bool = False) -> dict:
    msgs = load_messages(con, s["id"])
    first_user = ""
    last_assistant = ""
    digests = digests_for(con, s["id"])
    tools = 0
    for mdata, parts in msgs:
        texts = [(p.get("text") or "").strip() for p in parts if p.get("type") == "text"]
        t = "\n".join(x for x in texts if x).strip()
        tools += sum(1 for p in parts if p.get("type") == "tool")
        if mdata.get("role") == "user" and t and not first_user:
            first_user = t
        if mdata.get("role") == "assistant" and t:
            last_assistant = t

    def cap_text(x: str) -> str:
        if cap and cap > 0 and len(x) > cap:
            return x[:cap]
        return x

    dig = [{"created": ts_iso(d["created"]), "text": cap_text(d["text"])} for d in digests]
    if sanitize_on:
        first_user = sanitize(cap_text(first_user))
        last_assistant = sanitize(cap_text(last_assistant))
        for d_ in dig:
            d_["text"] = sanitize(d_["text"])
        first_user_raw = first_user
        last_assistant_raw = last_assistant
    else:
        first_user_raw = cap_text(first_user)
        last_assistant_raw = cap_text(last_assistant)

    e = {
        "id": s["id"],
        "title": s["title"] or s["slug"],
        "slug": s["slug"],
        "directory": s["directory"],
        "agent": s["agent"] or "",
        "model": model_str(s["model"]),
        "created": ts_iso(s["time_created"]),
        "updated": ts_iso(s["time_updated"]),
        "cost": s["cost"] or 0,
        "tokens": {
            "input": s["tokens_input"] or 0,
            "output": s["tokens_output"] or 0,
            "reasoning": s["tokens_reasoning"] or 0,
            "cache": {
                "read": s["tokens_cache_read"] or 0,
                "write": s["tokens_cache_write"] or 0,
            },
            "backfilled": bool(s.get("tokens_backfilled")),
        },
        "parent_id": s["parent_id"] or "",
        "messages": len(msgs),
        "tools": tools,
        "compactions": s["compactions"],
        "first_user": first_user_raw,
        "last_assistant": last_assistant_raw,
        "compaction_digests": dig,
        "todos": load_todos(con, s["id"]),
    }
    if files:
        e["files"] = touched_files(con, s["id"])
    return e


def memory_subagent_ref(sessions, sid: str) -> dict:
    s = sessions[sid]
    return {
        "id": sid,
        "title": s["title"] or s["slug"],
        "agent": s["agent"] or "",
        "directory": s["directory"],
        "created": ts_iso(s["time_created"]),
    }


def memory_export(con, sessions, roots, children_of, out_dir, args, db_path) -> None:
    # Stream the corpus line by line: one root + its subagents = one JSON line,
    # written to disk immediately. The corpus is never accumulated in memory (it
    # can be larger than the DB itself when --cap is off), which keeps the peak
    # RAM bounded to a single root session at a time.
    n_root = 0
    n_subs = 0
    total_msgs = 0
    total_comp = 0
    total_backfilled = 0
    with (out_dir / "corpus.jsonl").open("w", encoding="utf-8") as corpus:
        for rid in roots:
            root = sessions[rid]
            subs = children_of.get(rid, [])
            e = memory_session_entry(con, root, cap=args.cap or 0, files=args.files, sanitize_on=args.sanitize)
            e["subagents"] = [memory_subagent_ref(sessions, s) for s in subs]
            corpus.write(json.dumps(e, ensure_ascii=False) + "\n")
            corpus.flush()
            n_root += 1
            n_subs += len(subs)
            total_msgs += e["messages"]
            total_comp += e["compactions"]
            if e["tokens"]["backfilled"]:
                total_backfilled += 1

    idx_rows = [
        "# opencode memory corpus",
        "",
        "| Field | Value |",
        "|---|---|",
        "| Product | `memory` |",
        "| Date | {0} |".format(datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")),
        f"| Source DB | `{db_path}` |",
    ]
    if args.filter:
        idx_rows.append(f"| Filter | `{args.filter}` |")
    idx_rows += [
        f"| Root sessions | {n_root} |",
        f"| Subagents (summarized inline) | {n_subs} |",
        f"| Messages (roots) | {total_msgs} |",
        f"| Compactions | {total_comp} |",
        f"| Tuning | `--cap {'0 (unlimited)' if not args.cap else args.cap}` · `--files {'on' if args.files else 'off'}` |",
        f"| Sanitize | `{'on' if args.sanitize else 'off'}` |",
        f"| Tokens backfilled from step-finish | {total_backfilled} session(s) |",
        "| Role filter | `--role {0}` (applies to transcripts; memory ignores it)".format(args.role),
        "| Corpus | [`corpus.jsonl`](corpus.jsonl) - one JSON object per root session |",
        "",
        "Each entry is a reusable memory for RAG: metadata (id/title/agent/model/",
        "dates/tokens/cost) for filtering, the first user request (the goal), the",
        "last assistant answer (the outcome), ALL compaction digests (the durable",
        "knowledge opencode distilled), and optionally the touched files (`--files`).",
        "Text is unlimited by default; truncate any value with `--cap N` (0 = keep",
        "everything, the default). This is not a full transcript.",
        "",
    ]
    (out_dir / "index.md").write_text("\n".join(idx_rows), encoding="utf-8")

    corpus_bytes = (out_dir / "corpus.jsonl").stat().st_size

    lb = last_backup_info()
    meta = {
        "tool": "opencode-db/export.py",
        "version": TOOL_VERSION,
        "date": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "db": str(db_path),
        "db_sha256": sha256_file(db_path),
        "filter": args.filter,
        "profile": "memory",
        "sub": args.sub,
        "role": args.role,
        "cap": args.cap or 0,
        "files": bool(args.files),
        "sanitize": bool(args.sanitize),
        "tokens_backfilled": total_backfilled,
        "sessions": {"total": len(sessions), "roots": n_root, "subagents": n_subs},
        "compactions": total_comp,
        "messages": total_msgs,
        "last_backup": lb,
        "files": ["corpus.jsonl", "index.md"],
    }
    (out_dir / "metadatos.json").write_text(
        json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    print(f"[OK] Exported (memory) to: {out_dir}")
    print(f"   Root sessions : {n_root}")
    print(f"   Corpus lines  : {n_root} (corpus.jsonl)")
    print(f"   Subagents     : {n_subs} (summarized inline)")
    print(f"   Last backup   : {lb['file'] if lb else 'none'}")
    if not args.cap and corpus_bytes > 50 * 1024 * 1024:
        print(
            f"   [!] corpus.jsonl is {corpus_bytes / 1e6:.1f} MB with unlimited text:"
            " bound it with --cap N before feeding it to a strict model."
        )


def make_outdir_final(base: Path, profile: str, stamp: str | None = None) -> Path:
    stamp = stamp or datetime.now(timezone.utc).strftime("%Y-%m-%d_%H-%M")
    target = base / stamp / profile
    n = 2
    while target.exists():
        target = base / f"{stamp}@{n}" / profile
        n += 1
    target.mkdir(parents=True, exist_ok=False)
    return target


def session_faithful(con, s: dict, sanitize_on: bool) -> dict:
    """Native-shaped faithful archive: {"info": {...}, "messages": [{info, parts}]}."""
    data = {
        "info": {
            "id": s["id"],
            "title": s["title"] or s["slug"],
            "slug": s["slug"],
            "projectId": s["project_id"],
            "directory": s["directory"],
            "agent": s["agent"] or "",
            "model": model_str(s["model"]),
            "time": {"created": s["time_created"], "updated": s["time_updated"]},
            "parentId": s["parent_id"] or "",
            "tokens": {
                "input": s["tokens_input"] or 0,
                "output": s["tokens_output"] or 0,
                "reasoning": s["tokens_reasoning"] or 0,
                "cache": {"read": s["tokens_cache_read"] or 0, "write": s["tokens_cache_write"] or 0},
                "backfilled": bool(s.get("tokens_backfilled")),
            },
            "cost": s["cost"] or 0,
            "compactions": s["compactions"],
        },
        "messages": [],
    }
    for mid, mdata, parts in load_faithful(con, s["id"]):
        data["messages"].append(
            {
                "info": {
                    "id": mid,
                    "role": mdata.get("role", ""),
                    "mode": mdata.get("mode", ""),
                    "agent": mdata.get("agent", ""),
                    "time": mdata.get("time"),
                },
                "parts": parts,
            }
        )
    if sanitize_on:
        data = sanitize_json(data)
    return data


def write_session_json(con, s: dict, json_path: Path, sanitize_on: bool) -> None:
    data = session_faithful(con, s, sanitize_on)
    json_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def main() -> None:
    ap = argparse.ArgumentParser(prog="opencode-db export", description="Export opencode sessions (read-only).")
    ap.add_argument("profile", nargs="?", default="transcript",
                    choices=["transcript", "memory", "compactions", "full"],
                    help="product: transcript (markdown + optional JSON) | memory (RAG corpus) | compactions (digests)")
    ap.add_argument("--filter", help="SQL LIKE on session id/title, e.g. 'ses_f7%'")
    ap.add_argument("--out", help="output root dir")
    ap.add_argument("--sub", default="separate", choices=["separate", "inline", "omit"])
    ap.add_argument("--tool-output", default="truncated", choices=["full", "truncated", "omit"])
    ap.add_argument("--tool-input-limit", type=int, default=800)
    ap.add_argument("--tool-output-limit", type=int, default=500)
    ap.add_argument("--patch", default="full", choices=["full", "omit"])
    ap.add_argument("--no-reasoning", action="store_true", help="transcript: omit the reasoning parts")
    ap.add_argument("--mark-compactions", action="store_true")
    ap.add_argument("--summary-diffs", action="store_true")
    ap.add_argument("--role", default="all", choices=["all", "user", "assistant"],
                    help="transcript/compactions: only render messages of one role")
    ap.add_argument("--json", action="store_true",
                    help="transcript/compactions: also write a faithful JSON archive per session")
    ap.add_argument("--sanitize", action="store_true",
                    help="redact secret-looking values (API keys, bearer tokens, private keys, key=...)")
    ap.add_argument("--cap", type=int, default=0, help="memory: truncate each text value to N chars (0 = unlimited, default)")
    ap.add_argument("--files", action="store_true", help="memory: include touched files per session")
    ap.add_argument("--stamp", help=argparse.SUPPRESS)
    args = ap.parse_args()

    if args.profile == "full":
        args.profile = "transcript"  # alias

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

    sessions = load_sessions(con, args.filter)
    if not sessions:
        die("No sessions match the filter (e.g. 'ses_f7%').")

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

    # ------- escribir sesiones -------
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
    (out_dir / "metadatos.json").write_text(
        json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    print(f"[OK] Exported ({args.profile}) to: {out_dir}")
    print(f"   Root sessions : {len(written)}")
    print(f"   Subagents     : {sum(len(s[1]) for s in written)}")
    print(f"   Compactions   : {total_comp}")
    if n_backfilled:
        print(f"   Tokens        : {n_backfilled} session(s) backfilled from step-finish")
    print(f"   Last backup   : {last_bkp['file'] if last_bkp else 'none'}")


def _transcript_msgs(renderer, con, session: dict) -> list:
    msgs = load_messages(con, session["id"])
    if renderer.profile == "compactions":
        msgs = [(m, p) for (m, p) in msgs if m.get("mode") == "compaction"]
    if renderer.role != "all":
        msgs = [(m, p) for (m, p) in msgs if renderer.include_message(m)]
    return msgs


def write_transcript(con, renderer, session: dict, fpath: Path):
    title = session["title"] or session["slug"]
    msgs = _transcript_msgs(renderer, con, session)
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
        if renderer.profile == "compactions":
            f.write(f"- **Compaction digests:** {n_msgs} · **Compaction parts:** {n_comp}\n")
        else:
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
    msgs = _transcript_msgs(renderer, con, session)
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
        f.write(f"| Product | `{args.profile}` |\n")
        f.write(f"| Date | {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')} |\n")
        f.write(f"| Source DB | `{db_path}` |\n")
        if args.filter:
            f.write(f"| Filter | `{args.filter}` |\n")
        f.write(f"| Sessions (roots/subagents/total) | {len(written)} / {sum(len(s[1]) for s in written)} / {len(sessions)} |\n")
        f.write(f"| Messages | {total_msgs} |\n")
        f.write(f"| Compactions | {total_comp} |\n")
        f.write(f"| Tool output | `{args.tool_output}` |\n")
        f.write(f"| Reasoning | `{'on' if not args.no_reasoning else 'off'}` |\n")
        f.write(f"| JSON archive | `{'on' if args.json else 'off'}` |\n")
        f.write(f"| Sanitize | `{'on' if args.sanitize else 'off'}` |\n")
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