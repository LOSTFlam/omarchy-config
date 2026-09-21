#!/usr/bin/env python3
"""Explicit, reversible Outfit 0.2 identity migration; see IDENTITY_MIGRATION.md."""
from __future__ import annotations

import argparse
import copy
from contextlib import closing, contextmanager
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time

OLD = "io.github.ctl0v0.omafit"
NEW = "io.github.ctl0v0.outfit"
OFFICIAL_REPO = "https://github.com/ctl0v0/outfit.git"
PRIVATE = {"preferences.json", "interests.json", "quick-setup.json"}
PUBLIC = {"catalog.json", "readmes.json", "engagement.json", "readme-search.sqlite"}
MEDIA = re.compile(r"(?:preview-[0-3](?:-[0-9a-f]{12})?|thumb-[0-9a-f]{32}-[0-9a-f]{16})\.(?:png|jpg|webp|gif)")
ROOT = Path(__file__).resolve().parents[1]


def present(path):
    return path.exists() or path.is_symlink()


def safe_path(path):
    """Reject redirects and writable-by-other-user ancestors of owned state."""
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError(f"An absolute, normalized path is required: {path}")
    for part in reversed((path, *path.parents)):
        if not present(part):
            continue
        info = part.lstat()
        if stat.S_ISLNK(info.st_mode):
            raise ValueError(f"Symlink in state path: {part}")
        # /tmp is allowed as an ancestor for isolated tests, not a state root.
        if info.st_uid not in {0, os.getuid()} or (info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX):
            raise ValueError(f"Unsafe ownership or permissions: {part}")


def read_owned(path, limit=2 * 1024 * 1024):
    safe_path(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > limit:
            raise ValueError(f"Unsafe or oversized file: {path}")
        data = stream.read(limit + 1)
        if len(data) > limit:
            raise ValueError(f"Oversized file: {path}")
        return data


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def decode(raw):
    return json.loads(raw, object_pairs_hook=unique_keys)


def encode(value):
    return (json.dumps(value, indent=2, ensure_ascii=True) + "\n").encode()


def atomic(path, body, mode=0o600, expected=None):
    safe_path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix=".outfit-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(body)
            os.fchmod(stream.fileno(), mode)
            stream.flush()
            os.fsync(stream.fileno())
        if expected is not None and read_owned(path) != expected:
            raise ValueError("Shell config changed concurrently; refusing to overwrite it.")
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        Path(name).unlink(missing_ok=True)


def transform(raw):
    """Only supported registration slots change; arbitrary settings stay opaque."""
    original = decode(raw)
    if not isinstance(original, dict) or type(original.get("version")) is not int or original["version"] != 1:
        raise ValueError("Unsupported shell config version; config preserved.")
    final, paused = copy.deepcopy(original), copy.deepcopy(original)
    identities = []
    for document, pause in ((final, False), (paused, True)):
        plugins = document.get("plugins", [])
        bar = document.get("bar", {})
        if not isinstance(bar, dict) or not isinstance(plugins, list):
            raise ValueError("Unsupported shell config shape; config preserved.")
        layout = bar.get("layout", {})
        if not isinstance(layout, dict) or any(key not in {"left", "center", "right"} for key in layout):
            raise ValueError("Unsupported bar layout; config preserved.")
        slots = [(document, "plugins")] if "plugins" in document else []
        slots += [(layout, key) for key in layout]
        for owner, key in slots:
            if not isinstance(owner[key], list):
                raise ValueError("Unsupported plugin entries; config preserved.")
            result = []
            for entry in owner[key]:
                identity = entry.get("id") if isinstance(entry, dict) else entry
                if not isinstance(identity, str):
                    raise ValueError("Unsupported plugin entry; config preserved.")
                if not pause:
                    identities.append(identity)
                if pause and identity in {OLD, NEW}:
                    continue
                if identity == OLD:
                    entry = {**entry, "id": NEW} if isinstance(entry, dict) else NEW
                result.append(entry)
            owner[key] = result
        if not pause and bar.get("centerAnchor") == OLD:
            bar["centerAnchor"] = NEW
    if OLD in identities and NEW in identities:
        raise ValueError("Both identities have config entries; resolve the collision before migrating.")
    return final, paused, identities


def command(argv, env, timeout=8, maximum=256 * 1024):
    """Bound output and elapsed time, including a wedged native command's children."""
    process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, env=env, start_new_session=True)
    chunks = {process.stdout: bytearray(), process.stderr: bytearray()}
    deadline = time.monotonic() + timeout
    try:
        with selectors.DefaultSelector() as poll:
            for stream in chunks:
                os.set_blocking(stream.fileno(), False)
                poll.register(stream, selectors.EVENT_READ)
            while poll.get_map():
                if time.monotonic() >= deadline:
                    raise ValueError("Native command timed out; migration stopped.")
                for key, _ in poll.select(0.05):
                    data = os.read(key.fileobj.fileno(), 65536)
                    if not data:
                        poll.unregister(key.fileobj)
                    else:
                        chunks[key.fileobj].extend(data)
                        if sum(map(len, chunks.values())) > maximum:
                            raise ValueError("Native command exceeded output limit.")
            code = process.wait(timeout=max(0.01, deadline - time.monotonic()))
        return code, *(bytes(chunks[stream]).decode("utf-8", "strict").strip() for stream in chunks)
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        for stream in chunks:
            stream.close()


class Native:
    def __init__(self):
        base = Path(os.environ.get("OMARCHY_PATH", ""))
        if not base.is_absolute():
            raise ValueError("OMARCHY_PATH must identify the trusted native Omarchy installation.")
        self.bin = base.resolve() / "bin"
        for name in ("omarchy-shell", "omarchy-plugin-add", "omarchy-plugin-validate"):
            path = self.bin / name
            safe_path(path)
            if not path.is_file() or not os.access(path, os.X_OK):
                raise ValueError(f"Missing native command: {path}")
        self.env = dict(os.environ, PATH=f"{self.bin}:/usr/bin:/bin", OMARCHY_PATH=str(base.resolve()),
                        OMARCHY_SHELL_IPC_TIMEOUT="2s", GIT_TERMINAL_PROMPT="0")

    def call(self, name, *args, timeout=8):
        return command([str(self.bin / name), *map(str, args)], self.env, timeout)

    def shell(self, method, *args):
        code, out, err = self.call("omarchy-shell", "shell", method, *args)
        if code:
            raise ValueError(f"Native shell {method} failed: {err or out}")
        return out

    def status(self, identity):
        code, out, err = self.call("omarchy-shell", identity, "status")
        # Missing target is safe; timeout, absent shell and unknown status are not.
        if (err or out) == "Target not found.":
            return None
        if code:
            raise ValueError(f"Cannot check {identity}: {err or out}")
        result = decode(out)
        if not isinstance(result, dict):
            raise ValueError("Unrecognized Outfit status.")
        return result

    def validate(self, source):
        code, out, err = self.call("omarchy-plugin-validate", source, timeout=30)
        if code:
            raise ValueError(f"Native plugin validation failed: {err or out}")

    def add(self):
        code, out, err = self.call("omarchy-plugin-add", OFFICIAL_REPO, "--yes", timeout=120)
        if code:
            raise ValueError(f"Native plugin add failed: {err or out}")

    def reload(self, document):
        self.shell("reloadConfig")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if decode(self.shell("listShellConfig")) == document:
                return
            time.sleep(0.1)
        raise ValueError("Shell did not acknowledge the exact configuration.")

    def stopped(self):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if all(self.status(identity) is None for identity in (OLD, NEW)):
                return
            time.sleep(0.1)
        raise ValueError("Outfit service did not stop; data migration refused.")

    def ready(self, enabled, running=None):
        self.shell("reconcilePlugins")
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            rows = decode(self.shell("listPlugins"))
            if isinstance(rows, list):
                matches = [row for row in rows if row.get("id") == NEW]
                if len(matches) == 1 and matches[0].get("enabled") is enabled and not any(row.get("id") == OLD for row in rows):
                    if not (enabled if running is None else running) or self.status(NEW) is not None:
                        return
            time.sleep(0.1)
        raise ValueError("New Outfit registration/runtime could not be validated.")

    def verify_existing(self, document, enabled, running):
        """Read-only verification, independent of optional hardware analysis."""
        if decode(self.shell("listShellConfig")) != document:
            raise ValueError("Native shell configuration differs from the completed mapping.")
        rows = decode(self.shell("listPlugins"))
        if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
            raise ValueError("Unrecognized native plugin inventory.")
        matches = [row for row in rows if row.get("id") == NEW]
        if (len(matches) != 1 or matches[0].get("enabled") is not enabled
                or any(row.get("id") == OLD for row in rows)):
            raise ValueError("Native registration differs from the completed mapping.")
        if self.status(OLD) is not None:
            raise ValueError("Legacy Outfit service is still present.")
        status = self.status(NEW)
        if status is None:
            if running:
                raise ValueError("New Outfit service is missing.")
        elif any(type(status.get(key)) is not bool
                 for key in ("opened", "batchRunning", "interestsDirty", "ready")):
            raise ValueError("Unrecognized Outfit status.")


def idle(status):
    if status is None:
        return
    # 6db2b90 has no independent Settings-dirty flag: require a closed panel.
    required = {"opened": False, "batchRunning": False, "interestsDirty": False, "ready": True}
    if any(status.get(key) is not value for key, value in required.items()):
        raise ValueError("Save/discard drafts, finish pending work, close Outfit, then retry.")
    if any(status.get(key) for key in ("densitySavePending", "queryBusy", "backgroundBusy", "indexingBusy",
                                      "mutationBusy", "mutationActive")):
        raise ValueError("Outfit still has pending work; retry when idle.")
    recovery = status.get("panelRecovery", {})
    if not isinstance(recovery, dict):
        raise ValueError("Unrecognized Outfit recovery state.")
    if recovery.get("armed") and not recovery.get("suppressed"):
        raise ValueError("Outfit panel recovery is armed; close the panel before migrating.")
    items = status.get("batchItems", [])
    if not isinstance(items, list) or any(not isinstance(row, dict) for row in items):
        raise ValueError("Unrecognized Outfit batch state.")
    if any(row.get("status") in {"running", "checking", "installing", "enabling", "removing"} for row in items):
        raise ValueError("Outfit has an unfinished operation; resolve it before migrating.")


def manifest(source, accepted=(NEW,)):
    document = decode(read_owned(source / "manifest.json"))
    if not isinstance(document, dict) or document.get("schemaVersion") != 1 or document.get("id") not in accepted:
        raise ValueError("Unexpected source manifest identity/schema.")
    return document


def copy_data(config, cache):
    copied = []
    for base, private in ((config, True), (cache, False)):
        source, target = base / OLD, base / NEW
        safe_path(source)
        safe_path(target)
        if not source.exists():
            continue
        for path in sorted(source.iterdir()):
            if path.name not in (PRIVATE if private else PUBLIC) and (private or not MEDIA.fullmatch(path.name)):
                continue  # Raw hardware/profile memory, locks and unknown future files never migrate.
            destination = target / path.name
            safe_path(destination)
            if present(destination):
                continue  # An existing new file always wins, including a future schema.
            raw = read_owned(path, 512 * 1024 * 1024)
            target.mkdir(parents=True, exist_ok=True, mode=0o700)
            fd, name = tempfile.mkstemp(prefix=".identity-", dir=target)
            os.close(fd)
            stage = Path(name)
            try:
                if path.name == "readme-search.sqlite":
                    for suffix in ("-wal", "-shm", "-journal"):
                        if present(Path(str(path) + suffix)):
                            read_owned(Path(str(path) + suffix), 512 * 1024 * 1024)
                    deadline = time.monotonic() + 10
                    def progress(_status, _remaining, _total):
                        if time.monotonic() > deadline:
                            raise ValueError("SQLite backup timed out.")
                    with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=1)) as old_db:
                        with closing(sqlite3.connect(stage)) as new_db:
                            old_db.backup(new_db, pages=128, progress=progress, sleep=0.01)
                            if new_db.execute("PRAGMA quick_check").fetchone() != ("ok",):
                                raise ValueError("SQLite backup validation failed.")
                else:
                    stage.write_bytes(raw)
                stage.chmod(0o600)
                with stage.open("rb") as stream:
                    os.fsync(stream.fileno())
                try:
                    os.link(stage, destination)  # Atomic no-clobber publication.
                    copied.append(str(destination))
                except FileExistsError:
                    pass
            finally:
                stage.unlink(missing_ok=True)
    return copied


def launcher_module():
    # Load only the helper's sibling, never a module from --source or cwd.
    spec = importlib.util.spec_from_file_location("outfit_identity_launcher", ROOT / "scripts/launcher.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Migration:
    def __init__(self, config, cache, data, native, shell_config=None):
        self.config, self.cache, self.data, self.native = config, cache, data, native
        # Native Omarchy registration is rooted at HOME/.config, independently
        # of Outfit's XDG private preferences/cache directories.
        shell_config = config if shell_config is None else shell_config
        self.shell = shell_config / "omarchy/shell.json"
        self.plugins = shell_config / "omarchy/plugins"
        self.old, self.new = self.plugins / OLD, self.plugins / NEW

    @contextmanager
    def lock(self):
        path = self.shell.parent / ".outfit-identity.lock"
        safe_path(path)
        fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                raise ValueError("Unsafe identity migration lock.")
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            yield
        finally:
            os.close(fd)

    def plan(self, source=None, official=False, *, check_idle=True):
        raw = read_owned(self.shell)
        final, paused, ids = transform(raw)
        safe_path(self.plugins)
        for root in (self.config / NEW, self.cache / NEW, self.data):
            safe_path(root)
        if present(self.old):
            old_manifest = manifest(self.old.resolve(), (OLD, NEW))
            if official and old_manifest["id"] == NEW and not present(self.new):
                raise ValueError("Old folder already has the new manifest; use --source with that installed path.")
        if present(self.new):
            manifest(self.new.resolve())
        if source:
            source = source.resolve(strict=True)
            manifest(source)
        elif not official and not present(self.new):
            raise ValueError("Choose --source NEW_CHECKOUT or --official.")
        if official and self.shell.parent != Path.home() / ".config/omarchy":
            raise ValueError("Native add uses ~/.config; --official requires that config root.")
        if check_idle:
            for identity in (OLD, NEW):
                idle(self.native.status(identity))
        launcher_module().preflight(self.data)
        bar_ids = [entry.get("id") if isinstance(entry, dict) else entry
                   for entries in final.get("bar", {}).get("layout", {}).values() for entry in entries]
        return {"oldId": OLD, "newId": NEW, "source": str(source) if source else OFFICIAL_REPO,
                "sourceMode": "local" if source else "official", "config": str(self.shell),
                "configMode": oct(stat.S_IMODE(self.shell.stat().st_mode)),
                "oldInstalled": present(self.old), "newInstalled": present(self.new),
                "enabled": NEW in bar_ids, "serviceEnabled": OLD in ids or NEW in ids, "oldRegistered": OLD in ids,
                "dataPolicy": "copy allowlisted missing files only; retain all legacy data",
                "final": final, "paused": paused, "raw": raw}

    def rollback(self, backup):
        backup = Path(backup)
        if backup.parent != self.shell.parent or not backup.name.startswith(".outfit-identity-"):
            raise ValueError("Rollback must name an Outfit backup beside shell.json.")
        state = decode(read_owned(backup / "mapping.json"))
        if (not isinstance(state, dict) or state.get("phase") not in {"applying", "complete", "rolled-back"}
                or type(state.get("mode")) is not int or state["mode"] & ~0o777
                or type(state.get("newExisted")) is not bool):
            raise ValueError("Unsupported migration backup; preserved for manual recovery.")
        if state.get("phase") == "rolled-back":
            return
        if state.get("phase") == "complete":
            raise ValueError("Completed migrations are retained as backups, not automatic downgrades.")
        for identity in (OLD, NEW):
            idle(self.native.status(identity))
        current = read_owned(self.shell)
        original, paused, final = (read_owned(backup / name) for name in ("original.json", "paused.json", "final.json"))
        if current not in (original, paused, final):
            raise ValueError(f"Config changed outside migration; preserve and manually reconcile {backup}")
        atomic(self.shell, paused, state["mode"], current)
        self.native.reload(decode(paused))
        self.native.stopped()
        if not state["newExisted"] and present(self.new):
            os.rename(self.new, backup / "new-registration")
        if state.get("oldExisted") is False and present(self.old) and not present(backup / "legacy-registration"):
            # An unreleased public HEAD may have added OLD when no old folder
            # existed. Retain that failed add outside discovery as well.
            os.rename(self.old, backup / "unexpected-legacy-registration")
        if present(backup / "legacy-registration"):
            if present(self.old):
                raise ValueError("Legacy registration reappeared; refusing to overwrite it.")
            os.rename(backup / "legacy-registration", self.old)
        atomic(self.shell, original, state["mode"], paused)
        self.native.reload(decode(original))
        self.native.shell("reconcilePlugins")
        state["phase"] = "rolled-back"
        atomic(backup / "mapping.json", encode(state))

    def apply(self, source=None, official=False):
        with self.lock():
            return self._apply(source, official)

    def completed_record(self, state):
        if (state.get("phase") != "complete" or state.get("oldId") != OLD or state.get("newId") != NEW
                or not isinstance(state.get("source"), str) or not isinstance(state.get("copied"), list)):
            return False
        for name in state["copied"]:
            if not isinstance(name, str):
                return False
            path = Path(name)
            private = path.parent == self.config / NEW and path.name in PRIVATE
            public = path.parent == self.cache / NEW and (path.name in PUBLIC or MEDIA.fullmatch(path.name))
            if not (private or public):
                return False
            safe_path(path)
            if not path.exists():
                return False
            info = path.stat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                raise ValueError(f"Unsafe migrated data file: {path}")
        return True

    def _apply(self, source=None, official=False):
        # A hard interruption is not mistaken for a completed migration.
        completed = False
        for backup in self.shell.parent.glob(".outfit-identity-*"):
            if (backup / "mapping.json").exists():
                state = decode(read_owned(backup / "mapping.json"))
                if not isinstance(state, dict):
                    raise ValueError("Unrecognized migration record.")
                phase = state.get("phase")
                if phase == "applying":
                    raise ValueError(f"Interrupted migration: run --rollback {backup} --apply first.")
                completed = completed or self.completed_record(state)
        plan = self.plan(source, official, check_idle=False)
        if (completed and not plan["oldInstalled"] and not plan["oldRegistered"] and plan["newInstalled"]
                and decode(plan["raw"]) == plan["final"]):
            if source and source.resolve(strict=True) != self.new.resolve():
                raise ValueError("Requested source differs from the installed new registration.")
            self.native.validate(self.new.resolve())
            self.native.verify_existing(plan["final"], plan["enabled"], plan["serviceEnabled"])
            return {"result": "already-migrated"}
        # Every path which can alter registration, stores or launchers still
        # requires the original strict idle check, even if NEW is installed.
        for identity in (OLD, NEW):
            idle(self.native.status(identity))
        launcher = launcher_module()
        if source:
            source = source.resolve(strict=True)
            self.native.validate(source)
        mode = stat.S_IMODE(self.shell.stat().st_mode)
        backup = Path(tempfile.mkdtemp(prefix=".outfit-identity-", dir=self.shell.parent))
        state = {"phase": "applying", "oldId": OLD, "newId": NEW, "mode": mode,
                 "oldExisted": plan["oldInstalled"], "newExisted": plan["newInstalled"], "source": plan["source"]}
        paused, final = encode(plan["paused"]), encode(plan["final"])
        for name, raw in (("original.json", plan["raw"]), ("paused.json", paused), ("final.json", final)):
            atomic(backup / name, raw)
        atomic(backup / "mapping.json", encode(state))
        try:
            atomic(self.shell, paused, mode, plan["raw"])
            self.native.reload(plan["paused"])
            self.native.stopped()
            # Native add defaults to disabled. Do it while the original old-ID
            # directory is still registered: an unreleased old-ID public HEAD
            # then fails as a duplicate instead of displacing the old install.
            # Pausing first also covers orphaned NEW config entries: add must
            # never start NEW before its data is copied.
            if not source and not present(self.new):
                self.native.add()
                manifest(self.new.resolve())
                self.native.validate(self.new.resolve())
            # Resolve a normal old-folder checkout before archiving it. A developer
            # symlink's external checkout is never moved or edited.
            source_in_old = source and present(self.old) and not self.old.is_symlink() and source == self.old.resolve()
            if present(self.old):
                if not self.old.is_symlink() and ROOT == self.old.resolve():
                    # The running helper may itself live in the renamed folder.
                    # Keep using its already loaded launcher and archived assets.
                    launcher.ASSETS = backup / "legacy-registration/assets"
                os.rename(self.old, backup / "legacy-registration")
            self.plugins.mkdir(parents=True, exist_ok=True, mode=0o700)
            if not present(self.new):
                if source_in_old:
                    shutil.copytree(backup / "legacy-registration", self.new, symlinks=True)
                elif source:
                    self.new.symlink_to(source, target_is_directory=True)
                else:
                    raise ValueError("Native add did not retain the new registration.")
            manifest(self.new.resolve())
            self.native.validate(self.new.resolve())
            copied = copy_data(self.config, self.cache)
            state["copied"] = copied
            atomic(backup / "mapping.json", encode(state))
            atomic(self.shell, final, mode, paused)
            self.native.reload(plan["final"])
            self.native.ready(plan["enabled"], plan["serviceEnabled"])
            # Legacy launchers are removed only after the new runtime is validated.
            launcher.sync(self.data)
            state["phase"] = "complete"
            atomic(backup / "mapping.json", encode(state))
            return {"result": "migrated", "backup": str(backup), "copied": copied}
        except (Exception, KeyboardInterrupt) as error:
            try:
                self.rollback(backup)
            except (Exception, KeyboardInterrupt) as recovery:
                raise ValueError(f"Migration failed: {error}; rollback needs attention: {recovery}; backup: {backup}") from error
            raise ValueError(f"Migration failed and registration rolled back: {error}; backup: {backup}") from error


def xdg(name, fallback):
    path = Path(os.environ.get(name, ""))
    return path if path.is_absolute() else Path.home() / fallback


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    gate = parser.add_mutually_exclusive_group(required=True)
    gate.add_argument("--dry-run", action="store_true")
    gate.add_argument("--apply", action="store_true")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--source", type=Path, help="Explicitly trusted local new-ID checkout (linked, not executed)")
    mode.add_argument("--official", action="store_true", help="Native add from the fixed public Outfit repository")
    mode.add_argument("--rollback", type=Path, help="Recover an interrupted migration using its printed backup")
    args = parser.parse_args(argv)
    try:
        migration = Migration(xdg("XDG_CONFIG_HOME", ".config"), xdg("XDG_CACHE_HOME", ".cache"),
                              xdg("XDG_DATA_HOME", ".local/share"), Native(), Path.home() / ".config")
        if args.rollback:
            if not args.apply:
                print(json.dumps({"rollback": str(args.rollback), "applyRequired": True}))
                return 0
            with migration.lock():
                migration.rollback(args.rollback)
            result = {"result": "rolled-back", "backup": str(args.rollback)}
        elif args.apply:
            result = migration.apply(args.source, args.official)
        else:
            result = migration.plan(args.source, args.official)
            result.pop("raw")
            result.pop("paused")
            result["dryRun"] = True
        print(json.dumps(result, indent=2))
        return 0
    except (OSError, ValueError, sqlite3.Error, subprocess.SubprocessError) as error:
        print(f"Outfit identity migration: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
