#!/usr/bin/env python3
"""Stage the embedded Python client and cross-compile the Android JNI helper."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ABIS = {"arm64-v8a": ("arm64", "aarch64-linux-android"), "x86_64": ("amd64", "x86_64-linux-android")}
API = 36


def stage_python(project: Path) -> None:
    vendor = ROOT / "runtime/vendor/biliTickerBuy"
    manifest = json.loads((vendor / "MANIFEST.json").read_text())
    target = project / "android/app/src/main/python"
    temporary = target.with_name("python.pending")
    if temporary.exists():
        shutil.rmtree(temporary)
    temporary.mkdir(parents=True)
    try:
        for record in manifest["files"]:
            relative = Path(record["path"])
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError("unsafe upstream manifest path")
            source = vendor / relative
            if source.is_symlink() or hashlib.sha256(source.read_bytes()).hexdigest() != record["sha256"]:
                raise ValueError("upstream manifest hash mismatch")
            destination = temporary / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        for name in ("bridge.py", "android_bridge.py", "requirements-android.lock", "NOTICE.txt"):
            shutil.copy2(ROOT / "runtime" / name, temporary / name)
        shutil.copy2(vendor / "MANIFEST.json", temporary / "UPSTREAM_MANIFEST.json")
        if target.exists():
            shutil.rmtree(target)
        temporary.rename(target)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def find_ndk(explicit: str | None) -> Path:
    value = explicit or os.environ.get("ANDROID_NDK_HOME")
    if value:
        return Path(value).resolve()
    sdk = os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME")
    if sdk:
        base = Path(sdk)
    elif platform.system() == "Darwin":
        base = Path.home() / "Library/Android/sdk"
    else:
        base = Path.home() / "Android/Sdk"
    ndks = sorted((base / "ndk").glob("*"), key=lambda p: tuple(int(n) for n in p.name.split(".") if n.isdigit()))
    if not ndks:
        raise ValueError("Android NDK r27 or later is required")
    return ndks[-1]


def build(project: Path, ndk: Path, abis: list[str]) -> None:
    host = {"Darwin": "darwin-x86_64", "Linux": "linux-x86_64", "Windows": "windows-x86_64"}.get(platform.system())
    if not host:
        raise ValueError("unsupported Android build host")
    bin_dir = ndk / "toolchains/llvm/prebuilt" / host / "bin"
    for abi in abis:
        arch, triple = ABIS[abi]
        # NDK r27's highest platform is 35; a minimum-36 application can link
        # against that ABI because the helper uses no Android 36 native APIs.
        metadata = json.loads((ndk / "meta/platforms.json").read_text())
        compiler_api = min(API, int(metadata["max"]))
        compiler = bin_dir / f"{triple}{compiler_api}-clang"
        if platform.system() == "Windows":
            compiler = compiler.with_suffix(".cmd")
        if not compiler.is_file():
            raise ValueError("Android NDK compiler is missing")
        output = project / "android/app/src/main/jniLibs" / abi / "libmisaka_mobile.so"
        output.parent.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ, GOOS="android", GOARCH=arch, CGO_ENABLED="1", CC=str(compiler))
        subprocess.run([
            "go", "build", "-trimpath", "-buildmode=c-shared",
            "-ldflags=-s -w -buildid= -extldflags=-Wl,-z,max-page-size=16384",
            "-o", str(output), "./cmd/misaka-mobile",
        ], cwd=ROOT, env=env, check=True)
        output.with_suffix(".h").unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=ROOT / "LastOrder")
    parser.add_argument("--ndk")
    parser.add_argument("--abi", choices=ABIS, action="append")
    parser.add_argument("--stage-only", action="store_true")
    args = parser.parse_args()
    stage_python(args.project.resolve())
    if not args.stage_only:
        build(args.project.resolve(), find_ndk(args.ndk), args.abi or list(ABIS))
    print("Android embedded client and native helper prepared")


if __name__ == "__main__":
    main()
