from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import urllib.error

from tests.test_outfit import OUTFIT as app, ROOT


class ReadmeIndexTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.store = app.Store(Path(self.directory.name))
        self.addCleanup(self.store.close)
        raw = json.loads((ROOT / "demo/fixtures/example.json").read_text())
        self.items, self.generated = app.normalize_catalog(raw["catalog"])
        app.save_catalog(self.store, self.items, self.generated, 100)

    def document(self, text="orbitalwidgets", **values):
        return {"ok": True, "searchText": text, "path": "README.md", **values}

    def test_readme_only_search_is_local_and_preserves_selected_sort(self):
        with app.ReadmeIndex(self.store, create=True) as index:
            for item in self.items[:2]:
                index.put(app.readme_key(item), self.document("Introduction " * 120 + "orbitalwidgets"), 100)
        with mock.patch.object(app, "fetch_bytes", side_effect=AssertionError("Search must be local")):
            result = app.run({"action": "quick-setup", "setupQuery": "orbitalwidgets", "setupSort": "name"}, self.store, now=200)
            rows = result["setup"]["rows"]
            self.assertEqual({row["id"] for row in rows}, {item["id"] for item in self.items[:2]})
            self.assertTrue(all(row["searchReason"] == "README matches your search" for row in rows))
            self.assertEqual([r["name"] for r in rows], sorted(r["name"] for r in rows))
            legacy = app.run({"action": "search", "query": "orbitalwidgets"}, self.store, now=200)
            self.assertEqual(len(legacy["rows"]), 2)
            app.save_preferences(self.store, {**app.DEFAULT_PREFERENCES, "readmeEnrichment": False})
            self.assertEqual(app.run({"action": "quick-setup", "setupQuery": "orbitalwidgets"}, self.store)["setup"]["total"], 0)

    def test_progress_exceeds_candidate_and_preview_limits_and_resumes(self):
        items = [{**self.items[0], "id": f"example.item-{i}", "listingCommit": f"{i + 1:040x}"} for i in range(325)]
        with mock.patch.object(app, "fetch_search_readme", return_value=self.document()) as fetch:
            for _ in range(28):
                status = app.index_readmes(self.store, items, 100)
            self.assertEqual(status["indexed"], 325)
            self.assertEqual(status["due"], 0)
            self.assertEqual(fetch.call_count, 325)
            app.index_readmes(self.store, items, 200)
            self.assertEqual(fetch.call_count, 325)
        status = app.readme_index_data(self.store, items, "orbitalwidgets", now=200)
        self.assertEqual(status["indexed"], 325)
        self.assertTrue(all(app.search_score(item, "orbitalwidgets")[0] > 0 for item in items))

    def test_failures_back_off_and_do_not_starve_the_next_batch(self):
        items = [{**self.items[0], "id": f"example.item-{i}", "listingCommit": f"{i + 1:040x}"} for i in range(15)]
        def fetch_document(item):
            return {"ok": False} if int(item["id"].split("-")[-1]) < 12 else self.document()
        with mock.patch.object(app, "fetch_search_readme", side_effect=fetch_document) as fetch:
            first = app.index_readmes(self.store, items, 100)
            self.assertEqual(first["failed"], 12)
            self.assertEqual(first["due"], 3)
            app.index_readmes(self.store, items, 200)
            self.assertEqual(fetch.call_count, 12)
            # After the network backoff, fresh documents take priority over retries.
            second = app.index_readmes(self.store, items, 400)
            self.assertEqual(second["failed"], 12)
            self.assertEqual(second["indexed"], 3)
            self.assertEqual(fetch.call_count, 24)

    def test_github_rate_limit_is_remembered_across_workers(self):
        with mock.patch.object(app, "fetch_search_readme", return_value={"ok":False, "cooldown":900}) as fetch:
            result = app.index_readmes(self.store, self.items, 100)
            self.assertEqual(result["retryAt"], 1000)
            count = fetch.call_count
            app.index_readmes(self.store, self.items, 999)
            self.assertEqual(fetch.call_count, count)

    def test_repository_revision_and_shared_document_identity(self):
        duplicate = {**self.items[0], "id": "example.alias"}
        with mock.patch.object(app, "fetch_search_readme", return_value=self.document()) as fetch:
            result = app.index_readmes(self.store, [self.items[0], duplicate], 100)
            self.assertEqual(result["indexed"], 2)
            fetch.assert_called_once()
        changed = {**duplicate, "listingCommit": "f" * 40}
        app.readme_index_data(self.store, [changed], "orbitalwidgets")
        self.assertEqual(app.search_score(changed, "orbitalwidgets")[0], 0)
        with app.ReadmeIndex(self.store, create=True) as index:
            index.sync([changed], {}, 200)
            self.assertEqual(len(index.states()), 1)
            self.assertEqual(index.matches("orbitalwidgets"), {})

    def test_incremental_commits_and_concurrent_connections_keep_both_documents(self):
        with app.ReadmeIndex(self.store, create=True) as first, app.ReadmeIndex(self.store, create=True) as second:
            first.put(app.readme_key(self.items[0]), self.document(), 100)
            second.put(app.readme_key(self.items[1]), self.document(), 100)
            # A failed upgrade preserves useful same-revision text.
            first.put(app.readme_key(self.items[0]), {"ok": False}, 200)
        with app.ReadmeIndex(self.store) as reopened:
            self.assertEqual(len(reopened.matches("orbitalwidgets")), 2)
            self.assertEqual(reopened.matches("wi"), {})  # README substrings are not words.

    def test_readonly_reopens_and_noop_ownership_changes_keep_index_caches_warm(self):
        for active_writer in (False, True):
            with self.subTest(active_writer=active_writer), app.ReadmeIndex(self.store, create=True) as writer:
                writer.put(app.readme_key(self.items[0]), self.document(), 100)
                if not active_writer:
                    writer.close()
                # The first reader may create the WAL. Warm after it exists.
                app.readme_index_snapshot(self.store)
                states = app.readme_index_snapshot(self.store)
                matches = app.indexed_search_matches(self.store, "orbitalwidgets")
                stamp = app.readme_index_stamp(self.store)
                wal = self.store.base / "readme-search.sqlite-wal"
                before = wal.stat()
                self.assertEqual(before.st_size > 0, active_writer)
                # Like root-only SQLite fchown, chmod to the existing mode
                # changes ctime without changing bytes or access permissions.
                wal.chmod(before.st_mode & 0o777)
                self.assertNotEqual(wal.stat().st_ctime_ns, before.st_ctime_ns)
                with app.ReadmeIndex(self.store) as reader:
                    self.assertEqual(reader.states(), states[0])
                self.assertEqual(app.readme_index_stamp(self.store), stamp)
                with mock.patch.object(app, "ReadmeIndex", side_effect=AssertionError("Warm cache reopened SQLite")), \
                        mock.patch.object(app.os, "open", side_effect=AssertionError("Warm cache reread WAL")):
                    self.assertEqual(app.readme_index_snapshot(self.store), states)
                    self.assertEqual(app.indexed_search_matches(self.store, "orbitalwidgets"), matches)

    def test_sidecar_content_restored_mtime_identity_and_permissions_invalidate(self):
        for suffix in ("-wal", "-journal"):
            with self.subTest(suffix=suffix):
                path = self.store.base / ("readme-search.sqlite" + suffix)
                path.write_bytes(b"first contents")
                before = path.stat()
                stamp = app.readme_index_stamp(self.store)
                path.write_bytes(b"other contents")
                os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
                self.assertEqual(path.stat().st_size, before.st_size)
                changed = app.readme_index_stamp(self.store)
                self.assertNotEqual(changed, stamp)
                replacement = self.store.base / "replacement"
                replacement.write_bytes(path.read_bytes())
                os.utime(replacement, ns=(before.st_atime_ns, before.st_mtime_ns))
                replacement.replace(path)
                replaced = app.readme_index_stamp(self.store)
                self.assertNotEqual(replaced, changed)
                path.chmod(0o400)
                self.assertNotEqual(app.readme_index_stamp(self.store), replaced)

    def test_unsafe_sidecars_are_not_hashed_or_hidden_by_warm_stamps(self):
        for suffix in ("-wal", "-journal"):
            with self.subTest(suffix=suffix):
                path = self.store.base / ("readme-search.sqlite" + suffix)
                path.write_bytes(b"fixture")
                stamp = app.readme_index_stamp(self.store)
                with mock.patch.object(app.os, "getuid", return_value=os.getuid() + 1), \
                        mock.patch.object(app.os, "open", side_effect=AssertionError("Unsafe file opened")):
                    self.assertNotEqual(app.readme_index_stamp(self.store), stamp)
                    with self.assertRaises(ValueError):
                        app.ReadmeIndex(self.store)
                path.unlink()
                path.symlink_to(self.store.base / "catalog.json")
                with mock.patch.object(app.os, "open", side_effect=AssertionError("Symlink opened")):
                    self.assertNotEqual(app.readme_index_stamp(self.store), stamp)
                    with self.assertRaises(ValueError):
                        app.ReadmeIndex(self.store)
                path.unlink()

    def test_sidecar_open_race_does_not_poison_verified_stamp(self):
        name = "readme-search.sqlite-wal"
        path = self.store.base / name
        path.write_bytes(b"fixture")
        verified = app.readme_index_stamp(self.store)
        path.chmod(path.stat().st_mode & 0o777)
        with mock.patch.object(app.os, "open", side_effect=FileNotFoundError("Concurrent checkpoint")):
            self.assertNotEqual(app.readme_index_stamp(self.store), verified)
        self.assertEqual(app.readme_index_stamp(self.store), verified)

    def test_readonly_empty_index_and_corruption_do_not_break_listing_search(self):
        app.readme_index_data(self.store, self.items, "dock")
        self.assertFalse((self.store.base / "readme-search.sqlite").exists())
        (self.store.base / "readme-search.sqlite").write_bytes(b"not a database")
        result = app.run({"action": "quick-setup", "setupQuery": "dock"}, self.store)
        self.assertTrue(result["readmeIndex"]["error"])
        self.assertGreater(result["setup"]["total"], 0)

    def test_disabled_and_local_only_index_requests_never_download(self):
        with mock.patch.object(app, "fetch_search_readme", side_effect=AssertionError("No download")):
            app.run({"action": "index-readmes", "localOnly": True}, self.store)
            app.save_preferences(self.store, {**app.DEFAULT_PREFERENCES, "readmeIndexing": False})
            app.run({"action": "index-readmes"}, self.store)
        self.assertFalse((self.store.base / "readme-search.sqlite").exists())

    def test_bounded_pinned_fallback_and_code_text_are_indexed(self):
        missing = urllib.error.HTTPError("https://raw.githubusercontent.com/", 404, "Missing", {}, None)
        self.addCleanup(missing.close)
        body = b"<!-- hidden -->\nIntro\n```sh\norbitalwidgets --enable\n```"
        with mock.patch.object(app, "fetch_bytes", side_effect=[missing, body]) as fetch:
            result = app.fetch_search_readme(self.items[0])
        self.assertEqual(result["path"], "readme.md")
        self.assertIn("orbitalwidgets", result["searchText"])
        self.assertNotIn("hidden", result["searchText"])
        for call in fetch.call_args_list:
            self.assertIn("/" + self.items[0]["listingCommit"] + "/", call.args[0])
            self.assertEqual(call.args[2], app.MAX_README_BYTES)
        with mock.patch.object(app, "fetch_bytes", side_effect=missing) as fetch:
            self.assertTrue(app.fetch_search_readme(self.items[0])["unavailable"])
            self.assertEqual(fetch.call_count, 6)

    def test_private_storage_rejects_symlink_and_has_explicit_capacity(self):
        target = self.store.base / "readme-search.sqlite"
        target.symlink_to(self.store.base / "other")
        with self.assertRaises(ValueError):
            app.ReadmeIndex(self.store, create=True)
        target.unlink()
        with app.ReadmeIndex(self.store, create=True) as index:
            page = index.db.execute("PRAGMA page_size").fetchone()[0]
            limit = index.db.execute("PRAGMA max_page_count").fetchone()[0]
            self.assertLessEqual(page * limit, app.MAX_SEARCH_INDEX_BYTES)
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)


class LauncherTests(unittest.TestCase):
    def test_repeatable_install_remove_and_unmanaged_collision(self):
        spec = importlib.util.spec_from_file_location("launcher", ROOT / "scripts/launcher.py")
        launcher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(launcher)
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            launcher.sync(data)
            desktop = data / "applications/io.github.ctl0v0.outfit.desktop"
            before = desktop.stat().st_mtime_ns
            launcher.sync(data)
            self.assertEqual(before, desktop.stat().st_mtime_ns)
            self.assertIn("Exec=omarchy-shell shell summon io.github.ctl0v0.outfit", desktop.read_text())
            launcher.sync(data, remove=True)
            self.assertFalse(desktop.exists())
            desktop.write_text("[Desktop Entry]\nName=My custom launcher\n")
            with self.assertRaises(ValueError):
                launcher.sync(data)
            self.assertIn("My custom launcher", desktop.read_text())
