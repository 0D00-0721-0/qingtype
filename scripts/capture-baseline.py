#!/usr/bin/env python3
"""Record a local development baseline without exporting dictionary entries."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def command(*args, include_stderr=False):
    return subprocess.check_output(args, cwd=ROOT, text=True, stderr=subprocess.STDOUT if include_stderr else subprocess.PIPE).strip()


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", type=Path, default=ROOT / "build/QingType.app")
parser.add_argument("--output", type=Path, default=ROOT / "build/baseline.json")
args = parser.parse_args()
app = args.app.resolve()
status = json.loads(command(str(app / "Contents/MacOS/QingType"), "--status"))
runtime_lock = json.loads((ROOT / 'dependencies/runtime.lock.json').read_text())
runtime_override = os.environ.get('QINGTYPE_RUNTIME_APP')
cached_runtime = list((ROOT / 'build/runtime' / runtime_lock['version'] / 'expanded').rglob('Squirrel.app'))
runtime = Path(runtime_override) if runtime_override else (cached_runtime[0] if cached_runtime else ROOT / 'build/runtime/not-extracted')
runtime_info = plistlib.loads((runtime / "Contents/Info.plist").read_bytes()) if runtime.exists() else {}
settings_path = Path.home() / "Library/QingType/settings.json"
settings = json.loads(settings_path.read_text()) if settings_path.exists() else {}
report = {
    "capturedAtUTC": datetime.now(timezone.utc).isoformat(),
    "commit": command("git", "rev-parse", "HEAD"),
    "workspaceChanges": command("git", "status", "--short"),
    "toolchain": {"xcode": command("xcodebuild", "-version"), "swift": command("swift", "--version", include_stderr=True),
                  "macOS": command("sw_vers"), "architecture": command("uname", "-m")},
    "application": status,
    "runtime": {"SquirrelVersion": runtime_info.get("CFBundleShortVersionString", runtime_info.get("CFBundleVersion")),
                "archive": runtime_lock, "explicitOverride": bool(runtime_override),
                "headersCommit": command("git", "-C", "librime", "rev-parse", "HEAD"),
                "binaries": {str(p.relative_to(app)): sha256(p) for p in sorted((app / "Contents/Frameworks").rglob("*.dylib"))}},
    "Yams": json.loads((ROOT / "dependencies/Package.resolved").read_text()),
    "localModelMetadata": [{k: model.get(k) for k in ("name", "sha256", "byteCount", "language", "variant")}
                           for model in settings.get("models", [])],
    "activeModelID": settings.get("activeModelID"),
    "entryContentsIncluded": False,
}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(f"Baseline saved: {args.output}")
