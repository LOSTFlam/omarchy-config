#!/usr/bin/env python3
"""Native lifecycle gate. Refuses physical hosts and existing fixture installs."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
ID = "org.example.omafit-release-fixture"
def command(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=120).stdout

if (os.environ.get("OUTFIT_TEST_VM") or os.environ.get("OMAFIT_TEST_VM")) != "1" or subprocess.run(
    ["systemd-detect-virt", "--vm"], stdout=subprocess.DEVNULL).returncode:
    raise SystemExit("Run only in the disposable VM, with OUTFIT_TEST_VM=1.")
for tool in ("omarchy", "omarchy-shell", "git"):
    if not shutil.which(tool):
        raise SystemExit(f"Missing prerequisite: {tool}")
def inventory():
    raw = json.loads(command("omarchy", "plugin", "list", "--json"))
    return raw if isinstance(raw, list) else raw.get("plugins", [])

def wait_for_state(present=True, enabled=None):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        try:
            row = next((row for row in inventory() if row.get("id") == ID), None)
            if not present and row is None: return
            if present and row is not None and (enabled is None or row.get("enabled") is enabled): return
        except subprocess.CalledProcessError:
            pass
        time.sleep(0.2)
    raise AssertionError(f"Authoritative fixture state not observed: present={present}, enabled={enabled}")

if any(row.get("id") == ID for row in inventory()):
    raise SystemExit("Fixture already exists; inspect the previous run before retrying.")
if "--lifecycle-only" not in sys.argv:
    print(command(str(ROOT / "tests/run"), "--require-omarchy"))
state = Path(tempfile.mkdtemp(prefix="omafit-vm-"))
source = state / "fixture"
shutil.copytree(ROOT / "tests/vm/fixture-plugin", source)
environment = dict(os.environ, GIT_AUTHOR_NAME="Outfit fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                   GIT_COMMITTER_NAME="Outfit fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid")
def git(*args):
    subprocess.run(["git", "-C", str(source), *args], env=environment, check=True, capture_output=True, timeout=15)

git("init", "-b", "main")
git("add", ".")
git("commit", "-m", "Initial fictional fixture")
installed = False
try:
    command("omarchy", "plugin", "validate", str(source))
    command("omarchy", "plugin", "add", str(source), "--yes")
    installed = True
    wait_for_state()
    command("omarchy", "plugin", "enable", ID, "right")
    wait_for_state(enabled=True)
    command("omarchy", "plugin", "disable", ID)
    wait_for_state(enabled=False)
    command("omarchy", "plugin", "enable", ID, "left")
    wait_for_state(enabled=True)
    manifest = json.loads((source / "manifest.json").read_text())
    manifest["version"] = "0.1.1"
    (source / "manifest.json").write_text(json.dumps(manifest))
    git("add", "manifest.json")
    git("commit", "-m", "Update fictional fixture")
    command("omarchy", "plugin", "update", ID, "--yes")
    target = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "omarchy/plugins" / ID
    assert json.loads((target / "manifest.json").read_text())["version"] == "0.1.1"
    print("Native fixture install/enable/disable/placement/update commands passed.")
finally:
    if installed or any(row.get("id") == ID for row in inventory()):
        command("omarchy", "plugin", "remove", ID, "--yes")
        wait_for_state(present=False)
    print("Retained fixture history and evidence directory:", state)
