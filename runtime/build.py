"""Build the native, offline bridge bundle with Python and all core dependencies."""
from __future__ import annotations

import argparse
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import sysconfig
import tempfile

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT.parent / "scripts"))
from release_config import BILI_VERSION, VERSION


def copy_licenses(bundle: Path) -> None:
    target = bundle / "licenses"
    target.mkdir()
    shutil.copy2(ROOT / "NOTICE.txt", target / "NOTICE.txt")
    shutil.copy2(ROOT / "vendor/biliTickerBuy/LICENSE", target / "biliTickerBuy-LICENSE.txt")
    python_license = Path(sysconfig.get_path("stdlib")) / "LICENSE.txt"
    if python_license.is_file():
        shutil.copy2(python_license, target / "Python-LICENSE.txt")
    # Python standalone distributions also ship licenses for the native
    # libraries linked into their interpreter, outside Python package metadata.
    standalone_licenses = Path(sys.base_prefix) / "licenses"
    if standalone_licenses.is_dir():
        shutil.copytree(standalone_licenses, target / "python-native-libraries")
    records = []
    for distribution in sorted(importlib.metadata.distributions(), key=lambda item: item.metadata["Name"].lower()):
        name = distribution.metadata["Name"]
        records.append({"name": name, "version": distribution.version, "license": distribution.metadata.get("License-Expression", distribution.metadata.get("License", "See included license files"))})
        for path in distribution.files or []:
            basename = Path(str(path)).name.lower()
            if basename.startswith(("license", "copying", "notice", "authors")):
                source = Path(distribution.locate_file(path))
                if source.is_file():
                    # Preserve nested license names; bundled dependencies may
                    # each provide a different file named LICENSE.
                    relative = Path(str(path))
                    safe_parts = [part for part in relative.parts if part not in {"..", ".", "/"}]
                    destination = target / name / Path(*safe_parts)
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, destination)
    (target / "DEPENDENCIES.json").write_text(json.dumps(records, ensure_ascii=False, indent=2) + "\n")


def verify_existing(bundle: Path) -> None:
    """Stamp a runtime only after running its native version/dependency self-test."""
    check = subprocess.run([str(bundle / ("misaka-runtime.exe" if platform.system() == "Windows" else "misaka-runtime"))], input='{"op":"ping"}\n', text=True, capture_output=True, check=True, timeout=60)
    response = json.loads(check.stdout)
    if not response.get("ok") or not response.get("data", {}).get("ready") or check.stderr:
        raise RuntimeError("Bundled runtime self-test did not produce a clean ready result")
    runtime_info = response["data"]
    if (runtime_info.get("version"), runtime_info.get("bili_version"), runtime_info.get("protocol")) != (VERSION, BILI_VERSION, 1):
        raise RuntimeError("Bundled runtime version does not match the release")
    system = {"Darwin": "macos", "Linux": "linux", "Windows": "windows"}[platform.system()]
    arch = {"arm64": "arm64", "aarch64": "arm64", "x86_64": "amd64", "amd64": "amd64"}.get(platform.machine().lower())
    if arch is None:
        raise RuntimeError("Unsupported runtime build architecture")
    (bundle / "RUNTIME-MANIFEST.json").write_text(json.dumps(dict(
        version=VERSION, bili_version=BILI_VERSION, platform=system, arch=arch, protocol=1), indent=2) + "\n")


def build(output: Path) -> Path:
    if platform.system() not in {"Darwin", "Linux", "Windows"}:
        raise RuntimeError("Native runtime builds require macOS, Linux or Windows")
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    final = output / "misaka-runtime"
    # Keep compiled source paths outside a user's profile on Windows as well.
    scratch = Path(os.environ.get("SystemDrive", "C:") + "/") / "misaka-build" if platform.system() == "Windows" else Path("/tmp")
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="runtime-", dir=scratch) as temporary:
        stage = Path(temporary)
        source = stage / "source"
        source.mkdir()
        shutil.copy2(ROOT / "bridge.py", source / "bridge.py")
        shutil.copytree(ROOT / "vendor", source / "vendor", ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        vendor = source / "vendor/biliTickerBuy"
        command = [
            sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean", "--onedir",
            "--name", "misaka-runtime", "--distpath", str(stage / "dist"),
            "--workpath", str(stage / "work"), "--specpath", str(stage),
            "--paths", str(vendor), "--hidden-import", "interface", "--hidden-import", "task.buy",
            "--hidden-import", "util.h2client.ja_h2_client", "--hidden-import", "util.h2client.client_ja",
            "--hidden-import", "brotli", "--hidden-import", "zstandard", "--hidden-import", "socksio",
            "--collect-data", "certifi", "--add-data", str(vendor / "assets") + os.pathsep + "assets",
            "--exclude-module", "tkinter", "--exclude-module", "gradio", "--exclude-module", "numpy",
            str(source / "bridge.py"),
        ]
        env = dict(os.environ, PYINSTALLER_CONFIG_DIR=str(stage / "cache"), PYTHONHASHSEED="0", MACOSX_DEPLOYMENT_TARGET="15.0")
        subprocess.run(command, cwd=stage, env=env, check=True)
        bundle = stage / "dist/misaka-runtime"
        copy_licenses(bundle)
        shutil.copy2(ROOT / "vendor/biliTickerBuy/MANIFEST.json", bundle / "BILI-SOURCE-MANIFEST.json")
        verify_existing(bundle)
        if final.exists():
            shutil.rmtree(final)
        shutil.copytree(bundle, final, symlinks=True)
    return final


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--output", type=Path)
    group.add_argument("--verify-existing", type=Path, help="Self-test an existing native bundle and refresh its build manifest")
    args = parser.parse_args()
    if args.verify_existing:
        verify_existing(args.verify_existing.resolve())
    else:
        build(args.output)
    print("Offline runtime build manifest and dependency self-test passed.")
