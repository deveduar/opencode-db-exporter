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


def selection_meta(args) -> dict:
    """Machine provenance for metadata.json: the rule that produced the run.
    Stable keys per rule, so a consumer never has to guess what `value` means."""
    rule, value = selection_rule(args)
    if rule == "sessions":
        return {"rule": rule, "ids": value}
    if rule == "all":
        return {"rule": rule}
    return {"rule": rule, "value": value}


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