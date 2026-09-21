#!/usr/bin/env python3
"""Stage an uncommitted host candidate and its exact Git base in new VM paths."""
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
parser.add_argument("--source", type=Path, required=True)
parser.add_argument("--candidate", default="/home/tester/omarchy-upstream-continuity")
parser.add_argument("--baseline", default="/home/tester/omarchy-upstream-baseline")
parser.add_argument("--candidate-only", action="store_true")
parser.add_argument("--expect-shell-sha256", help="Require the handoff's exact shell source before staging")
args = parser.parse_args()
base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=args.source, text=True).strip()
if base != "d174d4aa279ea7393d4fad4a80fed147866106b9":
    raise SystemExit("Unexpected upstream base; inspect before staging")
if args.expect_shell_sha256 and hashlib.sha256((args.source / "shell/shell.qml").read_bytes()).hexdigest() != args.expect_shell_sha256:
    raise SystemExit("Candidate does not match the handoff shell hash")
meta = json.loads((args.work / "bootstrap.json").read_text())
ssh = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
       "-o", f"UserKnownHostsFile={args.work}/known_hosts", "-i", str(args.work / "ssh-key"),
       "-p", str(meta["sshPort"]), f'{meta["username"]}@127.0.0.1']
for guest in ([args.candidate] if args.candidate_only else [args.candidate, args.baseline]):
    guard = "import pathlib,subprocess; assert subprocess.check_output(['systemd-detect-virt','--vm']).strip(); p=pathlib.Path(" + repr(guest) + "); assert p.parent==pathlib.Path('/home/tester') and p.parent.is_dir() and not p.exists(); p.mkdir(mode=0o700)"
    subprocess.run([*ssh, shlex.join(["python3", "-c", guard])], check=True)
files = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=args.source).decode().split("\0")
hashes = {}
payload = io.BytesIO()
with tarfile.open(fileobj=payload, mode="w:gz") as archive:
    for name in sorted(set(files)):
        path = args.source / name
        if not name or not path.is_file():
            continue
        archive.add(path, arcname=name, recursive=False)
        hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    raw = json.dumps({"base": base, "files": hashes}, indent=2).encode()
    info = tarfile.TarInfo("vm-source-hashes.json")
    info.size = len(raw)
    archive.addfile(info, io.BytesIO(raw))
subprocess.run([*ssh, shlex.join(["tar", "-xz", "-C", args.candidate])], input=payload.getvalue(), check=True)
if not args.candidate_only:
    archive = subprocess.check_output(["git", "archive", "--format=tar.gz", base], cwd=args.source)
    subprocess.run([*ssh, shlex.join(["tar", "-xz", "-C", args.baseline])], input=archive, check=True)
print(json.dumps({"base": base, "candidate": args.candidate, "baseline": None if args.candidate_only else args.baseline,
                  "candidateFiles": len(hashes), "candidateArchiveBytes": len(payload.getvalue())}))
