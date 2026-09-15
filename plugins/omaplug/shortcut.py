#!/usr/bin/env python3
"""Opt-in Hyprland Lua shortcuts, with live conflict checks and owned blocks."""
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

MODIFIERS = {"SUPER": 64, "CTRL": 4, "ALT": 8, "SHIFT": 1}


def combination(value):
    parts = [p.strip().upper().replace("CONTROL", "CTRL") for p in value.split("+")]
    keys = [p for p in parts if p not in MODIFIERS]
    mods = [p for p in parts if p in MODIFIERS]
    if (len(keys) != 1 or not mods or len(set(parts)) != len(parts)
            or not re.fullmatch(r"[A-Z0-9]|F(?:[1-9]|1[0-2])|SLASH|SPACE|RETURN|TAB|ESCAPE|HOME|END|INSERT|DELETE|PAGEUP|PAGEDOWN|UP|DOWN|LEFT|RIGHT", keys[0])):
        raise ValueError("Use a modifier + supported key.")
    ordered = [m for m in MODIFIERS if m in mods]
    return " + ".join(ordered + keys), sum(MODIFIERS[m] for m in ordered), keys[0]


def command(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise ValueError(result.stderr.strip() or result.stdout.strip() or "Command failed: " + args[0])
    return result.stdout.strip()


def block(plugin, combo, replace=False):
    return (f"\n-- omaplug-shortcut-start: {plugin}\n"
            + ("hl.unbind(" + json.dumps(combo) + ")\n" if replace else "")
            + "o.bind(" + ", ".join(json.dumps(s) for s in
              (combo, "Omaplug: " + plugin, "omarchy-shell shell summon " + plugin)) + ")\n"
            + f"-- omaplug-shortcut-end: {plugin}\n")


def saved(raw, plugin):
    pattern = re.compile(r"\n-- omaplug-shortcut-start: " + re.escape(plugin)
                         + r"\n.*?-- omaplug-shortcut-end: " + re.escape(plugin) + r"\n", re.S)
    matches = pattern.findall(raw)
    if not matches:
        if "omaplug-shortcut-start: " + plugin + "\n" in raw:
            raise ValueError("The saved shortcut block was edited. Please review bindings.lua.")
        return "", raw
    if len(matches) != 1:
        raise ValueError("Multiple shortcut blocks found for this plugin.")
    match = re.search(r'o\.bind\("([^"\n]+)"', matches[0])
    # Older versions saved XKB key names with their original casing. Validate
    # the exact owned block without applying the current capture allowlist.
    if (not match or not re.fullmatch(
            r"(?:SUPER|CTRL|ALT|SHIFT)(?: \+ (?:SUPER|CTRL|ALT|SHIFT))* \+ (?:[A-Za-z0-9_]+|code:[0-9]+)", match[1])
            or matches[0] not in (block(plugin, match[1]), block(plugin, match[1], True))):
        raise ValueError("The saved shortcut was edited manually. Please review bindings.lua.")
    return match[1], pattern.sub("", raw)


def conflict(bindings, combo, plugin, own_combo=""):
    _, mask, key = combination(combo)
    own_ignored = False
    for binding in bindings:
        # Conservatively consider submaps too. A future submap must not steal this shortcut.
        if int(binding.get("modmask", 0)) & ~2 != mask:  # Caps Lock is not a chosen modifier.
            continue
        if binding.get("mouse"):
            continue
        bound_key = str(binding.get("key", "")).upper()
        uncertain_code = bool(binding.get("keycode")) or bound_key.startswith("CODE:")
        if not (bound_key == key or uncertain_code or binding.get("catch_all")):
            continue
        if (not own_ignored and combo == own_combo and bound_key == key
                and binding.get("description") == "Omaplug: " + plugin):
            own_ignored = True
            continue
        action = binding.get("description") or binding.get("arg") or binding.get("dispatcher") or "another action"
        if uncertain_code or binding.get("catch_all") or binding.get("submap"):
            return "Cannot confirm availability for this binding (" + action + "). Choose another combination."
        return "Already assigned to " + action + ". Select Replace to use this shortcut."
    return ""


def read(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, encoding="utf-8") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 1024 * 1024:
            raise ValueError("Expected a user-owned regular bindings.lua file under 1 MiB.")
        return stream.read(), stat.S_IMODE(info.st_mode)


def write(path, raw, mode):
    fd, temporary = tempfile.mkstemp(prefix=".omaplug-shortcut-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def run(action, plugin, value=""):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", plugin) or ".." in plugin:
        raise ValueError("Invalid plugin ID.")
    path = Path.home() / ".config/hypr/bindings.lua"
    if not path.exists():
        raise ValueError("This shortcut editor currently requires Omarchy's Lua bindings.lua configuration.")
    if action == "test":
        if command(["omarchy-shell", "shell", "summon", plugin]) != "ok":
            raise ValueError("This plugin has no available popup. Keep it enabled and on the bar, or choose another plugin.")
        return {"message": "Plugin opened. Return to Omaplug to save your shortcut."}
    raw, mode = read(path)
    own, _ = saved(raw, plugin)
    if action == "status":
        return {"shortcut": own, "message": "Saved shortcut: " + own if own else "No shortcut assigned."}
    combo = combination(value)[0] if action in ("check", "save", "replace") else ""
    if action in ("save", "replace"):
        plugins = json.loads(command(["omarchy-shell", "shell", "listPlugins"]))
        if not any(p.get("id") == plugin and p.get("enabled") is True for p in plugins):
            raise ValueError("Enable the plugin before saving a launch shortcut.")
    if action in ("check", "save", "replace"):
        bindings = json.loads(command(["hyprctl", "-j", "binds"]))
        if not isinstance(bindings, list):
            raise ValueError("Could not read current keyboard bindings.")
        message = conflict(bindings, combo, plugin, own)
        if message.startswith("Cannot confirm"):
            raise ValueError(message)
        if message and action != "replace":
            return {"shortcut": own, "pendingShortcut": combo, "message": message}
        if action == "check":
            return {"shortcut": combo, "message": "Available: " + combo}
    if action not in ("save", "replace", "remove"):
        raise ValueError("Unknown shortcut operation.")
    lock = os.open(path.parent / ".omaplug-shortcuts.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock, "w") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError("Unsafe shortcut lock file.")
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        raw, mode = read(path)
        own, base = saved(raw, plugin)
        if combo:
            message = conflict(json.loads(command(["hyprctl", "-j", "binds"])), combo, plugin, own)
            if message.startswith("Cannot confirm"):
                raise ValueError(message)
            if message and action != "replace":
                return {"shortcut": own, "pendingShortcut": combo, "message": message}
        if command(["hyprctl", "configerrors"]):
            raise ValueError("Fix the existing Hyprland configuration errors before saving shortcuts.")
        replacing = action == "replace" or (combo == own and block(plugin, own, True) in raw)
        updated = base + block(plugin, combo, replacing) if combo else base
        if updated == raw:
            return {"shortcut": combo, "message": "Shortcut unchanged."}
        if read(path)[0] != raw:
            raise ValueError("Bindings changed while saving. Please try again.")
        write(path, updated, mode)
        try:
            command(["hyprctl", "reload"])
            errors = command(["hyprctl", "configerrors"])
            if errors:
                raise ValueError(errors)
        except (ValueError, subprocess.TimeoutExpired) as error:
            if read(path)[0] == updated:
                write(path, raw, mode)
                command(["hyprctl", "reload"])
                remaining = command(["hyprctl", "configerrors"])
                raise ValueError("Shortcut was not saved; previous bindings restored. " + str(error)
                                 + (" Remaining configuration errors: " + remaining if remaining else ""))
            raise ValueError("Bindings changed externally; please review bindings.lua. " + str(error))
    return {"shortcut": combo, "message": "Shortcut saved." if combo else "Shortcut removed."}


if __name__ == "__main__":
    try:
        if len(sys.argv) not in (3, 4):
            raise ValueError("Expected operation, plugin ID, and optional shortcut.")
        print(json.dumps(run(*sys.argv[1:])))
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(json.dumps({"error": str(error)}))
        sys.exit(1)
