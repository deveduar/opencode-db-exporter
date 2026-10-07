# Shared small helpers: error exit, path/timestamp mangling, model string.
import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


def die(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def ts_iso(ms) -> str:
    """Epoch ms (or numeric timestamp) -> ISO-8601 UTC; '' when falsy/absent."""
    if not ms:
        return ""
    return datetime.fromtimestamp(float(ms) / 1000, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def safe_filename(name: str, fallback: str = "session") -> str:
    s = re.sub(r"[^A-Za-z0-9_\- ]+", "", name or "").strip()
    s = re.sub(r"\s+", " ", s)[:80]
    return s or fallback


def truncate(text: str, limit: int) -> str:
    text = str(text)
    if len(text) <= limit:
        return text
    return text[:limit] + f"\n[… truncated: {len(text) - limit} bytes more …]"


# The ONE selection rule of a run (filter | sessions | last | since | all) is
# described in exactly two shapes, both derived here so the metadata, the
# per-product index and the "matched nothing" error can never disagree.
SELECTION_LABELS = {
    "filter": "filter {value}",
    "sessions": "{n} explicit session id(s)",
    "last": "last {value} session(s) by last update",
    "since": "updated on or after {value}",
    "all": "ALL sessions",
}


def selection_rule(args) -> tuple[str, object]:
    """(rule, value) for the effective selection of this run, in the fixed
    precedence the CLI mutex already enforces."""
    if getattr(args, "filter", None) is not None:
        return "filter", args.filter
    if getattr(args, "sessions", None):
        return "sessions", list(args.sessions)
    if getattr(args, "last", None) is not None:
        return "last", args.last
    if getattr(args, "since", None) is not None:
        return "since", args.since
    return "all", None


def selection_label(args) -> str:
    """Human phrase for the effective rule (bundle index, error messages)."""
    rule, value = selection_rule(args)
    n = len(value) if rule == "sessions" else 0
    return SELECTION_LABELS[rule].format(value=value, n=n)


def session_record(sess: dict, kind: str) -> dict:
    """One session identity for `metadata.json.session_records`.

    IDENTITY ONLY, deliberately. `messages`/`compactions` are already totals at
    the top level of the same file, so repeating them per session would create a
    second set of numbers to keep in sync for no gain; what metadata did NOT have
    anywhere was WHICH sessions the run actually contains.

    Lives here, not in cli.py, because EVERY product records this: the memory
    product writes its own metadata and must emit the same records, or a bundle
    would carry the list in one product and not the other.
    """
    return {
        "id": sess["id"],
        "title": sess["title"] or sess["slug"],
        "kind": kind,
        # absent parent -> null, not "" (the machine-artifact rule)
        "parent_id": sess["parent_id"] or None,
        "created": ts_iso(sess["time_created"]),
        "updated": ts_iso(sess["time_updated"]),
    }


def selection_meta(args) -> dict:
    """Machine provenance for metadata.json: the rule that produced the run.
    Stable keys per rule, so a consumer never has to guess what `value` means."""
    rule, value = selection_rule(args)
    if rule == "sessions":
        return {"rule": rule, "ids": value}
    if rule == "all":
        return {"rule": rule}
    return {"rule": rule, "value": value}


def selection_phrase(meta) -> str:
    """Human phrase for a metadata.json's `.selection`, i.e. the INVERSE of
    selection_meta(). This is the one description of a stored selection, so the
    export confirm, the index row and `exports view` can never disagree.

    Read `.selection` and NOT `.filter`/`.sessions_selected`: those two only
    describe a filter or an explicit id list, so a run selected by `--last N` or
    `--since DATE` reads as "sessions: all" — flatly wrong, and wrong in the
    screen whose whole job is to say what a run contains. Runs written before
    `.selection` existed have none, and are labelled as legacy.
    """
    meta = meta or {}
    sel = meta.get("selection")
    if not isinstance(sel, dict) or "rule" not in sel:
        # Legacy run (pre-.selection): reconstruct what we can, and say so.
        if meta.get("filter"):
            return f"filter {meta['filter']} (legacy record)"
        ids = meta.get("sessions_selected")
        if ids:
            n = len(ids) if isinstance(ids, list) else 0
            return SELECTION_LABELS["sessions"].format(n=n) + " (legacy record)"
        return "all sessions (legacy record)"
    rule = sel["rule"]
    if rule == "sessions":
        return SELECTION_LABELS[rule].format(n=len(sel.get("ids") or []))
    if rule == "all":
        return SELECTION_LABELS[rule]
    return SELECTION_LABELS.get(rule, rule).format(value=sel.get("value"))


def model_str(model) -> str:
    """Normalize a model value to a single plain-id string.

    opencode may store the model as a plain string ('anthropic/claude-…') or as a
    JSON-serialized object ('{"id":"…","provider":"…"}'). Consumers (corpus/archive)
    always get one form: the model id when the object form is present, the string
    otherwise. Never returns a JSON blob.
    """
    if not model:
        return ""
    parsed = model
    if isinstance(model, str):
        try:
            parsed = json.loads(model)
        except (ValueError, TypeError):
            return model
    if isinstance(parsed, dict) and parsed.get("id"):
        return str(parsed["id"])
    return str(parsed)