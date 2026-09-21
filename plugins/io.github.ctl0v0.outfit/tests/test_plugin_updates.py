"""Updates against disposable Git checkouts; public network and native IPC are mocked."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
from unittest import mock

from tests.test_outfit import OUTFIT as app


class PluginUpdateTests(unittest.TestCase):
    identity = "example.widget"

    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="outfit-updates-")
        self.addCleanup(directory.cleanup)
        self.home = Path(directory.name)
        self.environment = mock.patch.dict(os.environ, {
            "HOME": str(self.home), "XDG_CONFIG_HOME": str(self.home / ".config"),
            "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8",
        }, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        # Hosted Ubuntu runners configure Git LFS filters system-wide. These
        # fixtures model ordinary repositories, not that host configuration.
        # Preserve repo-local (including adversarial) config; do not relax the
        # production executable-config check to accommodate a test runner.
        real_launch = app.command_launch
        def isolated_launch(argv):
            effective, environment = real_launch(argv)
            if argv[0] == app.COMMANDS["git"]:
                environment["GIT_CONFIG_NOSYSTEM"] = "1"
            return effective, environment
        launch_patch = mock.patch.object(app, "command_launch", side_effect=isolated_launch)
        launch_patch.start()
        self.addCleanup(launch_patch.stop)
        self.root = self.home / ".config/omarchy/plugins"
        self.repo = self.root / self.identity
        self.repo.mkdir(parents=True)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.write_manifest("1.0")
        self.git("add", "manifest.json")
        self.git("commit", "-qm", "Installed fixture")
        self.before = self.git("rev-parse", "HEAD").strip().decode()
        self.write_manifest("1.1")
        self.git("commit", "-qam", "Candidate fixture")
        self.candidate = self.git("rev-parse", "HEAD").strip().decode()
        self.git("reset", "--hard", self.before)
        self.git("remote", "add", "origin", "https://github.com/example/widget.git")
        self.item = app.validate_inventory([{
            "id": self.identity, "name": "Fixture Widget", "kinds": ["bar-widget"],
            "enabled": True, "canDisable": True, "barSection": "right",
        }])[0]
        self.store = app.Store(self.home / "cache")
        self.addCleanup(self.store.close)
        self.remote_revision = self.candidate
        self.remote_version = "1.1"
        self.remote_identity = self.identity
        self.comparison_status = "ahead"
        self.native_mode = "success"
        self.native_calls = []
        self.real_command = app.run_command
        self.real_public_head = app.public_update_head
        self.head_patch = mock.patch.object(app, "public_update_head", side_effect=self.head)
        self.head_mock = self.head_patch.start()
        self.addCleanup(self.head_patch.stop)
        self.network = mock.patch.object(app, "fetch_bytes", side_effect=self.fetch)
        self.fetch_mock = self.network.start()
        self.addCleanup(self.network.stop)
        self.commands = mock.patch.object(app, "run_command", side_effect=self.command)
        self.command_mock = self.commands.start()
        self.addCleanup(self.commands.stop)
        self.real_inventory = app.scan_inventory
        self.inventory_patch = mock.patch.object(app, "scan_inventory", side_effect=self.inventory)
        self.inventory_patch.start()
        self.addCleanup(self.inventory_patch.stop)
        # Transaction/state tests model the pinned mutator. Real fetch, pinning
        # and native updater execution are exercised in test_pinned_update.py.
        self.pinned_patch = mock.patch.object(app, "update_reviewed_plugin", side_effect=self.pinned_update)
        self.pinned_mock = self.pinned_patch.start()
        self.addCleanup(self.pinned_patch.stop)

    def pinned_update(self, item, local, expected, version):
        self.assertEqual(item["id"], self.identity)
        self.assertEqual(local["installedRevision"], self.before)
        self.assertEqual(expected, self.candidate)
        self.assertEqual(version, self.remote_version)
        self.assertTrue(local["sourceKey"])
        return self.command([app.COMMANDS["omarchy"], "plugin", "update", self.identity, "--yes"], 90, 128 * 1024)

    def git(self, *args):
        # Every actual Git subprocess is constrained to a fresh temporary repo.
        self.assertTrue(self.repo.is_relative_to(self.home))
        return subprocess.run(["/usr/bin/git", "-C", str(self.repo), *args], check=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout

    def write_manifest(self, version):
        (self.repo / "manifest.json").write_text(json.dumps({"id": self.identity, "name": "Fixture", "version": version}))

    def inventory(self, include_versions=True):
        return [app.inventory_version_metadata(self.item) if include_versions else dict(self.item)], False

    def head(self, repository, deadline):
        self.assertTrue(repository.startswith("https://github.com/"))
        self.assertGreater(deadline, time.monotonic())
        return f"ref: refs/heads/main\tHEAD\n{self.remote_revision}\tHEAD\n".encode()

    def fetch(self, url, host, maximum, timeout=12, **kwargs):
        self.assertGreater(timeout, 0)
        self.assertLessEqual(timeout, 10)
        self.assertLessEqual(maximum, 1024 * 1024)
        if host == "raw.githubusercontent.com":
            self.assertIn("/" + self.remote_revision + "/manifest.json", url)
            return json.dumps({"id": self.remote_identity, "version": self.remote_version}).encode()
        self.assertEqual(host, "api.github.com")
        self.assertIn("/compare/", url, "Only differing SHAs may consume GitHub REST quota")
        value = {"status": self.comparison_status, "ahead_by": 1, "behind_by": 0,
                 "base_commit": {"sha": self.before}, "merge_base_commit": {"sha": self.before}}
        return json.dumps(value).encode()

    def command(self, argv, timeout, maximum):
        if argv[0] == app.COMMANDS["git"]:
            self.assertIn("-C", argv)
            target = Path(argv[argv.index("-C") + 1])
            self.assertTrue(target.is_relative_to(self.home), "Refusing to inspect a live installation")
            self.assertNotIn("fetch", argv)
            return self.real_command(argv, timeout, maximum)
        self.assertEqual(argv, [app.COMMANDS["omarchy"], "plugin", "update", self.identity, "--yes"])
        self.native_calls.append(argv)
        if self.native_mode == "rollback":
            raise ValueError("Native validation failed; rolled back")
        if self.native_mode == "noop":
            return b"up to date"
        self.git("reset", "--hard", self.candidate)
        if self.native_mode == "late":
            self.write_manifest("1.2")
            self.git("commit", "-qam", "Late upstream movement")
        if self.native_mode == "placement":
            self.item["barSection"] = "left"
        if self.native_mode == "disabled":
            self.item["enabled"] = False
        if self.native_mode == "failure-after-merge":
            raise TimeoutError("Native timed out")
        return b"Updated fixture"

    def check(self, **kwargs):
        return app.run({"action": "check-updates", "pluginId": self.identity, "generation": 7, **kwargs},
                       self.store, now=1000)

    def update(self, **kwargs):
        return app.run({"action": "update-plugin", "pluginId": self.identity,
                        "expectedRevision": self.candidate, "expectedInstalledRevision": self.before,
                        "batchItem": False, **kwargs}, self.store, now=1001)

    def test_authoritative_inventory_and_read_only_available_check(self):
        # Capture all Git metadata, including index bytes and mtimes: status
        # must not refresh/write the installed index and no fetch is permitted.
        before = {str(path): (path.read_bytes(), path.stat().st_mtime_ns)
                  for path in (self.repo / ".git").rglob("*") if path.is_file()}
        result = self.check()
        after = {str(path): (path.read_bytes(), path.stat().st_mtime_ns)
                 for path in (self.repo / ".git").rglob("*") if path.is_file()}
        self.assertEqual(before, after)
        self.assertFalse(self.native_calls)
        self.assertTrue(result["inventoryAuthoritative"])
        self.assertEqual(result["responseKind"], "updates")
        self.assertEqual(result["generation"], 7)
        row = result["updates"][0]
        self.assertEqual((row["state"], row["canUpdate"], row["selfUpdate"]), ("available", True, False))
        self.assertEqual((row["installedVersion"], row["availableVersion"]), ("1.0", "1.1"))
        self.assertEqual(result["inventory"][0]["installedRevision"], self.before)
        self.assertEqual(result["inventory"][0]["installedVersion"], "1.0")
        self.assertNotIn("sourceKey", row)
        self.assertEqual(set(row), {"id", "name", "installedVersion", "availableVersion", "installedRevision",
                                   "availableRevision", "state", "canUpdate", "selfUpdate", "reason", "checkError", "checkedAt"})

    def test_targeted_check_and_update_inspect_only_target_independent_of_inventory_size(self):
        others = app.validate_inventory([{"id": f"example.other-{n}", "enabled": True,
            "installedVersion": "9.0", "installedRevision": "f" * 40} for n in range(500)])
        # Use the real cheap scan with modeled host responses. No unrelated
        # repository exists, and any version enrichment is a regression.
        original = self.command

        def command(argv, timeout, maximum):
            if argv == [app.COMMANDS["omarchy"], "plugin", "list", "--json"]:
                return json.dumps([self.item, *others]).encode()
            if argv == [app.COMMANDS["omarchy-shell"], "shell", "listShellConfig"]:
                return json.dumps({"bar": {"layout": {"right": [self.identity]}}}).encode()
            return original(argv, timeout, maximum)

        with mock.patch.object(app, "scan_inventory", wraps=self.real_inventory) as inventory, \
                mock.patch.object(app, "run_command", side_effect=command), \
                mock.patch.object(app, "inventory_version_metadata", side_effect=AssertionError("unrelated enrichment")), \
                mock.patch.object(app, "inspect_update_target", wraps=app.inspect_update_target) as inspect:
            checked = self.check()
            self.assertEqual(inspect.call_count, 1)
            result = self.update(inventory=checked["inventory"])
            self.assertTrue(result["operation"]["verified"])
            self.assertEqual(inspect.call_count, 4)  # check + before/network recheck/after
            self.assertEqual({call.args[0]["id"] for call in inspect.call_args_list}, {self.identity})
            self.assertTrue(all(call.kwargs == {"include_versions": False} for call in inventory.call_args_list))
            self.assertEqual(result["inventory"][0]["installedRevision"], self.candidate)
            self.assertEqual(result["inventory"][1]["installedRevision"], "f" * 40)

    def test_same_version_different_revision_is_available(self):
        self.remote_version = "1.0"
        self.assertEqual(self.check()["updates"][0]["state"], "available")

    def test_current_revision_avoids_compare(self):
        self.remote_revision = self.before
        self.remote_version = "1.0"
        row = self.check()["updates"][0]
        self.assertEqual(row["state"], "current")
        self.assertFalse(row["canUpdate"])
        self.assertEqual(self.head_mock.call_count, 1)
        self.assertEqual(self.fetch_mock.call_count, 1)
        self.assertEqual(self.fetch_mock.call_args.args[1], "raw.githubusercontent.com")

    def test_local_ahead_and_diverged_are_blocked(self):
        for status in ("behind", "diverged", "identical", "unknown"):
            with self.subTest(status=status):
                self.comparison_status = status
                row = self.check(force=True)["updates"][0]
                self.assertEqual(row["state"], "blocked")
                self.assertFalse(row["canUpdate"])

    def test_compare_requires_actual_installed_ancestor(self):
        original = self.fetch
        def bad_compare(url, *args, **kwargs):
            value = original(url, *args, **kwargs)
            if "/compare/" in url:
                data = json.loads(value)
                data["merge_base_commit"]["sha"] = "a" * 40
                return json.dumps(data).encode()
            return value
        self.fetch_mock.side_effect = bad_compare
        self.assertEqual(self.check()["updates"][0]["state"], "blocked")

    def test_customized_trees_show_upstream_without_changing_local_files(self):
        for filename in ("manifest.json", "untracked.txt"):
            with self.subTest(filename=filename):
                (self.repo / filename).write_text("dirty" if filename != "manifest.json" else json.dumps({"id": self.identity, "version": "2"}))
                before = (self.repo / filename).read_bytes()
                result = self.check(force=True)
                row = result["updates"][0]
                self.assertEqual(row["state"], "customized")
                self.assertFalse(row["canUpdate"])
                self.assertEqual((row["availableVersion"], row["availableRevision"]), ("1.1", self.candidate))
                self.assertEqual(result["updatesError"], "")
                self.assertEqual(result["updatesUnavailableCount"], 0)
                self.assertEqual((self.repo / filename).read_bytes(), before)
                self.assertEqual(self.git("rev-parse", "HEAD").strip().decode(), self.before)
                with self.assertRaises(ValueError):
                    self.update()
                self.git("reset", "--hard", self.before)
        self.assertFalse(self.native_calls)
        self.assertTrue(self.fetch_mock.called)
        self.assertFalse(any(call.args[1] == "api.github.com" for call in self.fetch_mock.call_args_list))

    def test_customized_current_upstream_is_still_not_automatically_updateable(self):
        self.write_manifest("2.0-local")
        self.remote_revision = self.before
        self.remote_version = "1.0"
        row = self.check()["updates"][0]
        self.assertEqual(row["state"], "customized")
        self.assertEqual((row["installedVersion"], row["availableVersion"]), ("2.0-local", "1.0"))
        self.assertEqual(row["installedRevision"], row["availableRevision"])
        self.assertFalse(row["canUpdate"])

    def test_customized_check_cache_and_failure_retry_are_separate_from_local_edits(self):
        self.write_manifest("2.0-local")
        first = self.check()
        calls = self.head_mock.call_count
        self.assertEqual(self.check(), first)
        self.assertEqual(self.head_mock.call_count, calls)
        self.head_mock.side_effect = app.PublicUpdateUnavailable("private failure")
        failed = self.check(force=True)
        row = failed["updates"][0]
        self.assertEqual(row["state"], "customized")
        self.assertTrue(row["checkError"])
        self.assertNotIn("private failure", json.dumps(failed))
        self.assertEqual(failed["updatesError"], "")
        self.assertEqual(failed["updatesUnavailableCount"], 1)
        calls = self.head_mock.call_count
        app.run({"action":"check-updates", "pluginId":self.identity}, self.store, now=1299)
        self.assertEqual(self.head_mock.call_count, calls)
        self.head_mock.side_effect = self.head
        recovered = app.run({"action":"check-updates", "pluginId":self.identity}, self.store, now=1300)
        self.assertEqual(recovered["updates"][0]["state"], "customized")
        self.assertEqual(recovered["updates"][0]["checkError"], "")
        self.assertEqual(recovered["updates"][0]["availableVersion"], "1.1")
        # Cleaning the working tree invalidates the customized cache, even at the same HEAD.
        self.git("reset", "--hard", self.before)
        self.assertEqual(self.check()["updates"][0]["state"], "available")

    def test_unsupported_and_credential_origins_are_not_exposed(self):
        for origin in ("git@github.com:example/widget.git", "https://private:secret@github.com/example/widget.git",
                       "https://gitlab.com/example/widget.git", "file:///tmp/elsewhere"):
            with self.subTest(origin=origin):
                self.git("remote", "set-url", "origin", origin)
                result = self.check(force=True)
                self.assertEqual(result["updates"][0]["state"], "manual")
                self.assertEqual(result["updatesError"], "")
                self.assertEqual(result["updatesUnavailableCount"], 0)
                self.assertNotIn(origin, json.dumps(result))
                self.assertNotIn("secret", json.dumps(result))
        self.fetch_mock.assert_not_called()

    def test_url_rewrites_and_multiple_origins_are_not_supported(self):
        self.git("config", "url.https://github.com/other/.insteadOf", "https://github.com/example/")
        self.assertEqual(self.check()["updates"][0]["state"], "manual")
        self.git("config", "--unset", "url.https://github.com/other/.insteadOf")
        self.git("config", "--add", "remote.origin.url", "https://github.com/other/widget.git")
        self.assertEqual(self.check(force=True)["updates"][0]["state"], "manual")
        self.fetch_mock.assert_not_called()

    def test_symlink_development_non_git_and_first_party(self):
        source = self.home / "development"
        self.repo.rename(source)
        self.repo.symlink_to(source, target_is_directory=True)
        self.assertEqual(self.check()["updates"][0]["state"], "development")
        self.assertEqual(app.installed_revision(self.identity), "")
        self.repo.unlink()
        self.repo.mkdir()
        self.write_manifest("1.0")
        self.assertEqual(self.check()["updates"][0]["state"], "manual")
        self.item["firstParty"] = True
        self.assertEqual(self.check()["updates"][0]["state"], "managed")
        self.fetch_mock.assert_not_called()

    def test_outfit_development_record_is_always_included_and_blocked(self):
        own = self.root / app.APP_ID
        source = self.home / "outfit-source"
        source.mkdir()
        (source / "manifest.json").write_text(json.dumps({"id": app.APP_ID, "version": "0.1"}))
        own.symlink_to(source, target_is_directory=True)
        result = app.run({"action": "check-updates"}, self.store, now=1000)
        row = next(row for row in result["updates"] if row["id"] == app.APP_ID)
        self.assertEqual(row["state"], "blocked")
        self.assertTrue(row["selfUpdate"])
        self.assertFalse(row["canUpdate"])

    def test_outfit_available_is_exclusively_self_update(self):
        local = app.inspect_update_target(self.item)
        self.remote_identity = app.APP_ID
        row = app.check_plugin_update({"id": app.APP_ID, "name": "Outfit"}, 1000, local)
        self.assertEqual(row["state"], "available")
        self.assertTrue(row["selfUpdate"])
        self.assertFalse(row["canUpdate"])
        with self.assertRaisesRegex(ValueError, "ordinary"):
            self.update(pluginId=app.APP_ID)
        self.assertFalse(self.native_calls)

    def test_candidate_identity_mismatch_and_network_failure_are_unavailable(self):
        self.remote_identity = "other.plugin"
        self.assertEqual(self.check()["updates"][0]["state"], "unavailable")
        self.fetch_mock.side_effect = TimeoutError("Sensitive transport details")
        result = self.check(force=True)
        self.assertEqual(result["updates"][0]["state"], "unavailable")
        self.assertNotIn("Sensitive", json.dumps(result))

    def test_cache_six_hours_force_and_targeted_merge(self):
        first = self.check()
        calls = self.fetch_mock.call_count
        self.assertEqual(self.check(), first)
        self.assertEqual(self.fetch_mock.call_count, calls)
        app.run({"action": "check-updates", "pluginId": self.identity}, self.store, now=1000 + app.UPDATES_MAX_AGE - 1)
        self.assertEqual(self.fetch_mock.call_count, calls)
        app.run({"action": "check-updates", "pluginId": self.identity}, self.store, now=1000 + app.UPDATES_MAX_AGE)
        self.assertGreater(self.fetch_mock.call_count, calls)
        calls = self.fetch_mock.call_count
        self.check(force=True)
        self.assertGreater(self.fetch_mock.call_count, calls)
        app.run({"action": "check-updates", "pluginId": app.APP_ID}, self.store, now=1001)
        self.assertIn(self.identity, app.load_plugin_updates(self.store))

    def test_cache_is_invalidated_by_local_changes(self):
        self.check()
        (self.repo / "untracked").write_text("local")
        row = self.check()["updates"][0]
        self.assertEqual(row["state"], "customized")

    def test_scan_inventory_reads_manifest_and_git_metadata_instead_of_native_version_hint(self):
        original = self.command
        def native_list(argv, timeout, maximum):
            if argv == [app.COMMANDS["omarchy"], "plugin", "list", "--json"]:
                return json.dumps([{**self.item, "installedVersion": "forged", "installedRevision": "f" * 40}]).encode()
            if argv == [app.COMMANDS["omarchy-shell"], "shell", "listShellConfig"]:
                return json.dumps({"bar": {"layout": {"right": [self.identity]}}}).encode()
            return original(argv, timeout, maximum)
        self.command_mock.side_effect = native_list
        inventory, unavailable = self.real_inventory()
        self.assertFalse(unavailable)
        self.assertEqual(inventory[0]["installedRevision"], self.before)
        self.assertEqual(inventory[0]["installedVersion"], "1.0")
        self.assertEqual(inventory[0]["barSection"], "right")

    def test_sparse_and_assume_unchanged_flags_block_updates(self):
        for flag in ("assume-unchanged", "skip-worktree"):
            with self.subTest(flag=flag):
                self.git("update-index", "--" + flag, "manifest.json")
                row = self.check(force=True)["updates"][0]
                self.assertEqual(row["state"], "blocked")
                self.git("update-index", "--no-" + flag, "manifest.json")
        self.fetch_mock.assert_not_called()

    def test_private_repository_invalid_head_and_oversized_manifest_fail_closed(self):
        self.head_mock.side_effect = app.PublicUpdateUnavailable("Sensitive private repository details")
        result = self.check()
        self.assertEqual(result["updates"][0]["state"], "unavailable")
        self.assertIn("without credentials", result["updates"][0]["reason"])
        self.assertNotIn("Sensitive", json.dumps(result))
        self.head_mock.side_effect = None
        self.head_mock.return_value = b"not a remote HEAD"
        self.assertEqual(self.check(force=True)["updates"][0]["state"], "unavailable")
        self.fetch_mock.assert_not_called()
        with self.assertRaisesRegex(ValueError, "size limit"):
            app.update_manifest(b"x" * (app.MAX_UPDATE_MANIFEST_BYTES + 1), self.identity)

    def test_deadlines_prevent_network_and_git_dispatch(self):
        self.command_mock.reset_mock()
        with self.assertRaises(TimeoutError):
            self.real_public_head("https://github.com/example/widget", time.monotonic() - 1)
        with self.assertRaises(TimeoutError):
            app.update_git(self.repo, ["status"], time.monotonic() - 1)
        self.command_mock.assert_not_called()
        self.fetch_mock.assert_not_called()

    def test_remote_update_contract_pins_manifest_without_rest_resolution(self):
        target = app.remote_update_target("https://github.com/example/widget.git", self.identity)
        self.assertEqual(target, {"revision": self.candidate, "version": "1.1", "branch": "main"})
        self.assertEqual(self.head_mock.call_count, 1)
        self.assertEqual(self.fetch_mock.call_count, 1)
        self.assertEqual(self.fetch_mock.call_args.args[:3], (
            f"https://raw.githubusercontent.com/example/widget/{self.candidate}/manifest.json",
            "raw.githubusercontent.com", app.MAX_UPDATE_MANIFEST_BYTES))

    def test_outdated_check_uses_only_one_compare_api_call(self):
        self.assertEqual(self.check()["updates"][0]["state"], "available")
        self.assertEqual(self.head_mock.call_count, 1)
        calls = [call for call in self.fetch_mock.call_args_list if call.args[1] == "api.github.com"]
        self.assertEqual(len(calls), 1)
        self.assertIn(f"/compare/{self.before}...{self.candidate}?per_page=1", calls[0].args[0])

    def test_current_cache_lasts_six_hours_but_unavailable_checks_retry_after_five_minutes(self):
        self.remote_revision = self.before
        self.remote_version = "1.0"
        first = self.check()
        result = app.run({"action": "check-updates", "pluginId": self.identity},
                         self.store, now=1000 + app.UPDATES_MAX_AGE - 1)
        self.assertEqual(result["updates"], first["updates"])
        self.assertEqual(self.head_mock.call_count, 1)
        app.run({"action": "check-updates", "pluginId": self.identity}, self.store, now=1000 + app.UPDATES_MAX_AGE)
        self.assertEqual(self.head_mock.call_count, 2)

        self.head_mock.side_effect = app.PublicUpdateUnavailable("No public remote")
        self.assertEqual(self.check(force=True)["updates"][0]["state"], "unavailable")
        calls = self.head_mock.call_count
        app.run({"action": "check-updates", "pluginId": self.identity}, self.store, now=1299)
        self.assertEqual(self.head_mock.call_count, calls)
        self.head_mock.side_effect = self.head
        result = app.run({"action": "check-updates", "pluginId": self.identity}, self.store, now=1300)
        self.assertEqual(result["updates"][0]["state"], "current")
        self.assertEqual(self.head_mock.call_count, calls + 1)

    def test_rate_limits_missing_history_and_raw_manifest_errors_have_safe_reasons(self):
        original = self.fetch
        for host in ("api.github.com", "raw.githubusercontent.com"):
            for code, headers, reason in (
                    (403, {"X-RateLimit-Remaining": "0"}, "rate-limiting"),
                    (403, {"x-ratelimit-remaining": "0"}, "rate-limiting"),
                    (403, {"Retry-After": "60"}, "rate-limiting"),
                    (429, {}, "rate-limiting"),
                    (403, {}, "denied or rate-limited"),
                    (404, {}, "missing or inaccessible")):
                with self.subTest(host=host, code=code, headers=headers):
                    def unavailable(url, actual_host, *args, **kwargs):
                        if actual_host == host:
                            raise urllib.error.HTTPError("https://private:secret@github.com/example/widget",
                                                         code, "rawsecretmessage", headers, None)
                        return original(url, actual_host, *args, **kwargs)
                    self.fetch_mock.side_effect = unavailable
                    result = self.check(force=True)
                    row = result["updates"][0]
                    self.assertEqual(row["state"], "unavailable")
                    self.assertFalse(row["canUpdate"])
                    self.assertIn(reason, row["reason"])
                    self.assertNotIn("secret", json.dumps(result))
                    self.assertEqual(result["updatesError"], "")
                    self.assertEqual(result["updatesUnavailableCount"], 1)
                    calls = self.fetch_mock.call_count
                    app.run({"action": "check-updates", "pluginId": self.identity}, self.store, now=1299)
                    self.assertEqual(self.fetch_mock.call_count, calls)
                    self.fetch_mock.side_effect = original
                    recovered = app.run({"action": "check-updates", "pluginId": self.identity}, self.store, now=1300)
                    self.assertEqual(recovered["updates"][0]["state"], "available")

    def test_symref_parser_matches_actual_git_advertisement_and_nested_branch(self):
        for branch in ("main", "release/stable"):
            if branch != "main":
                self.git("branch", branch, self.before)
                self.git("symbolic-ref", "HEAD", "refs/heads/" + branch)
            # Local transport fixture only; real git, no external connection.
            raw = self.git("ls-remote", "--symref", "--exit-code", "--", str(self.repo), "HEAD")
            self.assertEqual(app.parse_update_head(raw), {"revision": self.before, "branch": branch})
            reversed_lines = b"\n".join(reversed(raw.rstrip(b"\n").split(b"\n"))) + b"\n"
            self.assertEqual(app.parse_update_head(reversed_lines), {"revision": self.before, "branch": branch})

    def test_symref_parser_rejects_missing_duplicate_malicious_and_ambiguous_heads(self):
        symref = b"ref: refs/heads/main\tHEAD\n"
        head = self.before.encode() + b"\tHEAD\n"
        invalid = [b"", head, symref, head + head, symref + symref, symref + head + head,
                   symref + head + self.candidate.encode() + b"\trefs/heads/main\n",
                   symref + b"HEAD\tHEAD\n", symref + b"0" * 40 + b"\tHEAD\n",
                   symref + b"A" * 40 + b"\tHEAD\n", symref + b"$(touch secret)\tHEAD\n",
                   b"ref: refs/tags/main\tHEAD\n" + head, symref + head + b"\n",
                   symref + head.replace(b"\tHEAD", b"\trefs/heads/main"),
                   b"\xff" + head, b"x" * (app.MAX_UPDATE_HEAD_BYTES + 1)]
        for branch in ("../main", "main..old", ".hidden", "main.lock", "main//next", "main/",
                       "main@{1}", "main\\old", "main\r", "main\x00", "main?", "main.",
                       "main\tHEAD\nref: refs/heads/evil", "main; touch secret", "x" * 257):
            invalid.append(f"ref: refs/heads/{branch}\tHEAD\n".encode() + head)
        for raw in invalid:
            with self.subTest(raw=raw[:80]), self.assertRaisesRegex(ValueError, "missing, ambiguous or invalid") as raised:
                app.parse_update_head(raw)
            self.assertNotIn("secret", str(raised.exception))

    def test_anonymous_head_launch_clears_credentials_config_rewrites_and_repository_context(self):
        real_popen = subprocess.Popen
        captured = []
        fixture = self.head("https://github.com/example/widget", time.monotonic() + 10)
        def launch(argv, **kwargs):
            captured.append((argv, kwargs))
            # Only a controlled Python stdout fixture is executed; never Git's
            # network transport. Preserve actual runner pipes/env/cwd for proof.
            return real_popen([sys.executable, "-B", "-c", f"import os; os.write(1, {fixture!r})"], **kwargs)
        poison = {"HOME": str(self.home), "XDG_CONFIG_HOME": str(self.repo),
                  "GIT_CONFIG_GLOBAL": str(self.repo / "rewrite"), "GIT_CONFIG_SYSTEM": str(self.repo / "rewrite"),
                  "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "http.extraHeader", "GIT_CONFIG_VALUE_0": "secret",
                  "GIT_CONFIG_PARAMETERS": "secret", "GIT_DIR": str(self.repo / ".git"),
                  "GIT_WORK_TREE": str(self.repo), "GIT_ASKPASS": "/secret/helper", "GIT_EXEC_PATH": "/secret/bin",
                  "GITHUB_TOKEN": "secret", "GH_TOKEN": "secret", "NETRC": "/secret/netrc",
                  "http_proxy": "https://private:secret@proxy.invalid", "HTTPS_PROXY": "secret",
                  "LD_PRELOAD": "/secret/lib.so", "PATH": "/secret/bin"}
        with mock.patch.dict(os.environ, poison), mock.patch.object(app.subprocess, "Popen", side_effect=launch):
            raw = self.real_public_head("https://github.com/example/widget.git", time.monotonic() + 10)
        self.assertEqual(raw, fixture)
        argv, kwargs = captured[0]
        self.assertEqual(argv[0], app.COMMANDS["git"])
        self.assertEqual(argv[-6:], ["ls-remote", "--symref", "--exit-code", "--", "https://github.com/example/widget.git", "HEAD"])
        self.assertNotIn("fetch", argv)
        self.assertNotIn("shell", kwargs)
        self.assertEqual(kwargs["cwd"], "/")
        self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
        self.assertEqual(kwargs["stderr"], subprocess.DEVNULL)
        self.assertTrue(kwargs["start_new_session"])
        environment = kwargs["env"]
        self.assertEqual(environment["HOME"], "/dev/null")
        self.assertEqual(environment["XDG_CONFIG_HOME"], "/dev/null")
        self.assertEqual(environment["GIT_CONFIG_GLOBAL"], "/dev/null")
        self.assertEqual(environment["GIT_CONFIG_SYSTEM"], "/dev/null")
        self.assertEqual(environment["GIT_CONFIG_NOSYSTEM"], "1")
        self.assertEqual(environment["GIT_TERMINAL_PROMPT"], "0")
        self.assertEqual(environment["GIT_ASKPASS"], "/bin/false")
        self.assertEqual(environment["PATH"], app.SYSTEM_COMMAND_PATH)
        for key in poison.keys() - {"HOME", "XDG_CONFIG_HOME", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_ASKPASS", "PATH"}:
            self.assertNotIn(key, environment)
        self.assertNotIn("secret", json.dumps(environment))
        for setting in ("credential.helper=", "protocol.allow=never", "protocol.https.allow=always",
                        "http.followRedirects=false", "http.sslVerify=true", "http.extraHeader=", "http.cookieFile="):
            self.assertIn(setting, argv)
        self.assertFalse(app._children)

    def test_anonymous_head_rejects_credential_origins_before_process_launch(self):
        for repository in ("https://private:secret@github.com/example/widget.git", "git@github.com:example/widget.git",
                           "https://gitlab.com/example/widget", "https://github.com/../widget",
                           "https://github.com/example/widget?token=secret", "https://github.com/example/$(secret)"):
            with self.subTest(repository=repository), mock.patch.object(app.subprocess, "Popen") as launch:
                with self.assertRaisesRegex(ValueError, "Unsupported") as raised:
                    self.real_public_head(repository, time.monotonic() + 10)
                self.assertNotIn("secret", str(raised.exception))
                launch.assert_not_called()

    def test_anonymous_head_bounds_output_time_and_failure_without_exposing_stderr(self):
        real_popen = subprocess.Popen
        for script, budget in (("import os; os.write(1, b'x' * 8192)", 2),
                               ("import time; time.sleep(30)", 0.03),
                               ("import os; os.write(2, b'rawsecretmessage'); raise SystemExit(1)", 2)):
            with self.subTest(script=script):
                def launch(argv, **kwargs):
                    return real_popen([sys.executable, "-B", "-c", script], **kwargs)
                with mock.patch.object(app.subprocess, "Popen", side_effect=launch), \
                        self.assertRaises(app.PublicUpdateUnavailable) as raised:
                    self.real_public_head("https://github.com/example/widget", time.monotonic() + budget)
                self.assertNotIn("secret", str(raised.exception))
                self.assertFalse(app._children)

    def test_check_concurrency_is_bounded(self):
        items = app.validate_inventory([{"id": f"example.fixture{i}"} for i in range(12)])
        lock = threading.Lock()
        active = maximum = 0
        def remote(*args, **kwargs):
            nonlocal active, maximum
            with lock:
                active += 1
                maximum = max(maximum, active)
            time.sleep(0.01)
            with lock:
                active -= 1
            return {"revision": self.before, "version": "1", "branch": "main"}
        local = {"installedRevision": self.before, "installedVersion": "1", "state": "ready",
                 "reason": "", "sourceKey": "a" * 64, "repository": "https://github.com/example/fixture"}
        with mock.patch.object(app, "scan_inventory", return_value=(items, False)), \
                mock.patch.object(app, "inspect_update_target", return_value=local), \
                mock.patch.object(app, "remote_update_target", side_effect=remote):
            result = app.run({"action": "check-updates"}, self.store, now=1000)
        self.assertEqual(len(result["updates"]), 13)  # Includes Outfit.
        self.assertGreater(maximum, 1)
        self.assertLessEqual(maximum, app.UPDATES_WORKERS)

    def test_corrupt_cache_is_rebuilt_and_cache_cannot_inject_response_fields(self):
        self.store.write("plugin-updates.json", {"schema": 1, "entries": []}, app.MAX_UPDATES_CACHE_BYTES)
        self.assertEqual(self.check()["updates"][0]["state"], "available")
        entries = app.load_plugin_updates(self.store)
        entries[self.identity]["record"]["rawOrigin"] = "secret"
        self.store.write("plugin-updates.json", {"schema": 1, "entries": entries}, app.MAX_UPDATES_CACHE_BYTES)
        self.assertNotIn("rawOrigin", self.check()["updates"][0])
        for fields in ({"state": []}, {"checkedAt": 10 ** 400}, {"checkedAt": float("nan")}):
            with self.subTest(fields=fields):
                malformed = json.loads(json.dumps(entries))
                malformed[self.identity]["record"].update(fields)
                self.store.write("plugin-updates.json", {"schema": 1, "entries": malformed}, app.MAX_UPDATES_CACHE_BYTES)
                self.assertEqual(self.check()["updates"][0]["state"], "available")

    def test_boolean_request_fields_are_strict(self):
        for fields in ({"force": "true"}, {"pluginId": []}):
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                self.check(**fields)
        self.check()
        with self.assertRaises(ValueError):
            self.update(batchItem="true")

    def test_unavailable_authoritative_inventory_never_offers_update(self):
        self.check()
        with mock.patch.object(app, "scan_inventory", return_value=([self.item], True)):
            result = self.check()
        self.assertFalse(result["inventoryAuthoritative"])
        self.assertFalse(result["updates"][0]["canUpdate"])
        self.assertTrue(result["updatesError"])

    def test_successful_update_fixed_native_command_and_verified_metadata(self):
        self.check()
        progress = []
        result = app.run({"action": "update-plugin", "pluginId": self.identity,
                          "expectedRevision": self.candidate, "expectedInstalledRevision": self.before,
                          "batchItem": True, "streamProgress": True}, self.store, now=1001, progress=progress.append)
        operation = result["operation"]
        self.pinned_mock.assert_called_once()
        self.assertEqual(len(self.native_calls), 1)
        self.assertTrue(operation["observed"])
        self.assertTrue(operation["verified"])
        self.assertTrue(operation["batchItem"])
        self.assertEqual(operation["installedRevision"], self.candidate)
        self.assertEqual(operation["installedVersion"], "1.1")
        self.assertEqual(operation["expectedRevision"], self.candidate)
        self.assertEqual(result["inventory"][0]["barSection"], "right")
        self.assertTrue(result["inventory"][0]["enabled"])
        self.assertEqual(result["responseKind"], "mutation")
        self.assertFalse(result["error"])
        self.assertNotIn(self.identity, app.load_plugin_updates(self.store))
        self.assertIn("updating", [event["phase"] for event in progress])

    def test_local_only_update_needs_no_catalog_and_preserves_disabled_state(self):
        self.item.update(enabled=False, barSection="")
        with mock.patch.object(app, "load_catalog", side_effect=AssertionError("Updates do not use the catalog")):
            self.check()
            result = self.update()
        self.assertTrue(result["operation"]["observed"])
        self.assertFalse(result["inventory"][0]["enabled"])
        self.assertEqual(result["inventory"][0]["barSection"], "")

    def test_missing_review_and_forged_revisions_are_rejected(self):
        with self.assertRaises(ValueError):
            self.update()
        self.check()
        for fields in ({"expectedRevision": "a" * 40}, {"expectedInstalledRevision": "b" * 40},
                       {"expectedRevision": "HEAD"}, {"pluginId": "../other"}):
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                self.update(**fields)
        self.assertFalse(self.native_calls)

    def test_source_changed_since_review_even_with_same_sha_is_rejected(self):
        self.check()
        self.git("remote", "set-url", "origin", "https://github.com/other/widget.git")
        with self.assertRaisesRegex(ValueError, "source.*changed"):
            self.update()
        self.assertFalse(self.native_calls)

    def test_installed_revision_changed_and_expired_review_are_rejected(self):
        self.check()
        self.git("reset", "--hard", self.candidate)
        with self.assertRaises(ValueError):
            self.update()
        self.git("reset", "--hard", self.before)
        with self.assertRaises(ValueError):
            app.run({"action": "update-plugin", "pluginId": self.identity,
                     "expectedRevision": self.candidate, "expectedInstalledRevision": self.before},
                    self.store, now=1000 + app.UPDATES_MAX_AGE)
        self.assertFalse(self.native_calls)

    def test_enabled_state_change_during_preflight_is_rejected(self):
        self.check()
        original = self.fetch
        def changed(url, *args, **kwargs):
            value = original(url, *args, **kwargs)
            if "/compare/" in url:
                self.item["enabled"] = False
            return value
        self.fetch_mock.side_effect = changed
        with self.assertRaisesRegex(ValueError, "enabled state"):
            self.update()
        self.assertFalse(self.native_calls)

    def test_unknown_placement_and_concurrent_updater_block_native_dispatch(self):
        self.check()
        self.item["barSectionKnown"] = False
        with self.assertRaisesRegex(ValueError, "placement"):
            self.update()
        self.item["barSectionKnown"] = True
        with app.plugin_update_lock(self.store), self.assertRaisesRegex(ValueError, "Another plugin update"):
            self.update()
        self.assertFalse(self.native_calls)

    def test_non_native_xdg_directory_is_blocked(self):
        # Native uses HOME/.config even when XDG_CONFIG_HOME points elsewhere.
        # Never offer a command that would target a different installation.
        other_home = self.home / "other-home"
        other_home.mkdir()
        with mock.patch.dict(os.environ, {"HOME": str(other_home)}):
            row = self.check()["updates"][0]
            self.assertEqual(row["state"], "blocked")
            self.assertIn("configuration directory", row["reason"])
            with self.assertRaisesRegex(ValueError, "configuration directory"):
                self.update()
        self.assertFalse(self.native_calls)

    def test_version_mismatch_after_native_update_is_not_verified(self):
        self.remote_version = "9.9"
        self.check()
        result = self.update()
        self.assertEqual(result["operation"]["installedRevision"], self.candidate)
        self.assertEqual(result["operation"]["installedVersion"], "1.1")
        self.assertFalse(result["operation"]["observed"])

    def test_remote_moved_before_dispatch_is_rejected(self):
        self.check()
        self.remote_revision = "d" * 40
        with self.assertRaisesRegex(ValueError, "remote target"):
            self.update()
        self.assertFalse(self.native_calls)

    def test_dirty_tree_before_dispatch_is_rejected(self):
        self.check()
        (self.repo / "local-file").write_text("untracked")
        with self.assertRaises(ValueError):
            self.update()
        self.assertFalse(self.native_calls)

    def test_change_during_network_preflight_is_rejected(self):
        self.check()
        original = self.fetch
        def changed(url, *args, **kwargs):
            value = original(url, *args, **kwargs)
            if "/compare/" in url:
                self.git("remote", "set-url", "origin", "https://github.com/other/widget.git")
            return value
        self.fetch_mock.side_effect = changed
        with self.assertRaisesRegex(ValueError, "checkout changed"):
            self.update()
        self.assertFalse(self.native_calls)

    def test_failed_validation_rollback_is_reported_truthfully(self):
        self.check()
        self.native_mode = "rollback"
        result = self.update()
        self.assertFalse(result["operation"]["observed"])
        self.assertEqual(result["operation"]["installedRevision"], self.before)
        self.assertIn("rolled back", result["error"])

    def test_corrupt_native_result_and_noop_are_not_success(self):
        for mode in ("late", "noop", "failure-after-merge", "placement", "disabled"):
            with self.subTest(mode=mode):
                self.git("reset", "--hard", self.before)
                self.item.update(barSection="right", enabled=True)
                self.check(force=True)
                self.native_mode = mode
                result = self.update()
                self.assertFalse(result["operation"]["observed"])
                self.assertNotEqual(result["operation"]["status"], "completed")
                self.assertTrue(result["error"])
                if mode == "late":
                    self.assertIn("differs from the pinned target", result["error"])

    def test_mutation_observation_requires_target_revision_and_version(self):
        item = self.inventory()[0][0]
        request = {"expectedRevision": self.candidate, "expectedVersion": "1.1"}
        self.assertFalse(app.mutation_observed("update-plugin", request, self.identity, [item]))
        item["installedRevision"] = self.candidate
        self.assertFalse(app.mutation_observed("update-plugin", request, self.identity, [item]))
        item["installedVersion"] = "1.1"
        self.assertTrue(app.mutation_observed("update-plugin", request, self.identity, [item]))

    def test_native_environment_disables_prompts_helpers_hooks_and_other_protocols(self):
        _argv, environment = app.command_launch([app.COMMANDS["omarchy"], "plugin", "update", self.identity, "--yes"])
        self.assertEqual(environment["GIT_TERMINAL_PROMPT"], "0")
        self.assertEqual(environment["GIT_ASKPASS"], "/bin/false")
        settings = {environment[f"GIT_CONFIG_KEY_{i}"]: environment[f"GIT_CONFIG_VALUE_{i}"]
                    for i in range(int(environment["GIT_CONFIG_COUNT"]))}
        self.assertEqual(settings["credential.helper"], "")
        self.assertEqual(settings["core.hooksPath"], "/dev/null")
        self.assertEqual(settings["protocol.allow"], "never")
        self.assertEqual(settings["protocol.https.allow"], "always")


if __name__ == "__main__":
    unittest.main()
