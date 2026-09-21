"""Native Open capabilities and one-shot delivery, without live desktop IPC."""
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest
from unittest import mock

from tests.test_outfit import OUTFIT as app


class OpenPluginTests(unittest.TestCase):
    identity = "example.window"

    def setUp(self):
        # Opening must not enter any catalog, settings, network or activation path.
        for name in ("fetch_bytes", "fetch_catalog", "load_catalog", "load_preferences",
                     "save_preferences", "scan_inventory", "run_activation_command", "open_stores"):
            patch = mock.patch.object(app, name, side_effect=AssertionError("Unexpected " + name))
            patch.start()
            self.addCleanup(patch.stop)

    def entry(self, **extra):
        return {"id": self.identity, "enabled": True, "kinds": ["panel"], **extra}

    def request(self, **extra):
        return {"action": "open-plugin", "pluginId": self.identity, "generation": 17, **extra}

    def invoke(self, canonical, reply=b"ok\n", **extra):
        def command(argv, timeout, maximum):
            if argv == [app.COMMANDS["omarchy"], "plugin", "list", "--json"]:
                self.assertEqual((timeout, maximum), (5, 2 * 1024 * 1024))
                return json.dumps(canonical).encode()
            self.assertEqual(argv, [app.COMMANDS["omarchy-shell"], "shell", "summon", self.identity, "{}"])
            self.assertEqual((timeout, maximum), (app.HOST_IPC_TIMEOUT, app.MAX_OPEN_REPLY_BYTES))
            if isinstance(reply, Exception):
                raise reply
            return reply
        with mock.patch.object(app, "run_command", side_effect=command) as calls:
            result = app.run(self.request(**extra), None)
        self.assertEqual(result["action"], "open-plugin")
        self.assertEqual(result["generation"], 17)
        self.assertEqual(result["pluginId"], self.identity)
        return result, calls.call_count

    def test_standard_kinds_and_enabled_ui_widgets_are_accepted_once(self):
        for kinds in (["panel"], ["overlay"], ["menu"], ["bar-widget", "panel"], ["service", "menu"]):
            for first_party in (False, True):
                with self.subTest(kinds=kinds, first_party=first_party):
                    result, count = self.invoke([self.entry(kinds=kinds, firstParty=first_party)])
                    self.assertTrue(result["ok"])
                    self.assertEqual(result["openState"], "accepted")
                    self.assertEqual(result["error"], "")
                    self.assertNotIn("opened", result)
                    self.assertEqual(count, 2)

    def test_request_capabilities_payload_command_and_runtime_are_never_trusted(self):
        hostile = {"inventory": [self.entry()], "installed": [self.identity], "enabled": True,
                   "kinds": ["panel"], "command": "/tmp/untrusted", "OMARCHY_PATH": "/tmp/untrusted",
                   "payload": {"command": "anything"}, "enableAfter": True, "barSection": "left"}
        result, count = self.invoke([self.entry(enabled=False)], **hostile)
        self.assertFalse(result["ok"])
        self.assertEqual(count, 1)
        result, count = self.invoke([self.entry()], **hostile)
        self.assertEqual(result["openState"], "accepted")
        self.assertEqual(count, 2)

    def test_missing_disabled_service_widget_and_bar_only_do_not_summon(self):
        inventories = [[], [self.entry(enabled=False)], [self.entry(kinds=["service"])],
                       [self.entry(kinds=["bar-widget"])], [self.entry(kinds=["bar"])],
                       [self.entry(enabled=False, firstParty=True, active=True, barSection="right")]]
        for inventory in inventories:
            with self.subTest(inventory=inventory):
                result, count = self.invoke(inventory)
                self.assertFalse(result["ok"])
                self.assertEqual(result["openState"], "unavailable")
                self.assertTrue(result["error"])
                self.assertEqual(count, 1)

    def test_malformed_canonical_inventory_cannot_be_normalized_into_capability(self):
        inventories = [None, {}, [None], [self.entry(), self.entry()],
                       [self.entry(id=" example.window")], [self.entry(id="example..window")],
                       [self.entry(kinds="panel")], [self.entry(kinds={"panel": True})],
                       [self.entry(kinds=[" panel "])], [self.entry(kinds=["ｐａｎｅｌ"])],
                       [self.entry(kinds=["panel", None])], [self.entry(kinds=["panel", {}])],
                       [self.entry(kinds=["panel", "future-window"])], [self.entry(kinds=["panel"] * 9)],
                       [self.entry(enabled="true")], [self.entry(enabled=1)], [self.entry(enabled=None)],
                       [{"id": self.identity, "kinds": ["panel"]}]]
        for inventory in inventories:
            with self.subTest(inventory=inventory):
                result, count = self.invoke(inventory)
                self.assertEqual(result["openState"], "unavailable")
                self.assertEqual(count, 1)

    def test_invalid_identity_and_self_are_rejected_before_any_native_call(self):
        with mock.patch.object(app, "run_command") as command:
            for identity in (None, "", "-option", "example..window", "a/b", "x;cmd", " a", "ａｂｃ", "a" * 129):
                with self.subTest(identity=identity), self.assertRaises(ValueError):
                    app.run(self.request(pluginId=identity), None)
            result = app.run(self.request(pluginId=app.APP_ID), None)
            self.assertEqual(result["openState"], "unavailable")
            command.assert_not_called()

    def test_inventory_transport_failure_never_falls_back_or_summons(self):
        for failure in (TimeoutError(), subprocess.TimeoutExpired("fixture", 5), OSError(), ValueError()):
            with self.subTest(failure=failure), mock.patch.object(app, "run_command", side_effect=failure) as command:
                result = app.run(self.request(inventory=[self.entry()]), None)
                self.assertEqual(result["openState"], "unavailable")
                command.assert_called_once()

    def test_zero_exit_unknown_empty_json_and_invalid_host_replies_are_unavailable(self):
        for reply in (b"", b"unknown", b"unavailable", b"true", b'{"ok":true}', b'"ok"',
                      b"ok\nunknown", b"OK", b"\xff", b"ok\x00"):
            with self.subTest(reply=reply):
                result, count = self.invoke([self.entry()], reply)
                self.assertEqual(result["openState"], "unavailable")
                self.assertFalse(result["ok"])
                self.assertEqual(count, 2)

    def test_timeout_is_unconfirmed_and_never_retries_or_checks_for_rendering(self):
        for reply in (TimeoutError("secret"), subprocess.TimeoutExpired("secret", 3)):
            result, count = self.invoke([self.entry()], reply)
            self.assertFalse(result["ok"])
            self.assertEqual(result["openState"], "unconfirmed")
            self.assertIn("not retried", result["error"])
            self.assertNotIn("secret", result["error"])
            self.assertEqual(count, 2)

    def test_summon_transport_failure_is_bounded_and_not_reflected(self):
        for reply in (OSError("private runtime path"), ValueError("private output")):
            result, count = self.invoke([self.entry()], reply)
            self.assertEqual(result["openState"], "unavailable")
            self.assertNotIn("private", result["error"])
            self.assertEqual(count, 2)

    def test_each_explicit_open_rereads_inventory(self):
        self.assertTrue(self.invoke([self.entry()])[0]["ok"])
        result, count = self.invoke([self.entry(enabled=False)])
        self.assertFalse(result["ok"])
        self.assertEqual(count, 1)

    def test_one_shot_main_does_not_open_or_write_stores(self):
        output = []
        with mock.patch.object(app.sys, "stdin", mock.Mock(buffer=io.BytesIO(json.dumps(self.request()).encode()))), \
                mock.patch.object(app, "write_response", side_effect=output.append), \
                mock.patch.object(app, "run_command", side_effect=[json.dumps([self.entry()]).encode(), b"ok"]):
            self.assertEqual(app.main(), 0)
        self.assertEqual(output[0]["openState"], "accepted")
        self.assertNotIn("open-plugin", app.PLUGIN_MUTATIONS)


class OpenRuntimeRoutingTests(unittest.TestCase):
    def test_real_bounded_launch_uses_trusted_runtime_and_exact_fixed_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            runtime = base / "trusted runtime 雪"
            bindir = runtime / "bin"
            bindir.mkdir(parents=True)
            fixture = "#!/usr/bin/python3\n" + textwrap.dedent('''\
                import json, os, sys, time
                from pathlib import Path
                root = Path(os.environ["OMARCHY_PATH"])
                actor = Path(sys.argv[0]).name
                with (root / "calls.jsonl").open("a") as stream:
                    stream.write(json.dumps([actor, sys.argv[1:]]) + "\\n")
                assert os.environ["PATH"] == str(root / "bin") + ":/usr/bin:/bin"
                assert "PYTHONPATH" not in os.environ
                if actor == "omarchy":
                    assert sys.argv[1:] == ["plugin", "list", "--json"]
                    print(json.dumps([{"id":"example.window", "enabled":True, "kinds":["panel"]}]))
                else:
                    assert sys.argv[1:] == ["shell", "summon", "example.window", "{}"]
                    mode = (root / "mode").read_text()
                    if mode == "timeout":
                        time.sleep(10)
                    elif mode == "overflow":
                        print("x" * 10000)
                    else:
                        print(mode)
                ''')
            for name in ("omarchy", "omarchy-shell"):
                executable = bindir / name
                executable.write_text(fixture)
                executable.chmod(0o700)
            real_popen = app.subprocess.Popen

            def guarded(argv, **kwargs):
                self.assertIn(Path(argv[0]), [bindir / "omarchy", bindir / "omarchy-shell"])
                self.assertIsNot(kwargs.get("shell"), True)
                return real_popen(argv, **kwargs)

            with mock.patch.dict(os.environ, {"OMARCHY_PATH": str(runtime), "PATH": "/poison",
                                               "PYTHONPATH": "/poison", "HOME": directory}, clear=True), \
                    mock.patch.object(app.subprocess, "Popen", side_effect=guarded), \
                    mock.patch.object(app, "fetch_bytes", side_effect=AssertionError("No network")), \
                    mock.patch.object(app, "HOST_IPC_TIMEOUT", 0.25):
                for mode, state in (("ok", "accepted"), ("unknown", "unavailable"),
                                    ("timeout", "unconfirmed"), ("overflow", "unavailable")):
                    (runtime / "mode").write_text(mode)
                    result = app.run({"action": "open-plugin", "pluginId": "example.window", "generation": 1,
                                      "OMARCHY_PATH": "/poison", "command": "/poison", "payload": {"evil": True}}, None)
                    self.assertEqual(result["openState"], state)
                    self.assertFalse(app._children)
            calls = [json.loads(line) for line in (runtime / "calls.jsonl").read_text().splitlines()]
            self.assertEqual(calls, [["omarchy", ["plugin", "list", "--json"]],
                                     ["omarchy-shell", ["shell", "summon", "example.window", "{}"]]] * 4)
