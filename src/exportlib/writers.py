# Output helpers: stamp/profile dirs, the run index and backup-to-latest info.
import hashlib
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path

from exportlib import TOOL_VERSION
from exportlib.config import default_bkp_dir
from exportlib.db import walk_subagents
from exportlib.util import (
    safe_filename,
    selection_label,
    selection_meta,
    selection_phrase,
    ts_iso,
)


def _preset_suffix_for_name(name: str | None) -> str:
    """Short human suffix to append to the run folder, e.g. _review.
    The suffix is only used for naming; the preset name is still recorded in metadata."""
    if not name:
        return ""
    clean = str(name).strip().replace(" ", "-")
    clean = ''.join(ch if ch.isalnum() or ch in "-_" else "-" for ch in clean)
    clean = clean.strip("-")
    return f"_{clean}" if clean else ""


def make_outdir_final(
    base,
    stamp: str | None = None,
    preset_name: str | None = None,
    *,
    bundle_child: bool = False,
):
    stamp = stamp or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    if bundle_child:
        target = base / stamp
        target.mkdir(parents=True, exist_ok=True)
        return target
    suffix = _preset_suffix_for_name(preset_name)
    target = base / f"{stamp}{suffix}"
    n = 2
    while target.exists():
        target = base / f"{stamp}{suffix}@{n}"
        n += 1
    target.mkdir(parents=True, exist_ok=False)
    return target


def session_updated_date(session: dict) -> str:
    try:
        return ts_iso(session.get("time_updated"))[:10] or "unknown-date"
    except (OverflowError, OSError, TypeError, ValueError):
        return "unknown-date"


def project_key(session: dict) -> str:
    directory = str(session.get("directory") or "")
    normalized = re.sub(r"/+", "/", directory.replace("\\", "/")).rstrip("/")
    if not normalized or re.fullmatch(r"[A-Za-z]:", normalized):
        return "no-project"
    windows_drive = re.match(r"^([A-Za-z]):/(.*)$", normalized)
    wsl_drive = re.match(r"^/mnt/([A-Za-z])/(.*)$", normalized, flags=re.IGNORECASE)
    if windows_drive:
        return f"{windows_drive.group(1)}:/{windows_drive.group(2)}".casefold()
    if wsl_drive:
        return f"{wsl_drive.group(1)}:/{wsl_drive.group(2)}".casefold()
    return normalized.casefold() if os.name == "nt" else normalized


def project_id(session: dict) -> str:
    return hashlib.sha256(project_key(session).encode("utf-8")).hexdigest()[:12]


def session_file_stem(session: dict) -> str:
    title = session["title"] or session["slug"]
    return f"{session_updated_date(session)}__{safe_filename(title)}_{session['id'][:8]}"


def project_folder_name(session: dict) -> str:
    directory = str(session.get("directory") or "")
    parts = [part for part in directory.replace("\\", "/").split("/") if part]
    name = parts[-1] if parts else ""
    if not name or name.endswith(":"):
        return "no-project"
    return safe_filename(name, fallback="no-project")


def _project_dates(sessions: dict) -> dict:
    dates = {}
    for session in sessions.values():
        key = project_key(session)
        date = session_updated_date(session)
        if date != "unknown-date" and (key not in dates or date > dates[key]):
            dates[key] = date
    return dates


def project_folder_name_with_date(session: dict, date: str) -> str:
    return f"{date}_{project_folder_name(session)}_{project_id(session)}"


def _unique_folder_name(name: str, used: set[str]) -> str:
    if name not in used:
        used.add(name)
        return name
    index = 2
    candidate = f"{name}@{index}"
    while candidate in used:
        index += 1
        candidate = f"{name}@{index}"
    used.add(candidate)
    return candidate


def subagent_family_folder(root: dict, subs: list[str], sessions: dict,
                           project: str | None = None) -> str:
    project = project or project_folder_name(root)
    dates = [session_updated_date(sessions[sid]) for sid in subs]
    date = max((d for d in dates if d != "unknown-date"), default="unknown-date")
    title = safe_filename(root["title"] or root["slug"], fallback="session")
    return f"{date}__{project}__{root['id'][:8]}_{title}__subagents"


def session_layouts(sessions: dict, roots: list[str], children_of: dict) -> dict:
    layouts = {}
    used_families: set[str] = set()
    ordered = sorted(roots, key=lambda sid: sessions[sid]["id"])
    projects = {}
    dates = _project_dates(sessions)
    for rid in ordered:
        session = sessions[rid]
        key = project_key(session)
        projects[rid] = project_folder_name_with_date(
            session, dates.get(key, session_updated_date(session))
        )
    for rid in ordered:
        root = sessions[rid]
        subs = [sid for sid, _depth in walk_subagents(rid, children_of)]
        project = projects[rid]
        family = subagent_family_folder(root, subs, sessions, project) if subs else None
        if family:
            family = _unique_folder_name(family, used_families)
        layouts[rid] = (project, family, subs)
    return {rid: layouts[rid] for rid in roots}


def session_product_path(out_dir, session: dict, product: str, suffix: str, args,
                         project: str, family: str | None = None,
                         subagent: bool = False):
    folder = Path(project)
    if subagent and family:
        folder = folder / family
    return out_dir / folder / session_product_filename(
        session_file_stem(session), product, suffix, args
    )


def product_artifact_path(out_dir, filename: str, args):
    """Suffix indexes/metadata only when several products share a run root."""
    if getattr(args, "bundle_child", False):
        path = Path(filename)
        return out_dir / f"{path.stem}.{args.profile}{path.suffix}"
    return out_dir / filename


def session_product_filename(stem: str, product: str, suffix: str, args) -> str:
    return f"{stem}.{product}{suffix}"


def product_artifact_files(out_dir, args) -> list[str]:
    files = sorted(path for path in out_dir.rglob("*") if path.is_file())
    if not getattr(args, "bundle_child", False):
        return [str(path.relative_to(out_dir)) for path in files]
    profile = args.profile

    def belongs(path: Path) -> bool:
        return (
            path.name == f"index.{profile}.md"
            or path.name == f"metadata.{profile}.json"
            or path.name.endswith(f".{profile}.md")
            or path.name.endswith(f".{profile}.json")
            or (profile == "transcript" and path.parent.name.endswith(".transcript.parts"))
            or (profile == "memory" and path.name == "memory.jsonl")
            or (profile == "corpus" and path.name == "corpus.jsonl")
        )

    return [
        str(path.relative_to(out_dir))
        for path in files
        if belongs(path)
    ]


def write_index(index_path, out_dir, args, db_path, sessions, written, total_msgs, total_comp,
                total_digest=0, n_backfilled=0, scope=None, children_of=None):
    children_of = children_of or {}
    with index_path.open("w", encoding="utf-8") as f:
        f.write("# opencode session export\n\n")
        f.write("| Field | Value |\n|---|---|\n")
        f.write(f"| Product | `{args.profile}` |\n")
        # The name of the plan that produced this run, when one was used. This is
        # the human entry point of the run, so the provenance the machine reads in
        # metadata.json (`.preset`) belongs here too. A plain product keyword has
        # no preset row.
        if getattr(args, "preset", None):
            f.write(f"| Preset | `{args.preset}` |\n")
        f.write(f"| Date | {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} |\n")
        f.write(f"| Source DB | `{db_path}` |\n")
        # One row for the effective selection, whatever rule produced it
        # (filter / ids / last N / since DATE / all) — the same phrase as
        # metadata.json's `selection` and the "matched nothing" error.
        f.write(f"| Selection | {selection_label(args)} |\n")
        # A narrowed run has two facts worth keeping: what it contains
        # (`.selection`) and the wider set it was drawn from (`.scope`). They are
        # identical for a plain run, so the row only appears when it adds
        # information.
        if scope is not None and selection_meta(args) != scope:
            f.write(f"| Scope | {selection_phrase({'selection': scope})} |\n")
        # Provenance of a refreshed run (exports update): the base run it came
        # from and the axis it used, next to the selection it still follows.
        if getattr(args, "update_from", None):
            f.write(f"| Updated from | `{args.update_from}` ({args.update_mode or 'delta'}) |\n")
        f.write(f"| Sessions (roots/subagents/total) | {len(written)} / {sum(len(s[1]) for s in written)} / {len(sessions)} |\n")
        # Subagent inclusion: only surfaced when a flag narrowed the set (the
        # default run keeps the historical rows untouched).
        if getattr(args, "no_subagents", False):
            f.write("| Subagents | `excluded (--no-subagents)` |\n")
        elif getattr(args, "no_orphan_subagents", False):
            f.write("| Subagents | `only those whose parent is exported (--no-orphan-subagents)` |\n")
        # The `sub` MODE only when it changes the output: separate is the default.
        if getattr(args, "sub", "separate") != "separate":
            f.write(f"| Subagent layout | `{args.sub}` |\n")
        f.write(f"| Messages | {total_msgs} |\n")
        # Markers vs digest texts: two different counters (see docs/schemas.md §2).
        f.write(f"| Compactions | {total_comp} |\n")
        f.write(f"| Compaction digests | {total_digest} |\n")
        f.write(f"| Tool output | `{args.tool_output}` |\n")
        f.write(f"| Reasoning | `{'on' if not args.no_reasoning else 'off'}` |\n")
        # The role filter is a content-shaping flag: `all` is the default, so it
        # only gets a row when a role actually narrowed the transcript (e.g. the
        # `prompts` preset). A human reading the index must see it.
        if getattr(args, "role", "all") != "all":
            f.write(f"| Role | `{args.role}` |\n")
        # These two change the content but default to off: surface them only when
        # they were turned on, like the subagent-exclusion row above.
        if getattr(args, "summary_diffs", False):
            f.write("| Summary diffs | `on` |\n")
        if getattr(args, "mark_compactions", False):
            f.write("| Mark compactions | `on` |\n")
        f.write(f"| Sanitize | `{'on' if args.sanitize else 'off'}` |\n")
        # Token/cost backfill only when it happened.
        if n_backfilled:
            f.write(f"| Tokens backfilled | {n_backfilled} session(s) from step-finish |\n")
        f.write("| Extraction | Python `exportlib` (read `mode=ro`) from `~/.local/share/opencode/opencode.db` |\n")
        metadata_name = product_artifact_path(out_dir, "metadata.json", args).name
        f.write(f"| Full metadata | [`{metadata_name}`]({metadata_name}) |\n\n")
        f.write("## Sessions\n\n")
        for i, (root, subs, project, family) in enumerate(written, 1):
            rt = root["title"] or root["slug"]
            root_md = Path(project) / session_product_filename(
                session_file_stem(root), args.profile, ".md", args
            )
            f.write(f"{i}. **[{rt}]({root_md})**  — `{root['id']}`  · agent `{root.get('agent') or '?'}`\n")
            if children_of.get(root["id"]):
                f.write("   \n   Subagents:\n")

                def write_children(parent_id: str, depth: int) -> None:
                    for sid_ in children_of.get(parent_id, []):
                        sub = sessions[sid_]
                        st = sub["title"] or sub["slug"]
                        indent = "   " * depth
                        if getattr(args, "sub", "separate") == "separate":
                            sub_name = session_product_filename(
                                session_file_stem(sub),
                                args.profile,
                                ".md",
                                args,
                            )
                            rel_s = Path(project) / (family or "subagents") / sub_name
                            f.write(f"{indent}- [{st}]({rel_s})  `{sub['id'][:8]}`\n")
                        else:
                            f.write(f"{indent}- {st}  `{sub['id'][:8]}` (inline)\n")
                        write_children(sid_, depth + 1)

                write_children(root["id"], 1)
            f.write("\n")
        f.write("---\n")
        f.write(f"\nGenerated by `opencode-db` v{TOOL_VERSION}.\n")


def last_backup_info():
    manifest = Path(default_bkp_dir()) / "manifest.json"
    if not manifest.exists():
        return None
    try:
        data = json.loads(manifest.read_text(encoding="utf-8"))
        b = data.get("backups") or []
        if not b:
            return None
        b = sorted(b, key=lambda x: x.get("date", ""))
        last = b[-1]
        return {"file": last.get("file"), "date": last.get("date")}
    except Exception:
        return None
