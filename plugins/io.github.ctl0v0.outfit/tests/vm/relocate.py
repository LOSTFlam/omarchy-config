#!/usr/bin/env python3
"""Move stopped, owned VM artifacts out of a checkout and rebind COW paths."""
import argparse
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, required=True)
parser.add_argument("--destination", type=Path, required=True)
args = parser.parse_args()
source = args.source.resolve()
destination = args.destination.absolute()
if not source.is_dir() or destination.exists() or not destination.parent.is_dir():
    parser.error("Source must exist; destination must be new with an existing parent")
if source.stat().st_uid != os.getuid() or destination.parent.stat().st_uid != os.getuid():
    parser.error("VM state and destination parent must belong to the current user")
if source.stat().st_dev != destination.parent.stat().st_dev:
    parser.error("Use the same filesystem for an atomic move")
for pidfile in source.glob("**/qemu.pid"):
    pid = int(pidfile.read_text().strip())
    if Path(f"/proc/{pid}").exists():
        parser.error("Stop the VM before moving its disk chain")
chains = []
for image in source.glob("**/*.qcow2"):
    if image.is_symlink(): parser.error("Refusing an ambiguous symlinked VM disk")
    info = json.loads(subprocess.check_output(["qemu-img", "info", "--output=json", str(image)]))
    backing = info.get("full-backing-filename")
    if backing:
        path = Path(backing).resolve()
        if not path.is_relative_to(source): parser.error("Backing image is outside this VM state tree")
        chains.append((image.relative_to(source), path.relative_to(source)))
os.rename(source, destination)
os.chmod(destination, 0o700)
try:
    for image, backing in chains:
        subprocess.run(["qemu-img", "rebase", "-u", "-f", "qcow2", "-F", "qcow2",
                        "-b", str(destination / backing), str(destination / image)], check=True)
    for metadata in destination.glob("**/bootstrap.json"):
        value = json.loads(metadata.read_text())
        iso = Path(value.get("iso", ""))
        if iso.is_absolute() and iso.is_relative_to(source):
            value["iso"] = str(destination / iso.relative_to(source))
            metadata.write_text(json.dumps(value, indent=2))
except Exception:
    print("VM data is preserved at", destination, "but backing-path repair needs attention.")
    raise
print("Moved VM artifacts to", destination)
print("Rebound", len(chains), "copy-on-write backing paths. No disks or credentials were deleted.")
