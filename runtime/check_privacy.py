"""Scan runtime binaries, ZIP contents and compressed PyInstaller code for paths."""
from __future__ import annotations

import argparse
import io
import os
from pathlib import Path
import zipfile


def scan(root: Path, markers: list[bytes]) -> tuple[int, list[str]]:
    from PyInstaller.archive.readers import CArchiveReader
    failures: list[str] = []
    count = 0

    def inspect(data: bytes, label: str) -> None:
        nonlocal count
        count += 1
        if any(marker and marker in data for marker in markers):
            failures.append(label)

    for path in root.rglob("*"):
        if not path.is_file():
            continue
        label = str(path.relative_to(root))
        inspect(path.read_bytes(), label)
        if zipfile.is_zipfile(path):
            with zipfile.ZipFile(path) as archive:
                for name in archive.namelist():
                    inspect(archive.read(name), label + "!" + name)
        if path.name not in {"misaka-runtime", "misaka-runtime.exe"}:
            continue
        archive = CArchiveReader(str(path))
        for name in archive.toc:
            content = archive.extract(name)
            if content:
                inspect(content, label + "!" + name)
            if name.endswith(".pyz"):
                embedded = archive.open_embedded_archive(name)
                for module in embedded.toc:
                    content = embedded.extract(module, raw=True)
                    if content:
                        inspect(content, label + "!" + name + "!" + module)
    return count, sorted(set(failures))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--marker", action="append", default=[])
    args = parser.parse_args()
    markers = [os.fsencode(value) for value in args.marker or [str(Path.home()), str(Path(__file__).resolve().parents[1])]]
    count, failures = scan(args.bundle, markers)
    if failures:
        print("Private build-path markers found in these artifact members:")
        print("\n".join(failures))
        raise SystemExit(1)
    print(f"Privacy scan passed: {count} files/archive members checked.")
