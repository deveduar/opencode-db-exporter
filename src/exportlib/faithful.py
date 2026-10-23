# Faithful product: the complete session as native {info, messages:[{info, parts}]}
# JSON, one file per session. Unlike `transcript`, this is NOT filtered: every
# message and every part is kept verbatim (only --sanitize redacts), which is what
# makes a plan containing it lossless.
import json
from datetime import datetime, timezone

from exportlib import TOOL_VERSION
from exportlib.flags import effective_flags
from exportlib.db import load_faithful
from exportlib.sanitize import sanitize_json
from exportlib.util import (
    model_str,
    safe_filename,
    selection_label,
    selection_meta,
    session_record,
    sha256_file,
    ts_iso,
)
from exportlib.writers import last_backup_info


def session_faithful(con, s: dict, sanitize_on: bool) -> dict:
    """Native-shaped faithful archive: {"info": {...}, "messages": [{info, parts}]}."""
    data = {
        "info": {
            "id": s["id"],
            "title": s["title"] or s["slug"],
            "slug": s["slug"],
            "projectId": s["project_id"],
            "directory": s["directory"],
            "agent": s["agent"] or None,
            "model": model_str(s["model"]),
            "time": {"created": ts_iso(s["time_created"]) or None, "updated": ts_iso(s["time_updated"]) or None},
            "parentId": s["parent_id"] or None,
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
                    "role": mdata.get("role"),
                    "mode": mdata.get("mode") or None,
                    "agent": mdata.get("agent") or None,
                    "time": mdata.get("time"),
                },
                "parts": parts,
            }
        )
    if sanitize_on:
        data = sanitize_json(data)
    return data


def _write_session_json(con, s: dict, json_path, sanitize_on: bool) -> dict:
    """Write one faithful archive and return its loaded data (so the caller can
    count its messages without a second pass)."""
    data = session_faithful(con, s, sanitize_on)
    json_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return data


def faithful_export(con, sessions, roots, children_of, out_dir, args, db_path, hidden: int = 0,
                    scope: dict | None = None, excluded: list | None = None) -> None:
    """The `faithful` product: one `.json` per root session, with its subagents
    under `subagents/`. The session hierarchy mirrors `transcript` (numbered
    session folders) so the two products correlate, but only JSON is written."""
    n_root = 0
    n_subs = 0
    total_msgs = 0
    total_comp = 0
    total_digest = 0
    total_backfilled = 0
    records: list = []
    for rid in roots:
        root = sessions[rid]
        subs = children_of.get(rid, [])
        stem = safe_filename(root["title"] or root["slug"])
        rfolder = out_dir / f"{n_root + 1:02d}-{stem}_{rid[:8]}"
        rfolder.mkdir()
        data = _write_session_json(con, root, rfolder / f"{stem}.json", args.sanitize)
        total_msgs += len(data["messages"])
        total_comp += root.get("compactions") or 0
        total_digest += root.get("digests") or 0
        if root.get("tokens_backfilled"):
            total_backfilled += 1
        records.append(session_record(root, "root"))
        if subs:
            subdir = rfolder / "subagents"
            subdir.mkdir()
            for sid_ in subs:
                sub = sessions[sid_]
                sstem = safe_filename(sub["title"] or sub["slug"])
                sdata = _write_session_json(
                    con, sub, subdir / f"{sstem}_{sid_[:8]}.json", args.sanitize
                )
                total_msgs += len(sdata["messages"])
                total_comp += sub.get("compactions") or 0
                total_digest += sub.get("digests") or 0
                if sub.get("tokens_backfilled"):
                    total_backfilled += 1
                records.append(session_record(sub, "subagent"))
        n_root += 1
        n_subs += len(subs)

    idx_rows = [
        "# opencode faithful JSON archive",
        "",
        "| Field | Value |",
        "|---|---|",
        "| Product | `faithful` |",
        "| Date | {0} |".format(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")),
        f"| Source DB | `{db_path}` |",
    ]
    if getattr(args, "preset", None):
        idx_rows.insert(5, f"| Preset | `{args.preset}` |")
    if getattr(args, "update_from", None):
        # An updated run materializes its target set as --sessions, but the index
        # must read like the base run it refreshes, not list hundreds of ids.
        idx_rows.append(f"| Selection | {selection_label(args)} |")
        idx_rows.append(
            f"| Updated from | `{args.update_from}` ({args.update_mode or 'delta'}) |"
        )
    elif args.sessions:
        idx_rows.append(f"| Sessions | `{', '.join(args.sessions)}` |")
    elif args.filter:
        idx_rows.append(f"| Filter | `{args.filter}` |")
    idx_rows += [
        f"| Root sessions | {n_root} |",
        f"| Subagents | {n_subs} |",
        f"| Subagents excluded | {hidden} |",
        f"| Messages | {total_msgs} |",
        f"| Compaction markers | {total_comp} |",
        f"| Compaction digests | {total_digest} |",
        f"| Sanitize | `{'on' if args.sanitize else 'off'}` |",
        f"| Tokens backfilled from step-finish | {total_backfilled} session(s) |",
        "",
        "Each `.json` is the native opencode shape `{info, messages:[{info, parts}]}`,",
        "kept verbatim: no display filter applies (only `--sanitize` redacts). This is",
        "the lossless machine copy of the session; the Markdown `transcript` product is",
        "the filtered, human-readable counterpart.",
        "",
    ]
    (out_dir / "index.md").write_text("\n".join(idx_rows), encoding="utf-8")

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
        "scope": scope,
        "excluded": excluded or [],
        "flags": effective_flags(args),
        **({"updated_from": args.update_from, "update_mode": args.update_mode or "delta"}
           if getattr(args, "update_from", None) else {}),
        "profile": "faithful",
        "preset": args.preset,
        "no_subagents": bool(args.no_subagents),
        "no_orphan_subagents": bool(args.no_orphan_subagents),
        "subagents_hidden": hidden,
        "sanitize": bool(args.sanitize),
        "tokens_backfilled": total_backfilled,
        "sessions": {"total": len(sessions), "roots": n_root, "subagents": n_subs},
        "compactions": total_comp,
        "digests": total_digest,
        "session_records": records,
        "messages": total_msgs,
        "last_backup": lb,
        "files": [str(p.relative_to(out_dir)) for p in sorted(out_dir.rglob("*")) if p.is_file()],
    }
    (out_dir / "metadata.json").write_text(
        json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    print(f"[OK] Exported ({'preset ' + args.preset + ' → ' if args.preset else ''}faithful) to: {out_dir}")
    print(f"   Root sessions : {n_root}")
    print(f"   Subagents     : {n_subs}")
    if hidden:
        flag = "--no-subagents" if args.no_subagents else "--no-orphan-subagents"
        print(f"   Excluded      : {hidden} subagent(s) ({flag})")
    print(f"   Messages      : {total_msgs}")
    if total_backfilled:
        print(f"   Tokens        : {total_backfilled} session(s) backfilled from step-finish")
    print(f"   Last backup   : {lb['file'] if lb else 'none'}")
