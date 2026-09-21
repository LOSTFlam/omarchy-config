#!/usr/bin/env python3
"""Launch a disposable overlay of an existing, installed stable Omarchy VM."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--check", action="store_true")
parser.add_argument("--base", type=Path, help="Existing stable Omarchy qcow2 image (read-only backing file)")
parser.add_argument("--state-dir", type=Path, help="New directory for this disposable run; must not exist")
parser.add_argument("--firmware", type=Path, help="UEFI firmware matching the base image, if needed")
parser.add_argument("--memory", type=int, default=4096)
parser.add_argument("--cpus", type=int, default=2)
parser.add_argument("--ssh-port", type=int, default=22222)
parser.add_argument("--headless", action="store_true", help="Loopback-only VNC on display 77")
parser.add_argument("--daemonize", action="store_true")
parser.add_argument("--identity-dir", type=Path, help="Private connection metadata from this base image's bootstrap")
args = parser.parse_args()
tools = {name: shutil.which(name) for name in ("qemu-system-x86_64", "qemu-img")}
kvm = os.access("/dev/kvm", os.R_OK | os.W_OK)
if args.check:
    print(json.dumps({"tools": tools, "kvmAccessible": kvm, "ready": all(tools.values())}, indent=2))
    raise SystemExit(0 if all(tools.values()) else 2)
if not all(tools.values()):
    parser.error("QEMU tooling is missing; install the platform QEMU package before running this gate.")
if not args.base or not args.base.is_file() or not args.state_dir:
    parser.error("--base and --state-dir are required")
if args.state_dir.exists() or not args.state_dir.parent.is_dir():
    parser.error("The state directory must be new and its parent must exist")
if not 1024 <= args.memory <= 32768 or not 1 <= args.cpus <= 16 or not 1024 <= args.ssh_port <= 65535:
    parser.error("Invalid resource/port limits")
if args.firmware and not args.firmware.is_file():
    parser.error("Firmware does not exist")
root = Path(__file__).resolve().parents[2]
if args.state_dir.resolve().is_relative_to(root):
    parser.error("Keep VM runtime state outside the plugin checkout, for example under ~/.local/state/omafit-release-vm")
if "," in str(root):
    parser.error("QEMU shared-folder syntax does not support a comma in this checkout path")
args.state_dir.mkdir(mode=0o700)
if args.identity_dir:
    for name in ("bootstrap.json", "ssh-key", "ssh-key.pub", "guest-password", "known_hosts"):
        source = args.identity_dir / name
        if source.is_file(): shutil.copy2(source, args.state_dir / name)
    metadata = json.loads((args.state_dir / "bootstrap.json").read_text())
    metadata["sshPort"] = args.ssh_port
    (args.state_dir / "bootstrap.json").write_text(json.dumps(metadata))
overlay = args.state_dir.resolve() / "omarchy-test.qcow2"
subprocess.run([tools["qemu-img"], "create", "-f", "qcow2", "-F", "qcow2", "-b",
                str(args.base.resolve()), str(overlay)], check=True)
command = [tools["qemu-system-x86_64"], "-name", "Outfit release test", "-m", str(args.memory),
           "-smp", str(args.cpus), "-accel", "kvm" if kvm else "tcg", "-drive",
           f"file={overlay},format=qcow2,if=virtio", "-device", "virtio-vga", "-netdev",
           f"user,id=net0,hostfwd=tcp:127.0.0.1:{args.ssh_port}-:22", "-device", "virtio-net-pci,netdev=net0",
           "-virtfs", f"local,path={root},mount_tag=omafit,security_model=none,readonly=on"]
if args.firmware:
    command += ["-bios", str(args.firmware.resolve())]
command += ["-qmp", f"unix:{overlay.parent}/qmp.sock,server=on,wait=off", "-pidfile", str(overlay.parent / "qemu.pid")]
if args.headless: command += ["-display", "vnc=127.0.0.1:77"]
if args.daemonize: command += ["-daemonize"]
print("Guest checkout share: omafit (read-only). Run tests/vm/guest_check.py in the guest.")
print("Overlay retained for inspection:", overlay)
raise SystemExit(subprocess.call(command))
