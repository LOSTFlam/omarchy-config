from pathlib import Path
import tempfile
import unittest
from unittest import mock

from tests.test_outfit import OUTFIT as app


class DensityPreferencesTests(unittest.TestCase):
    def test_default_and_invalid_saved_values_are_comfortable(self):
        for value in [None, "unknown", True, [], {}]:
            self.assertEqual(app.validate_preferences({"browseDensity": value})["browseDensity"], "comfortable")
        for value in ("comfortable", "compact", "dense", "list"):
            self.assertEqual(app.validate_preferences({"browseDensity": value})["browseDensity"], value)

    def test_density_save_is_local_and_patches_only_latest_preference(self):
        with tempfile.TemporaryDirectory() as directory:
            store = app.Store(Path(directory))
            try:
                before = app.validate_preferences({**app.DEFAULT_PREFERENCES, "notes": "Fictional draft",
                    "readmeIndexing": False, "readmeEnrichment": False, "services": ["tailscale"]})
                app.save_preferences(store, {**before, "futurePreference": {"preserve": True}})
                with mock.patch.object(app, "fetch_bytes", side_effect=AssertionError("Unexpected network")), \
                     mock.patch.object(app, "scan_profile", side_effect=AssertionError("Unexpected scan")), \
                     mock.patch.object(app, "load_catalog", side_effect=AssertionError("Unexpected query")):
                    reply = app.run({"action": "save-density", "browseDensity": "dense", "generation": 8}, store)
                self.assertEqual(reply, {"ok": True, "action": "save-density", "generation": 8, "browseDensity": "dense"})
                self.assertEqual(store.read("preferences.json", app.MAX_PREFERENCES_BYTES, {})["futurePreference"], {"preserve": True})
                store.memory.clear()
                self.assertEqual(app.load_preferences(store), {**before, "browseDensity": "dense"})
                # Saving an older Settings draft must retain the newer density.
                app.run({"action": "save-preferences", "preferences": before}, store)
                self.assertEqual(app.load_preferences(store)["browseDensity"], "dense")
                with self.assertRaises(ValueError):
                    app.run({"action": "save-density", "browseDensity": "unsupported"}, store)
                self.assertEqual(app.load_preferences(store)["browseDensity"], "dense")
            finally:
                store.close()

    def test_invalid_preferences_are_preserved_on_density_save(self):
        with tempfile.TemporaryDirectory() as directory:
            store = app.Store(Path(directory))
            try:
                store.write("preferences.json", {"schema": 999, "notes": "Preserve me"}, app.MAX_PREFERENCES_BYTES)
                with self.assertRaisesRegex(ValueError, "Repair or reset"):
                    app.run({"action": "save-density", "browseDensity": "compact"}, store)
                self.assertEqual(store.read("preferences.json", 1000, {}), {"schema": 999, "notes": "Preserve me"})
            finally:
                store.close()

    def test_list_choice_survives_a_new_store_and_unrelated_settings_save(self):
        with tempfile.TemporaryDirectory() as directory:
            store = app.Store(Path(directory))
            app.run({"action": "save-density", "browseDensity": "list"}, store)
            store.close()
            restored = app.Store(Path(directory))
            try:
                self.assertEqual(app.load_preferences(restored)["browseDensity"], "list")
                app.run({"action": "save-preferences", "preferences": app.DEFAULT_PREFERENCES}, restored)
                self.assertEqual(app.load_preferences(restored)["browseDensity"], "list")
            finally:
                restored.close()
