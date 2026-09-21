#!/usr/bin/env python3
"""Enter the disposable guest's desktop environment without printing it."""
import os
import subprocess
import sys

if (os.environ.get("OUTFIT_TEST_VM") or os.environ.get("OMAFIT_TEST_VM")) != "1":
    raise SystemExit("Set OUTFIT_TEST_VM=1 in the disposable guest")
allowed = {"HYPRLAND_INSTANCE_SIGNATURE", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR",
           "DBUS_SESSION_BUS_ADDRESS", "OMARCHY_PATH", "XDG_CURRENT_DESKTOP", "PATH"}
values = subprocess.check_output(["systemctl", "--user", "show-environment"], text=True)
for line in values.splitlines():
    key, separator, value = line.partition("=")
    if separator and key in allowed: os.environ[key] = value
if len(sys.argv) < 2: raise SystemExit("A guest command is required")
os.execvp(sys.argv[1], sys.argv[1:])
