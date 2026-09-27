# Memory product: RAG corpus (corpus.jsonl, streamed line by line).
import json
from datetime import datetime, timezone

from exportlib import TOOL_VERSION
from exportlib.db import digests_for, load_messages, load_todos, touched_files
from exportlib.sanitize import sanitize
from exportlib.util import model_str, selection_meta, sha256_file, ts_iso
from exportlib.writers import last_backup_info


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

    dig = [{"created": ts_iso(d["created"]) or None, "text": cap_text(d["text"])} for d in digests]
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
        "schema_version": 1,
        "id": s["id"],
        "title": s["title"] or s["slug"],
        "slug": s["slug"],
        "directory": s["directory"],
        "agent": s["agent"] or None,
        "model": model_str(s["model"]),
        "created": ts_iso(s["time_created"]) or None,
        "updated": ts_iso(s["time_updated"]) or None,
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
        "parent_id": s["parent_id"] or None,
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
        "agent": s["agent"] or None,
        "directory": s["directory"],
        "created": ts_iso(s["time_created"]) or None,
    }


def memory_export(con, sessions, roots, children_of, out_dir, args, db_path, hidden: int = 0) -> None:
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
        "| Date | {0} |".format(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")),
        f"| Source DB | `{db_path}` |",
    ]
    if args.sessions:
        idx_rows.append(f"| Sessions | `{', '.join(args.sessions)}` |")
    elif args.filter:
        idx_rows.append(f"| Filter | `{args.filter}` |")
    idx_rows += [
        f"| Root sessions | {n_root} |",
        f"| Subagents (summarized inline) | {n_subs} |",
        f"| Subagents excluded | {hidden} |",
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
        "tool": "opencode-db/exportlib",
        "version": TOOL_VERSION,
        "date": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "db": str(db_path),
        "db_sha256": sha256_file(db_path),
        "filter": args.filter,
        "sessions_selected": args.sessions,
        "selection": selection_meta(args),
        "profile": "memory",
        "preset": args.preset,
        "sub": args.sub,
        "no_subagents": bool(args.no_subagents),
        "no_orphan_subagents": bool(args.no_orphan_subagents),
        "subagents_hidden": hidden,
        "role": args.role,
        "cap": args.cap or 0,
        "touched_files": bool(args.files),
        "sanitize": bool(args.sanitize),
        "tokens_backfilled": total_backfilled,
        "sessions": {"total": len(sessions), "roots": n_root, "subagents": n_subs},
        "compactions": total_comp,
        "messages": total_msgs,
        "last_backup": lb,
        "files": ["corpus.jsonl", "index.md"],
    }
    (out_dir / "metadata.json").write_text(
        json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    print(f"[OK] Exported ({'preset ' + args.preset + ' → ' if args.preset else ''}memory) to: {out_dir}")
    print(f"   Root sessions : {n_root}")
    print(f"   Corpus lines  : {n_root} (corpus.jsonl)")
    print(f"   Subagents     : {n_subs} (summarized inline)")
    if hidden:
        flag = "--no-subagents" if args.no_subagents else "--no-orphan-subagents"
        print(f"   Excluded      : {hidden} subagent(s) ({flag})")
    print(f"   Last backup   : {lb['file'] if lb else 'none'}")
    if not args.cap and corpus_bytes > 50 * 1024 * 1024:
        print(
            f"   [!] corpus.jsonl is {corpus_bytes / 1e6:.1f} MB with unlimited text:"
            " bound it with --cap N before feeding it to a strict model."
        )