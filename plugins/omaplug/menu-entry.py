#!/usr/bin/env python3
"""Manage only Omaplug's opt-in entry in the user's Omarchy menu."""
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

ENTRY = {
    "icon": "󱓖", "label": "Omaplug",
    "description": "Manage Omarchy plugins with Omaplug",
    "aliases": ["omaplug", "plugins"],
    "action": "omarchy-shell shell summon omaplug",
}
ENTRY_KEY = "apps.omaplug"
LEGACY_KEY = "omaplug"
LEGACY_ENTRY = dict(ENTRY, label="Plugin Manager")
OLD_ACTION_ENTRY = dict(ENTRY, action="omarchy-shell omaplug open")
BLOCK = re.compile(r'\n  // omaplug-menu-start\n.*?  // omaplug-menu-end\n', re.S)
TOKEN = re.compile(r'"(?:\\.|[^"\\])*"|//[^\n]*|\s+|.', re.S)


def parse(raw):
    # Retain source offsets so comments and all unrelated entries stay intact.
    tokens = [m for m in TOKEN.finditer(raw)
              if not m.group().isspace() and not m.group().startswith("//")]
    clean = "".join(m.group() for i, m in enumerate(tokens)
                    if not (m.group() == "," and i + 1 < len(tokens)
                            and tokens[i + 1].group() in ("}", "]")))
    data = json.loads(clean)
    if not isinstance(data, dict):
        raise ValueError("The Omarchy menu must be a JSON object.")
    if isinstance(data.get("items"), dict):
        depth = 0
        for i, token in enumerate(tokens):
            value = token.group()
            if depth == 1 and value == '"items"' and tokens[i + 1].group() == ":":
                return data["items"], tokens[i + 2].end()
            if value in ("{", "["):
                depth += 1
            elif value in ("}", "]"):
                depth -= 1
        raise ValueError("Cannot locate the menu items object.")
    return data, tokens[0].end()


def render(raw, enabled):
    entries, _ = parse(raw)
    blocks = BLOCK.findall(raw)
    if len(blocks) > 1:
        raise ValueError("Multiple Omaplug menu entries found; please review the menu file.")
    if blocks and entries.get(ENTRY_KEY) not in (ENTRY, OLD_ACTION_ENTRY) and entries.get(LEGACY_KEY) != LEGACY_ENTRY:
        raise ValueError("The Omaplug menu entry was edited; please review it before changing this setting.")
    if not blocks and "omaplug" in entries:
        raise ValueError("An existing custom Omaplug menu entry must be managed manually.")
    base = BLOCK.sub("", raw)
    entries, offset = parse(base)
    if not enabled:
        return base
    block = '\n  // omaplug-menu-start\n  "' + ENTRY_KEY + '": ' + json.dumps(ENTRY, ensure_ascii=False)
    block += ("," if entries else "") + '\n  // omaplug-menu-end\n'
    result = base[:offset] + block + base[offset:]
    parse(result)
    return result


def read(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return "{\n}\n", None
    with os.fdopen(fd, "r", encoding="utf-8") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 1024 * 1024:
            raise ValueError("Menu file must be a user-owned regular file under 1 MiB.")
        return stream.read(), info


def run(action):
    # Omarchy's menu loader uses this HOME path (not XDG_CONFIG_HOME).
    path = Path.home() / ".config/omarchy/extensions/omarchy-menu.jsonc"
    if action == "status":
        raw, _ = read(path)
        entries, _ = parse(raw)
        return entries.get(ENTRY_KEY) == ENTRY
    path.parent.mkdir(parents=True, exist_ok=True)
    lock = os.open(path.parent / ".omaplug-menu.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock, "w") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError("Unsafe menu lock file.")
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        raw, info = read(path)
        result = render(raw, action == "enable")
        if result != raw:
            fd, temporary = tempfile.mkstemp(prefix=".omaplug-menu-", dir=path.parent)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as output:
                    os.fchmod(output.fileno(), stat.S_IMODE(info.st_mode) if info else 0o600)
                    output.write(result)
                    output.flush()
                    os.fsync(output.fileno())
                current, current_info = read(path)
                if current != raw or (info is None) != (current_info is None):
                    raise ValueError("Menu changed while saving; please try again.")
                os.replace(temporary, path)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
    return action == "enable"


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2 or sys.argv[1] not in ("status", "enable", "disable"):
            raise ValueError("Expected status, enable, or disable.")
        print(json.dumps({"enabled": run(sys.argv[1])}))
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
