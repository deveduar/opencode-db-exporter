"""`exports update` — refresh an existing export run from the LIVE DB.

The run manager's counterpart of a fresh export: the run keeps its stamp (and its
place in `exports list`), its preset and its flags, and only its CONTENT moves on.
Sessions created since are added, sessions edited since are re-rendered, sessions
deleted from the DB are dropped. What a menu run deliberately left out is
recorded as metadata `.excluded` and STAYS out unless `--sticky` / the
`--include-excluded` offer re-open it, so refreshing a narrowed run can never
silently turn it into a full export.

Two explicit axes (they are independent):

    --mode delta          (default) the run keeps its own set: +new, -gone
    --mode accumulative   the run follows its scope now: every session in scope
    --keep-history        keep the previous state as <stamp>~<YYYY-MM-DD_HH-MM>
                          (a hardlink copy, so it costs no extra space)

`--mode accumulative` is the ONE way to bring the whole gap back: it lands on
`in_scope` (`still ∪ new ∪ ex_live`), and it also drops whatever left the scope
(a `--last N` window rolling forward). `--include-excluded` therefore takes
SPECIFIC ids only — the one thing accumulative cannot express — and refuses the
redundant `all` form with a pointer to accumulative.

The plan is always computed first (`--dry-run` prints it and writes nothing);
the write itself renders the target set into a temp dir and swaps it over the run
in two renames, so a failed run never leaves a half-updated export behind.
Read-only on the DB, always: `mode=ro` is what opens it.
"""
import argparse
import json
import os
import shutil
import sqlite3
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# Self-bootstrapping entry (like shrinklib/plan.py / exportlib/cli.py): running
# this file directly adds src/ to sys.path so the `exportlib` imports resolve.
MODULES_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if MODULES_DIR not in sys.path:
    sys.path.insert(0, MODULES_DIR)

from exportlib import TOOL_VERSION
from exportlib.config import default_db, default_out
from exportlib.db import all_session_ids, filter_subagent_policy, load_sessions
from exportlib.flags import FLAGS
from exportlib.stale import stale_ids
from exportlib.util import die, selection_phrase

MODES = ("delta", "accumulative")
STICKY = ("stale", "always", "never")

# Identity columns for the plan only (cheap: no per-row subqueries). The content
# renderers re-read whatever they need; this is just to compare timestamps.
LIVE_SQL = ("SELECT id, title, slug, parent_id, time_created, time_updated "
            "FROM session")


# ---------------------------------------------------------------- discovery ---
def _products_of(run_dir: Path) -> list[dict]:
    """One entry per product subdir: {"profile", "dir", "meta"}. A run without any
    metadata.json that carries .session_records cannot be refreshed — there is no
    record of WHICH sessions it contains, so the only honest move is re-export."""
    out = []
    for meta_path in sorted(run_dir.glob("*/metadata.json")):
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
        except Exception as e:
            die(f"{meta_path}: not readable JSON ({e})")
        if not isinstance(meta, dict):
            continue
        out.append({
            "profile": meta.get("profile") or meta_path.parent.name,
            "dir": meta_path.parent,
            "meta": meta,
        })
    if not out:
        die(f"{run_dir}: no metadata.json (legacy export? re-export it instead)")
    return out


def _baseline(prods: list[dict]) -> dict:
    """The run-level metadata: the product that carries `.session_records` (they
    are identical across the products of one run) and its rule/flags."""
    for p in prods:
        if p["meta"].get("session_records"):
            return p
    return prods[0]


def _effective_scope(in_scope: set, live: dict, live_ids: set, meta: dict) -> set:
    """The scope after the run's own subagent policy.

    Mirrors `exportlib.cli.filter_subagent_policy` (the ONE definition used at
    write time): a real subagent has a non-empty `parent_id` whose parent row
    still exists (an orphan is a root), and `--no-orphan-subagents` is a closed
    set. Without this, `new` could re-add a subagent the run's flags drop, and a
    legacy `.excluded` entry could be "revived" only to be dropped again — a plan
    that never converges.
    """
    flags = meta.get("flags") if isinstance(meta.get("flags"), dict) else {}
    selected = {sid: live[sid] for sid in in_scope if sid in live}
    effective = filter_subagent_policy(
        selected,
        live_ids,
        bool(meta.get("no_subagents") or flags.get("no_subagents")),
        bool(meta.get("no_orphan_subagents") or flags.get("no_orphan_subagents")),
        meta.get("sub") or flags.get("sub"),
    )
    return set(effective)


# --------------------------------------------------------------------- plan ---
def build_plan(args) -> dict:
    db = Path(default_db())
    if not db.exists():
        die(f"Database not found: {db}")
    run_dir = Path(args.out_base) / args.stamp
    if not run_dir.is_dir():
        die(f"Not found: {run_dir}")

    prods = _products_of(run_dir)
    base = _baseline(prods)
    meta = base["meta"]

    recs = {r.get("id"): r for r in (meta.get("session_records") or []) if r.get("id")}
    if not recs:
        die(f"{args.stamp}: no .session_records — cannot tell what it contains "
            "(re-export it instead)")
    excluded = {r.get("id"): r for r in (meta.get("excluded") or []) if r.get("id")}
    scope = meta.get("scope") or meta.get("selection") or {"rule": "all"}
    if not isinstance(scope, dict) or "rule" not in scope:
        scope = {"rule": "all"}
    included = set(recs)

    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    try:
        live = {r["id"]: dict(r) for r in con.execute(LIVE_SQL)}
        live_ids = all_session_ids(con)
        rule = scope.get("rule")
        if rule == "all":
            in_scope = set(live_ids)
        else:
            in_scope = set(load_sessions(
                con,
                scope.get("value") if rule == "filter" else None,
                scope.get("ids") if rule == "sessions" else None,
                scope.get("value") if rule == "last" else None,
                scope.get("value") if rule == "since" else None,
            ))
    finally:
        con.close()

    # The run's own subagent policy shapes the effective scope too. `.excluded`
    # is the SELECTION gap (the run records it already policy-filtered), but a
    # legacy run may still carry a policy-dropped subagent there; applying the
    # flags here means `new`/`revived` can never re-add one. This is what keeps
    # the plan equal to what the child export will really write.
    effective_scope = _effective_scope(in_scope, live, live_ids, meta)

    # ONE freshness rule (exportlib/stale.py), shared with `exports view` and
    # `exports stale`. A session "changed" when the DB's clock moved past the
    # timestamp the run recorded; missing sessions are handled by `gone`.
    states = {
        e["id"]: e["state"]
        for e in stale_ids(
            list(meta.get("session_records") or []) + list(excluded.values()),
            live,
        )
    }

    still = included & set(live_ids)
    gone = included - set(live_ids)
    new = effective_scope - included - set(excluded)
    # An excluded session only counts when it is still in scope AND still alive:
    # a dead one leaves `.excluded` rather than being offered forever.
    ex_live = set(excluded) & effective_scope & set(live_ids)
    ex_stale = {sid for sid in ex_live if states.get(sid) == "stale"}
    changed = {sid for sid in still if states.get(sid) == "stale"}

    mode = args.mode
    if mode == "accumulative":
        # The scope IS the content now: every excluded session comes back, and
        # anything that left the scope (a `--last N` window rolling forward) is
        # dropped. This is the "do it all over again" axis.
        target = set(effective_scope)
        revived = set(ex_live)
        excluded_out = set()
    else:
        if args.include_excluded:
            revived = ex_live & set(args.include_excluded)
        elif args.sticky == "always":
            revived = set(ex_live)
        elif args.sticky == "never":
            revived = set()
        else:  # stale (default): a deliberate skip stays deliberate, until the
            # session actually gets edited — then the run no longer describes it.
            revived = set(ex_stale)
        target = still | new | revived
        excluded_out = ex_live - revived

    if not target:
        die("update would leave the run empty (nothing in scope) — "
            "re-export with an explicit selection instead")

    # "Anything moved": the run is only worth re-rendering when its CONTENT can
    # differ — a set that did not change AND no session the DB edited.
    dirty = bool(new) or bool(changed) or bool(gone) or bool(revived) or target != included

    products = [p["profile"] for p in prods]
    plan = {
        "stamp": args.stamp,
        "mode": mode,
        "sticky": args.sticky,
        "include_excluded": (args.include_excluded or None),
        "keep_history": bool(args.keep_history),
        "scope": scope,
        "scope_label": selection_phrase({"selection": scope}),
        "preset": meta.get("preset"),
        "products": products,
        "counts": {
            "kept": len(target & included),
            "new": len(new),
            "changed": len(changed),
            "gone": len(gone),
            "revived": len(revived),
            "excluded_kept": len(excluded_out),
            "excluded_total": len(ex_live),
            "target": len(target),
            "before": len(included),
        },
        "new": _entries(new, live, recs),
        "changed": _entries(changed, live, recs),
        "gone": _entries(gone, live, recs),
        "revived": _entries(revived, live, recs),
        "excluded": _entries(excluded_out, live, recs),
        "target": sorted(target),
        "up_to_date": not dirty,
        "run_dir": str(run_dir),
    }
    plan["_included"] = included
    plan["_target"] = target
    plan["_in_scope"] = effective_scope
    plan["_prods"] = prods
    plan["_meta"] = meta
    plan["_scope"] = scope
    return plan


def _entries(ids, live, recs) -> list[dict]:
    """id/title/kind for one plan section: live title when it still exists, the
    run's own record when it is gone (that is the only place its name is left)."""
    out = []
    for sid in sorted(ids):
        if sid in live:
            r = live[sid]
            title = r.get("title") or r.get("slug") or ""
        else:
            r = recs.get(sid) or {}
            title = r.get("title") or ""
        out.append({"id": sid, "title": title})
    return out


# ------------------------------------------------------------------- output ---
def print_plan(plan: dict, stream=sys.stdout) -> None:
    w = stream.write
    c = plan["counts"]
    w(f"== Export update plan (read-only; nothing written) ==\n\n")
    w(f"  Run      : {plan['stamp']}\n")
    w(f"  Mode     : {plan['mode']}"
      + ("" if plan["mode"] == "delta" else "  (full re-sync with the scope)")
      + f"  · sticky: {plan['sticky']}\n")
    w(f"  Scope    : {plan['scope_label']}\n")
    if plan.get("preset"):
        w(f"  Preset   : {plan['preset']}\n")
    w(f"  Products : {' + '.join(plan['products'])}\n")
    w(f"  In the run now : {c['before']} session(s)\n\n")
    w(f"    kept     : {c['kept']}\n")
    w(f"    new      : {c['new']}{'  ' + _oneline(plan['new']) if plan['new'] else ''}\n")
    w(f"    changed  : {c['changed']}{'  ' + _oneline(plan['changed']) if plan['changed'] else ''}\n")
    w(f"    gone     : {c['gone']}{'  ' + _oneline(plan['gone']) if plan['gone'] else ''}\n")
    w(f"    revived  : {c['revived']}{'  ' + _oneline(plan['revived']) if plan['revived'] else ''}\n")
    w(f"    excluded : {c['excluded_kept']} kept out of {c['excluded_total']} "
      f"(the run's own leftovers, still out of scope)\n")
    w(f"\n  After the update : {c['target']} session(s)\n")
    if plan["keep_history"]:
        w("  Previous state   : kept as <stamp>~<date> (hardlinks)\n")
    w("\n")


def _oneline(entries, max_n: int = 4) -> str:
    parts = []
    for e in entries[:max_n]:
        t = (e["title"] or "").strip()
        if len(t) > 24:
            t = t[:23] + "…"
        parts.append(f"{e['id']} {t}".rstrip())
    if len(entries) > max_n:
        parts.append(f"… +{len(entries) - max_n}")
    return " · ".join(parts)


# ------------------------------------------------------------------ execute ---
def _flags_argv(meta: dict) -> list:
    """argv for one product's content flags: `.flags` when the run recorded it,
    the handful of top-level keys a legacy run did record otherwise (its missing
    keys are the flag defaults, which is what the shipped presets set anyway)."""
    spec = {f.name: f for f in FLAGS}
    flags = meta.get("flags")
    if not isinstance(flags, dict) or not flags:
        flags = {}
        for k in ("sub", "no_subagents", "no_orphan_subagents", "tool_output",
                  "tool_input_limit", "tool_output_limit", "patch", "role",
                  "summary_diffs", "sanitize", "cap", "files", "mark_compactions"):
            if k in meta and meta[k] is not None:
                flags[k] = meta[k]
        # `reasoning` is stored ON, metadata writes it ON, the flag is `--no-reasoning`.
        if "reasoning" in meta and "no_reasoning" not in flags:
            flags["no_reasoning"] = not bool(meta.get("reasoning"))
        if "no_reasoning" in flags:
            flags["no_reasoning"] = bool(flags["no_reasoning"])
        # memory stores the file list flag under its own name.
        if "touched_files" in meta:
            flags["files"] = bool(meta.get("touched_files"))
    argv = []
    for k, v in flags.items():
        f = spec.get(k)
        if f is None or v is None or v == "":
            continue
        if f.flag_type == "bool":
            if v:
                argv.append(f"--{f.cli_name}")
        elif f.flag_type == "int":
            try:
                argv.append(f"--{f.cli_name}={int(v)}")
            except (TypeError, ValueError):
                continue
        else:
            argv.append(f"--{f.cli_name}={v}")
    return argv


def _scope_argv(scope: dict) -> list:
    """The scope as a CLI selection, only when the target set IS the whole scope
    (then it reproduces it exactly and keeps a big id list out of argv); a
    narrowed target is always spelled out as explicit ids."""
    rule = scope.get("rule")
    if rule == "filter":
        return ["--filter", str(scope.get("value"))]
    if rule == "last":
        return [f"--last={scope.get('value')}"]
    if rule == "since":
        return [f"--since={scope.get('value')}"]
    if rule == "sessions":
        return [f"--sessions={i}" for i in (scope.get("ids") or [])]
    return []


def execute(plan: dict, args) -> str:
    run_dir = Path(plan["run_dir"])
    out_base = run_dir.parent
    stamp = plan["stamp"]
    scope_json = json.dumps(plan["_scope"], ensure_ascii=False)
    preset = plan.get("preset")
    # Only spell the target out as ids when it is NOT exactly the scope: a run
    # that covers its scope re-runs the scope's own rule, which keeps a huge id
    # list out of argv and records the same rule in metadata.
    full_scope = set(plan["target"]) == plan["_in_scope"]
    tmp = out_base / f".update-{stamp}-{os.getpid()}"
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir(parents=True)

    history = None
    if args.keep_history:
        history = _history_dir(run_dir)
        shutil.copytree(run_dir, history, copy_function=os.link, symlinks=True)

    cli_entry = str(Path(__file__).resolve().parent / "cli.py")
    try:
        for p in plan["_prods"]:
            meta = p["meta"]
            argv = [sys.executable, cli_entry, p["profile"],
                    "--stamp", stamp, "--out", str(tmp),
                    "--scope-json", scope_json,
                    "--update-from", stamp,
                    "--update-mode", plan["mode"]]
            if preset:
                argv.append(f"--preset-name={preset}")
            argv += _flags_argv(meta)
            argv += (["--sessions", ",".join(plan["target"])]
                     if not full_scope else _scope_argv(plan["_scope"]))
            # Flush our own buffered output first: the children write straight to
            # fd 1, so without this the plan would print AFTER their export lines.
            sys.stdout.flush()
            res = subprocess.run(argv)
            if res.returncode:
                raise SystemExit(res.returncode)

        new_stamp_dir = tmp / stamp
        if not new_stamp_dir.is_dir():
            die(f"update produced no output for {stamp}")

        if len(plan["_prods"]) > 1:
            from exportlib.cli import _write_bundle_index
            idx_args = _IdxArgs(preset=preset, scope_json=scope_json,
                                update_from=stamp, update_mode=plan["mode"])
            _write_bundle_index(new_stamp_dir, idx_args, stamp,
                                plan["products"], Path(default_db()))

        # Two renames: the run is never absent for longer than the gap between
        # them, and a crash before the second leaves the ORIGINAL run intact.
        trash = out_base / f".old-{stamp}-{os.getpid()}"
        os.rename(run_dir, trash)
        try:
            os.rename(new_stamp_dir, run_dir)
        except BaseException:
            os.rename(trash, run_dir)
            raise
        shutil.rmtree(trash, ignore_errors=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    return str(history) if history else ""


class _IdxArgs:
    """The two attributes `_write_bundle_index` reads from a bundle's args."""

    def __init__(self, **kw):
        for k, v in kw.items():
            setattr(self, k, v)


def _history_dir(run_dir: Path) -> Path:
    stem = run_dir.name + "~"
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d_%H-%M")
    cand = run_dir.parent / f"{stem}{ts}"
    n = 2
    while cand.exists():
        cand = run_dir.parent / f"{stem}{ts}@{n}"
        n += 1
    return cand


# --------------------------------------------------------------------- main ---
def build_argparser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        prog="opencode-db exports update",
        description="Refresh an existing export run from the live DB.",
    )
    ap.add_argument("stamp", help="export run to update (the name in `exports list`)")
    ap.add_argument("--mode", choices=MODES, default="delta",
                    help="delta keeps the run's own set (+new, -gone); "
                         "accumulative re-syncs it with the whole scope")
    ap.add_argument("--sticky", choices=STICKY, default="stale",
                    help="when an excluded session is pulled back in: only if it "
                         "changed (stale, default), always, or never")
    ap.add_argument("--include-excluded", default=None, metavar="ID,ID",
                    help="re-include specific excluded sessions (ids), "
                         "regardless of --sticky; to reopen EVERY excluded "
                         "session use --mode accumulative")
    ap.add_argument("--keep-history", action="store_true",
                    help="keep the previous state as <stamp>~<date> (hardlinks)")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the plan and write nothing")
    ap.add_argument("--json", action="store_true", help="print the plan as JSON")
    ap.add_argument("--yes", action="store_true", help="skip the confirmation")
    return ap


def main(argv=None) -> int:
    args = build_argparser().parse_args(argv)
    args.out_base = default_out()

    if args.include_excluded:
        if args.include_excluded.strip() == "all":
            # `--include-excluded all` was the exact twin of `--mode accumulative`
            # (both land on `in_scope`), so it is refused here with the one form
            # that also SUPERSETS it (accumulative additionally drops what left
            # the scope). Specific ids stay supported: that is the one thing
            # accumulative cannot express.
            die("--include-excluded all is redundant: use --mode accumulative "
                "(it reopens every excluded), or list specific ids")
        args.include_excluded = [i.strip() for i in args.include_excluded.split(",")
                                 if i.strip()]

    plan = build_plan(args)

    if args.json:
        json.dump({k: v for k, v in plan.items() if not k.startswith("_")},
                  sys.stdout, indent=2, ensure_ascii=False)
        sys.stdout.write("\n")
    elif not args.yes:
        # `--yes` means "the caller owns the gate AND already showed the plan"
        # (the menu wizard prints it right before its confirm), so re-printing it
        # here would put the same block on screen twice. `--dry-run` always prints.
        print_plan(plan)

    if args.dry_run:
        return 0
    if plan["up_to_date"]:
        if not args.json:
            print(f"Nothing to do: {plan['stamp']} is already up to date "
                  f"({plan['counts']['target']} session(s)).")
        return 0
    if not args.yes:
        if not sys.stdin.isatty():
            die("not interactive: re-run with --yes (or --dry-run to only see "
                "the plan)")
        try:
            answer = input(f"Update {plan['stamp']} ({plan['mode']}) now? [y/N] ")
        except (EOFError, KeyboardInterrupt):
            print()
            return 2
        if answer.strip().lower() not in ("y", "yes"):
            print("Cancelled (nothing written).")
            return 2

    history = execute(plan, args)
    c = plan["counts"]
    print(f"[OK] Updated export run: {plan['stamp']} ({plan['mode']})")
    print(f"   Sessions    : {c['kept']} kept · {c['new']} new · "
          f"{c['changed']} changed · {c['gone']} gone · {c['revived']} revived")
    print(f"   Excluded    : {c['excluded_kept']} still excluded")
    print(f"   Products    : {' + '.join(plan['products'])}")
    if history:
        print(f"   Previous    : {Path(history).name} (hardlink copy)")
    print(f"   See: opencode-db exports view {plan['stamp']}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print()
        sys.exit(130)
