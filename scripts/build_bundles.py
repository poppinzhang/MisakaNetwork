#!/usr/bin/env python3
"""Build Sisters and assemble offline bundles from native PyInstaller outputs."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

from release_config import BILI_VERSION, ROOT, TARGETS, VERSION
from runtime_manifest import validate_runtime
from windows_binary import verify_windows_executable


def build(target: str, runtime_root: Path, output: Path) -> dict:
    if target not in TARGETS:
        raise ValueError("Unsupported Sisters target")
    platform, arch = target.split("-")
    runtime = runtime_root / target / "misaka-runtime"
    validate_runtime(runtime, target)
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="misaka-bundle-") as temporary:
        stage = Path(temporary)
        env = dict(os.environ, GOOS="darwin" if platform == "macos" else platform, GOARCH=arch, CGO_ENABLED="0")
        executable = "sisters.exe" if platform == "windows" else "sisters"
        subprocess.run(["go", "build", "-trimpath", "-ldflags=-s -w -buildid=", "-o", str(stage / executable), "./Sisters/cmd/sisters"], cwd=ROOT, env=env, check=True)
        if platform == "windows":
            for binary in (stage / executable, runtime / "misaka-runtime.exe"):
                with binary.open("rb") as source:
                    verify_windows_executable(source.read(1024 * 1024), binary.name)
        shutil.copytree(runtime, stage / "runtime", symlinks=True)
        shutil.copy2(ROOT / "runtime/NOTICE.txt", stage / "NOTICE.txt")
        shutil.copy2(ROOT / "runtime/vendor/biliTickerBuy/LICENSE", stage / "BILITICKERBUY-LICENSE.txt")
        manifest = dict(version=VERSION, bili_version=BILI_VERSION, platform=platform, arch=arch)
        (stage / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        target_path = output / f"{target}.tar.gz"
        with tarfile.open(target_path, "w:gz") as archive:
            def metadata(info: tarfile.TarInfo) -> tarfile.TarInfo:
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                return info
            for item in sorted(stage.iterdir()):
                archive.add(item, arcname=item.name, filter=metadata)
    digest = hashlib.sha256(target_path.read_bytes()).hexdigest()
    (output / f"{target}.tar.gz.sha256").write_text(f"{digest}  {target_path.name}\n")
    return dict(name=target_path.name, bytes=target_path.stat().st_size, sha256=digest, **manifest)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime-root", type=Path, default=ROOT / ".build/runtime")
    parser.add_argument("--output", type=Path, default=ROOT / ".build/bundles")
    parser.add_argument("--targets", nargs="+", choices=TARGETS, default=list(TARGETS))
    args = parser.parse_args()
    artifacts = [build(target, args.runtime_root.resolve(), args.output.resolve()) for target in args.targets]
    (args.output / "bundles.json").write_text(json.dumps(dict(version=VERSION, bili_version=BILI_VERSION, artifacts=artifacts), indent=2) + "\n")
    print(f"Built {len(artifacts)} offline Sisters bundles")


if __name__ == "__main__":
    main()
