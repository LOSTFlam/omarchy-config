#!/usr/bin/env python3
"""Compile repository Python sources in memory without triggering plugin reloads."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
for directory in ("scripts", "demo", "tests", "tests/vm", "tests/fixtures"):
    for source in sorted((root / directory).glob("*.py")):
        compile(source.read_text(encoding="utf-8"), str(source), "exec")
print("Python syntax checks passed without writing bytecode.")
