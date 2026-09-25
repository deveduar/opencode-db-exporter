# Named shrink presets.
# A presets file (JSON, default ~/.config/opencode-db/shrink-presets.json, path via
# OCED_SHRINK_PRESETS) is the source of truth for named shrink recipes:
#   {"presets": {"lean": {"keep": 10, "strip_reasoning": true},
#                "spring-clean": {"discard_sessions": ["ses_...", "ses_..."]}}}
# A preset pins EXACTLY ONE keep rule (keep | older_than | since | keep_all |
# keep_sessions | discard_sessions) and optionally strip_reasoning. The built-in
# recipes (DEFAULT_SHRINK_PRESETS) are always available and a file preset may
# override or extend them. Invoked as `shrink <name>`; explicit CLI flags
# (--keep, --older-than, ...) win over the preset thanks to last-wins baking.
# The menu reads the same file for its preset rows and plans.
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
    """Validate one preset: shape, allowed keys, exactly one keep rule, types."""
    if not isinstance(pdata, dict):
        die(f"shrink preset '{name}': expected an object, got {type(pdata).__name__}")
    unknown = [k for k in pdata if k not in SHRINK_PRESET_KEYS]
    if unknown:
        die(
            f"shrink preset '{name}': unknown key '{unknown[0]}' "
            f"(allowed: {' | '.join(SHRINK_PRESET_KEYS)})"
        )
    rules = [k for k in KEEP_RULE_KEYS if k in pdata]
    if len(rules) != 1:
        die(
            f"shrink preset '{name}': exactly ONE keep rule required "
            f"(keep | older_than | since | keep_all | keep_sessions | discard_sessions), "
            f"got {len(rules)}"
        )
    rule = rules[0]
    if rule in ("keep", "older_than"):
        v = pdata[rule]
        if isinstance(v, bool) or not isinstance(v, int) or v < 1:
            die(f"shrink preset '{name}': '{rule}' must be a positive integer (got {v!r})")
    elif rule == "since":
        v = pdata[rule]
        if not isinstance(v, str) or not v:
            die(f"shrink preset '{name}': 'since' must be a date string YYYY-MM-DD (got {v!r})")
    elif rule == "keep_all":
        if not isinstance(pdata[rule], bool):
            die(f"shrink preset '{name}': 'keep_all' must be true/false (got {pdata[rule]!r})")
    else:  # keep_sessions / discard_sessions
        v = pdata[rule]
        if (
            not isinstance(v, list)
            or not v
            or not all(isinstance(x, str) and x.strip() for x in v)
        ):
            die(
                f"shrink preset '{name}': '{rule}' must be a non-empty list of session ids "
                f"(got {v!r})"
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
    """Resolve a preset/recipe into raw cross-flag arguments for the bash parser.
    `shrink <name>` prepends these BEFORE the user's flags (last-wins on the CLI).
    Dies with the list of known presets for unknown names."""
    presets = merged_presets()
    if name not in presets:
        known = ", ".join(sorted(presets))
        die(f"unknown shrink recipe/preset '{name}' — known: {known}")
    cfg = presets[name]
    args: list[str] = []
    if "keep" in cfg:
        args += ["--keep", str(cfg["keep"])]
    if "older_than" in cfg:
        args += ["--older-than", str(cfg["older_than"])]
    if "since" in cfg:
        args += ["--since", cfg["since"]]
    if cfg.get("keep_all"):
        args.append("--keep-all")
    if "keep_sessions" in cfg:
        args += ["--keep-sessions", ",".join(cfg["keep_sessions"])]
    if "discard_sessions" in cfg:
        args += ["--discard-sessions", ",".join(cfg["discard_sessions"])]
    if cfg.get("strip_reasoning"):
        args.append("--strip-reasoning")
    return args


def rule_lines(cfg: dict) -> list[str]:
    """Human description lines of a preset config ("keep the N most recent…").
    Kept phrase-compatible with the bash criteria strings so shrink.json and the
    menu plan agree."""
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
    if cfg.get("strip_reasoning"):
        out.append("strip reasoning (drop the 'reasoning' parts in the copy)")
    return out