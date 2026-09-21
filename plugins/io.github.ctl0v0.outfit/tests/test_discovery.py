from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from tests.test_outfit import OUTFIT, ROOT


class DiscoveryTests(unittest.TestCase):
    def setUp(self) -> None:
        fixture = json.loads((ROOT / "demo/fixtures/example.json").read_text())
        self.items, self.generated = OUTFIT.normalize_catalog(fixture["catalog"])
        self.profile = fixture["profile"]

    def test_dates_normalize_utc_and_fall_back_to_added_date(self) -> None:
        self.assertEqual(OUTFIT.listing_date("2026-08-05"), "2026-08-05T00:00:00Z")
        self.assertEqual(OUTFIT.listing_date("2026-08-05T02:00:00+02:00"), "2026-08-05T00:00:00Z")
        for value in [None, 25, "yesterday", "2026-02-30", "2026-08-05T01:00:00", "1960-01-01"]:
            self.assertEqual(OUTFIT.listing_date(value), "")
        raw = json.loads((ROOT / "demo/fixtures/example.json").read_text())["catalog"]
        raw["plugins"][0].update(listedAt="invalid", addedAt="2026-08-05")
        items, _ = OUTFIT.normalize_catalog(raw)
        self.assertEqual(items[0]["listedAt"], "2026-08-05T00:00:00Z")
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory))
            try:
                OUTFIT.save_catalog(store, items, self.generated, 1)
                store.memory.clear()
                restored, _, _ = OUTFIT.load_catalog(store)
                self.assertEqual(restored[0]["listedAt"], items[0]["listedAt"])
            finally:
                store.close()

    def test_likes_reject_bad_counts_and_preserve_reported_zero(self) -> None:
        payload = {"schemaVersion": 1, "plugins": {
            "example.zero": {"hearts": 0}, "example.good": {"hearts": 123},
            "example.bool": {"hearts": True}, "example.text": {"hearts": "12"},
            "example.negative": {"hearts": -1}, "example.float": {"hearts": 1.5},
            "example.huge": {"hearts": 2 ** 64}, "example.missing": {},
            "constructor": {"hearts": 3},
        }}
        self.assertEqual(OUTFIT.validate_engagement(payload), {
            "example.zero": {"hearts":0,"views":None,"copies":None},
            "example.good": {"hearts":123,"views":None,"copies":None}})
        for bad in [[], {}, {"schemaVersion": 2, "plugins": {}}, {"schemaVersion": 1, "plugins": []}]:
            with self.assertRaises(ValueError):
                OUTFIT.validate_engagement(bad)

    def test_new_badge_uses_listing_time_and_expires_at_twelve_hours(self) -> None:
        item = {**self.items[0], "listedAt": "2026-09-16T00:00:00Z"}
        listed = OUTFIT.listing_time(item["listedAt"])
        for offset, expected in [(-1, False), (0, True), (43199, True), (43200, False)]:
            self.assertEqual(OUTFIT.listing_badges(item, listed + offset)["isNew"], expected)
        self.assertFalse(OUTFIT.listing_badges({**item, "localOnly": True}, listed)["isNew"])
        self.assertFalse(OUTFIT.listing_badges({**item, "listedAt": "invalid"}, listed)["isNew"])

    def test_verification_details_remain_distinct_from_topic_tags(self) -> None:
        item = {**self.items[0], "verificationMethod": "maintainer-reviewed",
                "verificationStatus": "verified", "verificationSnapshotStatus": "pending",
                "verificationCommit": self.items[0]["listingCommit"]}
        row = OUTFIT.public_row(item, 0, "", set())
        self.assertEqual(row["verification"], "verified")
        self.assertEqual(row["verificationMethod"], "maintainer-reviewed")
        self.assertEqual(row["reviewState"], "snapshot checks not confirmed")
        self.assertEqual(row["tags"], item["tags"])

    def test_likes_cache_refresh_offline_and_local_only_actions(self) -> None:
        payload = json.dumps({"schemaVersion": 1, "plugins": {self.items[0]["id"]: {"hearts": 41}}}).encode()
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory))
            try:
                with mock.patch.object(OUTFIT, "fetch_bytes", return_value=payload) as fetch:
                    first = OUTFIT.update_engagement(store, "analyze", 100)
                    self.assertEqual(first, ({self.items[0]["id"]: {"hearts":41,"views":None,"copies":None}}, 100, ""))
                    for action in ["analyze", "quick-setup", "search", "rescan", "readme-plugin"]:
                        self.assertEqual(OUTFIT.update_engagement(store, action, 110), first)
                    fetch.assert_called_once_with(OUTFIT.ENGAGEMENT_URL, "api.omarchyplugins.com",
                                                  OUTFIT.MAX_ENGAGEMENT_BYTES, 10)
                with mock.patch.object(OUTFIT, "fetch_bytes", side_effect=OSError("offline")):
                    stale = OUTFIT.update_engagement(store, "refresh", 120)
                self.assertEqual(stale[:2], first[:2])
                self.assertIn("saved totals", stale[2])
                store.memory.clear()
                self.assertEqual(OUTFIT.load_engagement(store), first[:2])
                OUTFIT.save_catalog(store, self.items, self.generated, 100)
                with mock.patch.object(OUTFIT, "fetch_bytes", side_effect=AssertionError("unexpected network")):
                    result = OUTFIT.run({"action": "quick-setup"}, store, now=200)
                counts = {row["id"]: row["likes"] for row in result["setup"]["rows"]}
                self.assertEqual(counts[self.items[0]["id"]], 41)
                self.assertIsNone(counts[self.items[1]["id"]])
            finally:
                store.close()

    def test_likes_first_request_failure_does_not_invent_zero(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory))
            try:
                with mock.patch.object(OUTFIT, "fetch_bytes", side_effect=ValueError("invalid")):
                    counts, fetched, message = OUTFIT.update_engagement(store, "analyze", 100)
                self.assertEqual(counts, {})
                self.assertEqual(fetched, 0)
                self.assertTrue(message)
                self.assertFalse((Path(directory) / "engagement.json").exists())
            finally:
                store.close()

    def test_added_and_likes_sort_globally_and_ignore_display_grouping(self) -> None:
        first, second, third = [dict(item) for item in self.items[:3]]
        first.update(listedAt="2026-08-01T10:00:00Z", _likes=100, installAvailable=False)
        second.update(listedAt="2026-08-02T09:00:00Z", _likes=0)
        third.update(listedAt="", _likes=None)
        for grouping in ("none", "category", "purpose"):
            added = OUTFIT.setup_catalog([third, first, second], [], set(), sort="added", grouping=grouping)
            liked = OUTFIT.setup_catalog([third, first, second], [], set(), sort="likes", grouping=grouping)
            self.assertEqual([row["id"] for row in added["rows"]], [second["id"], first["id"], third["id"]])
            self.assertEqual([row["id"] for row in liked["rows"]], [first["id"], second["id"], third["id"]])
            self.assertFalse(added["overview"])

    def test_all_sorts_keep_identical_order_across_display_grouping(self) -> None:
        for sort in ("name", "recommended", "fit", "stars", "added", "likes"):
            outputs = [OUTFIT.setup_catalog(self.items, self.profile, set(), sort=sort, grouping=grouping,
                                           query="dock") for grouping in ("none", "category")]
            self.assertEqual([row["id"] for row in outputs[0]["rows"]],
                             [row["id"] for row in outputs[1]["rows"]])

    def test_specific_purposes_follow_primary_intent_and_avoid_ambiguous_brands(self) -> None:
        cases = [
            ("Messaging", "Web messaging hub for Slack and Discord.", "Productivity", [], "messaging"),
            ("BlueFerry", "Send iMessage and SMS through an iPhone.", "Productivity", [], "messaging"),
            ("OmaBond", "Private Tailscale presence and chat for two systems.", "Widgets", ["security"], "messaging"),
            ("OmaQ", "Invite-only group chat.", "Other", [], "messaging"),
            ("Microsoft Teams", "Teams chats, channels and calendar.", "Widgets", ["media"], "messaging"),
            ("Syncthing", "Sync files and folders.", "Widgets", [], "files-backup"),
            ("Proton Drive", "Browse cloud storage.", "Productivity", ["security"], "files-backup"),
            ("Restic Monitor", "Watch backup jobs.", "System", [], "files-backup"),
            ("LocalSend", "Share files on the local network.", "Widgets", [], "files-backup"),
            ("Omamail", "Email client with IMAP mailboxes.", "Productivity", [], "email-calendar"),
            ("Calendar Agenda", "A private HTTPS iCalendar feed.", "Widgets", [], "email-calendar"),
            ("RSS-Reeder", "Native RSS and Atom reader.", "Productivity", ["media"], "news-weather"),
            ("Aviation Weather", "METAR and TAF observations.", "Widgets", [], "news-weather"),
            ("Weather Outlook", "Tomorrow's weather outlook.", "System", [], "news-weather"),
            ("Weather Wallpaper", "A weather-themed desktop background.", "Appearance", [], "appearance"),
            ("omacord", "A Vencord theme for Discord.", "Appearance", [], "appearance"),
            ("Quick Emoji", "Slack-style emoji completion.", "Productivity", [], "productivity"),
            ("Signal", "A Sentry incident inbox.", "Developer Tools", [], "development-ai"),
            ("Agent Chat", "Chat with local AI models.", "Developer Tools", ["ai"], "development-ai"),
            ("Agent Chat", "Multi-agent group chat with AI models.", "Developer Tools", ["ai"], "development-ai"),
            ("Matrix LEDs", "Control a hardware LED matrix.", "Hardware", [], "hardware"),
            ("Task Board", "Task and calendar helper.", "Productivity", [], "productivity"),
            ("Football Calendar", "Sports fixtures and results.", "Kids", ["games"], "games-learning"),
            ("Password Manager", "Encrypted file backups and credentials.", "Productivity", ["security"], "network-privacy"),
        ]
        for name, description, category, tags, expected in cases:
            with self.subTest(name=name):
                item = {"id": "example.fixture", "name": name, "description": description,
                        "category": category, "tags": tags,
                        "_readme": "Join our Discord. Support by email. Back up your configuration."}
                self.assertEqual(OUTFIT.setup_group(item, True), expected)

    def test_new_purposes_have_contextual_facets_and_filterable_results(self) -> None:
        items = []
        for index, (name, description) in enumerate([
            ("Messaging", "Send messages"), ("Restic", "Backup jobs"),
            ("Calendar Agenda", "Calendar events"), ("RSS Reader", "News reader"),
        ]):
            item = dict(self.items[0])
            item.update(id=f"example.purpose-{index}", name=name, description=description,
                        category="Widgets", tags=[])
            items.append(item)
        result = OUTFIT.setup_catalog(items, [], set(), sort="name")
        expected = {"messaging", "files-backup", "email-calendar", "news-weather"}
        self.assertEqual({row["setupGroup"] for row in result["rows"]}, expected)
        self.assertEqual({group["id"] for group in result["groups"] if group["total"]}, expected)
        for purpose in expected:
            filtered = OUTFIT.setup_catalog(items, [], set(), group=purpose)
            self.assertEqual(len(filtered["rows"]), 1)
            self.assertEqual(filtered["rows"][0]["setupGroup"], purpose)
