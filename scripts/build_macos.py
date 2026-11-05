#!/usr/bin/env python3
"""Build LastOrder from a generic temporary source directory."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--output", type=Path, default=ROOT / ".build/LastOrder.app")
    args = p.parse_args()
    with tempfile.TemporaryDirectory(prefix="misaka-app-build-", dir="/tmp") as temp:
        source = Path(temp) / "LastOrder"
        shutil.copytree(ROOT / "LastOrder", source, ignore=shutil.ignore_patterns("build", ".dart_tool", "ephemeral", ".flutter-plugins-dependencies", "Pods", "xcuserdata", "*.iml"))
        env = dict(os.environ, PUB_CACHE="/tmp/misaka-pub-cache")
        subprocess.run(["flutter", "pub", "get", "--enforce-lockfile"], cwd=source, env=env, check=True)
        subprocess.run(["flutter", "build", "macos", "--release"], cwd=source, env=env, check=True)
        app = source / "build/macos/Build/Products/Release/LastOrder.app"
        if args.output.exists():
            shutil.rmtree(args.output)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(app, args.output, symlinks=True)
    print("LastOrder release app built from temporary source")


if __name__ == "__main__":
    main()
