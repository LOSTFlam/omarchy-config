import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[1] / "menu-entry.py"
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("menu_entry", HELPER)
menu = importlib.util.module_from_spec(spec)
spec.loader.exec_module(menu)


class MenuEntryTest(unittest.TestCase):
    def test_preserves_source_and_is_idempotent(self):
        for raw in ('{\n}\n', '{"items": {}}',
                    '{\n// other plugin\n"foo": {"action": "echo hi",},\n}\n',
                    '{"items": {"foo": {"label": "https://example.org/a,}"}}, "extra": 1}'):
            with self.subTest(raw=raw):
                enabled = menu.render(raw, True)
                self.assertEqual(menu.parse(enabled)[0][menu.ENTRY_KEY], menu.ENTRY)
                self.assertEqual(menu.render(enabled, True), enabled)
                self.assertEqual(menu.render(enabled, False), raw)
                self.assertEqual(menu.render(raw, False), raw)

    def test_refuses_invalid_or_custom_content(self):
        for raw in ('broken', '[]', '{"omaplug": {"action": "custom"}}',
                    menu.render('{}', True).replace('Omaplug', 'My Manager')):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                menu.render(raw, False)

    def test_real_file_round_trip_and_symlink_refusal(self):
        with tempfile.TemporaryDirectory() as directory:
            env = dict(os.environ, HOME=directory)
            path = Path(directory) / ".config/omarchy/extensions/omarchy-menu.jsonc"
            def run(action):
                return subprocess.run(["/usr/bin/python3", str(HELPER), action], env=env,
                                      capture_output=True, text=True)
            self.assertIn('"enabled": false', run("status").stdout)
            self.assertFalse(path.exists())
            self.assertEqual(run("enable").returncode, 0)
            self.assertIn('"enabled": true', run("status").stdout)
            self.assertEqual(run("disable").returncode, 0)
            self.assertEqual(path.read_text(), '{\n}\n')
            path.write_text('{invalid')
            self.assertNotEqual(run("enable").returncode, 0)
            self.assertEqual(path.read_text(), '{invalid')
            path.unlink()
            target = Path(directory) / "outside"
            target.write_text('{}')
            path.symlink_to(target)
            self.assertNotEqual(run("enable").returncode, 0)
            self.assertEqual(target.read_text(), '{}')


if __name__ == "__main__":
    unittest.main()
