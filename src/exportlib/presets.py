# Named export presets.
# A presets file (JSON, default ~/.config/opencode-db/presets.json, path via
# OCED_PRESETS) is the source of truth for named export recipes:
#   {"presets": {"clean": {"product": "transcript", "sanitize": true,
#                          "no_reasoning": true, "filter": "Project Beta"},
#                "everything": {"products": {"transcript": {"tool_output": "full"},
#                                            "faithful": {},
#                                            "memory": {"files": true}}}}}
# A preset pins the product + config flags and optionally the selection
# ('filter' LIKE pattern, or exact 'sessions' ids — not both). A single preset
# uses 'product' (transcript | memory | digest | faithful); a BUNDLE preset uses
# 'products' = {product: {flags...}} (selection stays top-level, shared by all
# products). Invoked as `export <name>`; explicit CLI flags
# (e.g. --filter, --sessions, --cap) win over the preset values.
# The menu reads the same file for its preset rows. Keys with no value = default.
import json
import sys
from pathlib import Path

from exportlib.config import default_presets
from exportlib.util import die, selection_meta
from exportlib.flags import (
    FLAGS,
    PRODUCTS,
    PRODUCT_KEYWORDS,
    PRODUCT_ALIASES,
    PRESET_DESCRIPTION_KEY,
    BUNDLE_PRODUCT_KEYS,
    SINGLE_PRESET_KEYS,
    BUNDLE_PRESET_KEYS,
)

# Internal derived views of flags.py (the SSoT); no other module imports these.
_PRODUCTS = PRODUCTS
_PRODUCT_FLAG_KEYS = {k: v for k, v in BUNDLE_PRODUCT_KEYS.items()}
_PRESET_KEYS_CHOICES = {f.name: f.choices for f in FLAGS if f.flag_type == "choice"}
_PRESET_KEYS_BOOL = [f.name for f in FLAGS if f.flag_type == "bool"]
_PRESET_KEYS = SINGLE_PRESET_KEYS
_PRESET_KEYS_BUNDLE = BUNDLE_PRESET_KEYS


def load_presets() -> dict:
    p = Path(default_presets())
    if not p.exists():
        return {}
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except Exception as e:
        die(f"invalid presets file {p}: {e}")
    presets = data.get("presets") if isinstance(data, dict) else None
    if not isinstance(presets, dict):
        die(f"presets file {p}: expected {{\"presets\": {{...}}}}")
    for name, pdata in presets.items():
        if not isinstance(pdata, dict):
            die(f"preset '{name}': expected an object, got {type(pdata).__name__}")
    return {str(k): v for k, v in presets.items()}


def _flag(k: str) -> str:
    """preset key (underscore) -> CLI flag (dash)."""
    return k.replace("_", "-")


def flag_in_argv(flag: str) -> bool:
    return any(a == flag or a.startswith(flag + "=") for a in sys.argv)


def preset_selection(name) -> dict | None:
    """The selection a named preset CARRIES, as a metadata-shaped rule.

    `_apply_selection` returns early the moment the CLI narrows a preset with
    `--sessions`, so the preset's own `filter`/`sessions` never reaches `args`;
    to record what the run was DRAWN FROM (metadata `.scope`) the selection has
    to be read back from the file. None = the preset carries no selection of its
    own (or the name is unknown / no file)."""
    if not name:
        return None
    pdata = load_presets().get(name) or {}
    if pdata.get("filter") is not None:
        return {"rule": "filter", "value": pdata["filter"]}
    if pdata.get("sessions") is not None:
        return {"rule": "sessions", "ids": list(pdata["sessions"])}
    return None


def scope_meta(args) -> dict:
    """metadata `.scope`: the BROAD selection the run was drawn FROM, as opposed
    to `.selection`, which is what it contains. They differ exactly when the CLI
    narrowed a preset (`--sessions` marks a subset of the scope), and that gap is
    what `exports update` re-opens (the gap itself is recorded as `.excluded`).

    The rules are the same as `.selection`, so `selection_phrase()` reads a
    `.scope` too without any new vocabulary."""
    explicit = getattr(args, "scope_json", None)
    if explicit:
        meta = explicit if isinstance(explicit, dict) else json.loads(explicit)
        if not isinstance(meta, dict) or "rule" not in meta:
            die("invalid --scope-json: expected a selection object")
        if meta["rule"] == "sessions":
            return {"rule": "sessions", "ids": list(meta.get("ids") or [])}
        if meta["rule"] == "all":
            return {"rule": "all"}
        return {"rule": meta["rule"], "value": meta.get("value")}
    if flag_in_argv("--sessions"):
        name = getattr(args, "preset_name", None) or getattr(args, "preset", None)
        if name:
            return preset_selection(name) or {"rule": "all"}
        return selection_meta(args)
    return selection_meta(args)


def _validate_value(name: str, k: str, v) -> None:
    if k in _PRESET_KEYS_CHOICES:
        choices = _PRESET_KEYS_CHOICES[k]
        if choices:
            if v not in choices:
                die(f"preset '{name}': '{k}' must be one of {', '.join(choices)} (got {v!r})")
        else:
            if isinstance(v, bool) or not isinstance(v, int) or v < 0:
                die(f"preset '{name}': '{k}' must be a non-negative integer (got {v!r})")
    elif k in _PRESET_KEYS_BOOL:
        if not isinstance(v, bool):
            die(f"preset '{name}': '{k}' must be true/false (got {v!r})")
    elif k == "cap":
        if isinstance(v, bool) or not isinstance(v, int) or v < 0:
            die(f"preset '{name}': 'cap' must be a non-negative integer (got {v!r})")


def _validate_description(name: str, pdata: dict) -> None:
    """The optional human one-liner must be a non-empty string (it configures
    nothing; it is only the picker/--list-presets/legend text)."""
    desc = pdata.get(PRESET_DESCRIPTION_KEY)
    if desc is not None and (not isinstance(desc, str) or not desc):
        die(f"preset '{name}': '{PRESET_DESCRIPTION_KEY}' must be a non-empty string")


def _apply_selection(args, name: str, pdata: dict) -> None:
    """filter/sessions on the preset. One CLI selection flag clobbers the whole preset selection."""
    if pdata.get("filter") is not None and pdata.get("sessions") is not None:
        die(f"preset '{name}': use either 'filter' or 'sessions', not both")
    cli_selection = flag_in_argv("--filter") or flag_in_argv("--sessions")
    if cli_selection:
        return
    if pdata.get("filter") is not None:
        v = pdata["filter"]
        if not isinstance(v, str) or not v:
            die(f"preset '{name}': 'filter' must be a non-empty string")
        args.filter = v
    if pdata.get("sessions") is not None:
        v = pdata["sessions"]
        if not isinstance(v, list) or not v or not all(isinstance(x, str) and x for x in v):
            die(f"preset '{name}': 'sessions' must be a non-empty list of session ids")
        args.sessions = v


def apply_preset(args, name: str, pdata: dict) -> None:
    for k in pdata:
        if k not in _PRESET_KEYS:
            die(
                f"preset '{name}': unknown key '{k}' (allowed: {' | '.join(_PRESET_KEYS)})"
            )
    _validate_description(name, pdata)
    _apply_selection(args, name, pdata)
    # config flags: preset sets the value unless the CLI already had it.
    for k, choices in _PRESET_KEYS_CHOICES.items():
        if k in pdata:
            if flag_in_argv("--" + _flag(k)):
                continue
            _validate_value(name, k, pdata[k])
            setattr(args, k, pdata[k])
    for k in _PRESET_KEYS_BOOL:
        if k in pdata:
            if flag_in_argv("--" + _flag(k)):
                continue
            _validate_value(name, k, pdata[k])
            setattr(args, k, pdata[k])
    if "cap" in pdata:
        if not flag_in_argv("--cap"):
            _validate_value(name, "cap", pdata["cap"])
            args.cap = pdata["cap"]


def apply_bundle(args, name: str, pdata: dict) -> None:
    """Bundle preset: 'products' = {product: flags}. Selection stays top-level and
    shared by every product; per-product config is applied when each product runs."""
    # Check for conflicting product/products first
    if "product" in pdata:
        die(f"preset '{name}': use either 'product' or 'products', not both")
    for k in pdata:
        if k not in _PRESET_KEYS_BUNDLE:
            die(
                f"preset '{name}': unknown key '{k}' (allowed: {' | '.join(_PRESET_KEYS_BUNDLE)})"
            )
    _validate_description(name, pdata)
    _apply_selection(args, name, pdata)
    products = pdata["products"]
    if not isinstance(products, dict) or not products:
        die(f"preset '{name}': 'products' must be a non-empty object (product -> flags)")
    cleaned = {}
    for prod, cfg in products.items():
        if prod not in PRODUCT_KEYWORDS:
            die(
                f"preset '{name}': 'products' keys must be {' | '.join(PRODUCT_KEYWORDS)} "
                f"(got {prod!r})"
            )
        if not isinstance(cfg, dict):
            die(f"preset '{name}': products.{prod} must be an object of flags (got {type(cfg).__name__})")
        for k in cfg:
            allowed = _PRODUCT_FLAG_KEYS.get(prod, [])
            if k not in allowed:
                die(f"preset '{name}': unknown key '{k}' in products.{prod} (allowed: {' | '.join(allowed)})")
            _validate_value(name, k, cfg[k])
        cleaned[prod] = dict(cfg)
    args.bundle = cleaned


def bundle_child_argv(args, product: str) -> list[str]:
    """argv (positional + flags) for one bundle product, re-exported standalone.

    The child gets the product keyword as its 'profile' and the shared stamp /
    preset provenance appended by the caller, so it runs the exact single-product
    pipeline (own index.md + metadata.json). User-explicit flags (flag_in_argv)
    are forwarded as-is and win over the preset's per-product config; the effective
    selection is materialized from args (CLI override or preset value)."""
    name = args.preset or ""
    argv = [product]
    if args.sessions:
        argv += [f"--sessions={s}" for s in args.sessions]
    elif args.filter is not None:
        argv += ["--filter", args.filter]
    elif args.last is not None:
        argv += [f"--last={args.last}"]
    elif args.since is not None:
        argv += [f"--since={args.since}"]
    for k in _PRESET_KEYS_CHOICES:
        if flag_in_argv("--" + _flag(k)):
            argv.append(f"--{_flag(k)}={getattr(args, k)}")
    for k in _PRESET_KEYS_BOOL:
        if flag_in_argv("--" + _flag(k)):
            argv.append("--" + _flag(k))
    if flag_in_argv("--cap"):
        argv.append(f"--cap={args.cap}")
    if flag_in_argv("--out"):
        argv.append(f"--out={args.out}")
    # Run-level metadata must match across every product in the bundle, just as
    # it does for a single-product export.
    if getattr(args, "source", None):
        argv += ["--source", args.source]
    if getattr(args, "title", None) is not None:
        argv += ["--title", args.title]
    if getattr(args, "notes", None) is not None:
        argv += ["--notes", args.notes]
    if getattr(args, "notes_kind", None):
        argv += ["--notes-kind", args.notes_kind]
    cfg = args.bundle.get(product, {})
    for k, v in cfg.items():
        if flag_in_argv("--" + _flag(k)):
            continue
        if isinstance(v, bool):
            if v:
                argv.append("--" + _flag(k))
        else:
            argv.append(f"--{_flag(k)}={v}")
    if name:
        argv.append(f"--preset-name={name}")
    return argv


def resolve_profile(args, ap) -> None:
    """product keyword / preset name / error. Sets args.profile (+ args.bundle)
    and args.preset. A bundle preset leaves args.profile=None and fills args.bundle."""
    args.preset = None
    args.bundle = None
    profile = args.profile
    # A deprecated spelling of a product keyword still resolves (compactions ->
    # digest) and is NORMALISED here, so everything downstream (preset lookup,
    # rendering, metadata, the plan) only ever sees the real name.
    if profile in PRODUCT_ALIASES:
        profile = PRODUCT_ALIASES[profile]
        args.profile = profile
    if profile in _PRODUCTS:
        return
    presets = load_presets()
    if profile in presets:
        pdata = presets[profile]
        if "products" in pdata:
            apply_bundle(args, profile, pdata)
            args.profile = None
            args.preset = profile
            return
        prod = pdata.get("product")
        if prod in PRODUCT_ALIASES:
            prod = PRODUCT_ALIASES[prod]
        if prod not in PRODUCT_KEYWORDS:
            die(
                f"preset '{profile}': 'product' must be {' | '.join(PRODUCT_KEYWORDS)} "
                f"(got {prod!r})"
            )
        args.profile = prod if prod != "full" else "transcript"
        args.preset = profile
        apply_preset(args, profile, pdata)
        return
    known = " | ".join(_PRODUCTS)
    if presets:
        hint = "presets: " + ", ".join(sorted(presets))
    else:
        hint = f"presets file '{default_presets()}' has no presets"
    ap.error(f"unknown export target '{profile}' — products: {known} · {hint}")
