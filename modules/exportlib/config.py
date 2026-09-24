# Default paths resolved from the environment (OCED_*) before falling back.
import os
from pathlib import Path


def default_db() -> str:
    return os.environ.get("OPENCODE_DB", str(Path.home() / ".local/share/opencode/opencode.db"))


def default_out() -> str:
    return os.environ.get("OCED_OUT", str(Path.home() / ".local/share/opencode-db-exporter/exports"))


def default_bkp_dir() -> str:
    return os.environ.get("OCED_BACKUP_DIR", str(Path.home() / ".local/share/opencode-db-exporter/backups"))


def default_presets() -> str:
    return os.environ.get("OCED_PRESETS", str(Path.home() / ".config/opencode-db/presets.json"))