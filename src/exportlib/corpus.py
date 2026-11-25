import json
from datetime import datetime, timezone

from exportlib import TOOL_VERSION
from exportlib.db import digests_for, load_messages, touched_files, walk_subagents
from exportlib.flags import effective_flags
from exportlib.progress import Progress
from exportlib.sanitize import sanitize
from exportlib.util import (
    model_str,
    selection_label,
    selection_meta,
    selection_phrase,
    session_record,
    sha256_file,
    ts_iso,
)
from exportlib.writers import (
    last_backup_info,
    product_artifact_files,
    product_artifact_path,
)


def _cap_text(text: str, cap: int) -> str:
    if cap and cap > 0 and len(text) > cap:
        return text[:cap]
    return text


def _render_value(value, cap: int) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return _cap_text(value.strip(), cap)
    return _cap_text(json.dumps(value, ensure_ascii=False, sort_keys=True), cap)


def _part_block(part: dict, cap: int) -> str:
    ptype = str(part.get("type") or "part")
    if ptype in ("text", "reasoning"):
        body = _render_value(part.get("text") or part.get("reasoning"), cap)
        return f"[{ptype}] {body}" if body else ""
    if ptype == "tool":
        state = part.get("state") or {}
        lines = [f"[tool · {part.get('tool') or '?'} · {state.get('status') or 'unknown'}]"]
        title = _render_value(state.get("title"), cap)
        if title:
            lines.append(f"title: {title}")
        for key in ("input", "output", "error"):
            value = state.get(key)
            if value in (None, "", {}, []):
                continue
            lines.append(f"{key}: {_render_value(value, cap)}")
        return "\n".join(lines)
    rest = {key: value for key, value in part.items() if key != "type"}
    body = _render_value(rest, cap)
    return f"[{ptype}] {body}" if body else ""


def corpus_document(con, root: dict, sessions: dict, subs: list[str],
                    cap: int = 0, files: bool = False,
                    sanitize_on: bool = False) -> dict:
    blocks: list[str] = []
    for label, session in [("root", root)] + [
        ("subagent", sessions[sid]) for sid in subs
    ]:
        if label == "subagent":
            title = session["title"] or session["slug"]
            blocks.append(f"## Subagent: {title} (`{session['id'][:8]}`)")
        for mdata, parts in load_messages(con, session["id"]):
            rendered = [block for block in (_part_block(p, cap) for p in parts) if block]
            if not rendered:
                continue
            body = "\n".join(rendered)
            if sanitize_on:
                body = sanitize(body)
            role = mdata.get("role") or "message"
            blocks.append(f"[{label} · {role}]\n{body}")
    content = "\n\n".join(blocks)
    doc = {
        "schema_version": 1,
        "id": root["id"],
        "title": root["title"] or root["slug"],
        "slug": root["slug"],
        "directory": root["directory"],
        "agent": root["agent"] or None,
        "model": model_str(root["model"]),
        "created": ts_iso(root["time_created"]) or None,
        "updated": ts_iso(root["time_updated"]) or None,
        "parent_id": root["parent_id"] or None,
        "content": content,
        "text": content,
    }
    if files:
        touched = list(touched_files(con, root["id"]))
        for sid in subs:
            for path in touched_files(con, sid):
                if path not in touched:
                    touched.append(path)
        doc["files"] = touched
    return doc


def corpus_export(con, sessions, roots, children_of, out_dir, args, db_path,
                  hidden: int = 0, scope: dict | None = None,
                  excluded: list | None = None) -> None:
    n_root = 0
    n_subs = 0
    total_msgs = 0
    total_comp = 0
    total_digest = 0
    total_backfilled = 0
    records: list = []
    progress = Progress(
        "Exporting corpus",
        len(sessions),
        disabled=args.no_progress,
    )
    progress.start()
    with (out_dir / "corpus.jsonl").open("w", encoding="utf-8") as corpus:
        for rid in roots:
            root = sessions[rid]
            subs = [sid for sid, _depth in walk_subagents(rid, children_of)]
            doc = corpus_document(
                con, root, sessions, subs, cap=args.cap or 0,
                files=args.files, sanitize_on=args.sanitize,
            )
            corpus.write(json.dumps(doc, ensure_ascii=False) + "\n")
            corpus.flush()
            n_root += 1
            n_subs += len(subs)
            session_ids = [rid] + subs
            total_msgs += sum(len(load_messages(con, sid)) for sid in session_ids)
            total_comp += sum(sessions[sid]["compactions"] or 0 for sid in session_ids)
            total_digest += sum(len(digests_for(con, sid)) for sid in session_ids)
            records.append(session_record(root, "root"))
            for sid in subs:
                records.append(session_record(sessions[sid], "subagent"))
            if root.get("tokens_backfilled"):
                total_backfilled += 1
            progress.advance(1 + len(subs))
    progress.finish()

    idx_rows = [
        "# opencode text corpus",
        "",
        "| Field | Value |",
        "|---|---|",
        "| Product | `corpus` |",
        "| Date | {0} |".format(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")),
        f"| Source DB | `{db_path}` |",
    ]
    if getattr(args, "preset", None):
        idx_rows.insert(5, f"| Preset | `{args.preset}` |")
    idx_rows.append(f"| Selection | {selection_label(args)} |")
    sel_meta = selection_meta(args)
    if sel_meta != scope:
        idx_rows.append(f"| Scope | {selection_phrase({'selection': scope})} |")
    if getattr(args, "update_from", None):
        idx_rows.append(
            f"| Updated from | `{args.update_from}` ({args.update_mode or 'delta'}) |"
        )
    idx_rows += [
        f"| Root sessions | {n_root} |",
        f"| Subagents (flattened inline) | {n_subs} |",
        f"| Subagents excluded | {hidden} |",
        f"| Messages (roots + subagents) | {total_msgs} |",
        f"| Compaction markers | {total_comp} |",
        f"| Compaction digests | {total_digest} |",
        f"| Tuning | `--cap {'0 (unlimited)' if not args.cap else args.cap}` · `--files {'on' if args.files else 'off'}` |",
        f"| Sanitize | `{'on' if args.sanitize else 'off'}` |",
        f"| Tokens backfilled from step-finish | {total_backfilled} root session(s) |",
        "| Corpus | [`corpus.jsonl`](corpus.jsonl) - one flat text document per root session |",
        "",
    ]
    product_artifact_path(out_dir, "index.md", args).write_text(
        "\n".join(idx_rows), encoding="utf-8"
    )

    corpus_bytes = (out_dir / "corpus.jsonl").stat().st_size
    lb = last_backup_info()
    meta = {
        "tool": "opencode-db/exportlib",
        "version": TOOL_VERSION,
        "date": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "db": str(db_path),
        "db_sha256": sha256_file(db_path),
        "title": getattr(args, "title", None) or None,
        "notes": getattr(args, "notes", None) or None,
        **({"notes_kind": args.notes_kind} if getattr(args, "notes_kind", None) else {}),
        "source": getattr(args, "source", None) or "direct",
        "selection": selection_meta(args),
        "scope": scope,
        "excluded": excluded or [],
        "flags": effective_flags(args),
        **({"updated_from": args.update_from, "update_mode": args.update_mode or "delta"}
           if getattr(args, "update_from", None) else {}),
        "profile": "corpus",
        "preset": args.preset,
        "subagents_hidden": hidden,
        "tokens_backfilled": total_backfilled,
        "compactions": total_comp,
        "digests": total_digest,
        "session_records": records,
        "messages": total_msgs,
        "last_backup": lb,
        "artifacts": product_artifact_files(out_dir, args),
    }
    product_artifact_path(out_dir, "metadata.json", args).write_text(
        json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    print(f"[OK] Exported ({'preset ' + args.preset + ' → ' if args.preset else ''}corpus) to: {out_dir}")
    print(f"   Root sessions : {n_root}")
    print(f"   Corpus lines  : {n_root} (corpus.jsonl)")
    print(f"   Subagents     : {n_subs} (flattened inline)")
    if hidden:
        flag = "--no-subagents" if args.no_subagents else "--no-orphan-subagents"
        print(f"   Excluded      : {hidden} subagent(s) ({flag})")
    print(f"   Last backup   : {lb['file'] if lb else 'none'}")
    if not args.cap and corpus_bytes > 50 * 1024 * 1024:
        print(
            f"   [!] corpus.jsonl is {corpus_bytes / 1e6:.1f} MB with unlimited text:"
            " bound it with --cap N before feeding it to a strict model."
        )
