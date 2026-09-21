#!/usr/bin/env python3
"""Measure real native plugin lifecycle without restarting or rearranging the shell."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--expect-continuity", action="store_true")
args = parser.parse_args()
if (os.environ.get("OUTFIT_TEST_VM") or os.environ.get("OMAFIT_TEST_VM")) != "1" or subprocess.run(
        ["systemd-detect-virt", "--vm"], stdout=subprocess.DEVNULL).returncode:
    raise SystemExit("Disposable VM only")
if args.output.exists() or not args.output.parent.is_dir():
    raise SystemExit("Choose a new output in an existing directory")
ROOT = Path(__file__).resolve().parents[2]
ID = "org.example.omafit-release-fixture"
def run(*command):
    return subprocess.check_output(command, text=True, timeout=120).strip()
def inventory():
    return json.loads(run("omarchy", "plugin", "list", "--json"))
if any(p["id"] == ID for p in inventory()):
    raise SystemExit("Fixture already installed; inspect previous run")

state = Path(tempfile.mkdtemp(prefix="omafit-continuity-"))
source = state / "fixture"
shutil.copytree(ROOT / "tests/vm/fixture-plugin", source)
env = dict(os.environ, GIT_AUTHOR_NAME="Outfit fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
           GIT_COMMITTER_NAME="Outfit fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid")
for command in (["init", "-b", "main"], ["add", "."], ["commit", "-m", "Fictional lifecycle fixture"]):
    subprocess.run(["git", "-C", str(source), *command], env=env, check=True, capture_output=True)
run("omarchy-shell", "shell", "summon", "io.github.ctl0v0.outfit", "{}")
time.sleep(2)
samples = []
phase = "baseline"
stop = threading.Event()
def sample():
    while not stop.is_set():
        try:
            clients = json.loads(run("hyprctl", "clients", "-j"))
            layers = json.loads(run("hyprctl", "layers", "-j"))
            backgrounds = [layer["address"] for monitor in layers.values()
                           for level, rows in monitor.get("levels", {}).items() for layer in rows
                           if "background" in str(layer.get("namespace", "")).lower()]
            app = [w for w in clients if w.get("title") == "Outfit - Plugin Manager"]
            samples.append({"time":time.monotonic(), "phase":phase, "backgrounds":backgrounds,
                            "windows":[w["address"] for w in app], "pids":[w["pid"] for w in app]})
        except (ValueError, subprocess.SubprocessError):
            samples.append({"time":time.monotonic(), "phase":phase, "probeError":True})
        stop.wait(0.04)
thread = threading.Thread(target=sample, daemon=True)
thread.start()
try:
    time.sleep(1)
    for label, command in [
        ("install-disabled", ["add", str(source), "--yes"]),
        ("enable", ["enable", ID, "right"]),
        ("remove-enabled", ["remove", ID, "--yes"]),
        ("reinstall-disabled", ["add", str(source), "--yes"]),
        ("remove-disabled", ["remove", ID, "--yes"]),
    ]:
        phase = label
        run("omarchy", "plugin", *command)
        time.sleep(2)
        # Reopen only between phases if the host destroyed the app, so every
        # phase starts with a visible sentinel; never during the measurement.
        phase = "between-operations"
        run("omarchy-shell", "shell", "summon", "io.github.ctl0v0.outfit", "{}")
        time.sleep(1)
finally:
    stop.set()
    thread.join(timeout=5)
    if any(p["id"] == ID for p in inventory()):
        run("omarchy", "plugin", "remove", ID, "--yes")
    args.output.write_text(json.dumps(samples, indent=2))
baseline = next((s for s in samples if s.get("windows") and s.get("backgrounds")), None)
if not baseline:
    raise SystemExit("No visible app/background baseline; inspect evidence")
changed = [s for s in samples if s.get("phase") not in {"baseline", "between-operations"}
           and (s.get("windows") != baseline["windows"] or s.get("backgrounds") != baseline["backgrounds"])]
print(json.dumps({"samples":len(samples), "discontinuousSamples":len(changed), "evidence":str(args.output)}))
if args.expect_continuity and changed:
    raise SystemExit("Unrelated app/background surfaces were replaced or lost")
