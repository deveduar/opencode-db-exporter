"""Per-session export integrity and scope coverage against the LIVE DB.

Snapshot integrity (`stale`, `missing`, `unverifiable`) and scope coverage
(`new`) are deliberately separate states.

Read-only on the DB, always: `mode=ro` is what opens it.
"""
import argparse
import json
import os
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

# Self-bootstrapping entry (like exportlib/cli.py / update.py): running this file
# directly adds src/ to sys.path so the `exportlib` imports resolve.
MODULES_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if MODULES_DIR not in sys.path:
    sys.path.insert(0, MODULES_DIR)

from exportlib.config import default_db, default_out
from exportlib.db import load_effective_scope
from exportlib.util import die, ts_iso


def _iso(v) -> str:
    if v is None:
        return ""
    try:
        return ts_iso(v)
    except (OverflowError, TypeError, ValueError):
        return ""


def _recorded_iso(value) -> str:
    if not isinstance(value, str) or not value:
        return ""
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return ""
    if parsed.tzinfo is None:
        return ""
    return parsed.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _clean(s) -> str:
    """One TSV field: tabs/newlines would split the row, so flatten them."""
    return str(s or "").replace("\t", " ").replace("\n", " ").replace("\r", " ")


def stale_ids(records: list, live: dict) -> list[dict]:
    """Flagged sessions for a run's `.session_records` against `live`.

    `live` maps id -> a row/dict carrying `time_updated` (epoch ms), which is
    what `exports update` already has in memory. Only flagged sessions are
    returned: stale, missing, then unverifiable, each ordered by the recorded
    `updated` descending (the same "last use" order the sessions list uses).
    """
    out: list[dict] = []
    for r in records or []:
        sid = r.get("id")
        if not sid:
            continue
        recorded = r.get("updated") or ""
        normalized_recorded = _recorded_iso(recorded)
        row = live.get(sid)
        if row is None:
            state = "missing"
        else:
            current = _iso(row.get("time_updated"))
            if not current or not normalized_recorded:
                state = "unverifiable"
            elif current <= normalized_recorded:
                continue
            else:
                state = "stale"
        out.append({
            "id": sid,
            "state": state,
            "kind": r.get("kind") or "root",
            "updated": recorded,
            "live_updated": current if row is not None else None,
            "title": r.get("title") or "",
        })
    out.sort(key=lambda e: e["updated"], reverse=True)
    order = {"stale": 0, "missing": 1, "unverifiable": 2}
    out.sort(key=lambda e: order[e["state"]])
    return out


def new_sessions(records: list, excluded: list, effective_scope: dict,
                 live_ids: set[str]) -> list[dict]:
    """Live sessions in the effective scope, but neither written nor excluded."""
    recorded_ids = {r.get("id") for r in records or [] if r.get("id")}
    excluded_ids = {r.get("id") for r in excluded or [] if r.get("id")}
    out = []
    for sid, row in effective_scope.items():
        if sid in recorded_ids or sid in excluded_ids:
            continue
        updated = _iso(row.get("time_updated"))
        parent_id = row.get("parent_id") or ""
        out.append({
            "id": sid,
            "state": "new",
            "kind": "subagent" if parent_id in live_ids else "root",
            "updated": updated,
            "live_updated": updated,
            "title": row.get("title") or row.get("slug") or "",
        })
    out.sort(key=lambda entry: (entry["updated"], entry["id"]), reverse=True)
    return out


def _records(meta: dict) -> list:
    recs = meta.get("session_records") if isinstance(meta, dict) else None
    return recs if isinstance(recs, list) else []


def _live_for(con, records: list) -> dict:
    ids = [r.get("id") for r in records if r.get("id")]
    if not ids:
        return {}
    live = {}
    for start in range(0, len(ids), 500):
        batch = ids[start:start + 500]
        q = "SELECT id, time_updated FROM session WHERE id IN (%s)" % (
            ",".join("?" * len(batch)))
        live.update({row[0]: {"time_updated": row[1]}
                     for row in con.execute(q, batch)})
    return live


def stale_for_meta(meta: dict, con) -> list[dict]:
    recs = _records(meta)
    return stale_ids(recs, _live_for(con, recs))


def coverage_for_meta(meta: dict, con) -> list[dict]:
    _, effective = load_effective_scope(meta, con)
    live_ids = set(effective)
    return new_sessions(_records(meta), meta.get("excluded") or [], effective, live_ids)


def _read_meta(path: Path) -> dict:
    try:
        meta = json.loads(path.read_text(encoding="utf-8"))
    except Exception as e:
        die(f"{path}: not readable JSON ({e})")
    if not isinstance(meta, dict):
        die(f"{path}: not a metadata object")
    return meta


def _find_meta(stamp: str):
    """The product metadata that carries `.session_records` (a bundle sorts its
    products, so the first file is not necessarily the one). `(None, None)` when
    the run exists but is legacy (no record of which sessions it contains)."""
    run = Path(default_out()) / stamp
    if not run.is_dir():
        die(f"Not found: {run}")
    for path in sorted(run.glob("*/metadata.json")):
        meta = _read_meta(path)
        if _records(meta):
            return path, meta
    return None, None


def _human(entries: list, label: str) -> None:
    if not entries:
        print(f"All clean: {label} matches the live DB.")
        return
    stale = sum(1 for e in entries if e["state"] == "stale")
    missing = sum(1 for e in entries if e["state"] == "missing")
    unverifiable = sum(1 for e in entries if e["state"] == "unverifiable")
    new = sum(1 for e in entries if e["state"] == "new")
    parts = []
    if stale:
        parts.append(f"{stale} stale")
    if missing:
        parts.append(f"{missing} missing")
    if unverifiable:
        parts.append(f"{unverifiable} unverifiable")
    if new:
        parts.append(f"{new} new in scope")
    print(f"{len(entries)} session(s) differ from the run: {', '.join(parts)}")
    print("")
    for e in entries:
          print(f"  {e['id']:<22} {e['state']:<12} {e['kind']:<8} "
              f"{e['updated']:<20} {e['live_updated'] or '-':<20} {e['title']}")


def summarize(entries: list, new: list | None = None) -> dict:
    new = new or []
    counts = {state: sum(1 for entry in entries if entry["state"] == state)
              for state in ("stale", "missing", "unverifiable")}
    counts["new"] = len(new)
    reasons = []
    if counts["stale"]:
        reasons.append(f"{counts['stale']} session(s) changed in the live DB")
    if counts["missing"]:
        reasons.append(f"{counts['missing']} session(s) deleted from the live DB")
    if counts["unverifiable"]:
        reasons.append(f"{counts['unverifiable']} session(s) have unverifiable timestamps")
    if counts["new"]:
        reasons.append(f"{counts['new']} new session(s) in scope")
    reason = "; ".join(reasons)
    if reason:
        reason += " since this export."
    tags = [state for state in ("stale", "missing", "unverifiable", "new")
            if counts[state]]
    tag = ",".join(tags)
    return {"tag": tag, "counts": counts, "reason": reason,
            "clean": not bool(tag), "new": new}


def build_argparser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        prog="opencode-db exports stale",
        description="List snapshot-integrity changes and new sessions in an "
                    "export run's effective scope (read-only).",
    )
    ap.add_argument("stamp", nargs="?", help="export run (the name in `exports list`)")
    ap.add_argument("--meta", default=None,
                    help="metadata.json to check (instead of a stamp)")
    out = ap.add_mutually_exclusive_group()
    out.add_argument("--tsv", action="store_true",
                     help="id<TAB>state<TAB>kind<TAB>updated<TAB>live_updated<TAB>title")
    out.add_argument("--json", action="store_true", help="JSON array of the flagged sessions")
    out.add_argument("--summary", action="store_true",
                     help="JSON run-level status: tag, counts, reason, clean")
    ap.add_argument("--summary-batch", nargs="+", metavar="META",
                    help="JSON map of metadata paths to summaries; opens the DB once")
    return ap


def main(argv=None) -> int:
    args = build_argparser().parse_args(argv)
    if args.summary_batch:
        db = Path(os.environ.get("OPENCODE_DB") or default_db())
        if not db.exists():
            die(f"Database not found: {db}")
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        con.row_factory = sqlite3.Row
        con.row_factory = sqlite3.Row
        try:
            results = {}
            for raw_path in args.summary_batch:
                path = Path(raw_path)
                if not path.is_file():
                    results[raw_path] = {"tag": "unverifiable", "counts": {},
                                         "reason": f"metadata.json missing: {path}",
                                         "clean": False}
                    continue
                meta = _read_meta(path)
                if not _records(meta):
                    results[raw_path] = {
                        "tag": "unverifiable", "counts": {},
                        "reason": "cannot verify freshness (no session_records recorded).",
                        "clean": False,
                    }
                    continue
                results[raw_path] = summarize(
                    stale_for_meta(meta, con), coverage_for_meta(meta, con))
        finally:
            con.close()
        json.dump(results, sys.stdout, indent=2, ensure_ascii=False)
        sys.stdout.write("\n")
        return 0

    if not args.stamp and not args.meta:
                _, effective = load_effective_scope(meta, con)
                new = new_sessions(_records(meta), meta.get("excluded") or [],
                                   effective, set(effective))
                results[raw_path] = summarize(stale_for_meta(meta, con), new)

    if args.meta:
        path = Path(args.meta)
        if not path.is_file():
            die(f"Not found: {path}")
        meta = _read_meta(path)
        label = str(path)
    else:
        path, meta = _find_meta(args.stamp)
        label = args.stamp

    if meta is None or not _records(meta):
        # A legacy run has no record of which sessions it contains; say so
        # instead of inventing a verdict (the view does the same).
        if args.json:
            print("[]")
        elif args.summary:
            json.dump({"tag": "unverifiable", "counts": {},
                       "reason": "cannot verify freshness (no session_records recorded).",
                       "clean": False}, sys.stdout)
            sys.stdout.write("\n")
        else:
            print(f"unverifiable: {label} has no .session_records", file=sys.stderr)
        return 0

    db = Path(os.environ.get("OPENCODE_DB") or default_db())
    if not db.exists():
        die(f"Database not found: {db}")
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    con.row_factory = sqlite3.Row
    try:
        entries = stale_for_meta(meta, con)
        new = coverage_for_meta(meta, con)
    finally:
        con.close()

    if args.summary:
        json.dump(summarize(entries, new), sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
    elif args.json:
        json.dump(entries + new, sys.stdout, indent=2, ensure_ascii=False)
        sys.stdout.write("\n")
    elif args.tsv:
        for e in entries + new:
            print("\t".join((e["id"], e["state"], e["kind"],
                             e["updated"], e["live_updated"] or "",
                             _clean(e["title"]))))
    else:
        _human(entries + new, label)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print()
        sys.exit(130)
