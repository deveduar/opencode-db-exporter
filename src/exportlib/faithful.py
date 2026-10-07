# Faithful JSON archive: native {info, messages:[{info, parts}]} shape.
import json

from exportlib.db import load_faithful
from exportlib.sanitize import sanitize_json
from exportlib.util import model_str, ts_iso


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


def write_session_json(con, s: dict, json_path, sanitize_on: bool) -> None:
    data = session_faithful(con, s, sanitize_on)
    json_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")