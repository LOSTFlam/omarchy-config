import copy
import json
import subprocess
import unittest
from unittest import mock

from tests.test_outfit import OUTFIT as app


class HostLifecycleTests(unittest.TestCase):
    def setUp(self):
        patch = mock.patch.object(app, "run_command", side_effect=AssertionError("Unmocked host IPC"))
        self.command = patch.start()
        self.addCleanup(patch.stop)
        self.store = mock.Mock(spec=app.Store)
        self.store.read.side_effect = AssertionError("Lifecycle requests must not read user state")
        self.status = {
            "version": 1, "generation": 17, "settledGeneration": 16,
            "scanning": True, "reconciling": False, "pending": True,
            "held": False, "leaseCount": 0, "scanError": "",
            "plugins": {"example.panel": {"revision": "a" * 64, "enabled": True,
                "loadErrors": {"panel": "Fictional component failed"}, "restartRequired": True}},
        }
        self.begin = {"version": 1, "ok": True, "token": "opaque-native-token", "generation": 12,
                      "expiresAt": 105000, "deadline": 160000}

    def request(self, operation, **values):
        return app.run({"action": "host-lifecycle", "generation": 73, "operation": operation, **values}, self.store)

    def replies(self, *documents):
        self.command.side_effect = [json.dumps(document).encode() for document in documents]

    def test_status_is_fixed_readonly_argv_and_preserves_native_error_evidence(self):
        self.status["plugins"]["example.panel"]["rendererInfo"] = {"panel": {"state": "loading", "visible": False}}
        self.status["environment"] = {"PRIVATE": "must not be returned"}
        self.status["plugins"]["example.panel"]["environment"] = {"PRIVATE": "must not be returned"}
        self.replies(self.status)
        reply = self.request("status")
        self.command.assert_called_once_with(
            [app.COMMANDS["omarchy-shell"], "shell", "pluginLifecycle"], app.HOST_IPC_TIMEOUT, 1024 * 1024)
        self.assertEqual(reply["generation"], 73)
        self.assertEqual(reply["host"]["generation"], 17)
        self.assertTrue(reply["host"]["supported"])
        plugin = reply["host"]["plugins"]["example.panel"]
        self.assertEqual(plugin["loadErrors"], {"panel": "Fictional component failed"})
        self.assertTrue(plugin["restartRequired"])
        self.assertFalse(plugin["rendererInfo"]["panel"]["visible"])
        self.assertNotIn("ready", reply["host"])
        self.assertNotIn("environment", json.dumps(reply))
        self.store.read.assert_not_called()
        self.store.write.assert_not_called()

    def test_begin_defaults_to_five_seconds_and_does_not_schedule_other_methods(self):
        self.replies(self.begin)
        reply = self.request("begin")
        self.command.assert_called_once_with(
            [app.COMMANDS["omarchy-shell"], "shell", "beginPluginChanges", "5000"], app.HOST_IPC_TIMEOUT, 16 * 1024)
        self.assertEqual(reply["host"], {**self.begin, "supported": True})

    def test_renew_passes_opaque_token_as_one_literal_argument_and_preserves_deadline(self):
        token = "opaque:$(no-shell-evaluation)"
        native = {"version": 1, "ok": True, "expiresAt": 160000, "deadline": 160000}
        self.replies(native)
        reply = self.request("renew", token=token, leaseMs=15000)
        self.command.assert_called_once_with(
            [app.COMMANDS["omarchy-shell"], "shell", "renewPluginChanges", token, "15000"], app.HOST_IPC_TIMEOUT, 16 * 1024)
        self.assertEqual(reply["host"], {**native, "supported": True})
        self.assertEqual(reply["host"]["deadline"], self.begin["deadline"])

    def test_end_enriches_errors_without_equating_acknowledgement_with_settlement(self):
        self.replies({"version": 1, "ok": True, "generation": 15}, self.status)
        reply = self.request("end", token="opaque-native-token")
        self.assertEqual(self.command.call_args_list, [
            mock.call([app.COMMANDS["omarchy-shell"], "shell", "endPluginChanges", "opaque-native-token"],
                      app.HOST_IPC_TIMEOUT, 16 * 1024),
            mock.call([app.COMMANDS["omarchy-shell"], "shell", "pluginLifecycle"], app.HOST_IPC_TIMEOUT, 1024 * 1024),
        ])
        host = reply["host"]
        self.assertTrue(host["ok"])
        self.assertEqual(host["generation"], 15)
        self.assertEqual(host["statusGeneration"], 17)
        self.assertEqual(host["settledGeneration"], 16)
        self.assertTrue(host["pending"])
        self.assertTrue(host["statusAvailable"])
        self.assertTrue(host["plugins"]["example.panel"]["loadErrors"])
        self.assertNotIn("ready", host)
        self.assertNotIn("rollback", json.dumps(reply))

    def test_native_refusal_and_expiry_are_supported_but_unsuccessful_operations(self):
        for operation, error in (("begin", "too many leases"), ("renew", "unknown or expired lease"),
                                 ("end", "unknown or expired lease")):
            with self.subTest(operation=operation):
                rejection = {"version": 1, "ok": False, "error": error}
                self.replies(rejection, self.status)
                reply = self.request(operation, token="opaque-native-token")
                self.assertTrue(reply["ok"])
                self.assertTrue(reply["host"]["supported"])
                self.assertFalse(reply["host"]["ok"])
                self.assertEqual(reply["host"]["error"], error)

    def test_unavailable_followup_status_does_not_erase_successful_end_ack(self):
        self.command.side_effect = [b'{"version":1,"ok":true,"generation":19}', TimeoutError("private native error")]
        reply = self.request("end", token="opaque-native-token")
        self.assertTrue(reply["host"]["supported"])
        self.assertTrue(reply["host"]["ok"])
        self.assertEqual(reply["host"]["generation"], 19)
        self.assertFalse(reply["host"]["statusAvailable"])
        self.assertNotIn("settledGeneration", reply["host"])
        self.assertNotIn("private native error", json.dumps(reply))

    def test_old_unavailable_or_invalid_native_responses_are_nonblocking_fallbacks(self):
        for native in (FileNotFoundError("PRIVATE"), TimeoutError("PRIVATE"),
                       subprocess.TimeoutExpired(["PRIVATE"], 3), ValueError("PRIVATE"),
                       b"unknown method PRIVATE", b"[]", b"null", b'{"version":2}', b'{"version":true}',
                       b'{"version":1}', b'{"version":1,"ok":true}', b"x" * (1024 * 1024 + 1)):
            with self.subTest(native=type(native).__name__):
                self.command.side_effect = [native]
                reply = self.request("status")
                self.assertTrue(reply["ok"])
                self.assertFalse(reply["host"]["supported"])
                self.assertLessEqual(len(reply["host"]["reason"]), 240)
                self.assertNotIn("PRIVATE", json.dumps(reply))

    def test_malformed_status_cannot_look_settled_or_silently_lose_plugin_errors(self):
        documents = [dict(self.status, pending="false"), dict(self.status, plugins=[]),
                     dict(self.status, generation=True), dict(self.status, scanError=None)]
        for value in (None, {}, {**self.status["plugins"]["example.panel"], "loadErrors": []},
                      {**self.status["plugins"]["example.panel"], "restartRequired": "false"}):
            documents.append({**self.status, "plugins": {"example.panel": value}})
        for document in documents:
            with self.subTest(document=document):
                self.replies(document)
                self.assertFalse(self.request("status")["host"]["supported"])

    def test_bad_native_leases_are_not_claimed_supported(self):
        for native in (dict(self.begin, token=""), dict(self.begin, token="x" * 257),
                       dict(self.begin, expiresAt=self.begin["deadline"] + 1),
                       {"version": 1, "ok": True, "token": "token"},
                       {"version": 1, "ok": False, "error": []}):
            self.replies(native)
            self.assertFalse(self.request("begin")["host"]["supported"])

    def test_invalid_operation_token_or_duration_is_rejected_before_any_ipc(self):
        requests = [{"operation": value} for value in (None, [], "", "status ", "reconcilePlugins", "install")]
        requests += [{"operation": "renew", "token": value} for value in
                     (None, [], False, "", "a" * 257, "with space", "line\nbreak", "nul\x00", "--flag")]
        requests += [{"operation": operation, "token": "token", "leaseMs": value}
                     for operation in ("status", "begin", "renew", "end")
                     for value in (None, [], True, "5000", 5000.0, 0, -1, 249, 15001, 60000)]
        for request in requests:
            with self.subTest(request=request), self.assertRaises(ValueError):
                app.run({"action": "host-lifecycle", **request}, self.store)
        self.command.assert_not_called()

    def test_minimum_duration_and_bounded_error_strings(self):
        self.replies({"version": 1, "ok": False, "error": "too many leases " * 1000})
        host = self.request("begin", leaseMs=250)["host"]
        self.assertTrue(host["supported"])
        self.assertLessEqual(len(host["error"]), 300)
        self.assertEqual(self.command.call_args.args[0][-1], "250")

    def test_wire_protocol_keeps_request_and_host_generations_separate(self):
        self.replies(self.begin)
        reply = app.process_request(json.dumps({"action": "host-lifecycle", "operation": "begin", "generation": 71}).encode(),
                                    self.store, self.store)
        self.assertEqual(reply["generation"], 71)
        self.assertEqual(reply["host"]["generation"], 12)
        self.assertNotIn("event", reply)
        invalid = app.process_request(b'{"action":"host-lifecycle","operation":"end","token":[]}', self.store, self.store)
        self.assertFalse(invalid["ok"])

    def test_settled_snapshot_preserves_failed_attempt_and_restart_requirement(self):
        status = copy.deepcopy(self.status)
        status.update(settledGeneration=17, scanning=False, pending=False, scanError="Fictional discovery error")
        self.replies(status)
        host = self.request("status")["host"]
        self.assertEqual(host["settledGeneration"], host["generation"])
        self.assertEqual(host["scanError"], "Fictional discovery error")
        self.assertTrue(host["plugins"]["example.panel"]["restartRequired"])
        self.assertNotIn("ready", host)
