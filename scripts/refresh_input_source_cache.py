"""Back up just the macOS input-source caches before registering an IME.

Sandbox clients keep their own keyboard-source tables. A newly installed source
can appear in the switcher while that client's old table cannot resolve its ID.
Moving the disposable tables before TISRegisterInputSource lets the system's
registration notification rebuild them. No application data or preferences move.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

CACHE_NAMES = frozenset(("com.apple.IntlDataCache.le", "com.apple.IntlDataCache.le.kbdx"))


def back_up_caches(root: Path, backup: Path) -> tuple[int, int]:
    root, backup = root.resolve(strict=True), backup.resolve()
    if root == backup or root in backup.parents:
        raise ValueError("Backup must be outside the cache directory")
    moved = skipped = 0
    for directory, folders, files in os.walk(root, followlinks=False):
        folders[:] = [name for name in folders if not (Path(directory) / name).is_symlink()]
        for name in files:
            if name not in CACHE_NAMES:
                continue
            source = Path(directory) / name
            if source.is_symlink() or not source.is_file():
                continue
            destination = backup / source.relative_to(root)
            if destination.exists():
                raise FileExistsError(destination)
            try:
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(source), str(destination))
                moved += 1
            except (PermissionError, FileNotFoundError):
                # Other apps can replace their disposable cache during install.
                skipped += 1
    return moved, skipped


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backup-dir", type=Path, required=True)
    args = parser.parse_args()
    cache_root = Path(subprocess.check_output(["getconf", "DARWIN_USER_CACHE_DIR"], text=True).strip())
    moved, skipped = back_up_caches(cache_root, args.backup_dir)
    print(f"输入源缓存已备份：{moved}；跳过：{skipped}")
