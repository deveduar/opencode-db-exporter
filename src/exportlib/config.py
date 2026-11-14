# Default paths resolved from the environment (OCED_*) before falling back.
# Mirror of the bash defaults in src/common.sh, including the PORTABLE
# fallback: when this checkout ships its own config (and no user config exists
# under ~/.config/opencode-db), the repo files and data dirs are the defaults.
# An installed prefix ships no repo config at all, so it never triggers the
# portable branch.
import os
import subprocess
import sys
from pathlib import Path

_MODULES = Path(__file__).resolve().parent  # .../src/exportlib
_REPO_ROOT = _MODULES.parent.parent  # .../src/exportlib -> checkout or install root


class DatabasePathError(RuntimeError):
    pass


def _config_dir() -> Path:
    if sys.platform == "win32":
        return Path(os.environ.get("APPDATA") or Path.home() / "AppData" / "Roaming") / "opencode-db"
    return Path.home() / ".config" / "opencode-db"


def _data_dir() -> Path:
    if sys.platform == "win32":
        return Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local") / "opencode-db-exporter"
    return Path.home() / ".local" / "share" / "opencode-db-exporter"


def _config_default(name: str) -> str:
    """The per-user config wins; the repo-shipped file is the fallback."""
    home = _config_dir() / name
    if home.exists():
        return str(home)
    repo = _REPO_ROOT / name
    if repo.exists():
        return str(repo)
    return str(home)


def _portable() -> bool:
    """Direct Python runs from a checkout default output into that checkout."""
    return (_REPO_ROOT / "opencode-db.conf").exists()


def _windows_db_from_opencode() -> str:
    # OpenCode's documented path command accounts for its channel and overrides.
    # The command is constant; shell=True is needed for npm's .cmd shim on Windows.
    try:
        result = subprocess.run(
            "opencode debug paths db",
            shell=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise DatabasePathError(
            "Could not resolve OpenCode's database path; install the OpenCode CLI "
            "or set OPENCODE_DB."
        ) from exc
    path = result.stdout.strip()
    if result.returncode != 0 or not path:
        detail = result.stderr.strip()
        suffix = f" ({detail})" if detail else ""
        raise DatabasePathError(
            f"'opencode debug paths db' did not return a database path{suffix}; "
            "set OPENCODE_DB to the database file."
        )
    return path


def default_db_with_origin() -> tuple[str, str]:
    """The database path plus WHERE it came from.

    `origin` is stable and machine-readable: `environment` (OPENCODE_DB),
    `opencode-cli` (native Windows discovery) or `default` (the known XDG path).
    """
    override = os.environ.get("OPENCODE_DB")
    if override:
        return override, "environment"
    if sys.platform == "win32":
        return _windows_db_from_opencode(), "opencode-cli"
    return str(Path.home() / ".local" / "share" / "opencode" / "opencode.db"), "default"


def default_db() -> str:
    return default_db_with_origin()[0]


def readonly_db_uri(path: str | Path) -> str:
    """Build a percent-encoded SQLite URI that works with native Windows paths."""
    return f"{Path(path).expanduser().resolve().as_uri()}?mode=ro"


def default_out() -> str:
    if os.environ.get("OCED_OUT"):
        return os.environ.get("OCED_OUT") or ""
    if _portable():
        return str(_REPO_ROOT / "exports")
    return str(_data_dir() / "exports")


def default_bkp_dir() -> str:
    if os.environ.get("OCED_BACKUP_DIR"):
        return os.environ.get("OCED_BACKUP_DIR") or ""
    if _portable():
        return str(_REPO_ROOT / "backups")
    return str(_data_dir() / "backups")


def default_presets() -> str:
    # An EMPTY value counts as unset (the menu shim exports "" when the env var
    # is absent; Path("") would resolve to the current directory).
    return os.environ.get("OCED_PRESETS") or _config_default("presets.json")