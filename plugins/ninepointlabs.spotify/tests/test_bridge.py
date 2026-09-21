"""Tests for the trust boundaries in bin/spotify-bridge: private state files,
bounded HTTP bodies, the login listener, the closed child environment and
trusted executable resolution.

Run with tests/run, or directly:

    /usr/bin/python3 -I -B -m unittest discover -s tests -v
"""

import errno
import http.server
import importlib.machinery
import importlib.util
import io
import json
import os
import pathlib
import shutil
import signal
import socket
import stat
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent.parent
BRIDGE = ROOT / "bin" / "spotify-bridge"

sys.dont_write_bytecode = True
_loader = importlib.machinery.SourceFileLoader("spotify_bridge", str(BRIDGE))
_spec = importlib.util.spec_from_loader("spotify_bridge", _loader)
bridge = importlib.util.module_from_spec(_spec)
_loader.exec_module(bridge)


def mode_of(path):
    return stat.S_IMODE(os.lstat(path).st_mode)


class TempHome(unittest.TestCase):
    """A private throwaway $HOME with every XDG directory pointed inside it,
    plus a 'victim' file that no attack in these tests may modify."""

    def setUp(self):
        self.home = os.path.realpath(tempfile.mkdtemp(prefix="spotify-bridge-test-"))
        os.chmod(self.home, 0o700)
        self.addCleanup(shutil.rmtree, self.home, True)
        env = {
            "HOME": self.home,
            "XDG_STATE_HOME": self.home + "/.local/state",
            "XDG_CACHE_HOME": self.home + "/.cache",
            "XDG_CONFIG_HOME": self.home + "/.config",
            "XDG_DATA_HOME": self.home + "/.local/share",
        }
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.reset_art_dir()
        self.addCleanup(self.reset_art_dir)
        self.victim = os.path.join(self.home, "victim.txt")
        with open(self.victim, "w") as fh:
            fh.write("precious\n")
        os.chmod(self.victim, 0o600)

    def reset_art_dir(self):
        if bridge._ART_DIR is not None:
            bridge._ART_DIR.close()
        bridge._ART_DIR = None

    def assertVictimIntact(self):
        with open(self.victim) as fh:
            self.assertEqual(fh.read(), "precious\n")

    @property
    def state(self):
        return os.path.join(self.home, ".local", "state", "omarchy-spotify")

    def make_state(self):
        os.makedirs(self.state, mode=0o700)
        return self.state


class StateFileTests(TempHome):
    def test_round_trip_is_private_and_leaves_no_temp_files(self):
        bridge.save_auth({"refresh_token": "r", "client_id": "c"})
        self.assertEqual(bridge.load_auth(), {"refresh_token": "r", "client_id": "c"})
        self.assertEqual(mode_of(self.state), 0o700)
        self.assertEqual(mode_of(os.path.join(self.state, "auth.json")), 0o600)
        self.assertEqual(os.listdir(self.state), ["auth.json"])

    def test_missing_state_is_signed_out(self):
        self.assertEqual(bridge.load_auth(), {})

    def test_symlink_at_auth_json_is_refused_for_read_and_write(self):
        link = os.path.join(self.make_state(), "auth.json")
        os.symlink(self.victim, link)
        with self.assertRaises(bridge.UnsafePath):
            bridge.load_auth()
        with self.assertRaises(bridge.UnsafePath):
            bridge.save_auth({"refresh_token": "attacker-wants-this"})
        self.assertTrue(os.path.islink(link))
        self.assertVictimIntact()

    def test_symlink_at_the_old_fixed_temp_name_is_never_written_through(self):
        os.symlink(self.victim, os.path.join(self.make_state(), "auth.json.tmp"))
        bridge.save_auth({"refresh_token": "r"})
        self.assertVictimIntact()
        self.assertFalse(os.path.lexists(os.path.join(self.state, "auth.json.tmp")))
        self.assertTrue(stat.S_ISREG(os.lstat(os.path.join(self.state, "auth.json")).st_mode))

    def test_a_planted_temp_name_collision_fails_closed(self):
        self.make_state()
        token = "ab" * 12
        os.symlink(self.victim, os.path.join(self.state, ".auth.json.%s.tmp" % token))
        with mock.patch.object(bridge.secrets, "token_hex", return_value=token):
            with self.assertRaises(FileExistsError):
                bridge.save_auth({"refresh_token": "r"})
        self.assertVictimIntact()
        self.assertFalse(os.path.lexists(os.path.join(self.state, "auth.json")))

    def test_fifo_is_refused_without_blocking(self):
        os.mkfifo(os.path.join(self.make_state(), "auth.json"), 0o600)

        def hung(signum, frame):
            raise AssertionError("reading a FIFO blocked")
        previous = signal.signal(signal.SIGALRM, hung)
        signal.alarm(5)
        try:
            with self.assertRaises(bridge.UnsafePath):
                bridge.load_auth()
            with self.assertRaises(bridge.UnsafePath):
                bridge.save_auth({"refresh_token": "r"})
        finally:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, previous)

    def test_oversized_token_file_is_refused(self):
        path = os.path.join(self.make_state(), "auth.json")
        with open(path, "wb") as fh:
            fh.write(b" " * (bridge.AUTH_MAX_BYTES + 1))
        os.chmod(path, 0o600)
        with self.assertRaises(bridge.UnsafePath):
            bridge.load_auth()

    def test_token_file_open_to_other_users_is_refused(self):
        path = os.path.join(self.make_state(), "auth.json")
        with open(path, "w") as fh:
            json.dump({"refresh_token": "r"}, fh)
        os.chmod(path, 0o640)
        with self.assertRaises(bridge.UnsafePath):
            bridge.load_auth()

    def test_hard_linked_token_file_is_refused(self):
        path = os.path.join(self.make_state(), "auth.json")
        with open(path, "w") as fh:
            json.dump({"refresh_token": "r"}, fh)
        os.chmod(path, 0o600)
        os.link(path, os.path.join(self.home, "second-name"))
        with self.assertRaises(bridge.UnsafePath):
            bridge.load_auth()

    def test_directory_at_auth_json_is_not_replaced(self):
        os.mkdir(os.path.join(self.make_state(), "auth.json"))
        with self.assertRaises(bridge.UnsafePath):
            bridge.save_auth({"refresh_token": "r"})

    def test_symlinked_plugin_state_directory_is_refused(self):
        os.makedirs(os.path.join(self.home, ".local", "state"))
        elsewhere = os.path.join(self.home, "elsewhere")
        os.mkdir(elsewhere, 0o700)
        os.symlink(elsewhere, self.state)
        with self.assertRaises(bridge.UnsafePath):
            bridge.save_auth({"refresh_token": "r"})
        with self.assertRaises(bridge.UnsafePath):
            bridge.load_auth()
        self.assertEqual(os.listdir(elsewhere), [])

    def test_safe_symlink_in_an_xdg_ancestor_is_followed(self):
        # A dotfile manager's relative link: ~/.local/state -> ../dotfiles/state
        real = os.path.join(self.home, "dotfiles", "state")
        os.makedirs(real, mode=0o700)
        os.makedirs(os.path.join(self.home, ".local"))
        os.symlink("../dotfiles/state", os.path.join(self.home, ".local", "state"))
        bridge.save_auth({"refresh_token": "r"})
        self.assertTrue(os.path.isfile(os.path.join(real, "omarchy-spotify", "auth.json")))
        self.assertEqual(bridge.load_auth(), {"refresh_token": "r"})

    def test_ancestor_writable_by_others_is_refused(self):
        os.makedirs(os.path.join(self.home, ".local", "state"))
        os.chmod(os.path.join(self.home, ".local"), 0o777)
        with self.assertRaises(bridge.UnsafePath):
            bridge.save_auth({"refresh_token": "r"})

    def test_failed_write_leaves_no_temp_file_and_keeps_the_old_file(self):
        bridge.save_auth({"refresh_token": "old"})
        with mock.patch.object(bridge.os, "fsync", side_effect=OSError(errno.EIO, "disk said no")):
            with self.assertRaises(OSError):
                bridge.save_auth({"refresh_token": "new"})
        self.assertEqual(os.listdir(self.state), ["auth.json"])
        self.assertEqual(bridge.load_auth(), {"refresh_token": "old"})

    def test_last_played_art_must_be_in_the_cover_cache(self):
        os.makedirs(os.path.join(self.home, ".cache", "omarchy-spotify", "art"))
        path = os.path.join(self.make_state(), "last-played.json")
        with open(path, "w") as fh:
            json.dump({"uri": "spotify:track:x", "artPath": "/etc/passwd"}, fh)
        self.assertEqual(bridge.load_last(), {})

    def test_last_played_round_trip(self):
        art = bridge.art_dir().entry("0" * 28 + ".jpg")
        bridge.remember_last({"uri": "spotify:track:abc", "name": "Song", "artPath": art})
        self.assertEqual(bridge.load_last()["artPath"], art)
        self.assertEqual(mode_of(os.path.join(self.state, "last-played.json")), 0o600)

    def test_symlink_in_cover_cache_is_replaced_not_followed(self):
        url = "https://i.scdn.co/image/abc"
        held = bridge.art_dir()
        name = bridge.hashlib.sha1(url.encode()).hexdigest()[:28] + ".jpg"
        os.symlink(self.victim, os.path.join(held.path, name))
        with mock.patch.object(bridge, "http_raw", return_value=(200, b"\xff\xd8jpeg", {})):
            self.assertEqual(bridge.cache_one(url), held.entry(name))
        self.assertVictimIntact()
        self.assertFalse(os.path.islink(held.entry(name)))

    def test_cover_from_a_non_spotify_host_is_not_fetched(self):
        with mock.patch.object(bridge, "http_raw") as fetch:
            self.assertEqual(bridge.cache_one("https://evil.example/cover.jpg"), "")
        fetch.assert_not_called()

    def test_a_symlinked_unit_is_never_ours_and_removal_takes_the_link(self):
        """The plugin no longer writes a unit, but it still removes the
        key-bearing one older versions left behind. That removal must take the
        name out of ~/.config/systemd/user and never follow it somewhere else."""
        unit_dir = os.path.join(self.home, ".config", "systemd", "user")
        os.makedirs(unit_dir, mode=0o700)
        unit = os.path.join(unit_dir, "soloist.service")
        with open(unit, "w") as fh:
            fh.write(bridge.UNIT_MARKER + "\n[Service]\nExecStart=/usr/bin/soloist\n")
        self.assertTrue(bridge.unit_is_ours())
        with open(self.victim, "w") as fh:
            fh.write(bridge.UNIT_MARKER + "\n")
        os.unlink(unit)
        os.symlink(self.victim, unit)
        # A link is never read as ours, however convincing what it points at.
        self.assertFalse(bridge.unit_is_ours())
        bridge.remove_our_unit()
        self.assertFalse(os.path.lexists(unit))
        self.assertTrue(os.path.exists(self.victim))


class NoCredentialPathTests(unittest.TestCase):
    """Soloist takes its API key only from `-k/--api-key` on the command line,
    so anything that starts Soloist puts the key where `ps`, `systemctl status`
    and crash reports can read it. The plugin's answer is to start nothing and
    store nothing: these tests pin that the credential path is gone from the
    shipped tree rather than merely unused."""

    def test_the_bridge_has_no_unit_or_key_writer(self):
        for name in ("write_soloist_env", "write_soloist_unit", "read_soloist_env",
                     "soloist_config_dir", "SOLOIST_KEY_RE"):
            self.assertFalse(hasattr(bridge, name), "%s is back" % name)

    def test_the_soloist_verbs_cannot_set_up_or_store_a_key(self):
        parser = bridge.build_parser()
        for verb in ("setup", "key"):
            with self.assertRaises(SystemExit):
                parser.parse_args(["soloist", verb, "--device-name", "x"])
        self.assertEqual(parser.parse_args(["soloist", "audit"]).action, "audit")

    def test_no_shipped_file_declares_a_command_to_run(self):
        """A repository-wide sweep, so a unit template — the only thing that
        ever put the key on a command line — cannot come back in any file the
        marketplace would ship.

        Markdown and `tests/` are exempt, and neither weakens the check: prose
        is not something systemd can load, and the suite has to name the
        pattern in order to look for it. Anything systemd *could* load is
        covered here and by `test_no_systemd_unit_is_shipped`."""
        offenders = []
        for path in sorted(ROOT.rglob("*")):
            rel = str(path.relative_to(ROOT))
            if not path.is_file() or rel.startswith((".git/", "tests/")):
                continue
            if path.suffix in (".png", ".jpg", ".md"):
                continue
            for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
                if line.lstrip().startswith(("ExecStart=", "ExecStartPre=", "EnvironmentFile=")):
                    offenders.append("%s: %s" % (rel, line.strip()[:80]))
        self.assertEqual(offenders, [], "a systemd unit is shipped again")

    def test_no_systemd_unit_is_shipped(self):
        self.assertFalse((ROOT / "contrib" / "systemd").exists())
        self.assertEqual(list(ROOT.glob("**/*.service")), [])

    def test_the_panel_has_no_key_entry(self):
        for name in ("Panel.qml", "Service.qml"):
            body = (ROOT / name).read_text(encoding="utf-8")
            self.assertNotIn("setSoloistKey", body)
            self.assertNotIn("soloistKeyField", body)


def fake_soloist(tmpdir, args, marker):
    """A live process whose command line looks exactly like Soloist's, so the
    audit can be pointed at real /proc entries rather than a fixture. Python is
    exec'd under the name `soloist`; everything after the -c script lands in
    the command line as Soloist's own arguments would."""
    name = os.path.join(tmpdir, "soloist")
    argv = [name, "-c", "import time; time.sleep(%d)" % 30, "--device-name", marker] + args
    pid = os.fork()
    if pid == 0:  # pragma: no cover - the child never returns
        try:
            os.execv(sys.executable, argv)
        finally:
            os._exit(127)
    return pid


class ArgvAuditTests(unittest.TestCase):
    """`soloist audit` — the check the marketplace review asks for. It reads
    live unit and process metadata and reports whether a Soloist API key is
    reachable from a command line, without ever echoing the key."""

    SECRET = "s3cr3t-soloist-key-value"

    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="soloist-audit-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.pids = []
        # No unit on the machine running the tests may leak into the result.
        patcher = mock.patch.object(bridge, "systemctl_user", return_value=(1, ""))
        patcher.start()
        self.addCleanup(patcher.stop)

    def spawn(self, args, marker):
        pid = fake_soloist(self.tmp, args, marker)
        self.pids.append(pid)
        self.addCleanup(self.reap, pid)
        # Wait for the exec to land, so /proc shows the new command line.
        for _ in range(200):
            try:
                with open("/proc/%d/cmdline" % pid, "rb") as fh:
                    if marker.encode() in fh.read():
                        return pid
            except OSError:
                pass
            time.sleep(0.01)
        self.fail("the fake soloist never showed up in /proc")

    def reap(self, pid):
        try:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        except OSError:
            pass

    def test_both_spellings_of_the_key_argument_are_recognised(self):
        self.assertTrue(bridge.argv_carries_key(["soloist", "-k", self.SECRET]))
        self.assertTrue(bridge.argv_carries_key(["soloist", "--api-key", self.SECRET]))
        self.assertTrue(bridge.argv_carries_key(["soloist", "--api-key=" + self.SECRET]))
        self.assertFalse(bridge.argv_carries_key(["soloist", "--device-name", "Omarchy"]))
        # A dangling flag with no value is not a key on the command line.
        self.assertFalse(bridge.argv_carries_key(["soloist", "--api-key"]))

    def test_a_finding_never_carries_the_key_itself(self):
        for argv in (["soloist", "-k", self.SECRET],
                     ["soloist", "--api-key", self.SECRET],
                     ["soloist", "--api-key=" + self.SECRET]):
            safe = bridge.redact_argv(argv)
            self.assertNotIn(self.SECRET, " ".join(safe))
            self.assertIn("<redacted>", " ".join(safe))

    def test_a_live_key_bearing_process_is_found_and_reported_redacted(self):
        self.spawn(["-k", self.SECRET], "audit-leaky")
        report = bridge.soloist_argv_audit()
        self.assertTrue(report["keyInCommandLine"])
        self.assertFalse(report["pluginWritesUnit"])
        self.assertFalse(report["pluginStoresKey"])
        leaky = [f for f in report["findings"]
                 if f["source"] == "process" and "audit-leaky" in " ".join(f["argv"])]
        self.assertEqual(len(leaky), 1)
        self.assertNotIn(self.SECRET, json.dumps(report))

    def test_a_soloist_started_without_a_key_audits_clean(self):
        """The scanner must not cry wolf over an ordinary Soloist command line.
        Scoped to this process by its marker, since the machine running the
        tests may have a real Soloist of its own."""
        pid = self.spawn([], "audit-clean")
        report = bridge.soloist_argv_audit()
        self.assertGreaterEqual(report["processesChecked"], 1)
        ours = [f for f in report["findings"]
                if f["where"] == "/proc/%d/cmdline" % pid or "audit-clean" in " ".join(f["argv"])]
        self.assertEqual(ours, [])

    def test_a_unit_that_expands_the_key_is_reported_without_it(self):
        """`systemctl show` reports ExecStart with `${SOLOIST_API_KEY}` still
        unexpanded, so the audit sees the shape of the command line and never
        the key — and reports it redacted even so."""
        shown = "\n".join([
            "FragmentPath=/home/someone/.config/systemd/user/soloist.service",
            "ExecStart={ path=/usr/bin/soloist ; argv[]=/usr/bin/soloist --device-name Omarchy "
            "--api-key ${SOLOIST_API_KEY} --ws 127.0.0.1:0 ; ignore_errors=no }",
        ])
        with mock.patch.object(bridge, "systemctl_user", return_value=(0, shown)):
            report = bridge.soloist_argv_audit()
        self.assertEqual(report["findings"][0]["where"],
                         "/home/someone/.config/systemd/user/soloist.service")
        unit = [f for f in report["findings"] if f["source"] == "unit"]
        self.assertEqual(len(unit), 1)
        self.assertIn("<redacted>", unit[0]["argv"])
        self.assertNotIn("${SOLOIST_API_KEY}", " ".join(unit[0]["argv"]))
        self.assertTrue(report["keyInCommandLine"])


class HostileServer(http.server.BaseHTTPRequestHandler):
    hits = []

    def log_message(self, *args):
        pass

    def do_GET(self):
        self.route()

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.route()

    def flood(self, status, total):
        self.send_response(status)
        self.send_header("Connection", "close")
        self.end_headers()
        chunk = b"x" * 65536
        try:
            for _ in range(total // len(chunk)):
                self.wfile.write(chunk)
        except OSError:
            pass

    def route(self):
        HostileServer.hits.append(self.path)
        if self.path == "/ok":
            body = b'{"ok": true}'
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/declared-huge":
            self.send_response(200)
            self.send_header("Content-Length", str(bridge.API_MAX_BYTES + 1))
            self.end_headers()
            self.wfile.write(b"{}")
        elif self.path == "/undeclared-huge" or self.path.startswith("/huge-accounts"):
            self.flood(200, 16 * 1024 * 1024)
        elif self.path == "/error-huge":
            self.flood(500, 4 * 1024 * 1024)
        elif self.path == "/error-small":
            body = b'{"error": {"status": 404, "message": "nope"}}'
            self.send_response(404)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/ok")
            self.send_header("Content-Length", "0")
            self.end_headers()
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()


class HttpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), HostileServer)
        cls.server.daemon_threads = True
        cls.base = "http://127.0.0.1:%d" % cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        HostileServer.hits = []
        patcher = mock.patch.object(bridge, "_OPENER", bridge.build_opener(allow_plain_http=True))
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_small_reply_is_read(self):
        status, body, _ = bridge.http("GET", self.base + "/ok")
        self.assertEqual((status, json.loads(body)), (200, {"ok": True}))

    def test_declared_oversized_body_is_refused_before_reading(self):
        with self.assertRaises(bridge.ResponseTooLarge):
            bridge.http("GET", self.base + "/declared-huge")

    def test_undeclared_oversized_body_is_cut_off_at_the_cap(self):
        started = time.monotonic()
        with self.assertRaises(bridge.ResponseTooLarge):
            bridge.http("GET", self.base + "/undeclared-huge")
        self.assertLess(time.monotonic() - started, 10)

    def test_oversized_error_body_is_refused(self):
        with self.assertRaises(bridge.ResponseTooLarge):
            bridge.http("GET", self.base + "/error-huge")

    def test_small_error_body_is_returned(self):
        status, body, _ = bridge.http("GET", self.base + "/error-small")
        self.assertEqual(status, 404)
        self.assertEqual(json.loads(body)["error"]["message"], "nope")

    def test_oversized_art_body_is_refused_at_its_own_cap(self):
        with self.assertRaises(bridge.ResponseTooLarge):
            bridge.http_raw("GET", self.base + "/undeclared-huge", limit=1024)

    def test_redirects_are_not_followed(self):
        status, _, headers = bridge.http("GET", self.base + "/redirect")
        self.assertEqual(status, 302)
        self.assertEqual(HostileServer.hits, ["/redirect"])

    def test_token_endpoint_body_is_capped(self):
        with mock.patch.object(bridge, "ACCOUNTS", self.base + "/huge-accounts"):
            with self.assertRaises(bridge.ResponseTooLarge):
                bridge.token_request({"grant_type": "refresh_token"})

    def test_production_opener_speaks_https_only(self):
        with mock.patch.object(bridge, "_OPENER", bridge.build_opener()):
            with self.assertRaises(bridge.ApiError) as caught:
                bridge.http("GET", self.base + "/ok")
        self.assertEqual(caught.exception.code, "network")
        self.assertEqual(HostileServer.hits, [])

    def test_whole_read_has_a_deadline(self):
        class Trickle:
            def read1(self, n):
                time.sleep(0.01)
                return b"x"
        with self.assertRaises(bridge.ApiError) as caught:
            bridge.read_bounded(Trickle(), 1 << 20, deadline=time.monotonic() + 0.2)
        self.assertEqual(caught.exception.code, "network")

    def test_art_urls_are_limited_to_spotify_image_hosts(self):
        allowed = bridge.art_url_allowed
        self.assertTrue(allowed("https://i.scdn.co/image/ab67616d0000b273"))
        self.assertTrue(allowed("https://mosaic.scdn.co/640/abc"))
        self.assertTrue(allowed("https://image-cdn-ak.spotifycdn.com/image/abc"))
        for url in ("http://i.scdn.co/image/x", "https://i.scdn.co.evil.example/x",
                    "https://evilscdn.co/x", "https://user:pw@i.scdn.co/x",
                    "https://i.scdn.co:8443/x", "file:///etc/passwd", "", None):
            self.assertFalse(allowed(url), url)


class ListenerTests(unittest.TestCase):
    def test_capped_reader_stops_at_its_limit(self):
        reader = bridge.CappedReader(io.BytesIO(b"G" * (1 << 20)), 1024)
        self.assertEqual(len(reader.readline(65537)), 1024)
        self.assertEqual(reader.readline(65537), b"")
        self.assertEqual(reader.read(10), b"")

    def request(self, port, payload):
        with socket.create_connection(("127.0.0.1", port), timeout=10) as sock:
            try:
                sock.sendall(payload)
            except OSError:
                pass
            chunks = []
            try:
                while True:
                    chunk = sock.recv(65536)
                    if not chunk:
                        break
                    chunks.append(chunk)
            except OSError:
                pass
            return b"".join(chunks)

    def test_listener_ignores_wrong_state_and_bounds_requests(self):
        bridge.CallbackHandler.expected_state = "right-state"
        bridge.CallbackHandler.result = {}
        server = http.server.HTTPServer(("127.0.0.1", 0), bridge.CallbackHandler)
        port = server.server_address[1]
        thread = threading.Thread(target=lambda: [server.handle_request() for _ in range(3)], daemon=True)
        thread.start()
        try:
            reply = self.request(port, b"GET /callback?state=wrong&code=abc HTTP/1.0\r\n\r\n")
            self.assertIn(b"did not match", reply)
            self.assertEqual(bridge.CallbackHandler.result, {})

            started = time.monotonic()
            self.request(port, b"GET /callback?state=wrong HTTP/1.0\r\n" + b"X-Junk: " + b"j" * (1 << 20) + b"\r\n\r\n")
            self.assertLess(time.monotonic() - started, 8)
            self.assertEqual(bridge.CallbackHandler.result, {})

            reply = self.request(port, b"GET /callback?state=right-state&code=good_Code-1 HTTP/1.0\r\n\r\n")
            self.assertIn(b"Connected to Spotify", reply)
            self.assertEqual(bridge.CallbackHandler.result, {"code": "good_Code-1"})
        finally:
            thread.join(10)
            server.server_close()


class EnvironmentTests(unittest.TestCase):
    HOSTILE = {
        "LD_PRELOAD": "/tmp/evil.so",
        "BASH_ENV": "/tmp/evil.sh",
        "BASH_FUNC_systemctl%%": "() { evil; }",
        "PYTHONPATH": "/tmp/evil",
        "https_proxy": "http://evil.example:8080",
        "SSL_CERT_FILE": "/tmp/evil.pem",
        "PATH": "/tmp/evil-bin:/usr/bin",
    }

    def test_child_environment_is_closed(self):
        env = dict(self.HOSTILE, HOME="/home/someone", USER="someone", WAYLAND_DISPLAY="wayland-1",
                   DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/bus\nLD_PRELOAD=/tmp/evil.so")
        with mock.patch.dict(os.environ, env, clear=True):
            closed = bridge.child_env()
            display = bridge.child_env(display=True)
        self.assertEqual(closed, {"PATH": bridge.TRUSTED_PATH, "HOME": "/home/someone", "USER": "someone", "LC_ALL": "C"})
        self.assertEqual(display["WAYLAND_DISPLAY"], "wayland-1")
        self.assertEqual(display["PATH"], bridge.TRUSTED_SESSION_PATH)
        for name in self.HOSTILE:
            if name != "PATH":
                self.assertNotIn(name, display)
        self.assertNotIn("DBUS_SESSION_BUS_ADDRESS", display)

    def test_relative_or_unnormalized_directories_are_ignored(self):
        with mock.patch.dict(os.environ, {"HOME": "/home/x", "XDG_STATE_HOME": "relative/state"}, clear=True):
            self.assertEqual(bridge.xdg_home("XDG_STATE_HOME", ".local", "state"), "/home/x/.local/state")
        with mock.patch.dict(os.environ, {"HOME": "/home/x", "XDG_CACHE_HOME": "/home/x/../y"}, clear=True):
            self.assertEqual(bridge.xdg_home("XDG_CACHE_HOME", ".cache"), "/home/x/.cache")

    def test_scrub_environment_keeps_only_the_allow_list(self):
        with mock.patch.dict(os.environ, dict(self.HOSTILE, HOME="/home/x", LANG="en_US.UTF-8"), clear=True):
            bridge.scrub_environment()
            self.assertEqual(dict(os.environ), {"HOME": "/home/x", "LANG": "en_US.UTF-8", "PATH": bridge.TRUSTED_PATH})

    def test_shebang_is_an_isolated_absolute_interpreter(self):
        with open(BRIDGE) as fh:
            self.assertEqual(fh.readline().rstrip("\n"), "#!/usr/bin/python3 -I")


class ExecutableTests(TempHome):
    def test_bad_tool_names_never_resolve(self):
        for name in ("", "../sh", "a/b", "-sh", "sh\n"):
            self.assertEqual(bridge.trusted_tool(name), "")

    @unittest.skipUnless(os.path.exists("/usr/bin/sh") or os.path.exists("/bin/sh"), "no system sh")
    def test_system_tool_resolves_to_an_absolute_trusted_path(self):
        path = bridge.trusted_tool("sh")
        self.assertIn(os.path.dirname(path), bridge.TRUSTED_BIN_DIRS)

    def test_user_owned_directory_is_never_trusted(self):
        fake = os.path.join(self.home, "bin")
        os.mkdir(fake)
        tool = os.path.join(fake, "systemctl")
        with open(tool, "w") as fh:
            fh.write("#!/bin/sh\n")
        os.chmod(tool, 0o755)
        self.assertEqual(bridge.trusted_tool("systemctl", (fake,)), "")

    def test_soloist_in_local_bin_needs_a_safe_owner_and_mode(self):
        local = os.path.join(self.home, ".local", "bin")
        os.makedirs(local)
        binary = os.path.join(local, "soloist")
        with open(binary, "w") as fh:
            fh.write("#!/bin/sh\n")
        os.chmod(binary, 0o755)
        with mock.patch.object(bridge, "trusted_tool", return_value=""):
            self.assertEqual(bridge.find_soloist(), binary)
            os.chmod(binary, 0o775)
            self.assertEqual(bridge.find_soloist(), "")
            os.chmod(binary, 0o755)
            os.chmod(local, 0o777)
            self.assertEqual(bridge.find_soloist(), "")
            os.chmod(local, 0o755)
            # A symlink into a directory others can write to is not accepted.
            shared = os.path.join(self.home, "shared")
            os.mkdir(shared)
            os.chmod(shared, 0o777)
            os.rename(binary, os.path.join(shared, "soloist"))
            os.symlink(os.path.join(shared, "soloist"), binary)
            self.assertEqual(bridge.find_soloist(), "")

    def test_run_tool_refuses_bare_names(self):
        self.assertEqual(bridge.run_tool(["systemctl", "--user"]), (1, ""))

    @unittest.skipUnless(os.path.exists("/usr/bin/env"), "no /usr/bin/env")
    def test_run_tool_gives_children_the_closed_environment(self):
        with mock.patch.dict(os.environ, {"BASH_ENV": "/tmp/evil.sh", "LEAK_CHECK": "1"}):
            code, text = bridge.run_tool(["/usr/bin/env"])
        self.assertEqual(code, 0)
        self.assertNotIn("BASH_ENV", text)
        self.assertNotIn("LEAK_CHECK", text)
        self.assertIn("PATH=" + bridge.TRUSTED_PATH, text.splitlines())


if __name__ == "__main__":
    unittest.main()
