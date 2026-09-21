"""Real subprocess routing in a disposable runtime; never execute host native IPC."""
import json
import os
from pathlib import Path
import sys
import tempfile
import textwrap
import unittest
from unittest import mock

from tests.test_outfit import OUTFIT as app, ROOT


class LaunchObserved(Exception):
    pass


class NativeRoutingTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.base = Path(directory.name)
        self.runtime = self.base / "native tree # 雪"
        self.bindir = self.runtime / "bin"
        self.bindir.mkdir(parents=True)
        self.poison = self.base / "caller-path"
        self.poison.mkdir()
        self.log = self.runtime / "routing.jsonl"
        fixture = f"#!{sys.executable} -B\n" + textwrap.dedent('''\
            import json
            import os
            from pathlib import Path
            import shutil
            import subprocess
            import sys

            root = Path(os.environ["OMARCHY_PATH"])
            bindir = root / "bin"
            assert os.environ.get("PATH") == str(bindir) + ":/usr/bin:/bin"
            actor = Path(sys.argv[0]).name
            with (root / "routing.jsonl").open("a") as stream:
                stream.write(json.dumps({"actor": actor, "executable": sys.argv[0], "args": sys.argv[1:],
                    "path": os.environ["PATH"], "runtime": str(root),
                    "unsafeKeys": [key for key in ("PYTHONPATH", "BASH_ENV", "OMARCHY_BIN_DIR") if key in os.environ]}) + "\\n")
            if actor == "omarchy":
                assert sys.argv[1] == "plugin" and sys.argv[2] in ("add", "remove")
                # Like the native router, dispatch from this executable's bin.
                helper = Path(sys.argv[0]).parent / ("omarchy-plugin-" + sys.argv[2])
                subprocess.run([str(helper), *sys.argv[3:]], check=True)
            elif actor in ("omarchy-plugin-add", "omarchy-plugin-remove"):
                # Guard before launch: a broken implementation must not invoke
                # any real host omarchy-shell while running this regression.
                assert shutil.which("omarchy-shell") == str(bindir / "omarchy-shell")
                subprocess.run(["omarchy-shell", "shell", "fixture", *sys.argv[1:]], check=True)
            elif actor == "omarchy-shell":
                assert shutil.which("omarchy-routing-fixture-leaf") == str(bindir / "omarchy-routing-fixture-leaf")
                subprocess.run(["omarchy-routing-fixture-leaf", *sys.argv[1:]], check=True)
            elif actor == "omarchy-routing-fixture-leaf":
                print(json.dumps({"version": 1, "generation": 3, "settledGeneration": 3,
                    "scanning": False, "reconciling": False, "pending": False, "held": False,
                    "leaseCount": 0, "scanError": "", "plugins": {}}))
            else:
                raise AssertionError("Unexpected fixture executable")
            ''')
        for name in ("omarchy", "omarchy-plugin-add", "omarchy-plugin-remove", "omarchy-shell", "omarchy-routing-fixture-leaf"):
            path = self.bindir / name
            path.write_text(fixture)
            path.chmod(0o700)
            poison = self.poison / name
            poison.write_text(f"#!{sys.executable} -B\nraise AssertionError('Caller PATH was used')\n")
            poison.chmod(0o700)
        self.environment = {
            "OMARCHY_PATH": str(self.runtime), "HOME": str(self.base), "LANG": "C.UTF-8",
            "PATH": str(self.poison), "PYTHONPATH": str(self.poison),
            "BASH_ENV": str(self.poison / "shell-init"), "OMARCHY_BIN_DIR": str(self.poison),
        }
        self.real_popen = app.subprocess.Popen

    def guarded_popen(self, argv, **kwargs):
        allowed = {(self.bindir / name).resolve() for name in ("omarchy", "omarchy-shell")}
        self.assertIn(Path(argv[0]).resolve(), allowed, "Refusing to execute a real host command in a routing test")
        self.assertIsNot(kwargs.get("shell"), True)
        return self.real_popen(argv, **kwargs)

    def records(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_declared_router_and_nested_add_remove_helpers_all_use_configured_tree(self):
        with mock.patch.dict(os.environ, self.environment, clear=True), \
                mock.patch.object(app.subprocess, "Popen", side_effect=self.guarded_popen) as launch:
            for verb, target in (("add", "https://github.com/example/fixture.git"), ("remove", "example.fixture")):
                arguments = [app.COMMANDS["omarchy"], "plugin", verb, target, "--yes"]
                original = list(arguments)
                output = app.run_command(arguments, 5, 8192)
                self.assertEqual(json.loads(output)["version"], 1)
                self.assertEqual(arguments, original)  # Declared audit/mocked-call inputs remain /usr/bin.
                self.assertEqual(launch.call_args.args[0], [str(self.bindir / "omarchy"), *original[1:]])
        records = self.records()
        self.assertEqual([row["actor"] for row in records], [
            "omarchy", "omarchy-plugin-add", "omarchy-shell", "omarchy-routing-fixture-leaf",
            "omarchy", "omarchy-plugin-remove", "omarchy-shell", "omarchy-routing-fixture-leaf"])
        self.assertTrue(all(row["path"] == str(self.bindir) + ":" + app.SYSTEM_COMMAND_PATH for row in records))
        self.assertTrue(all(row["runtime"] == str(self.runtime) and row["unsafeKeys"] == [] for row in records))

    def test_shell_direct_launch_and_opaque_arguments_preserve_spaces_and_punctuation(self):
        value = 'literal value; $(not-evaluated) "quoted" 雪'
        argv = [app.COMMANDS["omarchy-shell"], "shell", "fixture", value]
        with mock.patch.dict(os.environ, self.environment, clear=True), \
                mock.patch.object(app.subprocess, "Popen", side_effect=self.guarded_popen):
            app.run_command(argv, 5, 8192)
        records = self.records()
        self.assertEqual([row["actor"] for row in records], ["omarchy-shell", "omarchy-routing-fixture-leaf"])
        self.assertTrue(all(row["args"] == argv[1:] for row in records))
        self.assertEqual(records[0]["executable"], str(self.bindir / "omarchy-shell"))

    def test_symlinked_development_tree_remains_supported(self):
        alias = self.base / "linked runtime"
        alias.symlink_to(self.runtime, target_is_directory=True)
        with mock.patch.dict(os.environ, {**self.environment, "OMARCHY_PATH": str(alias)}, clear=True), \
                mock.patch.object(app.subprocess, "Popen", side_effect=self.guarded_popen):
            app.run_command([app.COMMANDS["omarchy"], "plugin", "remove", "example.fixture", "--yes"], 5, 8192)
        self.assertTrue(all(row["runtime"] == str(alias) for row in self.records()))
        self.assertEqual(self.records()[0]["executable"], str(alias / "bin/omarchy"))

    def test_other_allowlisted_programs_keep_their_absolute_system_executable(self):
        with mock.patch.dict(os.environ, self.environment, clear=True):
            for name in ("git", "pacman", "hyprctl", "bluetoothctl", "wpctl"):
                argv = [app.COMMANDS[name], "--fictional-argument"]
                effective, environment = app.command_launch(argv)
                self.assertEqual(effective, argv)
                self.assertEqual(environment["PATH"], str(self.bindir) + ":/usr/bin:/bin")

    def test_without_configured_runtime_the_system_fallback_uses_a_fixed_path(self):
        for configured in (None, ""):
            environment = {"PATH": str(self.poison), "HOME": str(self.base)}
            if configured is not None:
                environment["OMARCHY_PATH"] = configured
            with mock.patch.dict(os.environ, environment, clear=True), \
                    mock.patch.object(app.subprocess, "Popen", side_effect=LaunchObserved) as launch:
                for name in ("omarchy", "omarchy-shell"):
                    argv = [app.COMMANDS[name], "--fixture-only"]
                    with self.assertRaises(LaunchObserved):
                        app.run_command(argv, 1, 1024)
                    self.assertEqual(launch.call_args.args[0], argv)
                    self.assertEqual(launch.call_args.kwargs["env"]["PATH"], "/usr/bin:/bin")
                    self.assertNotIn("OMARCHY_PATH", launch.call_args.kwargs["env"])

    def test_unknown_commands_including_direct_runtime_paths_remain_blocked(self):
        with mock.patch.dict(os.environ, self.environment, clear=True), \
                mock.patch.object(app.subprocess, "Popen") as launch:
            for argv in ([], ["omarchy"], [str(self.bindir / "omarchy")], [str(self.poison / "omarchy")],
                         ["/usr/bin/omarchy-plugin-add"], ["/bin/sh", "-c", "true"],
                         [app.COMMANDS["omarchy"], None]):
                with self.subTest(argv=argv), self.assertRaisesRegex(ValueError, "allowlisted"):
                    app.run_command(argv, 1, 1024)
            launch.assert_not_called()

    def test_invalid_relative_colon_control_or_oversized_roots_are_rejected_before_launch(self):
        values = ["relative/tree", "~/runtime", str(self.runtime) + ":/other/bin", "/bad\nroot", "/bad\x00root",
                  "/" + "x" * app.MAX_RUNTIME_PATH_BYTES, "/" + "雪" * (app.MAX_RUNTIME_PATH_BYTES // 2)]
        for value in values:
            # Replace the mapping itself for the NUL case, which a real OS
            # environment setter already rejects before the helper could see it.
            with self.subTest(value=value[:30]), mock.patch.object(app.os, "environ", {"OMARCHY_PATH": value}), \
                    mock.patch.object(app.subprocess, "Popen") as launch, \
                    mock.patch.object(Path, "is_dir", side_effect=AssertionError("Invalid root reached filesystem")):
                with self.assertRaisesRegex(ValueError, "bounded absolute"):
                    app.run_command([app.COMMANDS["omarchy"], "plugin", "list"], 1, 1024)
                launch.assert_not_called()

    def test_explicit_missing_or_incomplete_runtime_never_silently_uses_packaged_native_code(self):
        empty = self.base / "empty-runtime"
        empty.mkdir()
        file_root = self.base / "not-a-directory"
        file_root.write_text("fixture")
        for root in (empty, file_root, self.base / "missing"):
            with mock.patch.dict(os.environ, {"OMARCHY_PATH": str(root)}, clear=True), \
                    mock.patch.object(app.subprocess, "Popen") as launch:
                with self.assertRaises(ValueError):
                    app.run_command([app.COMMANDS["omarchy"], "plugin", "add", "fixture"], 1, 1024)
                launch.assert_not_called()
        shell = self.bindir / "omarchy-shell"
        shell.chmod(0o600)
        with mock.patch.dict(os.environ, self.environment, clear=True), \
                mock.patch.object(app.subprocess, "Popen") as launch:
            with self.assertRaisesRegex(ValueError, "unusable native"):
                app.run_command([app.COMMANDS["omarchy"], "plugin", "add", "fixture"], 1, 1024)
            shell.unlink()
            with self.assertRaisesRegex(ValueError, "missing a native"):
                app.run_command([app.COMMANDS["omarchy-shell"], "shell", "fixture"], 1, 1024)
            launch.assert_not_called()

    def test_install_request_and_plugin_metadata_cannot_choose_runtime_or_executable(self):
        fixture = json.loads((ROOT / "demo/fixtures/example.json").read_text())
        items, generated = app.normalize_catalog(fixture["catalog"])
        items[0].update(command=str(self.poison / "omarchy"), OMARCHY_PATH=str(self.poison),
                        installNote="Untrusted listing text cannot select native code")
        store = app.Store(self.base / "cache")
        self.addCleanup(store.close)
        app.save_catalog(store, items, generated, 100)
        installed = app.validate_inventory([{"id": items[0]["id"], "enabled": False,
                                             "installedRevision": items[0]["listingCommit"]}])
        with mock.patch.dict(os.environ, self.environment, clear=True), \
                mock.patch.object(app.subprocess, "Popen", side_effect=self.guarded_popen), \
                mock.patch.object(app, "scan_inventory", side_effect=[([], False), (installed, False)]), \
                mock.patch.object(app, "installed_revision", return_value=""), \
                mock.patch.object(app, "install_reviewed_plugin", side_effect=lambda item, revision:
                    app.run_command([app.COMMANDS["omarchy"], "plugin", "add", "/private-reviewed-fixture", "--yes"], 60, 128 * 1024)) as install, \
                mock.patch.object(app, "fetch_bytes", side_effect=AssertionError("No network")), \
                mock.patch.object(app, "run_command", wraps=app.run_command) as declared:
            result = app.run({"action": "install-plugin", "pluginId": items[0]["id"], "reviewedRevision": items[0]["listingCommit"],
                "OMARCHY_PATH": str(self.poison), "PATH": str(self.poison), "command": str(self.poison / "omarchy"),
                "repo": "https://github.com/ignored/override"}, store, now=200)
            self.assertTrue(result["operation"]["observed"])
            self.assertEqual(install.call_args.args[0]["repo"], items[0]["repo"])
            self.assertEqual(install.call_args.args[1], items[0]["listingCommit"])
            declared.assert_called_once_with([app.COMMANDS["omarchy"], "plugin", "add", "/private-reviewed-fixture", "--yes"],
                                              60, 128 * 1024)
        self.assertEqual(self.records()[0]["executable"], str(self.bindir / "omarchy"))
        self.assertEqual(self.records()[1]["args"], ["/private-reviewed-fixture", "--yes"])

    def test_lifecycle_request_uses_configured_native_shell_not_request_metadata(self):
        with mock.patch.dict(os.environ, self.environment, clear=True), \
                mock.patch.object(app.subprocess, "Popen", side_effect=self.guarded_popen):
            result = app.run({"action": "host-lifecycle", "operation": "status", "generation": 44,
                              "OMARCHY_PATH": str(self.poison), "command": str(self.poison / "omarchy-shell")}, mock.Mock())
        self.assertTrue(result["host"]["supported"])
        self.assertEqual(result["generation"], 44)
        self.assertEqual(self.records()[0]["executable"], str(self.bindir / "omarchy-shell"))
        self.assertEqual(self.records()[0]["args"], ["shell", "pluginLifecycle"])
