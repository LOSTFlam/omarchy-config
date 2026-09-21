#!/usr/bin/env python3
"""Copy source and public build artifacts to an existing disposable VM, no install."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import shlex
import subprocess
import tarfile

parser = argparse.ArgumentParser()
parser.add_argument("--work", type=Path, required=True)
parser.add_argument("--pack", type=Path, required=True)
parser.add_argument("--guest", default="/home/tester/outfit-first-run")
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
meta = json.loads((args.work / "bootstrap.json").read_text())
ssh = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
       "-o", f"UserKnownHostsFile={args.work}/known_hosts", "-i", str(args.work / "ssh-key"),
       "-p", str(meta["sshPort"]), f'{meta["username"]}@127.0.0.1']
guard = "import pathlib,subprocess; assert subprocess.check_output(['systemd-detect-virt','--vm']).strip(); p=pathlib.Path(" + repr(args.guest) + "); assert p.parent.is_dir() and not p.exists(); p.mkdir(mode=0o700)"
subprocess.run([*ssh, shlex.join(["python3", "-c", guard])], check=True)
files = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=root).decode().split("\0")
hashes = {}
payload = io.BytesIO()
with tarfile.open(fileobj=payload, mode="w:gz") as archive:
    for name in sorted(set(files)):
        path = root / name
        if not name or not path.is_file() or name.startswith("test-results/"):
            continue
        archive.add(path, arcname="source/" + name)
        hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    for path in [args.pack / "latest.json", *args.pack.glob("search-pack-*.jsonl.gz")]:
        archive.add(path, arcname="pack/" + path.name)
    old = subprocess.check_output(["git", "archive", "6db2b90"], cwd=root)
    with tarfile.open(fileobj=io.BytesIO(old)) as legacy:
        for entry in legacy:
            stream = legacy.extractfile(entry) if entry.isfile() else None
            entry.name = "old/" + entry.name
            archive.addfile(entry, stream)
    raw = json.dumps(hashes, indent=2).encode()
    info = tarfile.TarInfo("source-hashes.json")
    info.size = len(raw)
    archive.addfile(info, io.BytesIO(raw))
subprocess.run([*ssh, shlex.join(["tar", "-xz", "-C", args.guest])], input=payload.getvalue(), check=True)
print(json.dumps({"guest": args.guest, "sourceFiles": len(hashes), "legacyCommit": "6db2b90"}))
