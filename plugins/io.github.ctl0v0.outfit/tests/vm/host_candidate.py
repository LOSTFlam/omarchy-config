#!/usr/bin/env python3
"""Configure the dev-link contract for the fixed disposable-VM host checkout."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

if (os.environ.get("OUTFIT_TEST_VM") or os.environ.get("OMAFIT_TEST_VM")) != "1" or os.getuid() != 0 or subprocess.run(
        ["systemd-detect-virt", "--vm"], stdout=subprocess.DEVNULL).returncode:
    raise SystemExit("Run as root only inside the disposable VM")
target = Path("/home/tester/omarchy-host")
if not all((target / part).is_dir() for part in ("bin", "default", "shell")):
    raise SystemExit("Fixed VM host checkout is incomplete")
if "pluginLifecycle" not in (target / "shell/shell.qml").read_text():
    raise SystemExit("The checkout does not contain the candidate lifecycle API")
backup = Path("/root/omafit-host-config-backup")
backup.mkdir(mode=0o700, exist_ok=True)
paths = [Path("/etc/omarchy.conf"), Path("/etc/sudoers.d/omarchy-dev-path")]
for path in paths:
    saved = backup / path.name
    if path.exists() and not saved.exists():
        shutil.copyfile(path, saved)
sudoers = f'Defaults secure_path="{target}/bin:/usr/local/sbin:/usr/local/bin:/usr/bin"\n'
with tempfile.NamedTemporaryFile(mode="w", dir="/tmp", prefix="omafit-sudoers-") as staged:
    staged.write(sudoers)
    staged.flush()
    subprocess.run(["visudo", "-cf", staged.name], check=True)
    subprocess.run(["install", "-m", "440", "-o", "root", "-g", "root", staged.name, str(paths[1])], check=True)
paths[0].write_text(f'export OMARCHY_PATH="{target}"\n')
os.chmod(paths[0], 0o644)
print("Disposable VM dev-link configured. Reboot the guest to activate its canonical environment.")
