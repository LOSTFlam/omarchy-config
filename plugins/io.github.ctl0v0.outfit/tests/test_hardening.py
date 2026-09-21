from __future__ import annotations

import errno
import fcntl
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

from tests.test_outfit import OUTFIT, ROOT


class HardeningTests(unittest.TestCase):
    def test_slow_drip_response_obeys_total_deadline(self) -> None:
        class Drip(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Length", "1000")
                self.end_headers()
                try:
                    for _ in range(1000):
                        self.wfile.write(b"x")
                        self.wfile.flush()
                        time.sleep(0.025)
                except (BrokenPipeError, ConnectionResetError):
                    pass
            def log_message(self, *_args):
                pass
        server = ThreadingHTTPServer(("127.0.0.1", 0), Drip)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=1)
        try:
            connection.request("GET", "/")
            response = connection.getresponse()
            started = time.monotonic()
            with response, self.assertRaises(TimeoutError):
                OUTFIT.read_bounded_response(response, 2000, started + 0.15)
            self.assertLess(time.monotonic() - started, 0.7)
        finally:
            connection.close()
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_dead_staging_cleanup_preserves_active_writer_and_unrelated_data(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            orphan = base / (".write-v2-" + "a" * 32)
            active = base / (".write-v2-" + "b" * 32)
            orphan.write_bytes(b"abandoned")
            active.write_bytes(b"writing")
            (base / "preferences.json").write_text("keep me")
            with active.open("rb") as stream:
                fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
                store = OUTFIT.Store(base)
                try:
                    self.assertFalse(orphan.exists())
                    self.assertTrue(active.exists())
                    self.assertEqual((base / "preferences.json").read_text(), "keep me")
                finally:
                    store.close()

    def test_reader_observes_other_workers_atomic_catalog_replacement(self) -> None:
        fixture = json.loads((ROOT / "demo/fixtures/example.json").read_text())
        items, generated = OUTFIT.normalize_catalog(fixture["catalog"])
        with tempfile.TemporaryDirectory() as directory:
            reader, writer = OUTFIT.Store(Path(directory)), OUTFIT.Store(Path(directory))
            try:
                OUTFIT.save_catalog(writer, items, generated, 10)
                self.assertEqual(len(OUTFIT.load_catalog(reader)[0]), 3)
                OUTFIT.save_catalog(writer, items[:1], generated, 20)
                self.assertEqual(len(OUTFIT.load_catalog(reader)[0]), 1)
            finally:
                reader.close()
                writer.close()

    def test_permission_and_space_failures_are_actionable_and_correlated(self) -> None:
        for code in (errno.ENOSPC, errno.EDQUOT, errno.EROFS, errno.EACCES):
            result = OUTFIT.error_response(OSError(code, "secret /personal/path"),
                                          {"action": "save-preferences", "generation": 7})
            self.assertEqual(result["generation"], 7)
            self.assertEqual(result["errorCode"], "storage-unavailable")
            self.assertNotIn("/personal", result["error"])
            self.assertIn("retry", result["error"].lower())

    def test_real_worker_recovers_after_bad_frame_in_unicode_xdg_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            environment = dict(os.environ, XDG_CACHE_HOME=directory + "/cache # 雪",
                               XDG_CONFIG_HOME=directory + "/config space", PYTHONDONTWRITEBYTECODE="1")
            result = subprocess.run([sys.executable, str(ROOT / "scripts/outfit.py"), "--serve"],
                                    input=b'bad json\n{"action":"load","generation":2}\n',
                                    capture_output=True, env=environment, timeout=5)
            replies = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertFalse(replies[0]["ok"])
            self.assertTrue(replies[1]["ok"])
            self.assertEqual(replies[1]["generation"], 2)
            self.assertEqual(result.returncode, 0)

    def test_failed_store_startup_still_returns_correlated_protocol_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / OUTFIT.APP_ID).symlink_to(base, target_is_directory=True)
            result = subprocess.run([sys.executable, str(ROOT / "scripts/outfit.py"), "--serve"],
                input=b'{"action":"load","generation":12}\n', capture_output=True,
                env=dict(os.environ, XDG_CACHE_HOME=directory), timeout=5)
            reply = json.loads(result.stdout)
            self.assertFalse(reply["ok"])
            self.assertEqual(reply["generation"], 12)
            self.assertEqual(reply["action"], "load")

    def test_timed_out_probe_terminates_descendant_after_leader_exits(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            pidfile = Path(directory) / "child.pid"
            with mock.patch.dict(OUTFIT.COMMANDS, fixture=sys.executable), \
                    mock.patch.dict(os.environ, {"OMARCHY_PATH": ""}):
                with self.assertRaises(TimeoutError):
                    OUTFIT.run_command([sys.executable, str(ROOT / "tests/fixtures/probe.py"),
                                        "descendant", str(pidfile)], 0.3, 1024)
            pid = int(pidfile.read_text())
            for _ in range(20):
                path = Path(f"/proc/{pid}/stat")
                try:
                    state = path.read_text().split(") ", 1)[1]
                except FileNotFoundError:
                    # Successful reaping may race the observation itself.
                    break
                if state.startswith("Z"):
                    break
                time.sleep(0.05)
            else:
                self.fail("Probe descendant survived cancellation")

    def test_preview_clear_is_narrow_and_diagnostics_are_redacted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory))
            try:
                png = b"\x89PNG\r\n\x1a\n" + bytes(8) + (800).to_bytes(4, "big") + (450).to_bytes(4, "big")
                store.write_blob("preview-0-aaaaaaaaaaaa.png", png, 4096)
                store.write("preferences.json", OUTFIT.DEFAULT_PREFERENCES, 4096)
                (Path(directory) / "private-note.txt").write_text("PRIVATE HOSTNAME")
                with mock.patch.object(OUTFIT, "run_command", return_value=b"omarchy 4.0.3-1\nqt6-base 6.11.2-1\n"):
                    result = OUTFIT.run({"action":"clear-previews", "generation":4}, store)
                self.assertTrue(result["ok"])
                self.assertEqual(result["diagnostics"]["previews"]["files"], 0)
                self.assertTrue((Path(directory) / "preferences.json").exists())
                self.assertTrue((Path(directory) / "private-note.txt").exists())
                report = json.dumps(result["diagnostics"])
                self.assertNotIn(directory, report)
                self.assertNotIn("PRIVATE HOSTNAME", report)
                self.assertNotIn("services", report)
            finally:
                store.close()

    def test_cached_startup_and_local_analysis_do_not_require_network(self) -> None:
        fixture = json.loads((ROOT / "demo/fixtures/example.json").read_text())
        items, generated = OUTFIT.normalize_catalog(fixture["catalog"])
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory))
            try:
                OUTFIT.save_catalog(store, items, generated, 1)
                with mock.patch.object(OUTFIT, "fetch_bytes", side_effect=AssertionError("network")), \
                        mock.patch.object(OUTFIT, "fetch_readme", side_effect=AssertionError("network")), \
                        mock.patch.object(OUTFIT, "scan_profile", return_value=(fixture["profile"], [], [])):
                    cached = OUTFIT.run({"action":"load"}, store, now=999999)
                    scanned = OUTFIT.run({"action":"analyze", "localOnly":True}, store, now=999999)
                self.assertEqual(len(cached["setup"]["rows"]), 3)
                self.assertTrue(scanned["inventoryAuthoritative"])
                self.assertEqual(scanned["readmesFetched"], 0)
            finally:
                store.close()

    def test_shared_thumbnail_asset_is_downloaded_once_per_batch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory))
            try:
                url = "https://plugins.omarchy.org/assets/img/plugins/shared-card.webp"
                image = b"\x89PNG\r\n\x1a\n" + bytes(8) + (800).to_bytes(4, "big") + (450).to_bytes(4, "big")
                with mock.patch.object(OUTFIT, "fetch_preview_image", return_value=(image, "png")) as fetch:
                    result = OUTFIT.materialize_thumbnails(store, [
                        {"id":"example.one", "previewThumbnail":url},
                        {"id":"example.two", "previewThumbnail":url},
                    ], "revision")
                fetch.assert_called_once_with(url)
                self.assertEqual(result["example.one"], result["example.two"])
            finally:
                store.close()

    def test_fixture_worker_uses_private_state_and_refuses_real_mutations(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            response = subprocess.run([sys.executable, "-I", str(ROOT / "demo/fixture_worker.py")],
                input=b'{"action":"install-plugin","generation":5,"pluginId":"example.dock-helper"}\n',
                capture_output=True, env=dict(os.environ, OUTFIT_DEMO_ROOT=directory), timeout=5)
            reply = json.loads(response.stdout)
            self.assertFalse(reply["ok"])
            self.assertEqual(reply["generation"], 5)
            self.assertIn("mutations are disabled", reply["error"])
            self.assertTrue((Path(directory) / "config" / OUTFIT.APP_ID / "preferences.json").is_file())
