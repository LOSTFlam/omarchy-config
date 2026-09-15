import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("shortcut", Path(__file__).resolve().parents[1] / "shortcut.py")
shortcut = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shortcut)


class ShortcutTest(unittest.TestCase):
    def test_legacy_keysym_does_not_block_new_shortcut(self):
        raw = '-- personal\n' + shortcut.block('test', 'SUPER + SHIFT + bracketleft')
        self.assertEqual(shortcut.saved(raw, 'test'), ('SUPER + SHIFT + bracketleft', '-- personal\n'))
        edited = raw.replace('"Omaplug: test"', '"Edited"')
        with self.assertRaises(ValueError):
            shortcut.saved(edited, 'test')

    def test_combinations_and_injection(self):
        self.assertEqual(shortcut.combination("ctrl + super + p"), ("SUPER + CTRL + P", 68, "P"))
        for text in ('P', 'SUPER + P; reboot', 'SUPER + $(id)', 'CTRL + CTRL + P', 'SUPER + P + Q'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                shortcut.combination(text)

    def test_conflicts_and_owned_shortcut(self):
        binding = {"modmask": 68, "key": "p", "description": "Existing action"}
        self.assertIn("Existing action", shortcut.conflict([binding], "SUPER + CTRL + P", "test"))
        self.assertEqual(shortcut.conflict([binding], "SUPER + ALT + P", "test"), "")
        binding["description"] = "Omaplug: test"
        self.assertEqual(shortcut.conflict([binding], "SUPER + CTRL + P", "test", "SUPER + CTRL + P"), "")
        self.assertTrue(shortcut.conflict([binding, binding], "SUPER + CTRL + P", "test", "SUPER + CTRL + P"))
        self.assertTrue(shortcut.conflict([{"modmask": 68, "keycode": 33}], "SUPER + CTRL + P", "test"))
        self.assertTrue(shortcut.conflict([{"modmask": 68, "catch_all": True}], "SUPER + CTRL + P", "test"))

    def test_preserve_save_remove_and_rollback(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, HOME=folder):
            path = Path(folder) / ".config/hypr/bindings.lua"
            path.parent.mkdir(parents=True)
            original = '-- personal bindings\no.bind("SUPER + X", "Existing", "example")\n'
            path.write_text(original)
            failures = []
            binds = []
            def command(args):
                if args[-1] == "listPlugins":
                    return json.dumps([{"id": "test", "enabled": True}])
                if args[-1] == "binds":
                    return json.dumps(binds)
                if args[-1] == "configerrors":
                    return failures.pop(0) if failures else ""
                return "ok"
            with patch.object(shortcut, "command", command):
                self.assertEqual(shortcut.run("status", "test")["shortcut"], "")
                shortcut.run("check", "test", "SUPER + CTRL + P")
                self.assertEqual(path.read_text(), original)
                shortcut.run("save", "test", "SUPER + CTRL + P")
                self.assertTrue(path.read_text().startswith(original))
                self.assertEqual(shortcut.run("status", "test")["shortcut"], "SUPER + CTRL + P")
                shortcut.run("remove", "test")
                self.assertEqual(path.read_text(), original)
                failures.extend(["", "simulated reload error", ""])
                with self.assertRaisesRegex(ValueError, "previous bindings restored"):
                    shortcut.run("save", "test", "SUPER + CTRL + P")
                self.assertEqual(path.read_text(), original)
                binds.append({"modmask": 68, "key": "p", "description": "Other"})
                result = shortcut.run("save", "test", "SUPER + CTRL + P")
                self.assertEqual(result['pendingShortcut'], 'SUPER + CTRL + P')
                self.assertEqual(path.read_text(), original)
                shortcut.run('replace', 'test', 'SUPER + CTRL + P')
                self.assertIn('hl.unbind("SUPER + CTRL + P")', path.read_text())
                shortcut.run('remove', 'test')
                self.assertEqual(path.read_text(), original)
                path.unlink()
                target = Path(folder) / "target"
                target.write_text(original)
                path.symlink_to(target)
                with self.assertRaises(OSError):
                    shortcut.run("status", "test")


if __name__ == "__main__":
    unittest.main()
