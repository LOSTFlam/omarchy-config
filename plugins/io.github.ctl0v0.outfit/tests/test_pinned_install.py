"""Real Git adversarial fixtures. Only the public-network fetch is substituted.

The native fixture executes an installer hook to exercise the execution boundary;
the optional packaged-Omarchy test uses its real add/validate scripts with inert IPC.
No real user plugin directory or running shell is touched.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from tests.test_outfit import OUTFIT as app


class PinnedInstallTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.remote = self.root / "remote"
        self.remote.mkdir()
        self.identity = getattr(self, "identity", "example.pinned")
        self.repository = "https://github.com/example/pinned"
        self.target = self.home / ".config/omarchy/plugins" / self.identity
        self.git_env = {"PATH": "/usr/bin:/bin", "HOME": str(self.root),
                        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                        "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                        "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}
        self.git(self.remote, "init", "-b", "main")
        (self.remote / "manifest.json").write_text(json.dumps({"schemaVersion": 1, "id": self.identity,
            "name": "Pinned fixture", "version": "1.0.0", "kinds": ["service"],
            "entryPoints": {"service": "Service.qml"}}))
        (self.remote / "Service.qml").write_text("import QtQuick\nItem {}\n")
        (self.remote / ".gitattributes").write_text("*.txt filter=fixture\n")
        (self.remote / "payload.txt").write_text("reviewed content\n")
        (self.remote / "install.py").write_text("from pathlib import Path\n(Path.home() / 'reviewed-ran').touch()\n")
        self.git(self.remote, "add", ".")
        self.git(self.remote, "commit", "-m", "Reviewed A")
        self.reviewed = self.git(self.remote, "rev-parse", "HEAD")
        (self.remote / "payload.txt").write_text("unreviewed HEAD content\n")
        (self.remote / "install.py").write_text("from pathlib import Path\n(Path.home() / 'UNREVIEWED-RAN').touch()\n")
        self.git(self.remote, "add", ".")
        self.git(self.remote, "commit", "-m", "Unreviewed B")
        self.head = self.git(self.remote, "rev-parse", "HEAD")
        self.item = {"id": self.identity, "repo": self.repository, "listingCommit": self.reviewed}
        self.runtime = self.root / "runtime"
        self.bindir = self.runtime / "bin"
        self.bindir.mkdir(parents=True)
        self.native_calls = []
        self.stages = []
        self.fetch_revision = None
        self.fail_native = False
        self.real_process = app.run_bounded_process
        self.write_executable("omarchy", f'''import json, os, subprocess, sys
from pathlib import Path
action, source = sys.argv[2:4]
path = Path(source)
assert path.is_absolute() and path.name.startswith("outfit-reviewed-")
assert path.stat().st_mode & 0o077 == 0
assert subprocess.check_output(["/usr/bin/git", "-C", source, "rev-parse", "HEAD"], text=True).strip() == {self.reviewed!r}
assert json.loads((path / "manifest.json").read_text())["id"] == {self.identity!r}
assert (path / "payload.txt").read_text() == "reviewed content\\n"
if action == "validate":
    sys.exit(0)
assert action == "add" and sys.argv[4:] == ["--yes"]
target = Path.home() / ".config/omarchy/plugins" / {self.identity!r}
target.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(["/usr/bin/git", "clone", "--", source, str(target)], check=True)
# Model a native installer that executes a plugin-supplied setup hook.
subprocess.run([{sys.executable!r}, "-I", "-B", str(target / "install.py")], check=True)
''')
        self.write_executable("omarchy-shell", "pass\n")
        self.environment = {"HOME": str(self.home), "XDG_CONFIG_HOME": str(self.home / ".config"),
                            "OMARCHY_PATH": str(self.runtime)}
        self.addCleanup(mock.patch.stopall)
        mock.patch.dict(os.environ, self.environment, clear=True).start()
        # Git metadata inspection must see this fixture's configuration, not
        # system-wide Git LFS/custom helpers installed on a hosted CI runner.
        real_launch = app.command_launch
        def isolated_launch(argv):
            effective, environment = real_launch(argv)
            if argv[0] == app.COMMANDS["git"]:
                environment["GIT_CONFIG_NOSYSTEM"] = "1"
            return effective, environment
        mock.patch.object(app, "command_launch", side_effect=isolated_launch).start()
        mock.patch.object(app, "run_bounded_process", side_effect=self.process).start()

    def write_executable(self, name, body):
        path = self.bindir / name
        path.write_text(f"#!{sys.executable} -B\n" + body)
        path.chmod(0o700)

    def git(self, path, *args):
        return subprocess.check_output(["/usr/bin/git", "-C", str(path), *args],
            env=self.git_env, stderr=subprocess.DEVNULL, text=True).strip()

    def process(self, argv, environment, timeout, maximum, cwd=None):
        argv = list(argv)
        if argv[0] == app.COMMANDS["git"] and "fetch" in argv:
            self.assertEqual(argv[-2:], [self.repository + ".git", self.reviewed])
            self.stages.append(Path(cwd))
            if self.fetch_revision == "unavailable":
                raise ValueError("Fixture commit unavailable")
            # Network-boundary substitution only: actual Git fetch/checkouts and
            # verification still run, with remote HEAD deliberately at B.
            argv[-2:] = [str(self.remote), self.fetch_revision or self.reviewed]
            argv[1:1] = ["-c", "protocol.file.allow=always"]
        if argv[0] == str(self.bindir / "omarchy"):
            self.native_calls.append(argv[2])
        result = self.real_process(argv, environment, timeout, maximum, cwd=cwd)
        if self.fail_native and argv[:3] == [str(self.bindir / "omarchy"), "plugin", "add"]:
            raise TimeoutError("Fixture IPC completion timeout")
        return result

    def install(self):
        return app.install_reviewed_plugin(self.item, self.reviewed)

    def test_remote_head_differs_but_only_reviewed_code_reaches_native_installer(self):
        self.assertNotEqual(self.head, self.reviewed)
        self.install()
        self.assertEqual(self.git(self.target, "rev-parse", "HEAD"), self.reviewed)
        self.assertEqual((self.target / "payload.txt").read_text(), "reviewed content\n")
        self.assertTrue((self.home / "reviewed-ran").exists())
        self.assertFalse((self.home / "UNREVIEWED-RAN").exists())
        self.assertEqual(self.git(self.target, "remote", "get-url", "origin"), self.repository + ".git")
        self.assertEqual(self.native_calls, ["validate", "add"])
        self.assertTrue(all(not path.exists() for path in self.stages))
        self.assertFalse((self.target / ".git/objects/info/alternates").exists())
        # Ordinary native updater's fetch/fast-forward works after staging is removed.
        self.git(self.target, "fetch", str(self.remote), "HEAD")
        self.git(self.target, "merge", "--ff-only", "FETCH_HEAD")
        self.assertEqual(self.git(self.target, "rev-parse", "HEAD"), self.head)

    def test_invalid_or_missing_full_sha_never_launches_anything(self):
        for revision in ("", "main", self.reviewed[:12], "f" * 40, None):
            with self.subTest(revision=revision), mock.patch.object(app, "install_git") as git:
                with self.assertRaises(ValueError):
                    app.install_reviewed_plugin(self.item, revision)
                git.assert_not_called()
        self.assertEqual(self.native_calls, [])

    def test_unavailable_or_wrong_fetched_commit_never_reaches_native_install(self):
        for revision in ("unavailable", self.head):
            with self.subTest(revision=revision):
                self.fetch_revision = revision
                with self.assertRaises(ValueError):
                    self.install()
                self.assertFalse(self.target.exists())
                self.assertEqual(self.native_calls, [])
                self.assertTrue(all(not path.exists() for path in self.stages))

    def test_manifest_identity_mismatch_is_rejected_before_native_execution(self):
        self.item["id"] = "example.different"
        with self.assertRaisesRegex(ValueError, "identity"):
            self.install()
        self.assertEqual(self.native_calls, [])
        self.assertFalse(self.target.exists())

    def test_hooks_templates_filters_and_url_rewrites_are_not_inherited(self):
        hooks = self.root / "hooks"
        hooks.mkdir()
        marker = self.home / "UNTRUSTED-GIT-RAN"
        hook = hooks / "post-checkout"
        hook.write_text(f"#!/bin/sh\ntouch '{marker}'\n")
        hook.chmod(0o700)
        (self.home / ".gitconfig").write_text(f'''[core]
    hooksPath = {hooks}
[init]
    templateDir = {self.root}
[filter "fixture"]
    smudge = touch {marker}
    required = true
[url "ext::sh -c touch {marker}"]
    insteadOf = https://github.com/
''')
        self.install()
        self.assertFalse(marker.exists())
        self.assertEqual((self.target / "payload.txt").read_text(), "reviewed content\n")

    def test_native_timeout_finalizes_only_verified_checkout_without_activating(self):
        self.fail_native = True
        with self.assertRaisesRegex(ValueError, "completion needs verification"):
            self.install()
        app.verify_reviewed_install(self.identity, self.reviewed, self.repository)
        self.assertEqual(self.native_calls, ["validate", "add"])
        self.assertFalse((self.home / "UNREVIEWED-RAN").exists())
        self.assertTrue(all(not path.exists() for path in self.stages))

    def test_existing_directory_is_never_overwritten(self):
        self.target.mkdir(parents=True)
        (self.target / "keep").write_text("user data")
        with self.assertRaisesRegex(ValueError, "already installed"):
            self.install()
        self.assertEqual((self.target / "keep").read_text(), "user data")
        self.assertEqual(self.native_calls, [])

    def test_failed_checkout_or_validation_never_reaches_native_add(self):
        original = app.install_git
        def checkout_failure(path, arguments, *args, **kwargs):
            if arguments[0] == "checkout":
                raise ValueError("Fixture checkout failure")
            return original(path, arguments, *args, **kwargs)
        with mock.patch.object(app, "install_git", side_effect=checkout_failure):
            with self.assertRaises(ValueError):
                self.install()
        self.assertEqual(self.native_calls, [])
        with mock.patch.object(app, "run_command", side_effect=ValueError("Invalid manifest")):
            with self.assertRaises(ValueError):
                self.install()
        self.assertFalse(self.target.exists())
        self.assertTrue(all(not path.exists() for path in self.stages))

    def test_recovery_activation_rechecks_revision_and_origin_in_backend(self):
        self.install()
        store = app.Store(self.root / "cache")
        self.addCleanup(store.close)
        row = {"id": self.identity, "enabled": False, "canDisable": True, "kinds": ["service"]}
        with mock.patch.object(app, "scan_inventory", return_value=([row], False)), \
                mock.patch.object(app, "load_catalog", return_value=([self.item], 0, "")), \
                mock.patch.object(app, "run_activation_command") as activate:
            self.git(self.target, "remote", "set-url", "origin", str(self.remote))
            with self.assertRaisesRegex(ValueError, "origin"):
                app.run({"action": "enable-plugin", "pluginId": self.identity,
                         "reviewedRevision": self.reviewed}, store)
            self.git(self.target, "fetch", str(self.remote), "HEAD")
            self.git(self.target, "merge", "--ff-only", "FETCH_HEAD")
            with self.assertRaisesRegex(ValueError, "reviewed catalog commit"):
                app.run({"action": "enable-plugin", "pluginId": self.identity,
                         "reviewedRevision": self.reviewed}, store)
            activate.assert_not_called()

    def test_mismatched_inventory_cannot_become_success(self):
        request = {"reviewedRevision": self.reviewed, "enableAfter": True}
        for revision in ("", self.head, self.reviewed):
            inventory = [{"id": self.identity, "enabled": True, "installedRevision": revision}]
            self.assertEqual(app.mutation_observed("install-plugin", request, self.identity, inventory),
                             revision == self.reviewed)

    @unittest.skipUnless(Path("/usr/bin/omarchy-plugin-add").is_file(), "Packaged Omarchy unavailable")
    def test_packaged_native_add_and_validator_clone_the_verified_snapshot(self):
        for name in ("omarchy-plugin-add", "omarchy-plugin-validate", "omarchy-git-url-check"):
            shutil.copyfile(Path("/usr/bin") / name, self.bindir / name)
            (self.bindir / name).chmod(0o700)
        self.write_executable("omarchy-plugin-catalog", "print('[]')\n")
        self.write_executable("omarchy", '''import os, sys
from pathlib import Path
assert sys.argv[1] == "plugin" and sys.argv[2] in ("validate", "add")
executable = str(Path(__file__).parent / ("omarchy-plugin-" + sys.argv[2]))
os.execv(executable, [executable, *sys.argv[3:]])
''')
        self.install()
        app.verify_reviewed_install(self.identity, self.reviewed, self.repository)
        self.assertEqual(self.git(self.target, "rev-parse", "HEAD"), self.reviewed)
        self.assertFalse((self.home / "UNREVIEWED-RAN").exists())


if __name__ == "__main__":
    unittest.main()
