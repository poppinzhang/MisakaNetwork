#!/usr/bin/env python3
"""Package Windows LastOrder, its native runtime/helper and every Sisters bundle."""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import zipfile

from index_bundles import index_bundles
from release_config import BILI_VERSION, BUILD, ROOT, VERSION, artifact_name
from release_manifest import record_artifact
from runtime_manifest import validate_runtime


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / ".build/LastOrder-windows")
    parser.add_argument("--runtime-root", type=Path, default=ROOT / ".build/runtime")
    parser.add_argument("--bundles", type=Path, default=ROOT / ".build/bundles")
    parser.add_argument("--output", type=Path, default=ROOT / f"dist/{VERSION}")
    args = parser.parse_args()
    if platform.system() != "Windows":
        raise SystemExit("Windows packaging must run on Windows to validate the native executable")
    index_bundles(args.bundles)
    runtime = args.runtime_root / "windows-amd64/misaka-runtime"
    validate_runtime(runtime, "windows-amd64")
    executable = args.app / "LastOrder.exe"
    if not executable.is_file():
        raise SystemExit("Required Windows LastOrder executable is missing")
    # Windows PE version resources come from Flutter's pubspec version/build.
    quoted = str(executable.resolve()).replace("'", "''")
    result = subprocess.run(["powershell", "-NoProfile", "-Command",
        f"(Get-Item -LiteralPath '{quoted}').VersionInfo.ProductVersion"],
        text=True, capture_output=True, check=True)
    if result.stdout.strip() != f"{VERSION}+{BUILD}":
        raise SystemExit("Windows executable version/build number does not match this release")
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="misaka-package-") as temporary:
        app = Path(temporary) / "LastOrder"
        shutil.copytree(args.app, app)
        resources = app / "resources"
        resources.mkdir(exist_ok=True)
        shutil.copytree(runtime, resources / "runtime")
        shutil.copytree(args.bundles, resources / "bundles")
        shutil.copy2(ROOT / "runtime/NOTICE.txt", resources / "NOTICE.txt")
        shutil.copy2(ROOT / "runtime/vendor/biliTickerBuy/LICENSE", resources / "BILITICKERBUY-LICENSE.txt")
        env = dict(os.environ, GOOS="windows", GOARCH="amd64", CGO_ENABLED="0")
        subprocess.run(["go", "build", "-trimpath", "-ldflags=-s -w -buildid=", "-o",
                        str(resources / "misakactl.exe"), "./cmd/misakactl"], cwd=ROOT, env=env, check=True)
        (resources / "release-info.json").write_text(json.dumps(dict(
            version=VERSION, build=BUILD, bili_version=BILI_VERSION, platform="windows", arch="amd64")) + "\n")
        archive = args.output / artifact_name("windows-amd64")
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
            for file in sorted(app.rglob("*")):
                if file.is_file():
                    output.write(file, file.relative_to(app.parent).as_posix())
    record_artifact(archive, "windows", "amd64", signing="unsigned")
    print(f"Packaged {archive.name}; unsigned portable Windows application")


if __name__ == "__main__":
    main()
