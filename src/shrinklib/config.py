# Default paths resolved from the environment (OCED_*) before falling back.
# Mirror subset of exportlib/config.py: only the shrink-presets path lives here.
# Same portable fallback: a repo-shipped shrink-presets.json is the default when
# no user config exists under ~/.config/opencode-db.
import os
from pathlib import Path

_MODULES = Path(__file__).resolve().parent  # .../src/shrinklib
_REPO_ROOT = _MODULES.parent  # .../src -> the checkout root


def default_shrink_presets() -> str:
    # An EMPTY value counts as unset (the menu shim exports "" when the env var
    # is absent; Path("") would resolve to the current directory).
    env = os.environ.get("OCED_SHRINK_PRESETS")
    if env:
        return env
    home = Path.home() / ".config" / "opencode-db" / "shrink-presets.json"
    if home.exists():
        return str(home)
    repo = _REPO_ROOT / "shrink-presets.json"
    if repo.exists():
        return str(repo)
    return str(home)