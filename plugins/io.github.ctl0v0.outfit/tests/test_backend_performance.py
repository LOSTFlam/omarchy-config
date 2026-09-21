"""Offline backend race, cleanup and bounded-work regressions."""
import concurrent.futures
import errno
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

from tests.test_outfit import OUTFIT as app, ROOT


class CommandCleanupTests(unittest.TestCase):
    def command(self, source, timeout=0.05):
        processes = []
        popen = subprocess.Popen

        def launch(*args, **kwargs):
            process = popen(*args, **kwargs)
            processes.append(process)
            return process

        try:
            with mock.patch.object(app, "command_launch", return_value=(
                    [sys.executable, "-I", "-B", "-c", source], {"PATH": "/usr/bin:/bin"})), \
                    mock.patch.object(app.subprocess, "Popen", side_effect=launch):
                app.run_command([app.COMMANDS["git"]], timeout, 4096)
        finally:
            self.assertEqual(len(processes), 1)
            process = processes[0]
            # Check before emergency cleanup: a regression must not leave a
            # fixture process running after the test itself fails.
            try:
                self.assertIsNotNone(process.returncode)
                self.assertTrue(process.stdout.closed)
                self.assertNotIn(process, app._children)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, 9)
                    process.wait()

    def test_timeout_after_stdout_eof_is_builtin_timeout_and_reaps(self):
        with self.assertRaises(TimeoutError):
            self.command("import os,time; os.close(1); time.sleep(60)")

    def test_pipe_read_oserror_cleans_up(self):
        original = os.read

        def broken(fd, size):
            if any(child.stdout.fileno() == fd for child in app._children):
                raise OSError(errno.EIO, "failed pipe")
            return original(fd, size)

        with mock.patch.object(app.os, "read", side_effect=broken), self.assertRaises(OSError):
            self.command("import os,time; os.write(1,b'x'); time.sleep(60)", timeout=2)

    def test_subprocess_timeout_is_normalized_at_wait_boundary(self):
        with mock.patch.object(app, "_wait_command", side_effect=subprocess.TimeoutExpired("fixture", 0.1)), \
                self.assertRaises(TimeoutError):
            self.command("import os,time; os.close(1); time.sleep(60)", timeout=2)

    def test_selector_setup_and_cancellation_cleanup(self):
        for error in (OSError("selector setup"), KeyboardInterrupt()):
            with self.subTest(error=type(error).__name__), \
                    mock.patch.object(selectors, "DefaultSelector", side_effect=error), \
                    self.assertRaises(type(error)):
                self.command("import time; time.sleep(60)")

    def test_timeout_kills_descendant_after_leader_exit(self):
        # Descendant deliberately ignores TERM and keeps stdout open. A marker
        # would be written if group escalation accidentally skipped it.
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "survived"
            source = ("import os,signal,time; pid=os.fork(); "
                      "os._exit(0) if pid else None; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                      f"time.sleep(1); open({str(marker)!r},'w').close()")
            with self.assertRaises(TimeoutError):
                self.command(source, timeout=0.2)
            time.sleep(0.7)
            self.assertFalse(marker.exists())

    def test_failed_leader_with_stdout_closed_still_cleans_descendants(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "survived"
            source = ("import os,signal,time; os.close(1); pid=os.fork(); "
                      "os._exit(3) if pid else None; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                      f"time.sleep(1); open({str(marker)!r},'w').close()")
            with self.assertRaises(ValueError):
                self.command(source, timeout=2)
            time.sleep(0.7)
            self.assertFalse(marker.exists())


class ReadmeMergeTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.first = app.Store(Path(temp.name))
        self.second = app.Store(Path(temp.name))
        self.addCleanup(self.first.close)
        self.addCleanup(self.second.close)

    def entry(self, when, commit="a" * 40):
        return {"commit": commit, "text": "Fixture README", "content": "Fixture README",
                "summary": "Fixture README", "media": [], "contentVersion": app.README_CONTENT_VERSION,
                "documentVersion": 0, "documentSource": "", "fetchedAt": when}

    def test_stale_helpers_merge_without_losing_newer_or_unrelated_entries(self):
        app.save_readmes(self.first, {"example.one": self.entry(100)})
        stale = app.load_readmes(self.first)
        app.save_readmes(self.second, {"example.one": self.entry(200, "b" * 40),
                                            "example.two": self.entry(200)})
        stale["example.three"] = self.entry(150)
        merged = app.save_readmes(self.first, stale)
        self.assertEqual(set(merged), {"example.one", "example.two", "example.three"})
        self.assertEqual(merged["example.one"]["commit"], "b" * 40)
        stamp = self.first.stamp("readmes.json")
        app.save_readmes(self.second, merged)
        self.assertEqual(stamp, self.first.stamp("readmes.json"))

    def test_parallel_fetches_happen_outside_lock_and_both_results_survive(self):
        barrier = threading.Barrier(2)

        def fetch(item):
            barrier.wait(timeout=3)
            return {"ok": True, "text": item["id"], "content": item["id"], "summary": item["id"]}

        items = [{"id": "example." + name, "listingCommit": "a" * 40} for name in ("one", "two")]
        with mock.patch.object(app, "fetch_readme", side_effect=fetch), \
                concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            tasks = [executor.submit(app.enrich_readmes, store, [item], {})
                     for store, item in zip((self.first, self.second), items)]
            self.assertEqual([task.result(timeout=5) for task in tasks], [1, 1])
        self.assertEqual(set(app.load_readmes(self.first)), {item["id"] for item in items})

    def test_failed_enrichment_does_not_write_and_loaded_snapshots_are_not_mutated(self):
        app.save_readmes(self.first, {"example.one": self.entry(100)})
        entries = app.load_readmes(self.first)
        entries["example.two"] = self.entry(200)
        self.assertNotIn("example.two", app.load_readmes(self.first))
        before = self.first.stamp("readmes.json")
        with mock.patch.object(app, "fetch_readme", return_value={"ok": False}):
            self.assertEqual(app.enrich_readmes(self.first, [
                {"id": "example.three", "listingCommit": "a" * 40}], entries), 0)
        self.assertEqual(before, self.first.stamp("readmes.json"))

    def test_inspector_race_retains_newer_cache_but_renders_requested_pinned_document(self):
        raw = json.loads((ROOT / "demo/fixtures/example.json").read_text())["catalog"]
        items, generated = app.normalize_catalog(raw)
        target = items[0]
        app.save_catalog(self.first, items, generated, 100)

        def fetch(item):
            app.save_readmes(self.second, {item["id"]: self.entry(300, "f" * 40)})
            return {"ok": True, "text": "Requested pinned README", "content": "Requested pinned README",
                    "summary": "Requested pinned README", "media": []}

        with mock.patch.object(app, "fetch_readme", side_effect=fetch), \
                mock.patch.object(app, "fetch_bytes", side_effect=AssertionError("network")), \
                mock.patch.object(app, "run_command", side_effect=AssertionError("native")):
            result = app.run({"action": "readme-plugin", "localOnly": True, "pluginId": target["id"]}, self.first, now=200)
        self.assertEqual(result["readmeContent"], "Requested pinned README")
        self.assertEqual(app.load_readmes(self.first)[target["id"]]["commit"], "f" * 40)


class CheapInventoryTests(unittest.TestCase):
    def test_presence_scan_does_not_read_manifests_or_git_but_default_still_enriches(self):
        rows = [{"id": f"example.plugin-{number}", "enabled": True} for number in range(500)]
        with mock.patch.object(app, "run_command", return_value=json.dumps(rows).encode()), \
                mock.patch.object(app, "scan_bar_sections", return_value={rows[0]["id"]: "left"}), \
                mock.patch.object(app, "inventory_version_metadata", side_effect=lambda item, deadline: {
                    **item, "installedVersion": "1.2", "installedRevision": "a" * 40}) as enrich:
            inventory, unavailable = app.scan_inventory(include_versions=False)
            self.assertFalse(unavailable)
            self.assertEqual(len(inventory), 500)
            self.assertEqual(inventory[0]["barSection"], "left")
            enrich.assert_not_called()
            inventory, _ = app.scan_inventory()
            self.assertEqual(enrich.call_count, 500)
            self.assertEqual(inventory[0]["installedVersion"], "1.2")


class QueryLRUTests(unittest.TestCase):
    def test_fifth_query_evicts_least_recent_not_all_and_hits_refresh_recency(self):
        item = {"id": "example.widget", "name": "Fixture", "tags": [], "description": "alpha beta gamma delta epsilon"}
        original = app.search_evidence(item, "alpha")
        for query in ("beta", "gamma", "delta"):
            app.search_evidence(item, query)
        self.assertIs(app.search_evidence(item, "alpha"), original)
        app.search_evidence(item, "epsilon")
        cache = item["_searchEvidenceCache"]
        self.assertEqual(len(cache), 4)
        self.assertEqual({key[0] for key in cache}, {"alpha", "gamma", "delta", "epsilon"})
        self.assertIs(app.search_evidence(item, "alpha"), original)


class IndexProgressTests(unittest.TestCase):
    def test_progress_updates_counts_without_rescanning_full_index_per_document(self):
        with tempfile.TemporaryDirectory() as directory:
            store = app.Store(Path(directory))
            self.addCleanup(store.close)
            items = [{"id": f"example.plugin-{number}", "repo": "https://github.com/example/fixture",
                      "listingCommit": f"{number + 1:040x}"} for number in range(app.README_FETCH_LIMIT)]
            events = []
            with mock.patch.object(app, "fetch_search_readme", return_value={"ok": True, "searchText": "Fixture instructions"}), \
                    mock.patch.object(app, "readme_index_data", wraps=app.readme_index_data) as summary:
                result = app.index_readmes(store, items, 1000, lambda *args, **kwargs: events.append(kwargs))
                self.assertEqual(summary.call_count, 2)
            self.assertEqual(result["documents"]["indexed"], len(items))
            self.assertEqual([event["documents"]["indexed"] for event in events], list(range(1, len(items) + 1)))
            self.assertEqual(events[-1]["documents"], result["documents"])
