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


def snapshot_changes(records: list, live: dict) -> list[dict]:
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


CANONICAL_TYPES = {
    "selection": dict,
    "scope": dict,
    "flags": dict,
    "session_records": list,
    "excluded": list,
    "artifacts": list,
}


def _require_canonical(meta: dict, label: str) -> None:
    """Reject incomplete export metadata instead of assigning it a legacy state."""
    for key, expected in CANONICAL_TYPES.items():
        if not isinstance(meta.get(key), expected):
            die(f"{label}: missing or invalid .{key}; re-export this run")


def _records(meta: dict) -> list:
    return meta["session_records"]


def _live_for_ids(con, ids) -> dict:
    ids = sorted(set(ids))
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


def _live_for(con, records: list) -> dict:
    return _live_for_ids(con, (r.get("id") for r in records or []))


def snapshot_changes_for_meta(meta: dict, con) -> list[dict]:
    recs = _records(meta)
    return snapshot_changes(recs, _live_for(con, recs))


def _scope_cache_key(meta: dict) -> str:
    flags = meta["flags"]
    return json.dumps(
        [meta["scope"], bool(flags.get("no_subagents")),
         bool(flags.get("no_orphan_subagents")), flags.get("sub")],
        sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def coverage_for_meta(meta: dict, con, effective_cache=None, all_ids=None) -> list[dict]:
    key = _scope_cache_key(meta) if effective_cache is not None else None
    if key is not None and key in effective_cache:
        effective = effective_cache[key]
    else:
        _, effective = load_effective_scope(meta, con, all_ids=all_ids)
        if key is not None:
            effective_cache[key] = effective
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
    """Return canonical metadata for a run, rejecting incomplete products."""
    run = Path(default_out()) / stamp
    if not run.is_dir():
        die(f"Not found: {run}")
    paths = sorted(run.glob("*/metadata.json"))
    if not paths:
        die(f"{run}: no metadata.json; re-export this run")
    for path in paths:
        meta = _read_meta(path)
        _require_canonical(meta, str(path))
    path = paths[0]
    return path, _read_meta(path)


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
        prog="opencode-db exports freshness",
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
        try:
            metas = []
            all_record_ids = set()
            for raw_path in args.summary_batch:
                path = Path(raw_path)
                if not path.is_file():
                    die(f"metadata.json missing: {path}; re-export this run")
                meta = _read_meta(path)
                _require_canonical(meta, str(path))
                metas.append((raw_path, meta))
                all_record_ids.update(r.get("id") for r in _records(meta) if r.get("id"))

            # A run shelf often contains overlapping snapshots of the same
            # sessions. Fetch their live timestamps once for the whole batch.
            live = _live_for_ids(con, all_record_ids)
            all_ids = {row[0] for row in con.execute("SELECT id FROM session")}
            effective_cache = {}
            results = {}
            for raw_path, meta in metas:
                results[raw_path] = summarize(
                    snapshot_changes(_records(meta), live),
                    coverage_for_meta(meta, con, effective_cache, all_ids))
        finally:
            con.close()
        json.dump(results, sys.stdout, indent=2, ensure_ascii=False)
        sys.stdout.write("\n")
        return 0

    if not args.stamp and not args.meta:
        build_argparser().error("give a stamp or --meta")

    if args.meta:
        path = Path(args.meta)
        if not path.is_file():
            die(f"Not found: {path}")
        meta = _read_meta(path)
        _require_canonical(meta, str(path))
        label = str(path)
    else:
        path, meta = _find_meta(args.stamp)
        label = args.stamp

    db = Path(os.environ.get("OPENCODE_DB") or default_db())
    if not db.exists():
        die(f"Database not found: {db}")
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    try:
        entries = snapshot_changes_for_meta(meta, con)
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
