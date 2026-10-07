# Named shrink presets.
# A presets file (JSON, default ~/.config/opencode-db/shrink-presets.json, path via
# OCED_SHRINK_PRESETS) is the source of truth for named shrink recipes:
#   {"presets": {"lean":  {"strip_reasoning": true},
#                "quiet": {}}}
# A preset carries ONLY OPERATIONS (what is done to the copy besides the pruning).
# The SESSION SELECTION is deliberately NOT a preset key: the menu asks for it
# (sessions picker -> --keep-all/--keep-sessions/--discard-sessions) and the CLI
# takes the selection flags (--keep/--older-than/--since/--keep-all/
# --keep-sessions/--discard-sessions, exactly ONE, `keep` = 10 by default). A keep
# rule inside a preset is rejected with a pointer to those flags.
# The built-in recipes (DEFAULT_SHRINK_PRESETS) are always available and a file
# preset may override or extend them. Invoked as `shrink <name>`; explicit CLI
# flags win over the recipe thanks to last-wins baking.
# The menu reads the same file for its operation rows and plans.
import json
from pathlib import Path
from typing import Any

from shrinklib.config import default_shrink_presets
from shrinklib.flags import (
    DEFAULT_SHRINK_PRESETS,
    KEEP_RULE_KEYS,
    SHRINK_PRESET_KEYS,
)
from exportlib.util import die


def load_shrink_presets() -> dict:
    """Presets from the OCED_SHRINK_PRESETS file ({} when absent/invalid-shape)."""
    p = Path(default_shrink_presets())
    if not p.exists():
        return {}
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except Exception as e:
        die(f"invalid shrink presets file {p}: {e}")
    presets = data.get("presets") if isinstance(data, dict) else None
    if not isinstance(presets, dict):
        die(f"shrink presets file {p}: expected {{\"presets\": {{...}}}}")
    return {str(k): v for k, v in presets.items()}


def validate_preset(name: str, pdata: Any) -> dict:
    """Validate one preset: shape, allowed keys (operations only), types."""
    if not isinstance(pdata, dict):
        die(f"shrink preset '{name}': expected an object, got {type(pdata).__name__}")
    # A keep rule is not "legacy": the selection is simply a different concern.
    # Point the user at the CLI flags instead of silently ignoring it.
    for k in pdata:
        if k in KEEP_RULE_KEYS:
            die(
                f"shrink preset '{name}': '{k}' selects sessions, and a recipe no longer "
                f"selects sessions (the menu asks you with its picker). Use the CLI flag "
                f"--{k.replace('_', '-')} instead, or move the rule out of the preset."
            )
    unknown = [k for k in pdata if k not in SHRINK_PRESET_KEYS]
    if unknown:
        die(
            f"shrink preset '{name}': unknown key '{unknown[0]}' "
            f"(a recipe carries operations only: {' | '.join(SHRINK_PRESET_KEYS)})"
        )
    if "strip_reasoning" in pdata and not isinstance(pdata["strip_reasoning"], bool):
        die(
            f"shrink preset '{name}': 'strip_reasoning' must be true/false "
            f"(got {pdata['strip_reasoning']!r})"
        )
    return dict(pdata)


def merged_presets() -> dict:
    """Built-in recipes + the presets file (file wins on names; rarely used: it
    lets a user tune the shipped recipes too). All validated."""
    presets: dict[str, dict] = dict(DEFAULT_SHRINK_PRESETS)
    for name, pdata in load_shrink_presets().items():
        presets[name] = validate_preset(name, pdata)
    return presets


def bake_args(name: str) -> list[str]:
    """Resolve a recipe into raw cross-flag arguments for the bash parser
    (operations only). `shrink <name>` prepends these BEFORE the user's flags
    (last-wins on the CLI). Dies with the list of known recipes for unknown names."""
    presets = merged_presets()
    if name not in presets:
        known = ", ".join(sorted(presets))
        die(f"unknown shrink recipe/preset '{name}' — known: {known}")
    cfg = presets[name]
    args: list[str] = []
    if cfg.get("strip_reasoning"):
        args.append("--strip-reasoning")
    return args


def selection_lines(cfg: dict) -> list[str]:
    """Human description of a SESSION SELECTION rule (keep the N most recent…).

    Used by the CLI (`shrink --help`, shrink.json `criteria`, the criteria line of
    a real run) — never by a recipe, which carries no selection."""
    out: list[str] = []
    if "keep" in cfg:
        out.append(f"keep the {cfg['keep']} most recent session(s)")
    elif "older_than" in cfg:
        out.append(f"keep sessions updated within the last {cfg['older_than']} day(s)")
    elif "since" in cfg:
        out.append(f"keep sessions updated since {cfg['since']}")
    elif cfg.get("keep_all"):
        out.append("keep all sessions")
    elif "keep_sessions" in cfg:
        out.append(
            f"keep only the {len(cfg['keep_sessions'])} listed session(s) "
            "(their parents + subagents are kept too)"
        )
    elif "discard_sessions" in cfg:
        out.append(
            f"keep everything except the {len(cfg['discard_sessions'])} listed "
            "session(s) (their subagents are dropped too)"
        )
    return out


def op_lines(cfg: dict) -> list[str]:
    """Human description of the OPERATIONS of a recipe ("strip reasoning …").

    Kept phrase-compatible with the bash criteria strings so shrink.json and the
    menu plan agree."""
    out: list[str] = []
    if cfg.get("strip_reasoning"):
        out.append("strip reasoning (drop the 'reasoning' parts in the copy)")
    return out


def rule_lines(cfg: dict) -> list[str]:
    """Full human criteria of a resolved invocation: selection + operations.

    Single source with the bash engine's criteria line (plan.py rule-line)."""
    return selection_lines(cfg) + op_lines(cfg)


def selection_tag(cfg: dict) -> str:
    """The COMPACT shape of a session-selection rule — for a column.

    `selection_lines` is a sentence ("keep everything except the 2 listed
    session(s) (their subagents are dropped too)"), which is right inside
    shrink.json / `shrink --help` where the width costs nothing and wrong in a
    list row, where it pushed `shrinks list` to 225 characters and buried the
    three numbers that matter (how many sessions survived, how much space was
    freed). Same data, one word per rule; the sentence stays where it belongs.
    """
    if "keep" in cfg:
        return f"keep {cfg['keep']} newest"
    if "older_than" in cfg:
        return f"last {cfg['older_than']}d"
    if "since" in cfg:
        return f"since {cfg['since']}"
    if cfg.get("keep_all"):
        return "keep all"
    if "keep_sessions" in cfg:
        return f"keep {len(cfg['keep_sessions'])} ids"
    if "discard_sessions" in cfg:
        return f"discard {len(cfg['discard_sessions'])} ids"
    return ""


def rule_tags(cfg: dict) -> str:
    """Compact tag of a resolved invocation: selection + operations in one cell.

    `+strip` is the whole operations vocabulary that survives a shrink.json
    (strip_reasoning is recorded as a count); `quiet`'s prune+vacuum is implied
    by the size and the removed rows, so it needs no tag of its own."""
    out = selection_tag(cfg)
    if cfg.get("strip_reasoning"):
        out = f"{out} +strip" if out else "+strip"
    return out