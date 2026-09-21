"""Exercise new controls and historical harness fallbacks without host mutation."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from tests.test_outfit import OUTFIT, ROOT


class DemoCompatibilityTests(unittest.TestCase):
    def worker(self, controls):
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith(("OUTFIT_", "OMAFIT_"))}
        environment.update(controls)
        return subprocess.run([sys.executable, "-I", "-B", str(ROOT / "demo/fixture_worker.py")],
            input=b'{"action":"install-plugin","generation":5,"pluginId":"example.dock-helper"}\n',
            capture_output=True, env=environment, timeout=10)

    def test_both_control_spellings_keep_mutations_disabled_and_storage_isolated(self):
        for prefix in ("OUTFIT_", "OMAFIT_"):
            with self.subTest(prefix=prefix), tempfile.TemporaryDirectory() as directory:
                response = self.worker({prefix + "DEMO_ROOT": directory, prefix + "DEMO_SCENARIO": "cards",
                                        prefix + "DEMO_THUMBNAILS": "0"})
                self.assertEqual(response.returncode, 0, response.stderr)
                reply = json.loads(response.stdout)
                self.assertFalse(reply["ok"])
                self.assertIn("mutations are disabled", reply["error"])
                prefs = json.loads((Path(directory) / "config" / OUTFIT.APP_ID / "preferences.json").read_text())
                self.assertFalse(prefs["marketplaceThumbnails"])

    def test_current_controls_override_legacy_root_and_scenario(self):
        with tempfile.TemporaryDirectory() as directory:
            current, legacy = Path(directory) / "current", Path(directory) / "legacy"
            response = self.worker({"OUTFIT_DEMO_ROOT": str(current), "OMAFIT_DEMO_ROOT": str(legacy),
                "OUTFIT_DEMO_SCENARIO": "cards", "OMAFIT_DEMO_SCENARIO": "native-lifecycle",
                "OUTFIT_DEMO_THUMBNAILS": "0", "OMAFIT_DEMO_THUMBNAILS": "1"})
            self.assertEqual(response.returncode, 0, response.stderr)
            self.assertIn("mutations are disabled", json.loads(response.stdout)["error"])
            self.assertFalse(legacy.exists())
            prefs = json.loads((current / "config" / OUTFIT.APP_ID / "preferences.json").read_text())
            self.assertFalse(prefs["marketplaceThumbnails"])

    def test_current_vm_guard_cannot_be_bypassed_by_legacy_flag(self):
        with tempfile.TemporaryDirectory() as directory:
            response = self.worker({"OUTFIT_DEMO_ROOT": directory, "OUTFIT_DEMO_SCENARIO": "native-lifecycle",
                                    "OUTFIT_TEST_VM": "0", "OMAFIT_TEST_VM": "1"})
            self.assertNotEqual(response.returncode, 0)
            self.assertIn(b"isolated disposable VM environment", response.stderr)
            self.assertEqual(list(Path(directory).iterdir()), [])
