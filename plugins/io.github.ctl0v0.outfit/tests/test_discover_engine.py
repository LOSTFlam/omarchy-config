from __future__ import annotations

import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from tests.test_outfit import OUTFIT, ROOT


class DiscoverEngineTests(unittest.TestCase):
    def setUp(self):
        fixture = json.loads((ROOT / "demo/fixtures/example.json").read_text())
        self.profile = fixture["profile"]
        self.items = []
        samples = [("Window overview", "Desktop", ["workspaces"], "A workspace overview."),
                   ("Spotify controls", "Widgets", ["media"], "Control Spotify playback."),
                   ("New little game", "Games", ["games"], "A playful new desktop game."),
                   ("File shelf", "Productivity", [], "Keep files handy."),
                   ("Work timer", "Productivity", [], "Focus and take breaks."),
                   ("Wallpaper chooser", "Appearance", [], "Choose desktop backgrounds.")]
        for index, (name, category, tags, description) in enumerate(samples):
            raw = {**fixture["catalog"]["plugins"][0], "id":f"example.pick-{index}",
                "name":name, "description":description, "category":category, "tags":tags,
                "repo":f"https://github.com/owner{index}/plugin", "stars":100 if index == 0 else 0,
                "listedAt":"2026-01-15T00:00:00Z" if index == 2 else "2025-01-01T00:00:00Z"}
            self.items.extend(OUTFIT.normalize_catalog({"plugins":[raw]})[0])
        self.now = 1768478400
        self.notes = {self.items[0]["id"]:{"commit":"a" * 40, "heading":"Find a window quickly",
                      "setup":"Add a shortcut.", "signals":["multi-monitor"], "family":"overview", "everyday":True}}
        self.prefs = {**OUTFIT.DEFAULT_PREFERENCES, "services":["spotify"]}

    def picks(self, request=None, profile=None, installed=None):
        with mock.patch.object(OUTFIT, "discovery_notes", return_value=self.notes):
            return OUTFIT.discovery_catalog(self.items, self.profile if profile is None else profile,
                installed or set(), self.prefs, request or {}, self.now)

    def test_three_distinct_explainable_picks_include_zero_star_newcomer(self):
        result = self.picks()
        self.assertEqual([row["discoverySlot"] for row in result["rows"]], ["setup", "service", "different"])
        self.assertEqual([row["id"] for row in result["rows"]], ["example.pick-0", "example.pick-1", "example.pick-2"])
        self.assertEqual(result["rows"][2]["stars"], 0)
        self.assertEqual(result["rows"][2]["previewThumbnail"], "")
        self.assertIn("2 displays", result["rows"][0]["discoveryReason"])
        self.assertIn("Spotify", result["rows"][1]["discoveryReason"])
        self.assertEqual(result, self.picks())

    def test_stale_editorial_notes_do_not_claim_a_hardware_match(self):
        self.notes[self.items[0]["id"]]["commit"] = "f" * 40
        result = self.picks()
        self.assertTrue(all(row["discoverySlot"] != "setup" for row in result["rows"]))
        self.assertTrue(all(not row["discoveryCurated"] for row in result["rows"]))

    def test_no_watchlist_or_hardware_still_has_useful_diverse_picks(self):
        self.prefs["services"] = []
        result = self.picks(profile=[])
        self.assertEqual(len(result["rows"]), 3)
        self.assertTrue(all(row["discoverySlot"] not in {"setup", "service"} for row in result["rows"]))
        self.assertEqual(len({row["repo"].split("/")[3] for row in result["rows"]}), 3)

    def test_excludes_installed_queued_manual_and_shell_replacements(self):
        self.items[3]["installAvailable"] = False
        self.items[4]["kinds"] = ["bar"]
        result = self.picks({"queuedIds":["example.pick-1"]}, installed={"example.pick-0"})
        identities = {row["id"] for row in result["rows"]}
        self.assertTrue(identities.isdisjoint({"example.pick-0", "example.pick-1", "example.pick-3", "example.pick-4"}))
        self.assertLessEqual(len(identities), 2)

    def test_rotation_prefers_unseen_and_remains_deterministic(self):
        self.prefs["services"] = []
        self.notes = {}
        first = self.picks(profile=[])
        request = {"rotation":1, "seenIds":[row["id"] for row in first["rows"]]}
        second = self.picks(request, profile=[])
        self.assertEqual(second, self.picks(request, profile=[]))
        self.assertTrue({row["id"] for row in first["rows"]}.isdisjoint(row["id"] for row in second["rows"]))

    def test_discover_protocol_is_cached_and_legacy_feedback_is_inert(self):
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory))
            try:
                OUTFIT.save_catalog(store, self.items, "fixture", self.now)
                OUTFIT.save_preferences(store, {**self.prefs, "notFit":[item["id"] for item in self.items]})
                with mock.patch.object(OUTFIT, "fetch_bytes", side_effect=AssertionError("network")), \
                        mock.patch.object(OUTFIT, "scan_profile", side_effect=AssertionError("scan")):
                    result = OUTFIT.run({"action":"discover", "profile":self.profile}, store, now=self.now)
                self.assertTrue(result["ok"])
                self.assertTrue(all(not row["notFit"] and row["adjustment"] == 0 for row in result["discovery"]["rows"]))
                with self.assertRaisesRegex(ValueError, "retired"):
                    OUTFIT.run({"action":"set-feedback", "pluginId":self.items[0]["id"], "notFit":False}, store)
                self.assertEqual(len(OUTFIT.load_preferences(store)["notFit"]), len(self.items))
            finally:
                store.close()

    def test_verification_filter_and_new_metrics_sort_without_changing_membership(self):
        for index, item in enumerate(self.items):
            item["verificationStatus"] = "verified" if index % 2 == 0 else "unverified"
            item["_views"] = index * 10
            item["_copies"] = 100 - index
            item["repositoryUpdatedAt"] = f"2026-01-{index + 1:02d}T00:00:00Z"
        for grouping in ("none", "category"):
            for sort, expected in [("views", [4,2,0]), ("copies", [0,2,4]), ("activity", [4,2,0])]:
                result = OUTFIT.setup_catalog(self.items, [], set(), sort=sort, verification="verified", grouping=grouping)
                self.assertEqual([row["id"] for row in result["rows"]], [f"example.pick-{i}" for i in expected])
                self.assertEqual(result["verification"], "verified")
        local = copy.deepcopy(self.items[0])
        local.update(party="first-party", localOnly=True)
        self.assertEqual(OUTFIT.setup_catalog([local], [], set(), verification="unverified")["rows"], [])

    def test_old_heart_only_cache_has_unknown_views_and_copies(self):
        result = OUTFIT.validate_engagement({"schemaVersion":1, "plugins":{"example.plugin":{"hearts":0}}})
        self.assertEqual(result["example.plugin"], {"hearts":0,"views":None,"copies":None})
