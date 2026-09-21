from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from tests.test_outfit import OUTFIT, ROOT


class BrowseFeaturesTests(unittest.TestCase):
    def test_default_and_invalid_sort_use_likes_with_unknown_counts_last(self):
        items = [{**self.items[0], "id": "example.a", "name": "A", "stars": 100, "_likes": 1},
                 {**self.items[0], "id": "example.b", "name": "B", "stars": 0, "_likes": 9},
                 {**self.items[0], "id": "example.c", "name": "C", "stars": 1000, "_likes": None}]
        for options in ({}, {"sort": "invalid"}):
            result = OUTFIT.setup_catalog(items, [], set(), **options)
            self.assertEqual(result["sort"], "likes")
            self.assertEqual([row["id"] for row in result["rows"]], ["example.b", "example.a", "example.c"])
        starred = OUTFIT.setup_catalog(items, [], set(), sort="stars")
        self.assertEqual([row["id"] for row in starred["rows"]], ["example.c", "example.a", "example.b"])

    def setUp(self) -> None:
        fixture = json.loads((ROOT / "demo/fixtures/example.json").read_text())
        self.items, self.revision = OUTFIT.normalize_catalog(fixture["catalog"])
        self.profile = fixture["profile"]
        self.url = "https://plugins.omarchy.org/assets/img/plugins/example-card.webp"
        self.items[0].update({"previewThumbnail": self.url, "previewThumbnailWidth": 720,
                              "previewThumbnailHeight": 405})
        self.image = b"\x89PNG\r\n\x1a\n" + b"\x00" * 8 \
            + (720).to_bytes(4, "big") + (405).to_bytes(4, "big")

    def test_marketplace_metadata_round_trip_and_url_boundary(self) -> None:
        self.assertEqual(OUTFIT.marketplace_image_url("assets/img/plugins/example-card.webp"), self.url)
        for url in ["https://evil.example/assets/img/plugins/example.png",
                    "//evil.example/preview.webp", "assets/img/plugins/../private.png",
                    "assets/img/plugins/%2e%2e.png", "assets/img/plugins/example.webp?redirect=x",
                    "https://plugins.omarchy.org@evil.example/assets/img/plugins/x.png"]:
            with self.subTest(url=url):
                self.assertEqual(OUTFIT.marketplace_image_url(url), "")
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory))
            try:
                OUTFIT.save_catalog(store, self.items, self.revision, 10)
                store.memory.clear()
                restored, _fetched, _revision = OUTFIT.load_catalog(store)
                rows = OUTFIT.setup_catalog(restored, self.profile, set())["rows"]
                row = next(row for row in rows if row["id"] == self.items[0]["id"])
                self.assertEqual(row["previewThumbnail"], self.url)
                self.assertEqual(row["previewThumbnailWidth"], 720)
                self.assertEqual(row["previewThumbnailHeight"], 405)
            finally:
                store.close()

    def test_thumbnail_cache_hit_revision_refresh_and_offline_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory))
            try:
                with mock.patch.object(OUTFIT, "fetch_preview_image", return_value=(self.image, "png")) as fetch:
                    first = OUTFIT.materialize_thumbnails(store, self.items[:1], "rev1")
                    cached = OUTFIT.materialize_thumbnails(store, self.items[:1], "rev1")
                    fetch.assert_called_once_with(self.url)
                    self.assertEqual(first, cached)
                    refreshed = OUTFIT.materialize_thumbnails(store, self.items[:1], "rev2")
                identity = self.items[0]["id"]
                self.assertNotEqual(first[identity]["localSource"], refreshed[identity]["localSource"])
                with mock.patch.object(OUTFIT, "fetch_preview_image", side_effect=OSError("offline")):
                    offline = OUTFIT.materialize_thumbnails(store, self.items[:1], "rev3")
                self.assertEqual(offline[identity]["localSource"], refreshed[identity]["localSource"])
                for file in Path(directory).glob("thumb-*"):
                    self.assertEqual(file.stat().st_mode & 0o777, 0o600)
                self.assertEqual(Path(directory).stat().st_mode & 0o777, 0o700)
            finally:
                store.close()

    def test_thumbnail_protocol_respects_settings_and_never_fetches_readmes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory))
            try:
                OUTFIT.save_catalog(store, self.items, self.revision, 10)
                request = {"action": "thumbnails", "generation": 7, "pluginIds": [self.items[0]["id"]]}
                with mock.patch.object(OUTFIT, "fetch_preview_image", return_value=(self.image, "png")), \
                        mock.patch.object(OUTFIT, "fetch_readme") as readme, \
                        mock.patch.object(OUTFIT, "scan_profile") as scan:
                    result = OUTFIT.run(request, store)
                    self.assertTrue(result["thumbnails"][self.items[0]["id"]]["localSource"])
                    self.assertEqual(result["generation"], 7)
                    readme.assert_not_called()
                    scan.assert_not_called()
                OUTFIT.save_preferences(store, {**OUTFIT.DEFAULT_PREFERENCES, "marketplaceThumbnails": False})
                with mock.patch.object(OUTFIT, "materialize_thumbnails") as load:
                    self.assertEqual(OUTFIT.run(request, store)["thumbnails"], {})
                    load.assert_not_called()
            finally:
                store.close()

    def test_thumbnail_setting_defaults_on_and_is_independent_of_readmes(self) -> None:
        preferences = OUTFIT.validate_preferences({"readmeEnrichment": False})
        self.assertTrue(preferences["marketplaceThumbnails"])
        self.assertFalse(preferences["readmeEnrichment"])
        preferences = OUTFIT.validate_preferences({"marketplaceThumbnails": False})
        self.assertFalse(preferences["marketplaceThumbnails"])
        self.assertTrue(preferences["readmeEnrichment"])

    def test_thumbnail_fetch_rejects_oversized_stream_and_unknown_type(self) -> None:
        opener = mock.MagicMock()
        response = opener.open.return_value.__enter__.return_value
        response.headers = {}
        response.read.side_effect = [b"x" * (64 * 1024)] * 33
        with mock.patch.object(OUTFIT.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(ValueError, "size limit"):
                OUTFIT.fetch_preview_image(self.url)
            response.read.side_effect = [b"<svg width=400 height=300></svg>", b""]
            with self.assertRaisesRegex(ValueError, "supported image"):
                OUTFIT.fetch_preview_image(self.url)

    def test_thumbnail_cache_limits_and_symlink_rejection(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory))
            try:
                for index in range(4):
                    name = f"thumb-{index:032x}-{'a' * 16}.png"
                    store.write_blob(name, self.image, OUTFIT.MAX_PREVIEW_IMAGE_BYTES)
                with mock.patch.object(OUTFIT, "MAX_THUMBNAIL_FILES", 2):
                    OUTFIT.prune_thumbnails(store, set())
                self.assertEqual(len(list(Path(directory).glob("thumb-*"))), 2)
                name = f"thumb-{'f' * 32}-{'a' * 16}.png"
                os.symlink("/dev/zero", Path(directory) / name)
                with self.assertRaises(OSError):
                    store.read_thumbnail(name)
            finally:
                store.close()

    def test_ungrouped_ranks_globally_before_pagination(self) -> None:
        items = []
        for index in range(45):
            item = dict(self.items[index % len(self.items)])
            item.update(id=f"example.plugin-{index}", stars=index, name=f"Plugin {index:02d}")
            items.append(item)
        pages = [OUTFIT.setup_catalog(items, self.profile, set(), grouping="none",
                                     sort="stars", page=page, page_size=12)
                 for page in range(1, 5)]
        self.assertTrue(all(not page["overview"] for page in pages))
        stars = [row["stars"] for page in pages for row in page["rows"]]
        self.assertEqual(stars, list(reversed(range(45))))
        self.assertTrue(all(row["displayGroup"] == "all" for page in pages for row in page["rows"]))

    def test_ungrouped_fit_search_orders_by_fit_not_search_relevance(self) -> None:
        items = [{**item, "name": "Fixture " + item["name"]} for item in self.items]
        items[-1]["name"] = "Fixture"
        result = OUTFIT.setup_catalog(items, self.profile, set(), query="fixture",
                                      grouping="none", sort="fit")
        self.assertEqual(result["total"], len(items))
        scores = [row["score"] for row in result["rows"]]
        self.assertEqual(scores, sorted(scores, reverse=True))

    def test_category_grouping_preserves_scores_filters_and_unique_rows(self) -> None:
        outputs = [OUTFIT.setup_catalog(self.items, self.profile, set(), grouping=grouping,
                                       sort="fit", query="dock")
                   for grouping in ("purpose", "category", "none")]
        expected = {row["id"]: row["recommendationScore"] for row in outputs[0]["rows"]}
        for result in outputs[1:]:
            self.assertEqual({row["id"]: row["recommendationScore"] for row in result["rows"]}, expected)
            self.assertEqual(len(result["rows"]), len(expected))
        category = outputs[1]
        self.assertTrue(all(row["displayGroup"] == row["category"] for row in category["rows"]))
        self.assertEqual(sum(section["total"] for section in category["sections"]), category["total"])

    def test_grouping_protocol_and_invalid_default(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory))
            try:
                OUTFIT.save_catalog(store, self.items, self.revision, 10)
                for value in ("none", "category", "purpose", "invalid"):
                    result = OUTFIT.run({"action": "quick-setup", "setupGrouping": value}, store)
                    self.assertEqual(result["setup"]["grouping"], "category" if value == "category" else "none")
            finally:
                store.close()
