#!/usr/bin/env python3
"""Python-only entry point for exporting OpenCode sessions."""

import sys
from pathlib import Path

SRC = Path(__file__).resolve().parent / "src"
sys.path.insert(0, str(SRC))

from exportlib.cli import main


if __name__ == "__main__":
    main()
