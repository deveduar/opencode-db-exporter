# Default paths resolved from the environment (OCED_*) before falling back.
# Mirror subset of exportlib/config.py: only the shrink-presets path lives here.
import os
from pathlib import Path


def default_shrink_presets() -> str:
    # An EMPTY value counts as unset (the menu shim exports "" when the env var
    # is absent; Path("") would resolve to the current directory).
    return os.environ.get("OCED_SHRINK_PRESETS") or str(
        Path.home() / ".config/opencode-db/shrink-presets.json"
    )