#!/usr/bin/env python3
"""Detached, explicitly requested Outfit update-and-reopen transaction.

Public API: launch(backend, request, store), status(backend, store). Neither
status nor module import performs a mutation/reopen. A queued launch is not an
acknowledged launch: accepted becomes true only after the staged worker writes
its first receipt. Receipts are snapshots, not instructions to replay.

The worker stages this file AND the reviewed installed backend (stdlib-only).
It imports that private copy explicitly under Python -I -B, never the checkout
being replaced. Native Omarchy still chooses FETCH_HEAD; a moving remote cannot
be pinned by its current API, so resulting revision mismatches fail closed.
"""
from __future__ import annotations

from contextlib import contextmanager
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import subprocess
import sys
import time
import types
import uuid


APP_ID = "io.github.ctl0v0.outfit"
MAX_JSON = 32 * 1024
MAX_SOURCE = 2 * 1024 * 1024
JOB_LIFETIME = 300
RECEIPT_LIFETIME = 86400
ACK_TIMEOUT = 8
UNIT = "outfit-self-update.service"
ACTIVE = {"queued", "checking", "updating", "verified", "restarting", "reopening"}
TERMINAL = {"completed", "failed", "restart-failed", "reopen-failed"}
SHA = re.compile(r"[0-9a-f]{40}(?:[0-9a-f]{24})?")
TOKEN = re.compile(r"[0-9a-f]{32}")
ENV_KEYS = ("HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR",
            "DBUS_SESSION_BUS_ADDRESS", "HYPRLAND_INSTANCE_SIGNATURE", "WAYLAND_DISPLAY",
            "LANG", "LC_ALL")


class Refused(ValueError):
    """Only fixed, non-sensitive messages may cross the public boundary."""


def _json(value, maximum=MAX_JSON):
    raw = json.dumps(value, ensure_ascii=True, allow_nan=False, separators=(",", ":")).encode()
    if len(raw) > maximum:
        raise Refused("Self-update state exceeds its size limit.")
    return raw


def _safe_path(path):
    """Reject symlink ancestors and paths writable by another account.

    Root-owned sticky ancestors permit private temporary test directories; all
    actual state leaves additionally require this user's ownership and 0700.
    """
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts or path.resolve() != path:
        raise Refused("Self-update requires ordinary, non-symlinked paths.")
    for part in (*reversed(path.parents), path):
        info = part.lstat()
        sticky = stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and info.st_mode & stat.S_ISVTX
        if (stat.S_ISLNK(info.st_mode) or info.st_uid not in {0, os.getuid()}
                or (info.st_mode & 0o022 and not sticky)):
            raise Refused("Self-update encountered an unsafe path.")
    return path


def _private_dir(path):
    path = _safe_path(path)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise Refused("Self-update state must be an owner-only directory.")
    return path


def _read(path, maximum=MAX_JSON, private=True):
    _safe_path(path.parent)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1
                or info.st_size > maximum or info.st_mode & (0o077 if private else 0o022)):
            raise Refused("Self-update file is unsafe or too large.")
        raw = stream.read(maximum + 1)
    if len(raw) > maximum:
        raise Refused("Self-update file exceeds its size limit.")
    return raw


def _write(path, raw, replace=False):
    _private_dir(path.parent)
    temporary = path.parent / (".write-" + uuid.uuid4().hex) if replace else path
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        if replace:
            os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if replace:
            temporary.unlink(missing_ok=True)


@contextmanager
def _lock(path, wait=0):
    _private_dir(path.parent)
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600):
            raise Refused("Self-update lock is unsafe.")
        deadline = time.monotonic() + wait
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise Refused("Another plugin update is running; wait for it to finish.") from None
                time.sleep(0.05)
        yield
    finally:
        os.close(fd)


def _state_root(store, create=False):
    base = _private_dir(Path(store.base).absolute())
    if (os.fstat(store.fd).st_dev, os.fstat(store.fd).st_ino) != (base.stat().st_dev, base.stat().st_ino):
        raise Refused("The Outfit cache directory changed.")
    root = base / "self-update"
    if create:
        try:
            root.mkdir(mode=0o700)
        except FileExistsError:
            pass
    return _private_dir(root)


def _payload(value):
    """Allowlisted navigation/editor geometry only; no preferences or profiling.

    Settings drafts, interest criteria and restore tokens are deliberately not
    copied. An old token belongs to the old service and could reject this summon.
    """
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise Refused("Editor resume state must be an object.")
    _json(value, 64 * 1024)
    result = {}
    enums = {"view": {"setup", "fit"}, "workspaceView": {"browse", "discover"},
             "discoverTab": {"ideas", "matches"}, "setupStage": {"services", "browse", "review", "progress", "updates"},
             "setupGrouping": {"none", "category"}, "setupVerification": {"all", "verified", "unverified"}}
    for key in ("installFilter", "setupInstallFilter"):
        enums[key] = {"all", "installed", "available"}
    for key in ("partyFilter", "setupPartyFilter"):
        enums[key] = {"all", "first-party", "third-party"}
    for key, choices in enums.items():
        if key in value:
            if not isinstance(value[key], str) or value[key] not in choices:
                raise Refused("Editor resume state contains an invalid choice.")
            result[key] = value[key]
    for key, limit in {"setupQuery": 160, "query": 160, "category": 80, "setupCategory": 80,
                       "setupGroup": 40, "setupServiceFilter": 64, "selectedId": 160,
                        "inspectorFocus": 40, "setupSort": 24, "browseSort": 24, "updatesQuery": 160}.items():
        if key in value:
            text = value[key]
            if not isinstance(text, str) or len(text) > limit or any(not c.isprintable() for c in text):
                raise Refused("Editor resume state contains invalid text.")
            result[key] = text
    for key in ("settingsOpen", "interestsOpen", "interestsFromSettings", "setupHardwareOnly"):
        if key in value:
            if type(value[key]) is not bool:
                raise Refused("Editor resume state contains an invalid flag.")
            result[key] = value[key]
    def number(value, low, high):
        if type(value) not in (int, float) or not math.isfinite(value) or not low <= value <= high:
            raise Refused("Editor resume state contains an invalid position.")
        return value
    for key, low, high in (("windowWidth", 0, 10000), ("windowHeight", 0, 10000),
                           ("setupPage", 1, 1000000), ("inspectorScroll", 0, 1000000), ("updatesScroll", 0, 1000000)):
        if key in value:
            result[key] = number(value[key], low, high)
    if value.get("scrollAnchor") is not None:
        anchor = value["scrollAnchor"]
        if not isinstance(anchor, dict):
            raise Refused("Editor scroll anchor is invalid.")
        identity = anchor.get("id", "")
        if not isinstance(identity, str) or len(identity) > 160 or any(not c.isprintable() for c in identity):
            raise Refused("Editor scroll anchor is invalid.")
        result["scrollAnchor"] = {"id": identity, "offset": number(anchor.get("offset", 0), -10000, 10000),
                                  "y": number(anchor.get("y", 0), 0, 1000000)}
    if "setupServices" in value:
        values = value["setupServices"]
        if (not isinstance(values, list) or len(values) > 64
                or any(not isinstance(v, str) or not re.fullmatch(r"[a-zA-Z0-9._-]{1,64}", v) for v in values)):
            raise Refused("Editor service selection is invalid.")
        result["setupServices"] = values[:]
    context = value.get("updatesContext")
    if context is not None:
        if not isinstance(context, dict):
            raise Refused("Updates view state is invalid.")
        expanded = context.get("expanded", {})
        if not isinstance(expanded, dict) or len(expanded) > 64:
            raise Refused("Updates expansion state exceeds its limit.")
        kept = {}
        for identity, enabled in expanded.items():
            if (not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", identity)
                    or identity in {"constructor", "prototype"} or enabled is not True):
                raise Refused("Updates expansion state is invalid.")
            kept[identity] = True
        identity = context.get("id", "")
        action = context.get("action", "details")
        if not isinstance(identity, str) or len(identity) > 128 or action not in {"details", "update", "explain"}:
            raise Refused("Updates focus state is invalid.")
        saved = {"x":number(context.get("x",0),0,1000000), "y":number(context.get("y",0),0,1000000),
                 "expanded":kept, "id":identity, "action":action, "anchor":None}
        anchor = context.get("anchor")
        if anchor is not None:
            if not isinstance(anchor,dict) or not isinstance(anchor.get("id"),str) or len(anchor["id"]) > 128:
                raise Refused("Updates scroll anchor is invalid.")
            saved["anchor"] = {"id":anchor["id"], "offset":number(anchor.get("offset",0),-10000,10000)}
        result["updatesContext"] = saved
    _json(result, 16 * 1024)
    return result


def _base(state="idle", message="No recent Outfit self-update."):
    return {"state": state, "message": message, "id": APP_ID, "expectedRevision": "",
            "installedRevision": "", "accepted": False, "verified": False, "ok": False}


def _receipt(root):
    try:
        value = json.loads(_read(root / "receipt.json"))
    except FileNotFoundError:
        return None
    keys = {"schema", "id", "operationId", "state", "message", "startedAt", "updatedAt", "expiresAt",
            "accepted", "verified", "reopenRequested", "resumePayload", "expectedRevision",
            "expectedInstalledRevision", "installedRevision", "installedVersion", "expectedVersion", "reopenState"}
    if (not isinstance(value, dict) or set(value) - keys or value.get("schema") != 1 or value.get("id") != APP_ID
            or not isinstance(value.get("operationId"), str) or not TOKEN.fullmatch(value["operationId"])
            or value.get("state") not in ACTIVE | TERMINAL
            or any(type(value.get(k)) not in (int, float) or not math.isfinite(value[k])
                   for k in ("startedAt", "updatedAt", "expiresAt"))
            or any(not isinstance(value.get(k), str) or not SHA.fullmatch(value[k])
                   for k in ("expectedRevision", "expectedInstalledRevision"))
            or not isinstance(value.get("installedRevision"), str)
            or (value["installedRevision"] and not SHA.fullmatch(value["installedRevision"]))
            or any(type(value.get(k)) is not bool for k in ("accepted", "verified", "reopenRequested"))
            or not isinstance(value.get("message"), str) or len(value["message"]) > 300
            or any(not isinstance(value.get(k), str) or len(value[k]) > 64
                   or any(not c.isprintable() for c in value[k]) for k in ("installedVersion", "expectedVersion"))
            or value.get("reopenState", "accepted") not in {"accepted", "unconfirmed"}
            or not 0 <= value["startedAt"] <= value["updatedAt"] <= 253402300799
            or not value["startedAt"] < value["expiresAt"] <= value["updatedAt"] + RECEIPT_LIFETIME + 1
            or _payload(value.get("resumePayload")) != value.get("resumePayload")):
        raise Refused("Self-update receipt is invalid.")
    return value


def _public(value):
    if value is None:
        return _base()
    now = time.time()
    if value["startedAt"] > now + 5 or now >= value["expiresAt"]:
        result = _base("expired", "The previous self-update receipt expired; check installed versions again.")
        result.update(operationId=value["operationId"], expectedRevision=value["expectedRevision"],
                      expectedInstalledRevision=value["expectedInstalledRevision"])
        return result
    result = dict(value)
    result.pop("schema", None)
    result["ok"] = value["accepted"] and value["state"] not in {"failed", "restart-failed", "reopen-failed"}
    return result


def status(backend, store):
    """Idempotent bounded receipt read. Never starts/restarts/summons anything."""
    try:
        return _public(_receipt(_state_root(store)))
    except FileNotFoundError:
        return _base()
    except (OSError, ValueError, TypeError, RecursionError):
        return _base("unavailable", "Self-update status is unavailable or unsafe.")


def _record(root, value, state, message, **fields):
    result = {**value, **fields, "state": state, "message": message, "updatedAt": time.time()}
    if state in TERMINAL:
        result["expiresAt"] = time.time() + RECEIPT_LIFETIME
    _write(root / "receipt.json", _json(result), replace=True)
    return result


def _runtime(backend):
    raw = os.environ.get("OMARCHY_PATH", "")
    if (not raw or len(os.fsencode(raw)) > 4096 or ":" in raw
            or not all(c.isprintable() for c in raw) or not Path(raw).is_absolute()):
        raise Refused("The original Omarchy runtime is unavailable.")
    root = _safe_path(Path(raw).resolve())
    for name in ("omarchy", "omarchy-shell", "omarchy-restart-shell"):
        path = _safe_path(root / "bin" / name)
        if not path.is_file() or not os.access(path, os.X_OK):
            raise Refused("The original Omarchy runtime is incomplete.")
    environment = {key: os.environ[key] for key in ENV_KEYS if key in os.environ}
    if any(len(value) > 4096 or "\0" in value or "\n" in value for value in environment.values()):
        raise Refused("The session environment is invalid.")
    environment.update(OMARCHY_PATH=str(root), PATH=str(root / "bin") + ":/usr/bin:/bin",
                       OMARCHY_SHELL_IPC_TIMEOUT="3s")
    # Obtain the existing backend's native updater Git restrictions without
    # inheriting the user manager's PATH, Python, shell or Git overrides.
    _, native_env = backend.command_launch([backend.COMMANDS["omarchy"], "plugin", "update", APP_ID, "--yes"])
    environment.update({k: v for k, v in native_env.items() if k.startswith("GIT_") or k == "SSH_ASKPASS"})
    return environment


def _command(argv, environment, timeout=5, maximum=128 * 1024):
    """Fixed argv only; bounded output is never forwarded to receipts/journal."""
    process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, env=environment, start_new_session=True)
    output = bytearray()
    deadline = time.monotonic() + timeout
    try:
        with selectors.DefaultSelector() as poll:
            poll.register(process.stdout, selectors.EVENT_READ)
            while poll.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("Self-update command timed out.")
                for key, _ in poll.select(min(remaining, 0.1)):
                    chunk = os.read(key.fd, min(65536, maximum + 1 - len(output)))
                    if not chunk:
                        poll.unregister(key.fileobj)
                    output.extend(chunk)
                    if len(output) > maximum:
                        raise Refused("Self-update command output exceeded its limit.")
        if process.wait(timeout=max(0.01, deadline - time.monotonic())):
            raise Refused("A required self-update command failed.")
        return bytes(output)
    except BaseException as error:
        # Keep an unreaped group leader until descendants have been killed.
        if process.returncode is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=2)
        if isinstance(error, subprocess.TimeoutExpired):
            raise TimeoutError("Self-update command timed out.") from None
        raise
    finally:
        process.stdout.close()


def _ordinary(backend, deadline=None):
    target = _safe_path(backend.plugin_install_path(APP_ID))
    if target != Path.home() / ".config/omarchy/plugins" / APP_ID or not target.is_dir():
        raise Refused("Self-update requires the ordinary native Outfit installation.")
    git = _safe_path(target / ".git")
    if (not git.is_dir() or any((git / name).exists() or (git / name).is_symlink()
                               for name in ("commondir", "worktrees", "objects/info/alternates", "info/grafts"))):
        raise Refused("Self-update does not support development installs or Git worktrees.")
    if target.stat().st_uid != os.getuid() or git.stat().st_uid != os.getuid():
        raise Refused("The Outfit checkout must belong to the current user.")
    for name in ("config", "HEAD", "index", "packed-refs", "objects", "refs"):
        path = git / name
        if path.exists() or path.is_symlink():
            _safe_path(path)
    if backend.update_git(target, ["for-each-ref", "--format=%(refname)", "refs/replace/"], deadline):
        raise Refused("Git replacement objects are unsupported for self-update.")
    # Native merge can execute configured filters/merge drivers. Deny all such
    # configuration rather than trying to sanitize command strings. Hooks and
    # fsmonitor are independently disabled by the native update environment.
    config = backend.update_git(target, ["config", "--null", "--list"], deadline)
    for entry in config.split(b"\0"):
        key = entry.split(b"\n", 1)[0].lower()
        if (key.startswith((b"filter.", b"merge.", b"include.", b"includeif.", b"url.", b"submodule.", b"extensions."))
                or key in {b"core.worktree", b"core.sshcommand", b"core.gitproxy"}):
            raise Refused("This checkout uses unsupported Git configuration.")
    return target


def _inventory_target(backend):
    inventory, unavailable = backend.scan_inventory(include_versions=False)
    matches = [item for item in inventory if item.get("id") == APP_ID]
    if (unavailable or len(matches) != 1 or matches[0].get("firstParty")
            or matches[0].get("enabled") is not True or matches[0].get("barSectionKnown") is not True):
        raise Refused("The installed Outfit identity, enabled state and placement could not be verified.")
    return matches[0]


def _validate(backend, request, store, binding=None):
    deadline = time.monotonic() + 60
    if backend.APP_ID != APP_ID:
        raise Refused("Self-update identity does not match Outfit.")
    target = _ordinary(backend, deadline)
    item = _inventory_target(backend)
    if binding and (binding["enabled"] != item["enabled"] or binding["barSection"] != item.get("barSection", "")):
        raise Refused("Outfit enabled state or placement changed since approval.")
    local = backend.inspect_update_target(item, deadline)
    reviewed = backend.load_plugin_updates(store).get(APP_ID)
    if (not backend.cached_update_matches(reviewed, local, time.time())
            or local["installedRevision"] != request["expectedInstalledRevision"]
            or reviewed["record"].get("availableRevision") != request["expectedRevision"]
            or reviewed["record"].get("selfUpdate") is not True
            or reviewed["record"].get("state") != "available"
            or (binding and (binding["sourceKey"] != local["sourceKey"]
                             or binding["repository"] != local["repository"]))):
        raise Refused("The reviewed Outfit source changed or expired; check updates again.")
    fresh = backend.check_plugin_update(item, time.time(), local, deadline)
    if (fresh["state"] != "available" or fresh.get("selfUpdate") is not True
            or fresh["availableRevision"] != request["expectedRevision"]
            or fresh["availableVersion"] != reviewed["record"]["availableVersion"]
            or (binding and fresh["availableVersion"] != binding["expectedVersion"])):
        raise Refused("The approved remote target changed or is unavailable; check updates again.")
    latest_item = _inventory_target(backend)
    if latest_item.get("barSection", "") != item.get("barSection", ""):
        raise Refused("Outfit placement changed during verification.")
    latest = backend.inspect_update_target(latest_item, deadline)
    if latest["state"] != "ready" or latest["sourceKey"] != local["sourceKey"]:
        raise Refused("The installed Outfit checkout changed during verification.")
    return {"target": str(target), "sourceKey": local["sourceKey"], "repository": local["repository"],
            "expectedVersion": fresh["availableVersion"], "installedVersion": local["installedVersion"],
            "enabled": item["enabled"], "barSection": item.get("barSection", "")}


def _sources(backend, target):
    sources = {}
    # Preserve module basenames for a backend that imports this helper with
    # importlib from Path(__file__).with_name("self_update.py") under -I.
    for name, source in (("self_update.py", Path(__file__)), ("outfit.py", Path(backend.__file__))):
        if source.absolute() != target / "scripts" / name:
            raise Refused("Self-update must run from its installed, reviewed Outfit checkout.")
        raw = _read(source, MAX_SOURCE, private=False)
        tracked = backend.update_git(target, ["show", "HEAD:scripts/" + name], maximum=MAX_SOURCE)
        if raw != tracked:
            raise Refused("The installed worker code differs from its reviewed Git revision.")
        sources[name] = raw
    return sources


def _retire(root, previous):
    """Keep only one staged generation, without traversing arbitrary cache data.

    Caller holds the worker lock, and previous is terminal/expired. A delayed
    systemd start cannot acquire that generation's sources or queued receipt.
    """
    if previous is None:
        return
    directory = root / previous["operationId"]
    if not directory.exists():
        return
    _private_dir(directory)
    if set(os.listdir(directory)) - {"self_update.py", "outfit.py", "job.json"}:
        raise Refused("The previous self-update staging directory is unsafe.")
    for name in ("self_update.py", "outfit.py", "job.json"):
        path = directory / name
        try:
            _read(path, MAX_SOURCE)
            path.unlink()
        except FileNotFoundError:
            pass
    directory.rmdir()


def launch(backend, request, store):
    """Explicit Update Outfit & reopen only; never usable as an Update-all item."""
    try:
        if (not isinstance(request, dict) or request.get("action", "self-update") != "self-update"
                or request.get("pluginId", APP_ID) != APP_ID or request.get("batchItem", False) is not False
                or any(not isinstance(request.get(k), str) or not SHA.fullmatch(request[k])
                       for k in ("expectedRevision", "expectedInstalledRevision"))
                or request["expectedRevision"] == request["expectedInstalledRevision"]):
            raise Refused("Self-update requires a separately reviewed Outfit update-and-reopen request.")
        payload = _payload(request.get("resumePayload"))
        root = _state_root(store, create=True)
        with _lock(root / "worker.lock"), _lock(root.parent / ".plugin-update.lock"):
            previous = _receipt(root)
            if previous and previous["state"] in ACTIVE and _public(previous)["state"] != "expired":
                result = _public(previous)
                return {**result, "ok": False, "message": "An Outfit self-update is already pending.", "duplicate": True}
            environment = _runtime(backend)
            binding = _validate(backend, request, store)
            target = Path(binding["target"])
            if root.is_relative_to(target):
                raise Refused("Self-update staging must be outside the installed plugin.")
            sources = _sources(backend, target)
            _retire(root, previous)
            operation = uuid.uuid4().hex
            job = root / operation
            job.mkdir(mode=0o700)  # exclusive, random name under a private parent
            now = time.time()
            receipt = {"schema": 1, "id": APP_ID, "operationId": operation, "state": "queued",
                       "message": "Waiting for the independent Outfit update worker.", "startedAt": now,
                       "updatedAt": now, "expiresAt": now + JOB_LIFETIME, "accepted": False,
                       "verified": False, "reopenRequested": True, "resumePayload": payload,
                       "expectedRevision": request["expectedRevision"],
                       "expectedInstalledRevision": request["expectedInstalledRevision"],
                       "installedRevision": request["expectedInstalledRevision"],
                       "installedVersion": binding["installedVersion"], "expectedVersion": binding["expectedVersion"]}
            for filename, raw in sources.items():
                _write(job / filename, raw)
            document = {"schema": 1, "operationId": operation, "environment": environment,
                        "binding": binding, "receipt": receipt,
                        "backendDigest": hashlib.sha256(sources["outfit.py"]).hexdigest()}
            _write(job / "job.json", _json(document))
            _write(root / "receipt.json", _json(receipt), replace=True)
            argv = ["/usr/bin/systemd-run", "--user", "--quiet", "--no-block", "--collect",
                    "--unit=" + UNIT, "--service-type=oneshot",
                    "--property=TimeoutStartSec=300", "--property=TimeoutStopSec=5",
                    "--property=KillMode=control-group", "--property=UMask=0077",
                    "--property=StandardOutput=null", "--property=StandardError=null",
                    "--property=WorkingDirectory=/", "--expand-environment=no",
                    "--", "/usr/bin/env", "-i", "/usr/bin/python3", "-I", "-B", str(job / "self_update.py"), "--worker"]
            try:
                _command(argv, environment, timeout=8, maximum=4096)
            except (OSError, ValueError, TimeoutError, subprocess.TimeoutExpired):
                # Still holding the handoff lock: a delayed worker cannot pass
                # its queued-state check after this durable cancellation.
                receipt = _record(root, receipt, "failed", "The user service manager did not confirm launch.")
                return _public(receipt)
        deadline = time.monotonic() + ACK_TIMEOUT
        while time.monotonic() < deadline:
            current = _receipt(root)
            if current and current["operationId"] == operation and (current["accepted"] or current["state"] in TERMINAL):
                return _public(current)
            time.sleep(0.05)
        return {**_public(receipt), "state": "unconfirmed", "ok": False,
                "message": "Worker launch is not acknowledged yet; poll self-update status before retrying."}
    except Refused as error:
        return _base("blocked", str(error))
    except (OSError, ValueError, TypeError, KeyError, RecursionError, TimeoutError, subprocess.TimeoutExpired):
        return _base("failed", "Outfit self-update could not be safely prepared; check updates and retry.")


def _invalidate(backend, store):
    with store.scoped_lock():
        entries = backend.load_plugin_updates(store)
        entries.pop(APP_ID, None)
        store.write("plugin-updates.json", {"schema": 1, "entries": entries}, backend.MAX_UPDATES_CACHE_BYTES)


def _observed(backend):
    # Independent disk evidence, even if the native command failed/rolled back.
    result = {"installedRevision": "", "installedVersion": ""}
    try:
        deadline = time.monotonic() + 30
        _ordinary(backend, deadline)
        local = backend.inspect_update_target({"id": APP_ID, "firstParty": False}, deadline)
        result.update(installedRevision=local["installedRevision"], installedVersion=local["installedVersion"])
        item = _inventory_target(backend)
        local.update(enabled=item["enabled"], barSection=item.get("barSection", ""))
        return result, local
    except (OSError, ValueError, TimeoutError):
        return result, None


def _restart_runtime(environment):
    # Native restart-shell prefers the user manager's OMARCHY_PATH. Refuse a
    # changed session runtime rather than silently restarting a different tree.
    raw = _command(["/usr/bin/systemctl", "--user", "show-environment"], environment, 5, 128 * 1024)
    roots = [line[len(b"OMARCHY_PATH="):].decode("utf-8")
             for line in raw.splitlines() if line.startswith(b"OMARCHY_PATH=")]
    if roots and (len(roots) != 1 or not Path(roots[0]).is_absolute()
                  or Path(roots[0]).resolve() != Path(environment["OMARCHY_PATH"])):
        raise Refused("The session Omarchy runtime changed; automatic restart was skipped.")


def _work(backend, store, root, job):
    """Run under the worker handoff lock; injectable backend/commands for tests."""
    receipt = _receipt(root)
    if (not receipt or receipt["operationId"] != job["operationId"] or receipt["state"] != "queued"
            or receipt != job["receipt"] or _public(receipt)["state"] == "expired"):
        return 1
    receipt = _record(root, receipt, "checking", "The independent worker is verifying the approved update.", accepted=True)
    environment = job["environment"]
    bindir = Path(environment["OMARCHY_PATH"]) / "bin"
    try:
        with _lock(root.parent / ".plugin-update.lock"):
            # Backend uses its usual safe environment for sourceKey continuity;
            # only the native mutator receives the stricter Git environment.
            if _runtime(backend) != environment:
                raise Refused("The original Omarchy runtime changed before the update.")
            binding = _validate(backend, receipt, store, job["binding"])
            _invalidate(backend, store)
            receipt = _record(root, receipt, "updating", "Updating Outfit through the native plugin updater.")
            failed = False
            try:
                backend.update_reviewed_plugin(
                    {"id": APP_ID, "enabled": binding["enabled"], "barSection": binding["barSection"],
                     "barSectionKnown": True},
                    {**binding, "installedRevision": receipt["expectedInstalledRevision"]},
                    receipt["expectedRevision"], binding["expectedVersion"],
                )
            except (OSError, ValueError, TimeoutError, subprocess.TimeoutExpired):
                failed = True
            observed, local = _observed(backend)
            if (failed or not local or local["state"] != "ready"
                    or local["repository"] != binding["repository"]
                    or local["enabled"] != binding["enabled"]
                    or local["barSection"] != binding["barSection"]
                    or observed["installedRevision"] != receipt["expectedRevision"]
                    or observed["installedVersion"] != binding["expectedVersion"]):
                _record(root, receipt, "failed", "The native update or resulting revision/manifest was not verified; shell restart was skipped.", **observed)
                return 1
            # Outcome is durable BEFORE any shell-disrupting command.
            receipt = _record(root, receipt, "verified", "The approved Outfit revision and manifest are installed.", verified=True, **observed)
            receipt = _record(root, receipt, "restarting", "Outfit updated; restarting the Omarchy shell.")
            try:
                _restart_runtime(environment)
                _command([str(bindir / "omarchy-restart-shell")], environment, 45, 4096)
            except (OSError, ValueError, TimeoutError, subprocess.TimeoutExpired):
                _record(root, receipt, "restart-failed", "Outfit updated, but shell restart was not confirmed. Reopen Outfit manually.")
                return 1
            # Only this explicit update-and-reopen transaction authorizes an
            # open. Status polling/expired receipts never resurrect closed UI.
            if not receipt["reopenRequested"]:
                _record(root, receipt, "completed", "Outfit updated; the editor remains closed.")
                return 0
            receipt = _record(root, receipt, "reopening", "Outfit updated; waiting for its shell service.")
            ready = False
            for attempt in range(6):
                try:
                    raw = _command([str(bindir / "omarchy-shell"), APP_ID, "status"], environment, 4, 16 * 1024)
                    state = json.loads(raw)
                    if isinstance(state, dict) and type(state.get("opened")) is bool:
                        ready = True
                        break
                except (OSError, ValueError, TimeoutError, subprocess.TimeoutExpired):
                    pass
                if attempt < 5:
                    time.sleep(0.5)
            if ready:
                try:
                    raw = _command([str(bindir / "omarchy-shell"), "shell", "summon", APP_ID,
                                    _json(receipt["resumePayload"], 8 * 1024).decode()], environment, 4, 4096)
                    if raw.strip() == b"ok":
                        _record(root, receipt, "completed", "Outfit updated; Omarchy accepted the reopen request.", reopenState="accepted")
                        return 0
                except (OSError, ValueError, TimeoutError, subprocess.TimeoutExpired):
                    pass
            # Never retry a possibly delivered summon: the user may have closed
            # it, and an IPC timeout does not establish that it was undelivered.
            _record(root, receipt, "reopen-failed", "Outfit updated, but reopen was not confirmed. Open Outfit manually.", reopenState="unconfirmed")
            return 1
    except (OSError, ValueError, KeyError, TypeError, TimeoutError, subprocess.TimeoutExpired):
        _record(root, receipt, "failed", "The worker could not safely complete the approved update; check updates again.")
        return 1


def _worker_main():
    job_dir = _private_dir(Path(__file__).absolute().parent)
    if not TOKEN.fullmatch(job_dir.name) or job_dir.parent.name != "self-update":
        return 1
    root = _private_dir(job_dir.parent)
    job = json.loads(_read(job_dir / "job.json"))
    if job.get("schema") != 1 or job.get("operationId") != job_dir.name:
        return 1
    # No environment inherited from systemd's manager may select code/commands.
    environment = job["environment"]
    allowed = set(ENV_KEYS) | {"OMARCHY_PATH", "PATH", "OMARCHY_SHELL_IPC_TIMEOUT", "SSH_ASKPASS"}
    if (not isinstance(environment, dict) or any(not isinstance(k, str) or not isinstance(v, str)
            or (k not in allowed and not k.startswith("GIT_")) for k, v in environment.items())):
        return 1
    os.environ.clear()
    os.environ.update(environment)
    source = _read(job_dir / "outfit.py", MAX_SOURCE)
    if hashlib.sha256(source).hexdigest() != job["backendDigest"]:
        return 1
    backend = types.ModuleType("outfit_self_update_backend")
    backend.__file__ = str(job_dir / "outfit.py")
    exec(compile(source, backend.__file__, "exec"), backend.__dict__)
    store = backend.Store(_private_dir(root.parent))
    try:
        with _lock(root / "worker.lock", wait=12):
            return _work(backend, store, root, job)
    finally:
        store.close()


if __name__ == "__main__":
    try:
        sys.exit(_worker_main() if sys.argv[1:] == ["--worker"] else 2)
    except Exception:
        # A killed/unbootable worker is observable as an expired pending receipt;
        # never print exception text, environment, native output or credentials.
        sys.exit(1)
