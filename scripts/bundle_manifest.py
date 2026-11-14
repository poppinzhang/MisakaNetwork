"""Validate Windows bundle contents on every packaging host without extraction."""
import json
import tarfile

from windows_binary import verify_windows_executable


def verify_windows_bundle(archive: tarfile.TarFile, expected: dict) -> None:
    members = archive.getmembers()

    def regular(name):
        matches = [member for member in members if member.name == name]
        if len(matches) != 1 or not matches[0].isfile() or matches[0].size <= 0:
            raise ValueError("Windows bundle required regular file missing or duplicated: " + name)
        return matches[0]

    for name in ("sisters.exe", "runtime/misaka-runtime.exe"):
        # Only the DOS/PE headers are needed. Limit even a corrupt archive's
        # declared binary size; supported Go/PyInstaller headers fit this bound.
        with archive.extractfile(regular(name)) as source:
            verify_windows_executable(source.read(1024 * 1024), name)
    manifest = regular("runtime/RUNTIME-MANIFEST.json")
    if manifest.size > 65536:
        raise ValueError("Windows bundle runtime manifest is oversized")
    actual = json.loads(archive.extractfile(manifest).read())
    if not isinstance(actual, dict) or any(actual.get(key) != value for key, value in (expected | {"protocol": 1}).items()):
        raise ValueError("Windows bundle runtime version or platform mismatch")
