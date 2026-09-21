"""Cross-component identity contracts and both-ID self-protection."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from scripts import launcher, migrate_identity, outfit

ROOT = Path(__file__).resolve().parents[1]


class IdentityRuntimeTests(unittest.TestCase):
    def test_release_manifest_launcher_ipc_and_store_share_new_identity(self):
        document = json.loads((ROOT / "manifest.json").read_text())
        identity = document["id"]
        self.assertEqual(identity, "io.github.ctl0v0.outfit")
        self.assertEqual(document["version"], "0.3.2")
        self.assertEqual({launcher.ID, migrate_identity.NEW, outfit.APP_ID}, {identity})
        service = (ROOT / "Service.qml").read_text()
        self.assertIn(f'target: "{identity}"', service)
        self.assertIn(f'moduleName: "{identity}"', (ROOT / "BarWidget.qml").read_text())
        self.assertTrue((ROOT / f"assets/{identity}.svg").is_file())
        self.assertIn(f"Exec=omarchy-shell shell summon {identity}\n", (ROOT / f"assets/{identity}.desktop").read_text())
        self.assertFalse((ROOT / f"assets/{migrate_identity.OLD}.desktop").exists())

    def test_ordinary_startup_uses_only_new_stores_and_does_not_migrate(self):
        with tempfile.TemporaryDirectory() as root:
            base = Path(root)
            old = base / "config" / migrate_identity.OLD
            old.mkdir(parents=True)
            (old / "preferences.json").write_text('{"legacy":"untouched"}')
            with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": str(base / "config"), "XDG_CACHE_HOME": str(base / "cache")}):
                cache, preferences = outfit.open_stores()
                try:
                    self.assertEqual(cache.base, base / "cache" / migrate_identity.NEW)
                    self.assertEqual(preferences.base, base / "config" / migrate_identity.NEW)
                    self.assertIsNone(preferences.stamp("preferences.json"))
                finally:
                    cache.close()
                    preferences.close()
            self.assertEqual((old / "preferences.json").read_text(), '{"legacy":"untouched"}')

    def test_both_identities_refuse_self_mutation_before_native_commands(self):
        with tempfile.TemporaryDirectory() as root:
            store = outfit.Store(Path(root) / "cache")
            try:
                with mock.patch.object(outfit, "run_command") as command, \
                     mock.patch.object(outfit, "scan_inventory") as inventory:
                    for identity in (migrate_identity.OLD, migrate_identity.NEW):
                        for action in ("enable-plugin", "disable-plugin", "remove-plugin"):
                            with self.subTest(identity=identity, action=action), self.assertRaisesRegex(ValueError, "own running state"):
                                outfit.run({"action": action, "pluginId": identity}, store)
                        self.assertEqual(outfit.open_plugin({"pluginId": identity}, 1)["openState"], "unavailable")
                    command.assert_not_called()
                    inventory.assert_not_called()
            finally:
                store.close()
