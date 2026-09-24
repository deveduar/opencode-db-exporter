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