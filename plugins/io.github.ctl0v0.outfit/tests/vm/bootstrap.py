#!/usr/bin/env python3
"""Install an official checksum-verified Omarchy ISO into a NEW disposable disk.

Uses the documented cidata unattended interface. No host block device is exposed.
Credentials are generated for the fictional guest and retained only in its 0700
working directory. This is a test-image builder, not a host installer.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("--iso", type=Path, required=True)
parser.add_argument("--sha256", required=True)
parser.add_argument("--work", type=Path, required=True, help="New private VM state directory")
parser.add_argument("--ssh-port", type=int, default=22222)
parser.add_argument("--vnc-display", type=int, default=77)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
if args.work.resolve().is_relative_to(root):
    parser.error("Keep VM runtime state outside the plugin checkout, for example under ~/.local/state/omafit-release-vm")
for name in ("qemu-system-x86_64", "qemu-img", "xorriso", "openssl", "ssh-keygen"):
    if not shutil.which(name): parser.error("Missing tool: " + name)
if not args.iso.is_file() or args.work.exists() or not args.work.parent.is_dir():
    parser.error("ISO must exist; --work must be new with an existing parent")
if not 1024 <= args.ssh_port <= 65535 or not 1 <= args.vnc_display <= 99:
    parser.error("Invalid loopback forwarding ports")
for port in (args.ssh_port, 5900 + args.vnc_display):
    with socket.socket() as check:
        check.bind(("127.0.0.1", port))
with args.iso.open("rb") as source:
    actual = hashlib.file_digest(source, "sha256").hexdigest()
if actual != args.sha256.lower(): parser.error("ISO checksum mismatch")
firmware = Path("/usr/share/edk2/x64/OVMF.4m.fd")
if not firmware.is_file(): parser.error("Install edk2-ovmf firmware")
os.umask(0o077)
args.work.mkdir(mode=0o700)
work = args.work.resolve()
seed = work / "cidata"
seed.mkdir()
password = secrets.token_urlsafe(24)
hashed = subprocess.check_output(["openssl", "passwd", "-6", "-stdin"], input=password.encode()).decode().strip()
(work / "guest-password").write_text(password)
subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "omafit-disposable-fixture",
                "-f", str(work / "ssh-key")], check=True)
shutil.copyfile(work / "ssh-key.pub", seed / "authorized_keys")
gib, mib = 1024 ** 3, 1024 ** 2
disk_size = 64 * gib
def size(value): return {"sector_size": {"unit":"B", "value":512}, "unit":"B", "value":value}
def partition(fs, start, length, mountpoint, flags, subvolumes):
    return {"btrfs": subvolumes, "dev_path": None, "flags": flags, "fs_type": fs,
            "mount_options": ["compress=zstd"] if fs == "btrfs" else [], "mountpoint":mountpoint,
            "obj_id":str(uuid.uuid4()), "size":size(length), "start":size(start), "status":"create", "type":"primary"}
configuration = {
    "app_config":None, "archinstall-language":"English", "auth_config":{},
    "audio_config":{"audio":"pipewire"},
    "bootloader_config":{"bootloader":"Limine", "uki":False, "removable":False},
    "custom_commands":[],
    "omarchy_install":{"mode":"full_disk", "target_mount":"/mnt", "defer_provisioning":False,
        "boot":{"esp_mount":"/boot", "esp_path":"/EFI/limine", "efi_binary":"limine_x64.efi", "enable_fallback":True},
        "storage":{"kernel":"linux-omarchy"}},
    "disk_config":{"config_type":"default_layout", "device_modifications":[{"device":"/dev/vda", "wipe":True,
        "partitions":[partition("fat32", mib, 2*gib, "/boot", ["boot","esp"], []),
                      partition("btrfs", 2*gib+mib, disk_size-2*gib-2*mib, None, [],
                         [{"mountpoint":path,"name":name} for path,name in
                          (("/","@"),("/home","@home"),("/var/log","@log"),("/var/cache/pacman/pkg","@pkg"))])]}]},
    "hostname":"omafit-test", "kernels":["linux-omarchy"], "network_config":{"type":"iso"},
    "ntp":True, "parallel_downloads":8, "script":None, "services":[], "swap":True, "timezone":"UTC",
    "locale_config":{"kb_layout":"us", "sys_enc":"UTF-8", "sys_lang":"en_US.UTF-8"},
    "mirror_config":{"custom_repositories":[], "custom_servers":[{"url":"https://mirror.omarchy.org/$repo/os/$arch"}],
                     "mirror_regions":{},"optional_repositories":[]},
    "packages":["base-devel","git","omarchy-keyring","omarchy-settings","omarchy"],
    "profile_config":{"gfx_driver":None,"greeter":None,"profile":{}}, "version":"3.0.9"
}
(seed / "user_configuration.json").write_text(json.dumps(configuration))
(seed / "user_credentials.json").write_text(json.dumps({"root_enc_password":hashed,
    "users":[{"enc_password":hashed,"groups":[],"sudo":True,"username":"tester"}]}))
(seed / "user_full_name.txt").write_text("Outfit Test User\n")
(seed / "user_email_address.txt").write_text("fixture@example.invalid\n")
(seed / "user_encrypt_installation.txt").write_text("false\n")
subprocess.run(["xorriso","-as","mkisofs","-quiet","-output",str(work / "cidata.iso"),
                "-volid","cidata","-joliet","-rock",str(seed)], check=True)
subprocess.run(["qemu-img","create","-f","qcow2",str(work / "base.qcow2"),"64G"],check=True)
command = ["qemu-system-x86_64", "-name","Outfit stable release test", "-machine","q35", "-accel","kvm", "-cpu","host",
    "-m","6144","-smp","4", "-bios",str(firmware),
    "-drive",f"file={work}/base.qcow2,if=virtio,format=qcow2",
    "-drive",f"file={args.iso.resolve()},media=cdrom,readonly=on",
    "-drive",f"file={work}/cidata.iso,media=cdrom,readonly=on", "-boot","order=cd",
    "-netdev",f"user,id=net0,hostfwd=tcp:127.0.0.1:{args.ssh_port}-:22", "-device","virtio-net-pci,netdev=net0",
    "-device","virtio-vga,xres=1600,yres=900", "-display",f"vnc=127.0.0.1:{args.vnc_display}",
    "-qmp",f"unix:{work}/qmp.sock,server=on,wait=off", "-serial",f"file:{work}/serial.log",
    "-pidfile",str(work / "qemu.pid"), "-daemonize"]
subprocess.run(command, check=True)
(work / "bootstrap.json").write_text(json.dumps({"iso":str(args.iso.resolve()), "sha256":actual,
    "sshPort":args.ssh_port, "vncDisplay":args.vnc_display, "username":"tester"}, indent=2))
print("Checksum verified. Disposable installer VM started:", work)
print("SSH after installation: tester@127.0.0.1, port", args.ssh_port, "key", work / "ssh-key")
print("QMP:", work / "qmp.sock", "— stop this VM before using base.qcow2 as a backing image.")
