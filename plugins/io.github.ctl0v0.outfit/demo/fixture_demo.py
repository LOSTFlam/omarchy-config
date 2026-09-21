#!/usr/bin/env python3
"""Render deterministic Outfit recommendations from a fictional fixture."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("outfit", ROOT / "scripts" / "outfit.py")
assert SPEC is not None and SPEC.loader is not None
OUTFIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OUTFIT)


def main() -> int:
    fixture_path = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "demo" / "fixtures" / "example.json"
    fixture = json.loads(fixture_path.read_text())
    items, generated_at = OUTFIT.normalize_catalog(fixture["catalog"])
    rows = OUTFIT.ranked_rows(items, fixture["profile"], set(), "", "")
    setup = OUTFIT.setup_catalog(items, fixture["profile"], set())
    print(f"Fixture: {fixture['fixture']}")
    print(f"Catalog: {len(items)} fictional plugins generated {generated_at}")
    for index, row in enumerate(rows, 1):
        print(f"{index}. {row['name']} [{row['score']}] - {row['reason']}")
    print("Quick Scan:")
    labels = {group["id"]: group["label"] for group in setup["groups"]}
    for row in setup["rows"]:
        print(
            f"- {labels[row['setupGroup']]}: {row['name']} "
            f"[recommended {row['recommendationScore']}, {row['stars'] or 0} stars]"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
