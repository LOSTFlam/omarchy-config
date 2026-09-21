"""Identity migration uses isolated files and a simulated host, never desktop IPC."""
from contextlib import closing
import copy
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from scripts import launcher, migrate_identity as migration

OLD, NEW = migration.OLD, migration.NEW
IDLE = {"opened": False, "batchRunning": False, "interestsDirty": False, "ready": True}


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(migration.encode(value))
    path.chmod(0o600)


class Host:
    def __init__(self):
        self.statuses = {OLD: dict(IDLE), NEW: None}
        self.events = []
        self.fail_ready = False
        self.fail_stop = False
        self.on_ready = lambda: None

    def status(self, identity):
        return self.statuses[identity]

    def validate(self, source):
        migration.manifest(source)
        self.events.append("validate")

    def reload(self, document):
        self.events.append("reload")
        self.document = copy.deepcopy(document)
        entries = document.get("plugins", []) + [entry for section in document.get("bar", {}).get("layout", {}).values() for entry in section]
        identities = [entry.get("id") if isinstance(entry, dict) else entry for entry in entries]
        for identity in (OLD, NEW):
            self.statuses[identity] = dict(IDLE) if identity in identities else None

    def stopped(self):
        self.events.append("stopped")
        if self.fail_stop:
            raise ValueError("simulated stop failure")
        if any(self.statuses.values()):
            raise AssertionError("copy must wait for both services to stop")

    def ready(self, enabled, running=None):
        self.events.append("ready")
        self.on_ready()
        if self.fail_ready:
            self.fail_ready = False
            raise ValueError("simulated new runtime failure")

    def shell(self, method):
        self.events.append(method)
        if method == "listShellConfig":
            return json.dumps(self.document)
        if method == "listPlugins":
            entries = [entry for section in self.document.get("bar", {}).get("layout", {}).values() for entry in section]
            ids = [entry.get("id") if isinstance(entry, dict) else entry for entry in entries]
            return json.dumps([{"id": NEW, "enabled": NEW in ids}])

    def verify_existing(self, document, enabled, running):
        migration.Native.verify_existing(self, document, enabled, running)


class IdentityMigrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.config, self.cache, self.data = [self.root / name for name in ("config", "cache", "data")]
        self.host = Host()
        self.m = migration.Migration(self.config, self.cache, self.data, self.host)
        self.source = self.root / "new checkout ; no execution"
        write(self.source / "manifest.json", {"schemaVersion": 1, "id": NEW, "version": "0.2.0"})
        write(self.m.old / "manifest.json", {"schemaVersion": 1, "id": OLD, "version": "0.1.0"})
        self.document = {"version": 1, "plugins": [{"id": "other.service", "token": "keep"}],
                         "bar": {"position": "left", "centerAnchor": OLD, "layout": {
                             "left": ["other.widget"], "center": [], "right": [
                                 {"id": OLD, "inline": {"unknown": [1, 2]}, "width": 31}, "another.widget"]}},
                         "future": {"id": OLD, "keep": "unrelated opaque setting"}}
        write(self.m.shell, self.document)
        self.m.shell.chmod(0o640)
        self.original = self.m.shell.read_bytes()

    def seed_data(self):
        for name in migration.PRIVATE:
            write(self.config / OLD / name, {"schema": 991, "future": name})
        for name in ("catalog.json", "readmes.json", "engagement.json"):
            write(self.cache / OLD / name, {"public": name})
        for name in ("raw-profile.json", "hardware.json", "future-secret.json"):
            write(self.cache / OLD / name, {"private": "must never migrate"})

    def test_plan_is_read_only_and_preserves_opaque_fields_and_target_mode(self):
        before = sorted(str(path.relative_to(self.root)) for path in self.root.rglob("*"))
        plan = self.m.plan(self.source)
        self.assertEqual(plan["configMode"], "0o640")
        self.assertEqual(self.m.shell.read_bytes(), self.original)
        self.assertEqual(before, sorted(str(path.relative_to(self.root)) for path in self.root.rglob("*")))
        expected = copy.deepcopy(self.document)
        expected["bar"]["centerAnchor"] = NEW
        expected["bar"]["layout"]["right"][0]["id"] = NEW
        self.assertEqual(plan["final"], expected)
        self.assertEqual(self.host.events, [])

    def test_public_old_install_migrates_data_before_runtime_then_reruns(self):
        self.seed_data()
        def validate_copies():
            for name in migration.PRIVATE:
                self.assertEqual((self.config / NEW / name).read_bytes(), (self.config / OLD / name).read_bytes())
            self.assertIn("stopped", self.host.events)
        self.host.on_ready = validate_copies
        result = self.m.apply(self.source)
        backup = Path(result["backup"])
        self.assertEqual(migration.decode((backup / "legacy-registration/manifest.json").read_bytes())["id"], OLD)
        self.assertFalse(self.m.old.exists())
        self.assertEqual(self.m.new.resolve(), self.source)
        self.assertEqual(self.m.shell.stat().st_mode & 0o777, 0o640)
        self.assertEqual((backup / "original.json").read_bytes(), self.original)
        self.assertEqual((backup / "original.json").stat().st_mode & 0o777, 0o600)
        self.assertFalse((self.cache / NEW / "raw-profile.json").exists())
        before = self.m.shell.read_bytes()
        self.assertEqual(self.m.apply(self.source)["result"], "already-migrated")
        self.assertEqual(before, self.m.shell.read_bytes())

    def snapshot(self):
        return {str(path.relative_to(self.root)): (os.readlink(path) if path.is_symlink() else
                (path.read_bytes(), path.stat().st_mode, path.stat().st_mtime_ns))
                for path in self.root.rglob("*") if path.is_symlink() or path.is_file()}

    def test_completed_closed_unanalyzed_rerun_is_read_only_even_during_metadata_query(self):
        self.seed_data()
        self.m.apply(self.source)
        # Existing new data may have changed since migration and must win.
        write(self.config / NEW / "preferences.json", {"user": "new settings"})
        write(self.cache / NEW / "catalog.json", {"newer": "public metadata"})
        before = self.snapshot()
        for query_busy in (False, True):
            with self.subTest(queryBusy=query_busy):
                self.host.statuses[NEW] = {**IDLE, "ready": False, "queryBusy": query_busy}
                self.host.events.clear()
                with mock.patch.object(migration, "copy_data", side_effect=AssertionError("no copying")), \
                     mock.patch.object(migration, "launcher_module", return_value=launcher), \
                     mock.patch.object(launcher, "sync", side_effect=AssertionError("no launcher writes")):
                    self.assertEqual(self.m.apply(self.source), {"result": "already-migrated"})
                self.assertEqual(self.host.events, ["validate", "listShellConfig", "listPlugins"])
                self.assertEqual(self.snapshot(), before)

    def test_unmigrated_new_registration_never_skips_missing_data_or_actual_idle_gate(self):
        self.seed_data()
        shutil.rmtree(self.m.old)
        self.m.new.symlink_to(self.source)
        document = migration.transform(self.original)[0]
        write(self.m.shell, document)
        self.host.reload(document)
        write(self.config / NEW / "preferences.json", {"user": "retain"})
        before = self.snapshot()
        for changes in ({}, {"queryBusy": True}, {"batchRunning": True},
                        {"mutationBusy": True}, {"interestsDirty": True}, {"opened": True}):
            with self.subTest(changes=changes):
                self.host.statuses[NEW] = {**IDLE, "ready": False, **changes}
                with self.assertRaisesRegex(ValueError, "Save/discard drafts"):
                    self.m.apply(self.source)
                self.assertFalse((self.config / NEW / "interests.json").exists())
                self.assertFalse((self.cache / NEW).exists())
                after = self.snapshot()
                after.pop("config/omarchy/.outfit-identity.lock", None)
                self.assertEqual(after, before)
        self.host.statuses[NEW] = dict(IDLE)
        self.assertEqual(self.m.apply(self.source)["result"], "migrated")
        self.assertEqual(migration.decode((self.config / NEW / "preferences.json").read_bytes()), {"user": "retain"})
        self.assertTrue((self.config / NEW / "interests.json").exists())
        self.assertTrue((self.cache / NEW / "catalog.json").exists())

    def test_completed_record_with_missing_data_cannot_bypass_actual_migration_gate(self):
        self.seed_data()
        self.m.apply(self.source)
        (self.config / NEW / "interests.json").unlink()
        self.host.statuses[NEW] = {**IDLE, "ready": False, "mutationBusy": True}
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "Save/discard drafts"):
            self.m.apply(self.source)
        self.assertEqual(self.snapshot(), before)
        self.host.statuses[NEW] = dict(IDLE)
        self.assertEqual(self.m.apply(self.source)["result"], "migrated")
        self.assertTrue((self.config / NEW / "interests.json").exists())

    def test_completed_rerun_rejects_different_source_and_preserves_files(self):
        self.m.apply(self.source)
        other = self.root / "another-source"
        write(other / "manifest.json", {"schemaVersion": 1, "id": NEW})
        self.host.statuses[NEW] = {**IDLE, "ready": False}
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "source differs"):
            self.m.apply(other)
        self.assertEqual(self.snapshot(), before)

    def test_completed_rerun_rejects_ambiguous_status_or_canonical_mapping(self):
        self.seed_data()
        self.m.apply(self.source)
        before = self.snapshot()
        for failure in (ValueError("IPC not responding"), TimeoutError("IPC timeout")):
            for target in (OLD, NEW):
                def status(identity):
                    if identity == target:
                        raise failure
                    return None if identity == OLD else {**IDLE, "ready": False}
                with self.subTest(failure=failure, target=target), \
                     mock.patch.object(self.host, "status", side_effect=status):
                    with self.assertRaises(type(failure)):
                        self.m.apply(self.source)
                    self.assertEqual(self.snapshot(), before)
        for status in (None, {}, {**IDLE, "ready": "false"}):
            self.host.statuses[NEW] = status
            with self.subTest(status=status), self.assertRaises(ValueError):
                self.m.apply(self.source)
        self.host.statuses[NEW] = {**IDLE, "ready": False}
        self.host.document = {"version": 1, "plugins": []}
        with self.assertRaisesRegex(ValueError, "configuration differs"):
            self.m.apply(self.source)
        self.assertEqual(self.snapshot(), before)

    def test_incomplete_completed_marker_cannot_claim_fresh_install_migrated(self):
        shutil.rmtree(self.m.old)
        self.m.new.symlink_to(self.source)
        write(self.m.shell, migration.transform(self.original)[0])
        write(self.m.shell.parent / ".outfit-identity-incomplete/mapping.json", {"phase": "complete"})
        self.host.statuses = {OLD: None, NEW: {**IDLE, "ready": False}}
        with self.assertRaisesRegex(ValueError, "Save/discard drafts"):
            self.m.apply(self.source)

    def test_local_legacy_symlink_is_archived_without_editing_its_checkout(self):
        old_source = self.root / "running-checkout"
        self.m.old.rename(old_source)
        self.m.old.symlink_to(old_source)
        original = (old_source / "manifest.json").read_bytes()
        result = self.m.apply(self.source)
        self.assertEqual((old_source / "manifest.json").read_bytes(), original)
        archived = Path(result["backup"]) / "legacy-registration"
        self.assertTrue(archived.is_symlink())
        self.assertEqual(archived.resolve(), old_source)

    def test_native_update_mismatch_old_folder_with_new_manifest(self):
        write(self.m.old / "manifest.json", {"schemaVersion": 1, "id": NEW})
        result = self.m.apply(self.m.old)
        self.assertFalse(self.m.new.is_symlink())
        self.assertEqual(migration.manifest(self.m.new)["id"], NEW)
        self.assertTrue((Path(result["backup"]) / "legacy-registration/manifest.json").is_file())

    def test_helper_running_from_updated_old_folder_survives_its_own_archival(self):
        write(self.m.old / "manifest.json", {"schemaVersion": 1, "id": NEW})
        (self.m.old / "scripts").mkdir()
        shutil.copyfile(migration.ROOT / "scripts/launcher.py", self.m.old / "scripts/launcher.py")
        shutil.copytree(migration.ROOT / "assets", self.m.old / "assets")
        with mock.patch.object(migration, "ROOT", self.m.old):
            self.m.apply(self.m.old)
        self.assertTrue((self.data / f"applications/{NEW}.desktop").is_file())

    def test_updated_symlink_same_shared_source_keeps_source_unchanged(self):
        shutil.rmtree(self.m.old)
        self.m.old.symlink_to(self.source)
        original = (self.source / "manifest.json").read_bytes()
        self.host.statuses = {OLD: None, NEW: dict(IDLE)}
        self.m.apply(self.m.old)
        self.assertEqual(self.m.new.resolve(), self.source)
        self.assertEqual((self.source / "manifest.json").read_bytes(), original)

    def test_missing_old_service_and_registration_are_fine(self):
        shutil.rmtree(self.m.old)
        self.host.statuses[OLD] = None
        self.seed_data()
        self.m.apply(self.source)
        self.assertTrue((self.config / NEW / "preferences.json").exists())

    def test_existing_new_data_and_future_schema_never_overwritten(self):
        self.seed_data()
        write(self.config / NEW / "preferences.json", {"schema": 9001, "keep": True})
        write(self.cache / NEW / "catalog.json", {"newer": True})
        before = (self.config / NEW / "preferences.json").read_bytes()
        self.m.apply(self.source)
        self.assertEqual((self.config / NEW / "preferences.json").read_bytes(), before)
        self.assertEqual(migration.decode((self.cache / NEW / "catalog.json").read_bytes()), {"newer": True})
        for name in migration.PRIVATE - {"preferences.json"}:
            self.assertEqual((self.config / NEW / name).stat().st_mode & 0o777, 0o600)

    def test_existing_new_registration_is_validated_not_replaced(self):
        write(self.m.new / "manifest.json", {"schemaVersion": 1, "id": NEW})
        marker = self.m.new / "user-file"
        marker.write_text("keep")
        self.m.apply(self.source)
        self.assertEqual(marker.read_text(), "keep")
        self.assertFalse(self.m.new.is_symlink())

    def test_disabled_install_stays_disabled(self):
        self.document["bar"]["layout"]["right"].pop(0)
        write(self.m.shell, self.document)
        self.host.statuses[OLD] = None
        plan = self.m.plan(self.source)
        self.assertFalse(plan["enabled"])
        self.assertFalse(plan["serviceEnabled"])
        self.m.apply(self.source)
        self.assertEqual(migration.decode(self.m.shell.read_bytes()), plan["final"])

    def test_service_only_config_preserves_registration_without_adding_bar_widget(self):
        self.document["bar"]["layout"]["right"].pop(0)
        self.document["plugins"].append({"id": OLD, "inline": {"keep": True}})
        write(self.m.shell, self.document)
        plan = self.m.plan(self.source)
        self.assertFalse(plan["enabled"])
        self.assertTrue(plan["serviceEnabled"])
        self.assertEqual(plan["final"]["plugins"][-1], {"id": NEW, "inline": {"keep": True}})

    def test_native_add_uses_fixed_official_repo_without_early_enable(self):
        def add():
            self.assertIn("stopped", self.host.events)
            self.assertTrue(self.m.old.exists())
            self.assertFalse(any(self.host.statuses.values()))
            shutil.copytree(self.source, self.m.new)
        self.host.add = add
        native_root = self.root / ".config"
        self.config.rename(native_root)
        self.m = migration.Migration(native_root, self.cache, self.data, self.host)
        with mock.patch.object(Path, "home", return_value=self.root):
            result = self.m.apply(official=True)
        self.assertEqual(result["result"], "migrated")
        native = object.__new__(migration.Native)
        native.call = mock.Mock(return_value=(0, "ok", ""))
        native.add()
        native.call.assert_called_once_with("omarchy-plugin-add", migration.OFFICIAL_REPO, "--yes", timeout=120)

    def test_unreleased_public_add_with_missing_old_is_quarantined_on_rollback(self):
        native_root = self.root / ".config"
        self.config.rename(native_root)
        self.m = migration.Migration(native_root, self.cache, self.data, self.host)
        shutil.rmtree(self.m.old)
        self.host.statuses[OLD] = None
        def add_old_release():
            write(self.m.old / "manifest.json", {"schemaVersion": 1, "id": OLD})
        self.host.add = add_old_release
        with mock.patch.object(Path, "home", return_value=self.root):
            with self.assertRaisesRegex(ValueError, "registration rolled back"):
                self.m.apply(official=True)
        self.assertFalse(self.m.old.exists())
        self.assertEqual(self.m.shell.read_bytes(), self.original)
        self.assertEqual(len(list(self.m.shell.parent.glob(".outfit-identity-*/unexpected-legacy-registration"))), 1)

    def test_busy_open_dirty_unknown_and_recovery_status_block_all_writes(self):
        cases = [{"batchRunning": True}, {"opened": True}, {"interestsDirty": True},
                 {"ready": False}, {"densitySavePending": True}, {"indexingBusy": True},
                 {"mutationBusy": True}, {"mutationActive": True},
                 {"panelRecovery": {"armed": True, "suppressed": False}},
                 {"batchItems": [{"status": "checking"}]}]
        for changes in cases:
            with self.subTest(changes=changes):
                self.host.statuses[OLD] = {**IDLE, **changes}
                with self.assertRaises(ValueError):
                    self.m.apply(self.source)
                self.assertEqual(self.m.shell.read_bytes(), self.original)
                self.assertTrue(self.m.old.exists())
                self.assertFalse(self.m.new.exists())
        with self.assertRaises(ValueError):
            migration.idle({})

    def test_unsupported_configs_and_both_id_collision_are_preserved(self):
        cases = [{**self.document, "version": 2}, {**self.document, "plugins": {}},
                 {**self.document, "plugins": [{"id": NEW}]},
                 {**self.document, "bar": {"layout": {"future": [OLD]}}}]
        for document in cases:
            with self.subTest(document=document):
                write(self.m.shell, document)
                before = self.m.shell.read_bytes()
                with self.assertRaises(ValueError):
                    self.m.apply(self.source)
                self.assertEqual(self.m.shell.read_bytes(), before)
        with self.assertRaises(ValueError):
            migration.transform(b'{"version":1,"version":2}')

    def test_runtime_failure_rolls_back_mapping_and_retains_all_data(self):
        self.seed_data()
        self.host.fail_ready = True
        with self.assertRaisesRegex(ValueError, "registration rolled back"):
            self.m.apply(self.source)
        self.assertEqual(self.m.shell.read_bytes(), self.original)
        self.assertTrue(self.m.old.is_dir())
        self.assertFalse(self.m.new.exists())
        self.assertTrue((self.config / NEW / "interests.json").exists())
        self.assertTrue((self.config / OLD / "interests.json").exists())
        self.assertEqual(self.m.apply(self.source)["result"], "migrated")

    def test_config_concurrent_edit_is_never_overwritten_on_failure(self):
        original_reload = self.host.reload
        def reload_with_edit(document):
            original_reload(document)
            write(self.m.shell, {"version": 1, "plugins": [], "concurrent": "keep"})
        self.host.reload = reload_with_edit
        with self.assertRaisesRegex(ValueError, "rollback needs attention"):
            self.m.apply(self.source)
        self.assertEqual(migration.decode(self.m.shell.read_bytes())["concurrent"], "keep")
        with self.assertRaisesRegex(ValueError, "Interrupted migration"):
            self.m.apply(self.source)

    def test_interrupted_migration_explicit_rollback_and_rerun(self):
        # Simulate process death after pause and archival, without invoking live host.
        backup = self.m.shell.parent / ".outfit-identity-interrupted"
        plan = self.m.plan(self.source)
        for name, raw in (("original.json", self.original), ("paused.json", migration.encode(plan["paused"])),
                          ("final.json", migration.encode(plan["final"]))):
            migration.atomic(backup / name, raw)
        write(backup / "mapping.json", {"phase": "applying", "mode": 0o640, "newExisted": False})
        self.m.old.rename(backup / "legacy-registration")
        self.m.new.symlink_to(self.source)
        write(self.m.shell, plan["paused"])
        with self.assertRaisesRegex(ValueError, "Interrupted migration"):
            self.m.apply(self.source)
        self.m.rollback(backup)
        self.m.rollback(backup)
        self.assertEqual(self.m.shell.read_bytes(), self.original)
        self.assertTrue(self.m.old.is_dir())
        self.assertEqual(self.m.apply(self.source)["result"], "migrated")

    def test_failed_stop_never_copies_data_or_archives_old_registration(self):
        self.seed_data()
        self.host.fail_stop = True
        with self.assertRaises(ValueError):
            self.m.apply(self.source)
        self.assertTrue(self.m.old.exists())
        self.assertFalse((self.config / NEW).exists())

    def test_state_symlinks_and_unmanaged_launcher_are_rejected(self):
        outside = self.root / "outside"
        outside.mkdir()
        (self.config / NEW).symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "Symlink"):
            self.m.apply(self.source)
        self.assertEqual(list(outside.iterdir()), [])
        (self.config / NEW).unlink()
        target = self.data / f"applications/{OLD}.desktop"
        target.parent.mkdir(parents=True)
        target.write_text("unmanaged")
        with self.assertRaisesRegex(ValueError, "unmanaged"):
            self.m.apply(self.source)
        self.assertEqual(self.m.shell.read_bytes(), self.original)

    def test_sqlite_backup_includes_committed_wal_not_partial_sidecar_copy(self):
        source = self.cache / OLD / "readme-search.sqlite"
        source.parent.mkdir(parents=True)
        with closing(sqlite3.connect(source)) as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("PRAGMA wal_autocheckpoint=0")
            db.execute("CREATE TABLE documents (text)")
            db.execute("INSERT INTO documents VALUES ('committed in WAL')")
            db.commit()
            self.assertGreater(Path(str(source) + "-wal").stat().st_size, 0)
            migration.copy_data(self.config, self.cache)
            target = self.cache / NEW / source.name
            with closing(sqlite3.connect(target)) as copied:
                self.assertEqual(copied.execute("SELECT text FROM documents").fetchall(), [("committed in WAL",)])
            self.assertFalse(Path(str(target) + "-wal").exists())
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)

    def test_allowlisted_source_symlink_never_copied(self):
        external = self.root / "secret"
        external.write_text("secret")
        (self.cache / OLD).mkdir(parents=True)
        (self.cache / OLD / "catalog.json").symlink_to(external)
        with self.assertRaisesRegex(ValueError, "Symlink"):
            migration.copy_data(self.config, self.cache)
        self.assertFalse((self.cache / NEW / "catalog.json").exists())


class MigrationCommandTests(unittest.TestCase):
    def test_completed_native_verification_rejects_noncanonical_inventory(self):
        native = object.__new__(migration.Native)
        document = {"version": 1, "plugins": [{"id": NEW}]}
        for rows in ({}, [None], [], [{"id": NEW, "enabled": True}],
                     [{"id": NEW, "enabled": False}, {"id": OLD}],
                     [{"id": NEW, "enabled": False}] * 2):
            native.shell = mock.Mock(side_effect=[json.dumps(document), json.dumps(rows)])
            native.status = mock.Mock(return_value=None)
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                native.verify_existing(document, False, True)
            self.assertEqual(native.shell.call_args_list, [mock.call("listShellConfig"), mock.call("listPlugins")])

    def test_execution_gate_and_import_have_no_native_side_effects(self):
        with mock.patch.object(migration, "Native") as native:
            with self.assertRaises(SystemExit) as error:
                migration.main([])
            self.assertEqual(error.exception.code, 2)
            native.assert_not_called()
        with mock.patch.object(subprocess, "Popen", side_effect=AssertionError("must not execute")):
            spec = __import__("importlib.util").util.spec_from_file_location("migration_import_test", migration.__file__)
            module = __import__("importlib.util").util.module_from_spec(spec)
            spec.loader.exec_module(module)

    def test_native_status_only_exact_missing_target_is_safe(self):
        native = object.__new__(migration.Native)
        for reply in ((1, "", "Target not found."), (0, "Target not found.", "")):
            native.call = mock.Mock(return_value=reply)
            self.assertIsNone(native.status(OLD))
        for reply in ((1, "", "omarchy-shell is not running"), (1, "", "Function not found."),
                      (0, "not json", ""), (0, "[]", "")):
            native.call = mock.Mock(return_value=reply)
            with self.assertRaises(ValueError):
                native.status(OLD)

    def test_commands_are_bounded_by_time_and_output(self):
        with self.assertRaisesRegex(ValueError, "timed out"):
            migration.command([sys.executable, "-I", "-c", "import time; time.sleep(5)"], dict(os.environ), timeout=0.1)
        with self.assertRaisesRegex(ValueError, "output limit"):
            migration.command([sys.executable, "-I", "-c", "print('x'*10000)"], dict(os.environ), maximum=100)


class LegacyLauncherIdentityTests(unittest.TestCase):
    def test_legacy_names_removed_only_after_both_new_files_validated(self):
        with tempfile.TemporaryDirectory() as root:
            data = Path(root)
            legacy = []
            for source, relative, _ in launcher.legacy_files():
                path = data / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes((launcher.ASSETS / source).read_bytes().replace(NEW.encode(), OLD.encode()).replace(b"Outfit", b"OmaFit"))
                legacy.append(path)
            original_replace = launcher.os.replace
            def fail_desktop(source, destination):
                if str(destination).endswith(".desktop"):
                    raise OSError("simulated disk failure")
                original_replace(source, destination)
            with mock.patch.object(launcher.os, "replace", side_effect=fail_desktop):
                with self.assertRaises(OSError):
                    launcher.sync(data)
            self.assertTrue(all(path.exists() for path in legacy))
            launcher.sync(data)
            self.assertTrue(all(not path.exists() for path in legacy))
            for _, relative, _ in launcher.FILES:
                self.assertTrue((data / relative).exists())
            launcher.sync(data)

    def test_unmanaged_old_name_and_symlink_do_not_get_removed(self):
        for symlink in (False, True):
            with self.subTest(symlink=symlink), tempfile.TemporaryDirectory() as root:
                data = Path(root)
                old = data / f"applications/{OLD}.desktop"
                old.parent.mkdir(parents=True)
                if symlink:
                    old.symlink_to(data / "missing")
                else:
                    old.write_text("unmanaged")
                with self.assertRaises(ValueError):
                    launcher.sync(data)
                self.assertTrue(migration.present(old))
                self.assertFalse((data / f"applications/{NEW}.desktop").exists())
