"""Owned launcher upgrades retain identity and reject unrelated destinations."""
from itertools import product
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from scripts import launcher


class LauncherMigrationTests(unittest.TestCase):
    def seed(self, data, legacy):
        paths = []
        for (source, relative, _markers), old in zip(launcher.FILES, legacy):
            path = data / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            body = (launcher.ASSETS / source).read_bytes()
            path.write_bytes(body.replace(b"Outfit", b"OmaFit") if old else body)
            paths.append(path)
        return paths

    def test_new_assets_keep_stable_identity_and_display_outfit(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            launcher.sync(data)
            desktop = (data / "applications/io.github.ctl0v0.outfit.desktop").read_text()
            icon = (data / "icons/hicolor/scalable/apps/io.github.ctl0v0.outfit.svg").read_text()
            self.assertIn("Name=Outfit\n", desktop)
            self.assertIn("X-Outfit-Managed=true\n", desktop)
            self.assertIn("Exec=omarchy-shell shell summon io.github.ctl0v0.outfit\n", desktop)
            self.assertIn("Icon=io.github.ctl0v0.outfit\n", desktop)
            self.assertIn("<!-- Outfit managed icon -->", icon)
            self.assertIn("<title>Outfit</title>", icon)

    def test_legacy_current_and_mixed_assets_upgrade_idempotently(self):
        for legacy in product((False, True), repeat=2):
            with self.subTest(legacy=legacy), tempfile.TemporaryDirectory() as directory:
                data = Path(directory)
                paths = self.seed(data, legacy)
                launcher.sync(data)
                for path, (source, _relative, _markers) in zip(paths, launcher.FILES):
                    self.assertEqual(path.read_bytes(), (launcher.ASSETS / source).read_bytes())
                    self.assertEqual(path.stat().st_mode & 0o777, 0o644)
                before = [(p.stat().st_ino, p.stat().st_mtime_ns) for p in paths]
                launcher.sync(data)
                self.assertEqual(before, [(p.stat().st_ino, p.stat().st_mtime_ns) for p in paths])

    def test_remove_accepts_both_markers_and_mixed_installations(self):
        for legacy in product((False, True), repeat=2):
            with self.subTest(legacy=legacy), tempfile.TemporaryDirectory() as directory:
                data = Path(directory)
                paths = self.seed(data, legacy)
                launcher.sync(data, remove=True)
                self.assertTrue(all(not p.exists() for p in paths))
                launcher.sync(data, remove=True)

    def test_collision_preflight_preserves_both_assets(self):
        for index, remove, marker_style in product(range(2), (False, True), range(2)):
            with self.subTest(index=index, remove=remove, marker_style=marker_style), tempfile.TemporaryDirectory() as directory:
                data = Path(directory)
                paths = self.seed(data, (True, True))
                marker = launcher.FILES[index][2][marker_style]
                # Merely embedding an ownership marker is not ownership.
                paths[index].write_bytes(b"unrelated prefix " + marker + b" suffix\n")
                before = [p.read_bytes() for p in paths]
                with self.assertRaisesRegex(ValueError, "unmanaged"):
                    launcher.sync(data, remove=remove)
                self.assertEqual(before, [p.read_bytes() for p in paths])

    def test_symlinks_are_rejected_even_to_owned_assets(self):
        for index, remove, dangling in product(range(2), (False, True), (False, True)):
            with self.subTest(index=index, remove=remove, dangling=dangling), tempfile.TemporaryDirectory() as directory:
                data = Path(directory)
                paths = self.seed(data, (True, False))
                untouched = paths[1 - index].read_bytes()
                target = data / "external-asset"
                if not dangling:
                    target.write_bytes(paths[index].read_bytes())
                paths[index].unlink()
                paths[index].symlink_to(target)
                with self.assertRaisesRegex(ValueError, "symlink"):
                    launcher.sync(data, remove=remove)
                self.assertTrue(paths[index].is_symlink())
                self.assertEqual(untouched, paths[1 - index].read_bytes())
                self.assertEqual(target.exists(), not dangling)

    def test_ownership_and_size_guards_apply_to_legacy_assets(self):
        for remove in (False, True):
            with self.subTest(remove=remove), tempfile.TemporaryDirectory() as directory:
                data = Path(directory)
                paths = self.seed(data, (True, True))
                before = [p.read_bytes() for p in paths]
                with mock.patch.object(launcher.os, "getuid", return_value=os.getuid() + 1):
                    with self.assertRaisesRegex(ValueError, "unmanaged"):
                        launcher.sync(data, remove=remove)
                self.assertEqual(before, [p.read_bytes() for p in paths])
                paths[1].write_bytes(before[1] + b"x" * (64 * 1024))
                with self.assertRaisesRegex(ValueError, "unmanaged"):
                    launcher.sync(data, remove=remove)
                self.assertEqual(paths[0].read_bytes(), before[0])
