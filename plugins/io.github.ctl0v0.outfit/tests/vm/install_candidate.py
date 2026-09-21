#!/usr/bin/env python3
"""Install/update an isolated candidate copy; never commits the working checkout."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--update", action="store_true")
args = parser.parse_args()
ROOT = Path(__file__).resolve().parents[2]
ID = "io.github.ctl0v0.outfit"
if (os.environ.get("OUTFIT_TEST_VM") or os.environ.get("OMAFIT_TEST_VM")) != "1" or subprocess.run(
        ["systemd-detect-virt", "--vm"], stdout=subprocess.DEVNULL).returncode:
    raise SystemExit("This candidate installer runs only in the disposable VM.")
target = Path.home() / ".config/omarchy/plugins" / ID
env = dict(os.environ, GIT_AUTHOR_NAME="Outfit test candidate", GIT_AUTHOR_EMAIL="fixture@example.invalid",
           GIT_COMMITTER_NAME="Outfit test candidate", GIT_COMMITTER_EMAIL="fixture@example.invalid")
def git(path, *command):
    return subprocess.check_output(["git", "-C", str(path), *command], env=env, text=True).strip()
if args.update:
    source = Path(git(target, "remote", "get-url", "origin"))
    if not source.name.startswith("omafit-candidate-") or source.parent != Path(tempfile.gettempdir()) \
            or not (target / ".vm-candidate").is_file():
        raise SystemExit("Existing origin is not an isolated VM candidate; refusing to change it.")
    if not source.exists() and not source.is_symlink():
        # /tmp can be cleared on VM reboot. Reconstruct only this harness's
        # origin from its installed Git clone, preserving fast-forward history.
        subprocess.run(["git", "clone", "--", str(target), str(source)], check=True, env=env)
    if source.is_symlink() or source.stat().st_uid != os.getuid() or not (source / ".vm-candidate").is_file():
        raise SystemExit("Existing origin is not an isolated VM candidate; refusing to change it.")
else:
    if target.exists() or target.is_symlink():
        raise SystemExit("Outfit already exists; use --update only for this harness's isolated candidate.")
    source = Path(tempfile.mkdtemp(prefix="omafit-candidate-"))
shutil.copytree(ROOT, source, dirs_exist_ok=True,
               ignore=shutil.ignore_patterns(".git", "test-results", "__pycache__", "*.pyc", ".omarchy-workbench.json"))
(source / ".vm-candidate").write_text("Fictional VM candidate history; not the publication repository.\n")
if not args.update: git(source, "init", "-b", "main")
git(source, "add", ".")
if git(source, "status", "--porcelain"):
    git(source, "commit", "-m", "Snapshot candidate for disposable VM validation")
command = ["omarchy", "plugin", "update", ID, "--yes"] if args.update else [
    "omarchy", "plugin", "add", str(source), "--enable", "--yes"]
subprocess.run(command, check=True, timeout=120)
print("Isolated candidate installed:", git(target, "rev-parse", "HEAD"))
