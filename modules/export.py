#!/usr/bin/env python3
# export.py — entry shim. The real implementation lives in the exportlib package
# (modules/exportlib/); this file only forwards to its CLI entry point.
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from exportlib.cli import main

if __name__ == "__main__":
    main()