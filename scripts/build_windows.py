#!/usr/bin/env python3
"""Build Windows LastOrder using a generic temporary source path."""
import argparse
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

from release_config import ROOT


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".build/LastOrder-windows")
    args = parser.parse_args()
    if platform.system() != "Windows":
        raise SystemExit("Windows LastOrder requires a Windows host with the Visual Studio C++ toolchain")
    scratch = Path(os.environ.get("SystemDrive", "C:") + "/") / "misaka-build"
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="app-", dir=scratch) as temporary:
        source = Path(temporary) / "LastOrder"
        shutil.copytree(ROOT / "LastOrder", source, ignore=shutil.ignore_patterns(
            "build", ".dart_tool", "ephemeral", ".flutter-plugins-dependencies", "Pods", "xcuserdata", "*.iml"))
        env = dict(os.environ, PUB_CACHE=str(scratch / "pub-cache"))
        # cmd dispatch is required for Flutter's Windows batch entry point.
        subprocess.run(["cmd", "/c", "flutter", "pub", "get", "--enforce-lockfile"], cwd=source, env=env, check=True)
        subprocess.run(["cmd", "/c", "flutter", "build", "windows", "--release"], cwd=source, env=env, check=True)
        built = source / "build/windows/x64/runner/Release"
        if not (built / "LastOrder.exe").is_file():
            raise RuntimeError("Windows build did not produce LastOrder.exe")
        if args.output.exists():
            shutil.rmtree(args.output)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(built, args.output)
    print("LastOrder Windows release app built from temporary source")


if __name__ == "__main__":
    main()
