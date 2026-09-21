#!/usr/bin/env python3
"""Run a fixed argv in the disposable guest without exposing its password."""
import argparse
import json
from pathlib import Path
import shlex
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--work", required=True, type=Path)
parser.add_argument("--sudo", action="store_true")
parser.add_argument("command", nargs=argparse.REMAINDER)
args = parser.parse_args()
work = args.work.resolve()
meta = json.loads((work / "bootstrap.json").read_text())
if not args.command:
    parser.error("A guest command is required")
command = args.command[1:] if args.command[0] == "--" else args.command
command = ["env", "OMARCHY_PATH=/usr/share/omarchy", *command]
payload = None
if args.sudo:
    payload = (work / "guest-password").read_bytes() + b"\n"
    command = ["sudo", "-S", "-p", "", "--", *command]
ssh = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
       "-o", f"UserKnownHostsFile={work}/known_hosts", "-o", "ConnectTimeout=5",
       "-i", str(work / "ssh-key"), "-p", str(meta["sshPort"]),
       f'{meta["username"]}@127.0.0.1', shlex.join(command)]
raise SystemExit(subprocess.run(ssh, input=payload, timeout=600).returncode)
