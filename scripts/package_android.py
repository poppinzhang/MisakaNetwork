#!/usr/bin/env python3
"""Build signed Android APKs with embedded Python, JNI helper and offline bundles."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from check_release import verify_release
from index_bundles import index_bundles
from release_config import BUILD, ROOT, VERSION, android_bundle_asset, artifact_name
from release_manifest import record_artifact

SIGNING_KEYS = ("MISAKA_ANDROID_KEYSTORE", "MISAKA_ANDROID_STORE_PASSWORD",
                "MISAKA_ANDROID_KEY_ALIAS", "MISAKA_ANDROID_KEY_PASSWORD")


def signing_mode(env: dict[str, str], allow_debug: bool) -> str:
    present = [bool(env.get(key)) for key in SIGNING_KEYS]
    if any(present) and not all(present):
        raise ValueError("All four MISAKA_ANDROID signing settings are required together")
    if all(present):
        if not Path(env[SIGNING_KEYS[0]]).is_file():
            raise ValueError("Configured Android signing keystore does not exist")
        return "release-keystore"
    if allow_debug:
        return "debug-test-only"
    raise ValueError("Android APK delivery requires signing settings; use --allow-debug-signing only for local test APKs")


def apk_signer(env: dict[str, str]) -> Path:
    roots = [Path(env[key]) for key in ("ANDROID_SDK_ROOT", "ANDROID_HOME") if env.get(key)]
    roots += [Path.home() / "Library/Android/sdk", Path.home() / "Android/Sdk"]
    candidates = [path for root in roots for path in (root / "build-tools").glob("*/apksigner*")
                  if path.is_file() and path.name in {"apksigner", "apksigner.bat"}]
    if not candidates:
        raise ValueError("Android SDK build-tools with apksigner are required")
    return max(candidates, key=lambda path: tuple(int(part) if part.isdigit() else 0 for part in path.parent.name.split(".")))


def stage_bundles(bundles: Path, assets: Path) -> None:
    index = index_bundles(bundles)
    if assets.exists():
        shutil.rmtree(assets)
    assets.mkdir(parents=True)
    shutil.copy2(bundles / "bundles.json", assets / "bundles.json")
    for item in index["artifacts"]:
        # Keep the gzip payload opaque to Android's resource packaging tools.
        shutil.copy2(bundles / item["name"], assets / android_bundle_asset(item["name"]))
        sidecar = item["name"] + ".sha256"
        shutil.copy2(bundles / sidecar, assets / sidecar)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundles", type=Path, default=ROOT / ".build/bundles")
    parser.add_argument("--output", type=Path, default=ROOT / f"dist/{VERSION}")
    parser.add_argument("--allow-debug-signing", action="store_true", help="Build test APKs with an Android debug key")
    args = parser.parse_args()
    env = dict(os.environ)
    mode = signing_mode(env, args.allow_debug_signing)
    if mode == "debug-test-only":
        env["MISAKA_ANDROID_ALLOW_DEBUG_SIGNING"] = "1"
    else:
        env.pop("MISAKA_ANDROID_ALLOW_DEBUG_SIGNING", None)
        env["MISAKA_ANDROID_KEYSTORE"] = str(Path(env["MISAKA_ANDROID_KEYSTORE"]).resolve())
    signer = apk_signer(env)
    index_bundles(args.bundles)
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="misaka-android-build-") as temporary:
        source = Path(temporary) / "LastOrder"
        shutil.copytree(ROOT / "LastOrder", source, ignore=shutil.ignore_patterns(
            "build", ".dart_tool", ".gradle", "local.properties", "ephemeral", ".flutter-plugins-dependencies",
            "Pods", "xcuserdata", "*.iml", "jniLibs"))
        assets = source / "android/app/src/main/assets/bundles"
        stage_bundles(args.bundles, assets)
        subprocess.run([sys.executable, str(ROOT / "scripts/build_android_native.py"),
                        "--project", str(source)], env=env, check=True)
        flutter = ["cmd", "/c", "flutter"] if os.name == "nt" else ["flutter"]
        subprocess.run(flutter + ["pub", "get", "--enforce-lockfile"], cwd=source, env=env, check=True)
        for arch, abi, flutter_target in (("arm64", "arm64-v8a", "android-arm64"),
                                          ("amd64", "x86_64", "android-x64")):
            # Chaquopy requires ndk.abiFilters, which AGP cannot combine with
            # Flutter's --split-per-abi. Build each ABI separately instead.
            env["MISAKA_ANDROID_ABI"] = abi
            subprocess.run(flutter + ["build", "apk", "--release", "--target-platform", flutter_target,
                            "--build-name", VERSION, "--build-number", str(BUILD)],
                           cwd=source, env=env, check=True)
            built = source / "build/app/outputs/flutter-apk/app-release.apk"
            if not built.is_file():
                raise RuntimeError(f"Expected signed {abi} APK was not produced")
            signing_command = ["cmd", "/c", str(signer)] if os.name == "nt" else [str(signer)]
            subprocess.run(signing_command + ["verify", str(built)], env=env, check=True)
            output = args.output / artifact_name(f"android-{arch}")
            shutil.copy2(built, output)
            record_artifact(output, "android", arch, signing=mode)
    # A matrix directory may contain only Android output; full-release aggregation
    # performs the same checks across every supported LastOrder target.
    release = json.loads((args.output / "release.json").read_text())
    targets = tuple(f"{item['platform']}-{item['arch']}" for item in release["artifacts"])
    verify_release(args.output, [], expected_targets=targets)
    print(f"Packaged two Android APKs; signing: {mode}")


if __name__ == "__main__":
    main()
