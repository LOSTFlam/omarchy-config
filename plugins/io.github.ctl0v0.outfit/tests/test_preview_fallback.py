"""Browse fallback uses pinned README screenshots, never guessed image URLs."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from tests.test_outfit import OUTFIT as app


class PreviewFallbackTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.store = app.Store(Path(temp.name))
        self.addCleanup(self.store.close)
        self.image = b"\x89PNG\r\n\x1a\n" + bytes(8) + (640).to_bytes(4, "big") + (480).to_bytes(4, "big")
        self.one = self.item("one", "a" * 40)
        self.two = self.item("two", "b" * 40)

    def item(self, name, sha):
        return {"id":"example." + name, "name":name, "repo":"https://github.com/example/" + name,
                "owner":"example", "repoName":name, "listingCommit":sha,
                "previewThumbnail":"", "previewImage":"", "party":"third-party"}

    def document(self, item, **kwargs):
        return {"ok":True, "media":app.readme_media(
            "![Project banner](assets/banner.png)\n![Screenshot](docs/screenshot.png)", item)}

    def render(self, items=None, enabled=True, revision="catalog-one"):
        return app.materialize_thumbnails(self.store, items or [self.one], revision, allow_readme=enabled)

    def test_empty_urls_do_not_group_unrelated_repositories_and_cache_is_reused(self):
        with mock.patch.object(app, "fetch_readme", side_effect=self.document) as readme, \
                mock.patch.object(app, "fetch_preview_image", return_value=(self.image,"png")) as image:
            result = self.render([self.one,self.two])
            self.assertEqual(readme.call_count,2)
            self.assertEqual(image.call_count,2)
            self.assertNotEqual(result[self.one["id"]]["localSource"],result[self.two["id"]]["localSource"])
            self.assertEqual(result, self.render([self.one,self.two]))
            self.assertEqual(readme.call_count,2)
            self.assertEqual(image.call_count,2)
            for item in [self.one,self.two]:
                row = result[item["id"]]
                self.assertEqual((row["source"],row["url"],row["state"]),("readme","","ready"))
                self.assertEqual(row["listingCommit"],item["listingCommit"])
                self.assertEqual(row["repo"],item["repo"])
            urls = [call.args[0] for call in image.call_args_list]
            self.assertTrue(all("/docs/screenshot.png" in url and "/banner.png" not in url for url in urls))

    def test_marketplace_wins_and_readme_is_only_used_after_download_failure(self):
        item = {**self.one,"previewThumbnail":"https://plugins.omarchy.org/assets/img/plugins/example.webp"}
        with mock.patch.object(app,"fetch_readme",side_effect=self.document) as readme, \
                mock.patch.object(app,"fetch_preview_image",return_value=(self.image,"png")):
            result = self.render([item])[item["id"]]
            self.assertEqual(result["source"],"marketplace")
            readme.assert_not_called()
        # A distinct URL has no primary cache to fall back to.
        item["previewThumbnail"] = "https://plugins.omarchy.org/assets/img/plugins/broken.webp"
        def download(url, **kwargs):
            if "plugins.omarchy.org" in url: raise OSError("offline")
            return self.image,"png"
        with mock.patch.object(app,"fetch_readme",side_effect=self.document), \
                mock.patch.object(app,"fetch_preview_image",side_effect=download):
            result = self.render([item])[item["id"]]
            self.assertEqual(result["source"],"readme")
            self.assertEqual(result["url"],item["previewThumbnail"])

    def test_revision_change_uses_new_readme_and_never_reuses_previous_screenshot(self):
        with mock.patch.object(app,"fetch_readme",side_effect=self.document) as readme, \
                mock.patch.object(app,"fetch_preview_image",return_value=(self.image,"png")) as image:
            first = self.render()[self.one["id"]]
            self.one["listingCommit"] = "c" * 40
            second = self.render()[self.one["id"]]
            self.assertNotEqual(first["localSource"],second["localSource"])
            self.assertEqual(readme.call_count,2)
            self.assertIn("/" + "c" * 40 + "/",image.call_args.args[0])

    def test_disabled_readmes_skip_cached_fallback_and_missing_revision_never_fetches(self):
        with mock.patch.object(app,"fetch_readme",side_effect=self.document), \
                mock.patch.object(app,"fetch_preview_image",return_value=(self.image,"png")):
            self.assertTrue(self.render()[self.one["id"]]["localSource"])
        with mock.patch.object(app,"fetch_readme") as readme, mock.patch.object(app,"fetch_preview_image") as image:
            self.assertEqual(self.render(enabled=False)[self.one["id"]]["localSource"],"")
            self.one["listingCommit"] = ""
            self.assertEqual(self.render()[self.one["id"]]["localSource"],"")
            readme.assert_not_called()
            image.assert_not_called()

    def test_readme_failures_back_off_and_genuine_absence_is_distinct(self):
        with mock.patch.object(app.time,"time",return_value=1000), \
                mock.patch.object(app,"fetch_readme",return_value={"ok":False}) as readme:
            self.assertEqual(self.render()[self.one["id"]]["state"],"failed")
            self.render()
            readme.assert_called_once()
        with mock.patch.object(app.time,"time",return_value=1301), \
                mock.patch.object(app,"fetch_readme",return_value={"ok":True,"media":[]}) as readme:
            self.assertEqual(self.render()[self.one["id"]]["state"],"missing")
            self.render()
            readme.assert_called_once()

    def test_invalid_first_image_tries_next_candidate(self):
        media = app.readme_media("![Screenshot](one.png)\n![Screenshot](two.png)", self.one)
        def download(url, **kwargs):
            if url.endswith("one.png"): raise ValueError("Unsupported dimensions")
            return self.image,"png"
        with mock.patch.object(app,"fetch_readme",return_value={"ok":True,"media":media}), \
                mock.patch.object(app,"fetch_preview_image",side_effect=download) as image:
            self.assertEqual(self.render()[self.one["id"]]["state"],"ready")
            self.assertEqual(image.call_count,2)

    def test_cached_candidates_cannot_escape_repository_or_commit(self):
        self.store.write("thumbnail-readmes.json",{"schema":1,"entries":{
            app.readme_key(self.one):{"ok":True,"checkedAt":1000,"urls":[
                "https://raw.githubusercontent.com/other/project/" + "b"*40 + "/secret.png",
                "https://raw.githubusercontent.com/example/one/" + "a"*40 + "/../secret.png",
                "https://evil.example/secret.png"]}}},2*1024*1024)
        with mock.patch.object(app.time,"time",return_value=1001), \
                mock.patch.object(app,"fetch_preview_image") as image:
            self.assertFalse(self.render()[self.one["id"]]["localSource"])
            image.assert_not_called()

    def test_expired_batch_budget_defers_without_poisoning_negative_cache(self):
        with mock.patch.object(app.time,"monotonic",side_effect=[0,33]):
            result = self.render()[self.one["id"]]
        self.assertEqual(result["state"],"deferred")
        self.assertEqual(app.thumbnail_readme_cache(self.store),{})

    def test_protocol_respects_both_settings(self):
        app.save_catalog(self.store,[self.one],"revision",1000)
        app.save_preferences(self.store,{**app.DEFAULT_PREFERENCES,"readmeEnrichment":False})
        with mock.patch.object(app,"fetch_readme") as readme:
            result = app.run({"action":"thumbnails","pluginIds":[self.one["id"]]},self.store)
            self.assertFalse(result["thumbnails"][self.one["id"]]["localSource"])
            readme.assert_not_called()
        app.save_preferences(self.store,{**app.DEFAULT_PREFERENCES,"marketplaceThumbnails":False})
        with mock.patch.object(app,"materialize_thumbnails") as materialize:
            self.assertEqual(app.run({"action":"thumbnails","pluginIds":[self.one["id"]]},self.store)["thumbnails"],{})
            materialize.assert_not_called()

    def test_clear_preview_cache_allows_immediate_retry_of_failed_discovery(self):
        with mock.patch.object(app,"fetch_readme",return_value={"ok":False}) as readme:
            self.render()
            self.assertTrue(app.thumbnail_readme_cache(self.store))
            app.preview_cache_summary(self.store, clear=True)
            self.assertEqual(app.thumbnail_readme_cache(self.store),{})
            self.render()
            self.assertEqual(readme.call_count,2)

    def test_cached_primary_and_cached_fallback_do_not_load_inspector_cache(self):
        item = {**self.one, "previewThumbnail": "https://plugins.omarchy.org/assets/img/plugins/working.webp"}
        with mock.patch.object(app, "load_readmes", side_effect=AssertionError("eager inspector read")), \
                mock.patch.object(app, "fetch_preview_image", return_value=(self.image, "png")) as image:
            self.render([item])
            self.render([item])
            image.assert_called_once()
        with mock.patch.object(app, "fetch_readme", side_effect=self.document), \
                mock.patch.object(app, "fetch_preview_image", return_value=(self.image, "png")):
            self.render()
        with mock.patch.object(app, "load_readmes", side_effect=AssertionError("eager inspector read")), \
                mock.patch.object(app, "fetch_readme", side_effect=AssertionError("cached discovery")):
            self.assertEqual(self.render()[self.one["id"]]["source"], "readme")

    def test_failed_primary_reuses_fallback_then_recovers_after_backoff(self):
        item = {**self.one, "previewThumbnail": "https://plugins.omarchy.org/assets/img/plugins/broken.webp"}

        def download(url, **kwargs):
            if "plugins.omarchy.org" in url:
                raise OSError("offline")
            return self.image, "png"

        with mock.patch.object(app.time, "time", return_value=1000), \
                mock.patch.object(app, "fetch_readme", side_effect=self.document), \
                mock.patch.object(app, "fetch_preview_image", side_effect=download) as image:
            first = self.render([item])[item["id"]]
            self.assertEqual(first["source"], "readme")
            self.assertEqual(image.call_count, 2)
        with mock.patch.object(app.time, "time", return_value=1061), \
                mock.patch.object(app, "fetch_preview_image", side_effect=AssertionError("backoff ignored")), \
                mock.patch.object(app, "load_readmes", side_effect=AssertionError("cached discovery")):
            self.assertEqual(self.render([item])[item["id"]], first)
        with mock.patch.object(app.time, "time", return_value=1301), \
                mock.patch.object(app, "fetch_preview_image", return_value=(self.image, "png")) as image:
            self.assertEqual(self.render([item])[item["id"]]["source"], "marketplace")
            image.assert_called_once()
        self.assertEqual(app.thumbnail_failures(self.store), {})

    def test_image_failures_are_revision_keyed_exponential_and_clearable(self):
        item = {**self.one, "previewThumbnail": "https://plugins.omarchy.org/assets/img/plugins/failure.webp"}
        with mock.patch.object(app, "fetch_preview_image", side_effect=OSError("offline")) as image:
            for now in (1000, 1061, 1301, 1602):
                with mock.patch.object(app.time, "time", return_value=now):
                    self.render([item], enabled=False)
            self.assertEqual(image.call_count, 2)  # second failure backs off 600s
            with mock.patch.object(app.time, "time", return_value=1602):
                self.render([item], enabled=False, revision="new-catalog")
                self.assertEqual(image.call_count, 3)
                app.preview_cache_summary(self.store, clear=True)
                self.assertEqual(app.thumbnail_failures(self.store), {})
                self.render([item], enabled=False)
                self.assertEqual(image.call_count, 4)

    def test_broken_readme_image_has_independent_backoff_and_next_candidate_reuse(self):
        media = app.readme_media("![Screenshot](one.png)\n![Screenshot](two.png)", self.one)

        def download(url, **kwargs):
            if url.endswith("one.png"):
                raise ValueError("unsupported image")
            return self.image, "png"

        with mock.patch.object(app.time, "time", return_value=1000), \
                mock.patch.object(app, "fetch_readme", return_value={"ok": True, "media": media}), \
                mock.patch.object(app, "fetch_preview_image", side_effect=download) as image:
            result = self.render()
            self.assertEqual(result, self.render())
            self.assertEqual(image.call_count, 2)

    def test_clear_during_fetch_does_not_resurrect_negative_cache(self):
        item = {**self.one, "previewThumbnail": "https://plugins.omarchy.org/assets/img/plugins/failure.webp"}

        def download(*args, **kwargs):
            app.preview_cache_summary(self.store, clear=True)
            raise OSError("failed after explicit clear")

        with mock.patch.object(app, "fetch_preview_image", side_effect=download):
            self.render([item], enabled=False)
        self.assertEqual(app.thumbnail_failures(self.store), {})
