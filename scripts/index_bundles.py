#!/usr/bin/env python3
"""Validate downloaded platform bundles and atomically assemble their index."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tarfile
import tempfile

from build_bundles import BILI_VERSION, ROOT, TARGETS, VERSION


def collect_artifacts(directory: Path) -> list[dict]:
    artifacts = []
    for target in TARGETS:
        name = target + ".tar.gz"
        archive_path = directory / name
        sidecar = directory / (name + ".sha256")
        for file in (archive_path, sidecar):
            if file.is_symlink() or not file.is_file():
                raise ValueError(f"Required regular bundle file is missing: {file.name}")
        digest = hashlib.sha256()
        size = 0
        with archive_path.open("rb") as source:
            while chunk := source.read(1024 * 1024):
                size += len(chunk)
                digest.update(chunk)
        checksum = digest.hexdigest()
        if sidecar.read_text() != f"{checksum}  {name}\n":
            raise ValueError(f"Bundle SHA-256 sidecar mismatch: {name}")
        platform, arch = target.split("-")
        expected = dict(version=VERSION, bili_version=BILI_VERSION, platform=platform, arch=arch)
        with tarfile.open(archive_path, mode="r:gz") as archive:
            manifests = [member for member in archive.getmembers() if member.name == "manifest.json"]
            if len(manifests) != 1 or not manifests[0].isfile() or not 0 < manifests[0].size <= 65536:
                raise ValueError(f"Bundle manifest missing, duplicated or invalid: {name}")
            manifest = json.loads(archive.extractfile(manifests[0]).read())
        if not isinstance(manifest, dict) or any(manifest.get(key) != value for key, value in expected.items()):
            raise ValueError(f"Bundle version or platform mismatch: {name}")
        artifacts.append(dict(name=name, bytes=size, sha256=checksum, **expected))
    return artifacts


def index_bundles(directory: Path) -> dict:
    # Validate every input before replacing an existing index. Never extract tar
    # members or trust archive-provided paths to address the local filesystem.
    index = dict(version=VERSION, bili_version=BILI_VERSION, artifacts=collect_artifacts(directory))
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", prefix=".bundles-index-", dir=directory, delete=False) as output:
            temporary = Path(output.name)
            output.write(json.dumps(index, indent=2) + "\n")
        os.replace(temporary, directory / "bundles.json")
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return index


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", nargs="?", type=Path, default=ROOT / ".build/bundles")
    args = parser.parse_args()
    index = index_bundles(args.directory)
    print(f"Indexed {len(index['artifacts'])} validated offline bundles for {index['version']}")


if __name__ == "__main__":
    main()
