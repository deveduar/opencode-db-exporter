# Default paths resolved from the environment (OCED_*) before falling back.
# Mirror of the bash defaults in src/common.sh, including the PORTABLE
# fallback: when this checkout ships its own config (and no user config exists
# under ~/.config/opencode-db), the repo files and data dirs are the defaults.
# An installed prefix ships no repo config at all, so it never triggers the
# portable branch.
import os
from pathlib import Path

_MODULES = Path(__file__).resolve().parent  # .../src/exportlib
_REPO_ROOT = _MODULES.parent  # .../src -> the checkout root


def _config_default(name: str) -> str:
    """~/.config/opencode-db/<name> wins; the repo-shipped file is the fallback."""
    home = Path.home() / ".config" / "opencode-db" / name
    if home.exists():
        return str(home)
    repo = _REPO_ROOT / name
    if repo.exists():
        return str(repo)
    return str(home)


def _portable() -> bool:
    """True when the bash `OCED_PORTABLE` branch would be active: the repo ships a
    real conf and no user conf exists (the user config wins when both exist)."""
    home_conf = Path.home() / ".config" / "opencode-db" / "opencode-db.conf"
    return not home_conf.exists() and (_REPO_ROOT / "opencode-db.conf").exists()


def default_db() -> str:
    return os.environ.get("OPENCODE_DB", str(Path.home() / ".local/share/opencode/opencode.db"))


def default_out() -> str:
    if os.environ.get("OCED_OUT"):
        return os.environ.get("OCED_OUT") or ""
    if _portable():
        return str(_REPO_ROOT / "exports")
    return str(Path.home() / ".local/share/opencode-db-exporter/exports")


def default_bkp_dir() -> str:
    if os.environ.get("OCED_BACKUP_DIR"):
        return os.environ.get("OCED_BACKUP_DIR") or ""
    if _portable():
        return str(_REPO_ROOT / "backups")
    return str(Path.home() / ".local/share/opencode-db-exporter/backups")


def default_presets() -> str:
    # An EMPTY value counts as unset (the menu shim exports "" when the env var
    # is absent; Path("") would resolve to the current directory).
    return os.environ.get("OCED_PRESETS") or _config_default("presets.json")