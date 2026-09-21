#!/usr/bin/env python3
"""Verify README-only search against a generated VM fixture, never a user cache."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--root", type=Path, required=True)
parser.add_argument("--scenario", default="omarchy-cold")
args = parser.parse_args()
root = args.root.resolve()
fixture = (root / args.scenario).resolve()
if (os.environ.get("OUTFIT_TEST_VM") != "1" or Path.home() != Path("/home/tester")
        or subprocess.run(["systemd-detect-virt", "--vm"], stdout=subprocess.DEVNULL).returncode
        or fixture.parent != root or not (fixture / "transport.jsonl").is_file()
        or not (root / "source-hashes.json").is_file()):
    raise SystemExit("Previously generated disposable VM fixture only")
spec = importlib.util.spec_from_file_location("outfit", root / "source/scripts/outfit.py")
backend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backend)

def blocked(*args, **kwargs):
    raise RuntimeError("This search evidence check must not access the network")

backend.fetch_bytes = blocked
socket.create_connection = blocked
cache = backend.Store(fixture / "cache" / backend.APP_ID)
preferences = backend.Store(fixture / "config" / backend.APP_ID)
original = backend.load_preferences
try:
    request = {"action": "quick-setup", "generation": 1, "setupQuery": "oauth",
               "setupSort": "relevance", "setupPageSize": 48, "localOnly": True}
    full = backend.run(request, cache, preferences_store=preferences)["setup"]
    backend.load_preferences = lambda store: {**original(store), "readmeEnrichment": False}
    metadata = backend.run(request, cache, preferences_store=preferences)["setup"]
    evidence = {"query": "oauth", "withDocumentation": full["total"], "metadataOnly": metadata["total"],
                "documentEvidence": [{"id": row["id"], "reason": row["searchReason"],
                                      "snippetPresent": bool(row.get("searchSnippet"))}
                                     for row in full["rows"] if "README" in row.get("searchReason", "")]}
    evidence["passed"] = bool(evidence["documentEvidence"]) and full["total"] > metadata["total"]
    path = root / "evidence" / (args.scenario + "-search-supplement.json")
    path.write_text(json.dumps(evidence, indent=2))
    print(json.dumps(evidence, indent=2))
    raise SystemExit(0 if evidence["passed"] else 1)
finally:
    cache.close()
    preferences.close()
