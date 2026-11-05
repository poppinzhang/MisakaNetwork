"""Reject stale or mismatched native runtimes before offline packaging."""
import json
from pathlib import Path

from release_config import BILI_VERSION, VERSION


def validate_runtime(directory: Path, target: str) -> dict:
    platform, arch = target.split("-")
    name = "misaka-runtime.exe" if platform == "windows" else "misaka-runtime"
    if not (directory / name).is_file():
        raise ValueError(f"Required native runtime executable is missing for {target}")
    path = directory / "RUNTIME-MANIFEST.json"
    if not path.is_file():
        raise ValueError(f"Runtime build manifest is missing for {target}; rebuild runtime/build.py")
    manifest = json.loads(path.read_text())
    expected = dict(version=VERSION, bili_version=BILI_VERSION, platform=platform, arch=arch, protocol=1)
    if not isinstance(manifest, dict) or any(manifest.get(key) != value for key, value in expected.items()):
        raise ValueError(f"Runtime version or platform does not match {target}; rebuild runtime/build.py")
    return manifest
