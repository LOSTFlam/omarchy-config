"""Detached update transactions, using only temp files and modeled commands.

No test executes Git, systemd, network requests, native scripts or a shell
restart. The backend's real review/manifest/cache APIs consume the modeled Git
and GitHub responses, including sourceKey changes.
"""
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time
import unittest
from unittest import mock

from tests.test_outfit import OUTFIT as app


SOURCE = Path(__file__).resolve().parents[1] / "scripts/self_update.py"
SPEC = importlib.util.spec_from_file_location("self_update_tests_module", SOURCE)
worker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(worker)
REAL_COMMAND = worker._command


class SelfUpdateTests(unittest.TestCase):
    def test_virtual_updates_context_is_allowlisted_in_resume_payload(self):
        context = {"x":10,"y":100,"expanded":{"example.plugin":True},"id":"example.plugin",
                   "action":"explain","anchor":{"id":"example.plugin","offset":-10},"private":"drop"}
        result = worker._payload({"setupStage":"updates","updatesContext":context})
        self.assertEqual(result["updatesContext"],{k:v for k,v in context.items() if k != "private"})
        with self.assertRaises(ValueError):
            worker._payload({"updatesContext":{"expanded":{"constructor":True}}})

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="outfit-self-update-")
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        self.repo = self.home / ".config/omarchy/plugins" / app.APP_ID
        (self.repo / ".git").mkdir(parents=True)
        (self.repo / "scripts").mkdir()
        self.sources = {"self_update.py": SOURCE.read_bytes(), "outfit.py": Path(app.__file__).read_bytes()}
        for name, raw in self.sources.items():
            (self.repo / "scripts" / name).write_bytes(raw)
        self.runtime = self.home / "original-runtime"
        (self.runtime / "bin").mkdir(parents=True)
        for name in ("omarchy", "omarchy-shell", "omarchy-restart-shell"):
            path = self.runtime / "bin" / name
            path.write_text("# Fake command source: this file must never be executed.\n")
            path.chmod(0o700)
        self.patch(mock.patch.dict(os.environ, {"HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.home / ".config"), "OMARCHY_PATH": str(self.runtime),
            "PATH": "/untrusted/bin", "LD_PRELOAD": "/untrusted.so", "PYTHONPATH": "/untrusted",
            "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.hooksPath",
            "GIT_CONFIG_VALUE_0": "/untrusted-hooks"}, clear=True))
        self.patch(mock.patch.object(worker, "__file__", str(self.repo / "scripts/self_update.py")))
        self.patch(mock.patch.object(app, "__file__", str(self.repo / "scripts/outfit.py")))
        self.store = app.Store(self.home / "cache")
        self.addCleanup(self.store.close)
        self.before, self.after = "1" * 40, "2" * 40
        self.revision = self.before
        self.remote_revision = self.after
        self.remote_version = "2.0"
        self.version = "1.0"
        self.origin = "https://github.com/ctl0v0/outfit.git"
        self.config = b"core.repositoryformatversion\n0\0remote.origin.url\nhttps://github.com/ctl0v0/outfit.git\0"
        self.dirty = b""
        self.tracked = b"H manifest.json\0H scripts/outfit.py\0H scripts/self_update.py\0"
        self.replacements = b""
        self.item = {"id": app.APP_ID, "firstParty": False, "enabled": True, "barSectionKnown": True,
                     "barSection": "right", "name": "Outfit"}
        self.write_manifest()
        self.patch(mock.patch.object(app, "scan_inventory", side_effect=lambda **kwargs: ([dict(self.item)], False)))
        self.git_mock = self.patch(mock.patch.object(app, "update_git", side_effect=self.git))
        self.patch(mock.patch.object(app, "fetch_bytes", side_effect=self.fetch))
        self.patch(mock.patch.object(app, "public_update_head", side_effect=lambda repository, deadline:
            f"ref: refs/heads/main\tHEAD\n{self.remote_revision}\tHEAD\n".encode()))
        # Defense in depth: any accidental real backend process is a test error.
        self.patch(mock.patch.object(app, "run_command", side_effect=AssertionError("Unexpected real backend command")))
        self.patch(mock.patch.object(subprocess, "Popen", side_effect=AssertionError("No actual subprocess allowed")))
        self.commands = []
        self.mode = "success"
        self.readiness_failures = 0
        self.command_mock = self.patch(mock.patch.object(worker, "_command", side_effect=self.command))
        self.pinned_mock = self.patch(mock.patch.object(app, "update_reviewed_plugin", side_effect=self.pinned_update))
        self.patch(mock.patch.object(worker, "ACK_TIMEOUT", 0))
        self.review()

    def pinned_update(self, item, local, expected, version):
        self.assertEqual(item["id"], app.APP_ID)
        self.assertEqual(local["installedRevision"], self.before)
        self.assertEqual(expected, self.after)
        self.assertEqual(version, self.remote_version)
        self.assertTrue(local["sourceKey"])
        return worker._command([str(self.runtime / "bin/omarchy"), "plugin", "update", app.APP_ID, "--yes"],
                               worker._runtime(app), 90)

    def patch(self, patcher):
        value = patcher.start()
        self.addCleanup(patcher.stop)
        return value

    def write_manifest(self, identity=app.APP_ID):
        (self.repo / "manifest.json").write_text(json.dumps({"id": identity, "version": self.version}))

    def git(self, target, args, deadline=None, maximum=64 * 1024):
        self.assertEqual(target, self.repo)
        responses = {
            ("rev-parse", "--show-toplevel"): str(self.repo).encode(),
            ("rev-parse", "--verify", "HEAD"): self.revision.encode(),
            ("config", "--get-all", "remote.origin.url"): self.origin.encode(),
            ("remote", "get-url", "--all", "origin"): self.origin.encode(),
            ("status", "--porcelain=v1", "--untracked-files=normal", "--ignore-submodules=none"): self.dirty,
            ("ls-files", "-v", "-z"): self.tracked,
            ("config", "--null", "--list"): self.config,
            ("for-each-ref", "--format=%(refname)", "refs/replace/"): self.replacements,
        }
        if len(args) == 2 and args[0] == "show":
            return self.sources[args[1].split("/")[-1]]
        self.assertIn(tuple(args), responses)
        return responses[tuple(args)]

    def fetch(self, url, host, maximum, timeout=12):
        if host == "raw.githubusercontent.com":
            return json.dumps({"id": app.APP_ID, "version": self.remote_version}).encode()
        self.assertEqual(host, "api.github.com")
        if "/compare/" in url:
            value = {"status": "ahead", "behind_by": 0, "ahead_by": 1,
                     "base_commit": {"sha": self.revision}, "merge_base_commit": {"sha": self.revision}}
        elif "/git/ref/heads/" in url:
            value = {"object": {"type": "commit", "sha": self.remote_revision}}
        else:
            value = {"private": False, "default_branch": "main"}
        return json.dumps(value).encode()

    def review(self):
        local = app.inspect_update_target(self.item)
        row = app.check_plugin_update(self.item, snapshot=local)
        self.assertEqual(row["state"], "available")
        self.store.write("plugin-updates.json", {"schema": 1, "entries": {
            app.APP_ID: {"sourceKey": local["sourceKey"], "record": row}}}, app.MAX_UPDATES_CACHE_BYTES)

    def command(self, argv, environment, timeout=5, maximum=128 * 1024):
        self.commands.append((list(argv), dict(environment)))
        self.assertNotIn("LD_PRELOAD", environment)
        self.assertNotIn("PYTHONPATH", environment)
        self.assertEqual(environment["PATH"], str(self.runtime / "bin") + ":/usr/bin:/bin")
        if argv[0] == "/usr/bin/systemd-run":
            if self.mode == "launch-failure":
                raise ValueError("credentials must not appear in receipts")
            if self.mode == "launch-timeout":
                raise TimeoutError("credentials must not appear in receipts")
            return b""
        if argv == ["/usr/bin/systemctl", "--user", "show-environment"]:
            runtime = self.home / "different-runtime" if self.mode == "runtime-changed" else self.runtime
            return ("OMARCHY_PATH=" + str(runtime)).encode()
        if argv == [str(self.runtime / "bin/omarchy"), "plugin", "update", app.APP_ID, "--yes"]:
            if self.mode == "update-failure":
                raise ValueError("sensitive transport failure")
            if self.mode != "noop":
                self.revision = "3" * 40 if self.mode == "remote-moved" else self.after
                self.version = "9.0" if self.mode == "bad-version" else "2.0"
                self.write_manifest("wrong.id" if self.mode == "bad-identity" else app.APP_ID)
            if self.mode == "timeout-after-merge":
                raise TimeoutError("update may have completed")
            if self.mode == "replace-sources":
                for name in self.sources:
                    (self.repo / "scripts" / name).unlink()
            return b"Updated"
        if argv == [str(self.runtime / "bin/omarchy-restart-shell")]:
            receipt = worker.status(app, self.store)
            self.assertTrue(receipt["verified"])
            self.assertEqual(receipt["installedRevision"], self.after)
            if self.mode == "restart-failure":
                raise ValueError("native refused")
            return b""
        if argv == [str(self.runtime / "bin/omarchy-shell"), app.APP_ID, "status"]:
            if self.readiness_failures:
                self.readiness_failures -= 1
                raise ValueError("not ready")
            return b'{"opened":false}'
        self.assertEqual(argv[:4], [str(self.runtime / "bin/omarchy-shell"), "shell", "summon", app.APP_ID])
        self.assertLessEqual(len(argv[4]), 8192)
        if self.mode == "summon-timeout":
            raise TimeoutError("possibly delivered")
        return b"no" if self.mode == "summon-rejected" else b"ok\n"

    def launch(self, **fields):
        return worker.launch(app, {"action": "self-update", "expectedRevision": self.after,
            "expectedInstalledRevision": self.before, "resumePayload": {"view": "setup"}, **fields}, self.store)

    def staged(self):
        receipt = worker._receipt(worker._state_root(self.store))
        directory = worker._state_root(self.store) / receipt["operationId"]
        return directory, json.loads((directory / "job.json").read_bytes())

    def work(self):
        directory, job = self.staged()
        with worker._lock(directory.parent / "worker.lock"), mock.patch.object(worker.time, "sleep"):
            code = worker._work(app, self.store, directory.parent, job)
        return code, worker.status(app, self.store)

    def native_calls(self):
        return [argv for argv, _ in self.commands if argv[0] not in {"/usr/bin/systemd-run", "/usr/bin/systemctl"}]

    def test_stage_is_private_complete_outside_checkout_and_fixed_user_oneshot(self):
        result = self.launch()
        self.assertEqual(result["state"], "unconfirmed")
        self.assertFalse(result["ok"])
        directory, job = self.staged()
        self.assertFalse(directory.is_relative_to(self.repo))
        self.assertEqual((directory / "outfit.py").read_bytes(), self.sources["outfit.py"])
        self.assertEqual((directory / "self_update.py").read_bytes(), self.sources["self_update.py"])
        for path in (directory, directory.parent):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700)
        for path in directory.iterdir():
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        argv, env = self.commands[0]
        for argument in ("--user", "--no-block", "--collect", "--service-type=oneshot",
                         "--property=KillMode=control-group", "--property=TimeoutStartSec=300",
                         "--property=StandardOutput=null", "--property=StandardError=null", "-I", "-B"):
            self.assertIn(argument, argv)
        self.assertEqual(argv[-2:], [str(directory / "self_update.py"), "--worker"])
        self.assertNotIn("--scope", argv)
        self.assertNotIn("--wait", argv)
        self.assertIn("--unit=outfit-self-update.service", argv)
        self.assertEqual(argv[argv.index("--") + 1:argv.index("--") + 5],
                         ["/usr/bin/env", "-i", "/usr/bin/python3", "-I"])
        self.assertNotIn("/untrusted", json.dumps(job))
        self.assertEqual(env["GIT_CONFIG_GLOBAL"], "/dev/null")

    def test_worker_acknowledges_before_launch_claims_acceptance(self):
        def acknowledge(_delay):
            root = worker._state_root(self.store)
            with worker._lock(root / "worker.lock"):
                receipt = worker._receipt(root)
                worker._record(root, receipt, "checking", "Worker acknowledged.", accepted=True)
        with mock.patch.object(worker, "ACK_TIMEOUT", 1), mock.patch.object(worker.time, "sleep", side_effect=acknowledge):
            result = self.launch()
        self.assertEqual(result["state"], "checking")
        self.assertTrue(result["accepted"])
        self.assertTrue(result["ok"])
        self.assertFalse(result["verified"])

    def test_state_changes_during_remote_verification_refuse_native_update(self):
        self.launch()
        original = app.check_plugin_update

        def check(*args, **kwargs):
            result = original(*args, **kwargs)
            self.item["enabled"] = False
            return result

        with mock.patch.object(app, "check_plugin_update", side_effect=check):
            code, result = self.work()
        self.assertEqual(code, 1)
        self.assertFalse(result["verified"])
        self.assertFalse(self.native_calls())

    def test_changed_placement_since_launch_refuses_worker(self):
        self.launch()
        self.item["barSection"] = "left"
        code, result = self.work()
        self.assertEqual(code, 1)
        self.assertFalse(result["verified"])
        self.assertFalse(self.native_calls())

    def test_native_state_change_never_records_verified_or_restarts(self):
        for field, value in (("enabled", False), ("barSection", "left"), ("barSectionKnown", False)):
            with self.subTest(field=field):
                self.item.update(enabled=True, barSection="right", barSectionKnown=True)
                self.revision, self.version = self.before, "1.0"
                self.write_manifest()
                self.review()
                self.launch()
                original = self.command

                def command(argv, *args, **kwargs):
                    result = original(argv, *args, **kwargs)
                    if "update" in argv:
                        self.item[field] = value
                    return result

                with mock.patch.object(worker, "_command", side_effect=command):
                    code, result = self.work()
                self.assertEqual(code, 1)
                self.assertFalse(result["verified"])
                self.assertEqual(result["installedRevision"], self.after)
                self.assertFalse(any("omarchy-restart-shell" in argv[0] for argv in self.native_calls()))

    def test_success_writes_verified_receipt_before_restart_and_summons_once(self):
        self.launch(resumePayload={"view": "setup", "query": "audio", "windowWidth": 900})
        code, result = self.work()
        self.pinned_mock.assert_called_once()
        self.assertEqual(code, 0)
        self.assertEqual(result["state"], "completed")
        self.assertEqual(result["installedRevision"], self.after)
        self.assertTrue(result["verified"])
        self.assertEqual(result["reopenState"], "accepted")
        calls = self.native_calls()
        self.assertEqual(len(calls), 4)
        self.assertEqual(json.loads(calls[-1][-1])["query"], "audio")
        self.assertNotIn(app.APP_ID, app.load_plugin_updates(self.store))
        snapshot = (worker._state_root(self.store) / "receipt.json").read_bytes()
        for _ in range(3):
            self.assertEqual(worker.status(app, self.store), result)
        self.assertEqual((worker._state_root(self.store) / "receipt.json").read_bytes(), snapshot)
        self.assertEqual(len(self.native_calls()), 4)

    def test_failed_launch_cancels_delayed_worker_and_does_not_leak_errors(self):
        for mode in ("launch-failure", "launch-timeout"):
            with self.subTest(mode=mode):
                self.mode = mode
                result = self.launch()
                self.assertEqual(result["state"], "failed")
                self.assertFalse(result["accepted"])
                self.assertNotIn("credentials", json.dumps(result))
                code, result = self.work()
                self.assertEqual(code, 1)
                self.assertFalse(self.native_calls())

    def test_queued_launch_prevents_duplicate_without_native_command(self):
        first = self.launch()
        second = self.launch()
        self.assertTrue(second["duplicate"])
        self.assertFalse(second["ok"])
        self.assertEqual(first["operationId"], second["operationId"])
        self.assertEqual(len(self.commands), 1)

    def test_live_worker_lock_and_shared_plugin_lock_prevent_launch(self):
        root = worker._state_root(self.store, create=True)
        for path in (root / "worker.lock", root.parent / ".plugin-update.lock"):
            with self.subTest(path=path), worker._lock(path):
                result = self.launch()
                self.assertEqual(result["state"], "blocked")
                self.assertFalse(self.commands)

    def test_ordinary_update_winning_handoff_fails_worker_safely(self):
        self.launch()
        with worker._lock(self.store.base / ".plugin-update.lock"):
            code, result = self.work()
        self.assertEqual(code, 1)
        self.assertEqual(result["state"], "failed")
        self.assertFalse(self.native_calls())

    def test_requires_own_reviewed_revisions_and_explicit_nonbatch_action(self):
        for fields in ({"pluginId": "other.plugin"}, {"action": "update-all"}, {"batchItem": True},
                       {"expectedRevision": "main"}, {"expectedInstalledRevision": "a" * 40},
                       {"expectedRevision": self.before}, {"expectedRevision": "a" * 40}):
            with self.subTest(fields=fields):
                result = self.launch(**fields)
                self.assertIn(result["state"], {"blocked", "failed"})
                self.assertFalse(self.commands)

    def test_stale_review_source_config_and_remote_changes_fail_closed(self):
        for change in ("cache", "source", "remote", "version", "dirty", "hidden"):
            with self.subTest(change=change):
                cache = (self.store.base / "plugin-updates.json").read_bytes()
                old_config, old_remote, old_version = self.config, self.remote_revision, self.remote_version
                if change == "cache":
                    doc = json.loads(cache)
                    doc["entries"][app.APP_ID]["record"]["checkedAt"] = time.time() - app.UPDATES_MAX_AGE - 1
                    (self.store.base / "plugin-updates.json").write_bytes(json.dumps(doc).encode())
                elif change == "source": self.config += b"user.name\nChanged\0"
                elif change == "remote": self.remote_revision = "3" * 40
                elif change == "version": self.remote_version = "3.0"
                elif change == "dirty": self.dirty = b" M manifest.json"
                else: self.tracked = b"S manifest.json\0"
                self.assertIn(self.launch()["state"], {"blocked", "failed"})
                self.assertFalse(self.commands)
                (self.store.base / "plugin-updates.json").write_bytes(cache)
                self.config, self.remote_revision, self.remote_version = old_config, old_remote, old_version
                self.dirty, self.tracked = b"", b"H manifest.json\0"

    def test_worker_revalidates_after_staging_before_mutation(self):
        self.launch()
        self.remote_revision = "3" * 40
        code, result = self.work()
        self.assertEqual((code, result["state"]), (1, "failed"))
        self.assertTrue(result["accepted"])
        self.assertFalse(self.native_calls())

    def test_worker_does_not_restart_on_failure_noop_unapproved_head_or_bad_manifest(self):
        for mode in ("update-failure", "noop", "remote-moved", "bad-version", "bad-identity", "timeout-after-merge"):
            with self.subTest(mode=mode):
                self.revision, self.version = self.before, "1.0"
                self.write_manifest()
                self.review()
                self.mode = mode
                self.commands.clear()
                self.launch()
                code, result = self.work()
                self.assertEqual((code, result["state"]), (1, "failed"))
                self.assertFalse(result["verified"])
                self.assertEqual(len(self.native_calls()), 1)
                self.assertNotIn("sensitive", json.dumps(result))

    def test_restart_failure_preserves_verified_outcome_without_summon(self):
        self.mode = "restart-failure"
        self.launch()
        code, result = self.work()
        self.assertEqual((code, result["state"]), (1, "restart-failed"))
        self.assertTrue(result["verified"])
        self.assertEqual(len(self.native_calls()), 2)

    def test_readiness_retries_bounded_and_summon_timeout_is_never_retried(self):
        self.mode = "summon-timeout"
        self.readiness_failures = 3
        self.launch()
        code, result = self.work()
        self.assertEqual((code, result["state"]), (1, "reopen-failed"))
        self.assertTrue(result["verified"])
        calls = self.native_calls()
        self.assertEqual(sum("status" in argv for argv in calls), 4)
        self.assertEqual(sum("summon" in argv for argv in calls), 1)
        for _ in range(3):
            worker.status(app, self.store)
        self.assertEqual(calls, self.native_calls())

    def test_unready_shell_does_not_summon(self):
        self.readiness_failures = 100
        self.launch()
        code, result = self.work()
        self.assertEqual((code, result["state"]), (1, "reopen-failed"))
        self.assertEqual(sum("status" in argv for argv in self.native_calls()), 6)
        self.assertFalse(any("summon" in argv for argv in self.native_calls()))

    def test_payload_allowlist_strips_private_data_drafts_and_old_restore_tokens(self):
        payload = {"view": "setup", "setupQuery": "audio", "scrollAnchor": {"id": "example.plugin", "offset": 3, "y": 10},
                   "profile": [{"secret": "hardware"}], "preferences": {"secret": "preferences"},
                   "rawdevices": ["private"], "draft": {"watchHardware": False}, "restoreDraft": True,
                   "restoreToken": "old-service-token", "setupInterestCriteria": [{"label": "private"}],
                   "command": ["/bin/false"], "environment": {"HOME": "/elsewhere"}}
        self.launch(resumePayload=payload)
        directory, job = self.staged()
        staged = json.dumps(job)
        for forbidden in ("hardware", "preferences", "rawdevices", "private", "old-service-token", "elsewhere"):
            self.assertNotIn(forbidden, staged)
        self.assertEqual(job["receipt"]["resumePayload"], {k: payload[k] for k in ("view", "setupQuery", "scrollAnchor")})

    def test_invalid_or_unbounded_payloads_never_launch(self):
        for payload in ([], {"query": "x" * 161}, {"query": "secret\ncontrol"}, {"windowWidth": float("nan")},
                        {"windowHeight": -1}, {"setupServices": ["a"] * 65}, {"settingsOpen": "yes"},
                        {"scrollAnchor": {"y": float("inf")}}, {"profile": "x" * 65536}):
            with self.subTest(payload_type=type(payload)):
                self.assertIn(self.launch(resumePayload=payload)["state"], {"blocked", "failed"})
                self.assertFalse(self.commands)

    def test_expired_pending_job_is_not_executed_or_reopened(self):
        self.launch()
        directory, job = self.staged()
        with mock.patch.object(worker.time, "time", return_value=job["receipt"]["expiresAt"] + 1):
            self.assertEqual(worker.status(app, self.store)["state"], "expired")
            code, result = self.work()
            self.assertEqual((code, result["state"]), (1, "expired"))
        self.assertFalse(self.native_calls())

    def test_completed_receipt_expiration_has_no_resume_payload_or_success(self):
        self.launch()
        _, result = self.work()
        with mock.patch.object(worker.time, "time", return_value=result["expiresAt"] + 1):
            expired = worker.status(app, self.store)
        self.assertEqual(expired["state"], "expired")
        self.assertFalse(expired["ok"])
        self.assertNotIn("resumePayload", expired)

    def test_checkout_symlink_and_worktree_layout_are_rejected(self):
        original = self.home / "development"
        self.repo.rename(original)
        self.repo.symlink_to(original, target_is_directory=True)
        self.assertEqual(self.launch()["state"], "blocked")
        self.repo.unlink()
        original.rename(self.repo)
        (self.repo / ".git").rmdir()
        (self.repo / ".git").write_text("gitdir: /elsewhere")
        self.assertEqual(self.launch()["state"], "blocked")
        (self.repo / ".git").unlink()
        (self.repo / ".git/worktrees").mkdir(parents=True)
        self.assertEqual(self.launch()["state"], "blocked")
        self.assertFalse(self.commands)

    def test_git_executable_configuration_blocks_checks_and_existing_review(self):
        for key in ("filter.evil.smudge", "merge.evil.driver", "include.path", "url.file:///tmp/.insteadof", "core.sshcommand"):
            with self.subTest(key=key):
                self.config = key.encode() + b"\nmalicious command\0"
                self.assertNotEqual(app.inspect_update_target(self.item)["state"], "ready")
                self.assertEqual(self.launch()["state"], "blocked")
                self.assertFalse(self.commands)

    def test_source_must_be_tracked_exact_installed_code(self):
        (self.repo / "scripts/self_update.py").write_text("unreviewed code")
        self.assertEqual(self.launch()["state"], "blocked")
        self.assertFalse(self.commands)

    def test_git_replacements_alternates_and_symlinked_metadata_are_rejected(self):
        self.replacements = b"refs/replace/" + self.before.encode()
        self.assertEqual(self.launch()["state"], "blocked")
        self.replacements = b""
        (self.repo / ".git/config").symlink_to(self.repo / "manifest.json")
        self.assertEqual(self.launch()["state"], "blocked")
        (self.repo / ".git/config").unlink()
        (self.repo / ".git/objects/info").mkdir(parents=True)
        (self.repo / ".git/objects/info/alternates").write_text("/other/objects")
        self.assertEqual(self.launch()["state"], "blocked")
        self.assertFalse(self.commands)

    def test_missing_or_symlinked_runtime_commands_are_rejected(self):
        command = self.runtime / "bin/omarchy-restart-shell"
        command.unlink()
        self.assertIn(self.launch()["state"], {"blocked", "failed"})
        command.symlink_to(self.runtime / "bin/omarchy")
        self.assertEqual(self.launch()["state"], "blocked")
        self.assertFalse(self.commands)

    def test_store_descriptor_and_path_must_still_match(self):
        original = self.home / "moved-cache"
        self.store.base.rename(original)
        self.store.base.mkdir(mode=0o700)
        self.assertEqual(self.launch()["state"], "blocked")
        self.assertFalse(self.commands)

    def test_unavailable_or_disabled_inventory_is_not_authorized(self):
        self.item["enabled"] = False
        self.assertEqual(self.launch()["state"], "blocked")
        with mock.patch.object(app, "scan_inventory", return_value=([dict(self.item)], True)):
            self.assertEqual(self.launch()["state"], "blocked")
        self.assertFalse(self.commands)

    def test_cache_symlink_hardlink_and_lock_attacks_do_not_touch_victim(self):
        victim = self.home / "victim"
        victim.write_text("do not alter")
        victim.chmod(0o600)
        root = worker._state_root(self.store, create=True)
        for name in ("receipt.json", "worker.lock"):
            for link in ("symlink", "hardlink"):
                with self.subTest(name=name, link=link):
                    path = root / name
                    path.unlink(missing_ok=True)
                    path.symlink_to(victim) if link == "symlink" else os.link(victim, path)
                    self.assertIn(self.launch()["state"], {"blocked", "failed"})
                    self.assertEqual(victim.read_text(), "do not alter")
                    path.unlink()
        self.assertFalse(self.commands)

    def test_cache_parent_symlink_and_world_readable_state_refused(self):
        root = worker._state_root(self.store, create=True)
        root.chmod(0o755)
        self.assertEqual(self.launch()["state"], "blocked")
        root.chmod(0o700)
        root.rmdir()
        root.symlink_to(self.runtime, target_is_directory=True)
        self.assertEqual(self.launch()["state"], "blocked")
        self.assertFalse(self.commands)

    def test_status_rejects_oversized_malformed_and_symlink_receipts(self):
        root = worker._state_root(self.store, create=True)
        path = root / "receipt.json"
        for raw in (b"invalid", b"[]", b"x" * (worker.MAX_JSON + 1)):
            path.write_bytes(raw)
            path.chmod(0o600)
            self.assertEqual(worker.status(app, self.store)["state"], "unavailable")
        path.unlink()
        path.symlink_to(self.repo / "manifest.json")
        self.assertEqual(worker.status(app, self.store)["state"], "unavailable")
        self.assertFalse(self.commands)

    def test_staged_bootstrap_import_survives_installed_sources_disappearing(self):
        # Model the parent's future -I-compatible eager helper integration too:
        # preserving basenames must keep this dependency import operational.
        integration = b'''\nimport importlib.util as _import_util
_self_spec = _import_util.spec_from_file_location("staged_self_update", Path(__file__).with_name("self_update.py"))
SELF_UPDATE = _import_util.module_from_spec(_self_spec)
_self_spec.loader.exec_module(SELF_UPDATE)
'''
        self.sources["outfit.py"] += integration
        (self.repo / "scripts/outfit.py").write_bytes(self.sources["outfit.py"])
        self.launch()
        directory, _ = self.staged()
        for name in self.sources:
            (self.repo / "scripts" / name).unlink()
        def verify(backend, store, root, job):
            self.assertEqual(backend.APP_ID, app.APP_ID)
            self.assertEqual(backend.__file__, str(directory / "outfit.py"))
            self.assertTrue(callable(backend.inspect_update_target))
            self.assertTrue(callable(backend.remote_update_target))
            self.assertEqual(backend.SELF_UPDATE.APP_ID, app.APP_ID)
            self.assertEqual(backend.SELF_UPDATE.__file__, str(directory / "self_update.py"))
            self.assertNotIn("LD_PRELOAD", os.environ)
            self.assertEqual(os.environ["OMARCHY_PATH"], str(self.runtime))
            return 0
        with mock.patch.object(worker, "__file__", str(directory / "self_update.py")), mock.patch.object(worker, "_work", side_effect=verify):
            self.assertEqual(worker._worker_main(), 0)
        self.assertFalse(self.native_calls())

    def test_replacing_original_sources_during_native_update_keeps_worker_functional(self):
        self.mode = "replace-sources"
        self.launch()
        code, result = self.work()
        self.assertEqual((code, result["state"]), (0, "completed"))
        directory, _ = self.staged()
        self.assertEqual((directory / "outfit.py").read_bytes(), self.sources["outfit.py"])

    def test_changed_session_runtime_prevents_restart(self):
        self.mode = "runtime-changed"
        self.launch()
        code, result = self.work()
        self.assertEqual((code, result["state"]), (1, "restart-failed"))
        self.assertTrue(result["verified"])
        self.assertEqual(len(self.native_calls()), 1)

    def test_terminal_staging_is_retired_on_explicit_retry(self):
        self.mode = "update-failure"
        self.launch()
        old, _ = self.staged()
        self.work()
        self.review()
        self.launch()
        new, _ = self.staged()
        self.assertNotEqual(old, new)
        self.assertFalse(old.exists())
        self.assertTrue(new.is_dir())

    def test_bounded_process_runner_models_success_failure_overflow_and_timeout(self):
        for mode in ("success", "failure", "overflow", "timeout"):
            with self.subTest(mode=mode):
                process = mock.Mock(pid=123456, returncode=None)
                process.stdout = mock.Mock()
                def wait(timeout=None):
                    process.returncode = 1 if mode == "failure" else 0
                    return process.returncode
                process.wait.side_effect = wait
                selector = mock.MagicMock()
                selector.__enter__.return_value = selector
                selector.get_map.side_effect = [True, True, False]
                selector.select.return_value = [(mock.Mock(fd=99), None)]
                clock = [0, 6] if mode == "timeout" else [0, 1, 2, 3]
                chunks = [b"x" * 17] if mode == "overflow" else [b"ok", b""]
                with mock.patch.object(worker.subprocess, "Popen", return_value=process) as popen, \
                     mock.patch.object(worker.selectors, "DefaultSelector", return_value=selector), \
                     mock.patch.object(worker.os, "read", side_effect=chunks), \
                     mock.patch.object(worker.os, "killpg") as kill, \
                     mock.patch.object(worker.time, "monotonic", side_effect=clock):
                    if mode == "success":
                        self.assertEqual(REAL_COMMAND(["/fixed/command"], {}, maximum=16), b"ok")
                    else:
                        with self.assertRaises((ValueError, TimeoutError)):
                            REAL_COMMAND(["/fixed/command"], {}, maximum=16)
                    self.assertEqual(popen.call_args.args[0], ["/fixed/command"])
                    self.assertNotIn("shell", popen.call_args.kwargs)
                    self.assertEqual(popen.call_args.kwargs["stderr"], subprocess.DEVNULL)
                    if mode in {"timeout", "overflow"}:
                        kill.assert_called_once_with(123456, worker.signal.SIGKILL)
                    else:
                        kill.assert_not_called()
                    process.stdout.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
