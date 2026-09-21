"""Real Git updates, with only public fetch transport and shell IPC substituted.

The same cases exercise ordinary plugin IDs and Outfit's self-update identity.
Transaction/restart ownership is separately covered by test_self_update.py.
"""
import json
from pathlib import Path
import shutil
import sys
import unittest
from unittest import mock

from tests import test_pinned_install as fixtures
from tests.test_outfit import OUTFIT as app


class PinnedUpdateTests(unittest.TestCase):
    plugin_id = "example.pinned"

    def setUp(self):
        f = self.fixture = fixtures.PinnedInstallTests()
        f.identity = self.plugin_id
        self.addCleanup(f.doCleanups)
        f.setUp()
        f.install()
        self.before = f.reviewed
        manifest = json.loads((f.remote / "manifest.json").read_text())
        manifest["version"] = "1.1.0"
        (f.remote / "manifest.json").write_text(json.dumps(manifest))
        (f.remote / "payload.txt").write_text("reviewed update\n")
        (f.remote / "install.py").write_text("from pathlib import Path\n(Path.home() / 'REVIEWED-UPDATE-RAN').touch()\n")
        f.git(f.remote, "add", ".")
        f.git(f.remote, "commit", "-m", "Reviewed update B")
        self.expected = f.reviewed = f.git(f.remote, "rev-parse", "HEAD")
        (f.remote / "payload.txt").write_text("moved unreviewed HEAD\n")
        (f.remote / "install.py").write_text("from pathlib import Path\n(Path.home() / 'MOVED-HEAD-RAN').touch()\n")
        f.git(f.remote, "add", ".")
        f.git(f.remote, "commit", "-m", "Unreviewed C")
        self.moved = f.git(f.remote, "rev-parse", "HEAD")
        f.git(f.remote, "reset", "--hard", self.expected)
        f.native_calls.clear()
        f.stages.clear()
        self.item = app.validate_inventory([{"id": f.identity, "enabled": True, "barSection": "right",
                                             "barSectionKnown": True, "kinds": ["service"]}])[0]
        patch = mock.patch.object(app, "scan_inventory", side_effect=lambda **kwargs: ([dict(self.item)], False))
        patch.start()
        self.addCleanup(patch.stop)
        self.local = app.inspect_update_target(self.item)
        self.assertEqual(self.local["state"], "ready")
        self.config_before = (f.target / ".git/config").read_bytes()
        self.environment = None
        self.during_fetch = None
        self.during_native = None
        self.native_timeout = False
        self.wrong_mapping = False
        self.write_router()
        patch = mock.patch.object(app, "run_bounded_process", side_effect=self.process)
        patch.start()
        self.addCleanup(patch.stop)

    def write_router(self):
        f = self.fixture
        # Mimic the stock fetch/ff/validate/rollback ordering. Deliberately run a
        # plugin code sentinel at the execution boundary to detect loading C.
        f.write_executable("omarchy", f'''import os, subprocess, sys
from pathlib import Path
action, value = sys.argv[2:4]
expected = {self.expected!r}
def git(path, *args):
    return subprocess.check_output(["/usr/bin/git", "-C", str(path), *args], text=True).strip()
if action == "validate":
    assert git(value, "rev-parse", "HEAD") == expected
    if Path(value) == Path({str(f.target)!r}) and (Path.home() / "reject-installed").exists():
        sys.exit(1)
    sys.exit(0)
assert action == "update" and value == {f.identity!r} and sys.argv[4:] == ["--yes"]
target = Path({str(f.target)!r})
source = Path(git(target, "remote", "get-url", "origin"))
assert source.name.startswith("outfit-reviewed-") and source.stat().st_mode & 0o077 == 0
assert git(source, "rev-parse", "HEAD") == expected
assert (source / "payload.txt").read_text() == "reviewed update\\n"
old = git(target, "rev-parse", "HEAD")
git(target, "fetch", "--quiet", "origin", "HEAD")
assert git(target, "rev-parse", "FETCH_HEAD") == expected
git(target, "merge", "--ff-only", "FETCH_HEAD")
if subprocess.run([sys.argv[0], "plugin", "validate", str(target)]).returncode:
    git(target, "reset", "--hard", old)
    sys.exit(1)
assert git(target, "rev-parse", "HEAD") == expected
subprocess.run([{sys.executable!r}, "-I", "-B", str(target / "install.py")], check=True)
''')

    def process(self, argv, environment, timeout, maximum, cwd=None):
        f = self.fixture
        native = argv[:3] == [str(f.bindir / "omarchy"), "plugin", "update"]
        if native:
            self.environment = dict(environment)
            # Remote moves AFTER Outfit has checked/staged the reviewed target,
            # just before native fetch. The process-local origin must remain B.
            f.git(f.remote, "reset", "--hard", self.moved)
            if self.during_native:
                self.during_native()
        if self.wrong_mapping and argv[-4:] == ["remote", "get-url", "--all", "origin"]:
            return (f.repository + ".git\n").encode()
        result = f.process(argv, environment, timeout, maximum, cwd)
        if argv[0] == app.COMMANDS["git"] and "fetch" in argv and self.during_fetch:
            self.during_fetch()
        if native and self.native_timeout:
            raise TimeoutError("Native IPC completion timed out")
        return result

    def update(self, version="1.1.0"):
        return app.update_reviewed_plugin(self.item, self.local, self.expected, version)

    def assert_original(self):
        f = self.fixture
        self.assertEqual(f.git(f.target, "rev-parse", "HEAD"), self.before)
        self.assertEqual((f.target / ".git/config").read_bytes(), self.config_before)
        self.assertFalse((f.home / "MOVED-HEAD-RAN").exists())
        self.assertTrue(all(not path.exists() for path in f.stages))

    def test_remote_moves_before_native_fetch_but_only_reviewed_update_executes(self):
        f = self.fixture
        self.update()
        self.assertEqual(f.git(f.remote, "rev-parse", "HEAD"), self.moved)
        self.assertNotEqual(self.moved, self.expected)
        self.assertEqual(f.git(f.target, "rev-parse", "HEAD"), self.expected)
        self.assertTrue((f.home / "REVIEWED-UPDATE-RAN").exists())
        self.assertFalse((f.home / "MOVED-HEAD-RAN").exists())
        self.assertEqual((f.target / "payload.txt").read_text(), "reviewed update\n")
        self.assertEqual((f.target / ".git/config").read_bytes(), self.config_before)
        self.assertEqual(f.git(f.target, "remote", "get-url", "origin"), f.repository + ".git")
        self.assertTrue(all(not path.exists() for path in f.stages))
        settings = {self.environment[f"GIT_CONFIG_KEY_{i}"]: self.environment[f"GIT_CONFIG_VALUE_{i}"]
                    for i in range(int(self.environment["GIT_CONFIG_COUNT"]))}
        self.assertEqual(settings["protocol.allow"], "never")
        self.assertEqual(settings["protocol.file.allow"], "always")
        self.assertNotIn("protocol.https.allow", settings)
        self.assertEqual(settings["core.hooksPath"], "/dev/null")
        self.assertEqual(settings["fetch.recurseSubmodules"], "false")

    def test_unavailable_or_wrong_commit_never_dispatches_native_update(self):
        f = self.fixture
        for bad in ("unavailable", self.moved):
            with self.subTest(commit=bad):
                f.fetch_revision = bad
                with self.assertRaises(ValueError):
                    self.update()
                self.assertNotIn("update", f.native_calls)
                self.assert_original()

    def test_manifest_version_and_fast_forward_are_verified_before_native_update(self):
        f = self.fixture
        with self.assertRaisesRegex(ValueError, "manifest"):
            self.update("wrong-version")
        self.local["installedRevision"] = self.moved
        with self.assertRaises(ValueError):
            self.update()
        self.assertNotIn("update", f.native_calls)
        self.assert_original()

    def test_changed_source_or_local_edits_during_staging_block_update(self):
        f = self.fixture
        self.during_fetch = lambda: (f.target / "user-work.txt").write_text("preserve me")
        with self.assertRaisesRegex(ValueError, "installed source changed"):
            self.update()
        self.assertEqual((f.target / "user-work.txt").read_text(), "preserve me")
        self.assertNotIn("update", f.native_calls)
        self.assert_original()

    def test_changed_placement_during_staging_blocks_update(self):
        self.during_fetch = lambda: self.item.update(barSection="left")
        with self.assertRaisesRegex(ValueError, "Plugin state changed"):
            self.update()
        self.assertNotIn("update", self.fixture.native_calls)
        self.assert_original()

    def test_unconfirmed_url_mapping_never_dispatches_native_update(self):
        self.wrong_mapping = True
        with self.assertRaisesRegex(ValueError, "bound to the reviewed"):
            self.update()
        self.assertNotIn("update", self.fixture.native_calls)
        self.assert_original()

    def test_native_validation_rollback_and_timeout_preserve_origin_and_cleanup(self):
        f = self.fixture
        (f.home / "reject-installed").touch()
        with self.assertRaises(ValueError):
            self.update()
        self.assert_original()
        (f.home / "reject-installed").unlink()
        self.native_timeout = True
        with self.assertRaises(TimeoutError):
            self.update()
        self.assertEqual(f.git(f.target, "rev-parse", "HEAD"), self.expected)
        self.assertEqual((f.target / ".git/config").read_bytes(), self.config_before)
        self.assertFalse((f.home / "MOVED-HEAD-RAN").exists())
        self.assertTrue(all(not path.exists() for path in f.stages))

    def test_network_cannot_be_reenabled_if_origin_changes_after_mapping_check(self):
        f = self.fixture
        f.write_executable("omarchy", f'''import subprocess, sys
from pathlib import Path
if sys.argv[2] == "validate":
    sys.exit(0)
result = subprocess.run(["/usr/bin/git", "-C", {str(f.target)!r}, "fetch", "origin", "HEAD"], capture_output=True)
assert b"transport 'https' not allowed" in result.stderr, result.stderr
(Path.home() / "HTTPS-REFUSED").touch()
raise SystemExit(1)
''')
        self.during_native = lambda: f.git(f.target, "remote", "set-url", "origin", "https://github.com/other/moved.git")
        with self.assertRaises(ValueError):
            self.update()
        self.assertTrue((f.home / "HTTPS-REFUSED").exists())
        self.assertEqual(f.git(f.target, "rev-parse", "HEAD"), self.before)
        self.assertFalse((f.home / "MOVED-HEAD-RAN").exists())

    def test_executable_local_git_configuration_is_blocked_before_status(self):
        f = self.fixture
        sentinel = f.home / "CONFIG-EXECUTED"
        f.git(f.target, "config", "filter.fixture.clean", f"touch '{sentinel}'")
        (f.target / "payload.txt").write_text("force status to consider the filter\n")
        self.assertEqual(app.inspect_update_target(self.item)["state"], "blocked")
        self.assertFalse(sentinel.exists())

    @unittest.skipUnless(Path("/usr/bin/omarchy-plugin-update").is_file(), "Packaged Omarchy unavailable")
    def test_packaged_native_updater_fetches_only_the_verified_local_commit(self):
        f = self.fixture
        for name in ("omarchy-plugin-update", "omarchy-plugin-validate"):
            shutil.copyfile(Path("/usr/bin") / name, f.bindir / name)
            (f.bindir / name).chmod(0o700)
        f.write_executable("omarchy", '''import os, sys
from pathlib import Path
assert sys.argv[1] == "plugin" and sys.argv[2] in ("validate", "update")
executable = str(Path(__file__).parent / ("omarchy-plugin-" + sys.argv[2]))
os.execv(executable, [executable, *sys.argv[3:]])
''')
        # At the real native rescan boundary, model loading the updated code.
        f.write_executable("omarchy-shell", f'''import subprocess
from pathlib import Path
target = Path({str(f.target)!r})
assert subprocess.check_output(["/usr/bin/git", "-C", str(target), "rev-parse", "HEAD"], text=True).strip() == {self.expected!r}
subprocess.run([{sys.executable!r}, "-I", "-B", str(target / "install.py")], check=True)
''')
        self.test_remote_moves_before_native_fetch_but_only_reviewed_update_executes()


class PinnedSelfUpdateTests(PinnedUpdateTests):
    plugin_id = app.APP_ID


if __name__ == "__main__":
    unittest.main()
