"""shrinklib — python source of truth for the shrink presets (SSoT).

Mirrors exportlib for the shrink side: the flag registry, the OCED_SHRINK_PRESETS
contract, preset validation and the plan/bake CLI bridge that menu.sh and
shrink.sh consume. The build engine (SQL/VACUUM/swap) stays in src/shrink.sh.
"""
TOOL_VERSION = "1.2.0"