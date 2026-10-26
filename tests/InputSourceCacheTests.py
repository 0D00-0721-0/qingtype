import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("cache_refresh", Path(__file__).parents[1] / "scripts/refresh_input_source_cache.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class InputSourceCacheTests(unittest.TestCase):
    def test_only_keyboard_tables_move_and_backup_preserves_bytes(self):
        with tempfile.TemporaryDirectory() as temp:
            root, backup = Path(temp) / "cache", Path(temp) / "backup"
            client = root / "test.client"
            client.mkdir(parents=True)
            for name in module.CACHE_NAMES:
                (client / name).write_bytes(b"old table")
            ordinary = client / "unrelated-cache"
            ordinary.write_bytes(b"preserve")
            (client / "com.apple.IntlDataCache.le.other").write_bytes(b"preserve")
            self.assertEqual(module.back_up_caches(root, backup), (2, 0))
            self.assertEqual(ordinary.read_bytes(), b"preserve")
            self.assertTrue((client / "com.apple.IntlDataCache.le.other").exists())
            for name in module.CACHE_NAMES:
                self.assertEqual((backup / "test.client" / name).read_bytes(), b"old table")
                self.assertFalse((client / name).exists())

    def test_does_not_follow_links_or_overwrite_backups(self):
        with tempfile.TemporaryDirectory() as temp:
            root, backup = Path(temp) / "cache", Path(temp) / "backup"
            root.mkdir()
            external = Path(temp) / "outside"
            external.mkdir()
            protected = external / "com.apple.IntlDataCache.le"
            protected.write_bytes(b"protected")
            (root / "linked-dir").symlink_to(external, target_is_directory=True)
            (root / "com.apple.IntlDataCache.le.kbdx").symlink_to(protected)
            self.assertEqual(module.back_up_caches(root, backup), (0, 0))
            self.assertEqual(protected.read_bytes(), b"protected")
            (root / "com.apple.IntlDataCache.le").write_bytes(b"new")
            backup.mkdir()
            (backup / "com.apple.IntlDataCache.le").write_bytes(b"old")
            with self.assertRaises(FileExistsError):
                module.back_up_caches(root, backup)
            self.assertEqual((root / "com.apple.IntlDataCache.le").read_bytes(), b"new")

    def test_rejects_backup_inside_cache(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaises(ValueError):
                module.back_up_caches(root, root / "backup")


if __name__ == "__main__":
    unittest.main()
