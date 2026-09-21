#!/usr/bin/env python3
"""Exercise the real Apps launcher in the disposable guest desktop session."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
ROOT = Path(__file__).resolve().parents[2]
ID = "io.github.ctl0v0.outfit"
if (os.environ.get("OUTFIT_TEST_VM") or os.environ.get("OMAFIT_TEST_VM")) != "1" or subprocess.run(
        ["systemd-detect-virt", "--vm"], stdout=subprocess.DEVNULL).returncode:
    raise SystemExit("Only run this check in the disposable VM.")
if args.output.exists() or not args.output.parent.is_dir():
    raise SystemExit("--output must be a new image in an existing directory")

def run(*command):
    return subprocess.check_output(command, text=True, timeout=20).strip()

run("python3", "-I", "-B", str(ROOT / "scripts/launcher.py"))
try:
    run("omarchy-shell", "shell", "hide", ID)
    run("omarchy", "menu", "summon", "apps")
    time.sleep(0.5)
    run("wtype", "Outfit")
    time.sleep(0.5)
    run("grim", str(args.output))
    run("wtype", "-k", "Return")
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        state = json.loads(run("omarchy-shell", ID, "status"))
        if state.get("opened"):
            break
        time.sleep(0.1)
    else:
        raise RuntimeError("Apps selection did not open Outfit")
    print("Apps search and keyboard launch passed; icon screenshot:", args.output)
finally:
    run("omarchy", "menu", "close")
    run("omarchy-shell", "shell", "hide", ID)
    run("python3", "-I", "-B", str(ROOT / "scripts/launcher.py"), "--remove")
