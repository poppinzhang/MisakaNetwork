#!/usr/bin/env python3
"""Verify release versions, bundle manifests, checksums and environment privacy."""
import argparse
import hashlib
import json
import io
from pathlib import Path
import plistlib
import re
import tarfile
import zipfile

from android_manifest import attributes as android_attributes
from release_config import APP_TARGETS, TARGETS, android_bundle_asset, artifact_name
APP_CONTENTS = "LastOrder.app/Contents/"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def verify_app(data: bytes, release: dict, target: str = "macos-amd64") -> None:
    platform, arch = target.split("-")
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), "Duplicate ZIP members")
        if platform == "macos":
            info = plistlib.loads(archive.read(APP_CONTENTS + "Info.plist"))
            require(info.get("CFBundleShortVersionString") == release["version"], "App version mismatch")
            require(info.get("CFBundleVersion") == str(release["build"]), "App build mismatch")
            prefix = APP_CONTENTS + "Resources/bundles/"
        elif platform == "windows":
            info = json.loads(archive.read("LastOrder/resources/release-info.json"))
            require(info.get("version") == release["version"], "App version mismatch")
            require(info.get("build") == release["build"], "App build mismatch")
            require(info.get("platform") == platform and info.get("arch") == arch, "App platform mismatch")
            for name in ("LastOrder.exe", "flutter_windows.dll", "resources/misakactl.exe",
                         "resources/runtime/misaka-runtime.exe"):
                require("LastOrder/" + name in names, "Windows native component missing: " + name)
            prefix = "LastOrder/resources/bundles/"
        else:
            manifest = android_attributes(archive.read("AndroidManifest.xml"))
            require(manifest.get("manifest", {}).get("versionName") == release["version"], "App version mismatch")
            # Per-ABI Android builds prepend an ABI digit to the Flutter build number.
            code = int(manifest.get("manifest", {}).get("versionCode", 0))
            require(code == {"arm64": 2, "amd64": 4}[arch] * 1000 + release["build"], "App build mismatch")
            require(int(manifest.get("uses-sdk", {}).get("minSdkVersion", 0)) >= 36,
                    "Android minimum API must be 36 or newer")
            abi = {"arm64": "arm64-v8a", "amd64": "x86_64"}[arch]
            for name in (f"lib/{abi}/libmisaka_mobile.so", f"lib/{abi}/libflutter.so"):
                require(name in names, "Android native component missing: " + name)
            require(not any(name.startswith("lib/") and name.split("/")[1] != abi for name in names),
                    "Unexpected Android ABI in split APK")
            prefix = "assets/bundles/"
        verify_bundles(archive, prefix, release, android=platform == "android")


def verify_bundles(archive: zipfile.ZipFile, prefix: str, release: dict, *, android: bool = False) -> None:
    index = json.loads(archive.read(prefix + "bundles.json"))
    require(index.get("version") == release["version"], "Bundle index version mismatch")
    require(index.get("bili_version") == release["bili_version"], "Bundle index bili version mismatch")
    artifacts = index.get("artifacts", [])
    expected = {f"{target}.tar.gz" for target in TARGETS}
    require(len(artifacts) == len(expected) and {item["name"] for item in artifacts} == expected,
            "Bundle index must contain all supported Sisters targets exactly once")
    for item in artifacts:
        target = item["name"].removesuffix(".tar.gz")
        platform, arch = target.split("-")
        manifest = dict(version=release["version"], bili_version=release["bili_version"],
                        platform=platform, arch=arch)
        require(all(item.get(key) == value for key, value in manifest.items()), "Bundle index metadata mismatch")
        asset = android_bundle_asset(item["name"]) if android else item["name"]
        require(prefix + asset in archive.namelist(), "Deployment bundle asset is missing: " + asset)
        bundle_data = archive.read(prefix + asset)
        digest = hashlib.sha256(bundle_data).hexdigest()
        require(len(bundle_data) == item.get("bytes"), "Nested bundle size mismatch")
        require(digest == item.get("sha256"), "Nested bundle SHA-256 mismatch")
        require(archive.read(prefix + item["name"] + ".sha256").decode() == f"{digest}  {item['name']}\n",
                "Nested bundle SHA-256 sidecar mismatch")
        with tarfile.open(fileobj=io.BytesIO(bundle_data), mode="r:gz") as bundle:
            manifests = [member for member in bundle.getmembers() if member.name == "manifest.json"]
            require(len(manifests) == 1 and manifests[0].isfile(), "Nested bundle manifest missing or duplicated")
            actual = json.loads(bundle.extractfile(manifests[0]).read())
            require(all(actual.get(key) == value for key, value in manifest.items()), "Nested bundle manifest mismatch")


def scan_bytes(data: bytes, forbidden: list[bytes], label: str) -> None:
    for marker in forbidden:
        if marker and marker in data:
            raise ValueError(f"Environment privacy check failed in {label}")


def scan_archive(data: bytes, forbidden: list[bytes], label: str, depth: int = 0) -> None:
    scan_bytes(data, forbidden, label)
    if depth > 4:
        return
    if data.startswith(b"PK\x03\x04"):
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for member in archive.infolist():
                if not member.is_dir():
                    scan_archive(archive.read(member), forbidden, member.filename, depth + 1)
    elif data.startswith(b"\x1f\x8b"):
        try:
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
                for member in archive:
                    if member.isfile():
                        scan_archive(archive.extractfile(member).read(), forbidden, member.name, depth + 1)
        except tarfile.ReadError:
            pass


def verify_release(directory: Path, markers: list[bytes], expected_arches: tuple[str, ...] | None = None,
                   *, expected_targets: tuple[str, ...] | None = None) -> dict:
    # --arch is retained for a single macOS matrix output; complete releases use all targets.
    if expected_targets is None:
        expected_targets = tuple(f"macos-{arch}" for arch in expected_arches) if expected_arches else APP_TARGETS
    require(bool(expected_targets) and len(set(expected_targets)) == len(expected_targets) and
            set(expected_targets) <= set(APP_TARGETS), "Invalid expected targets")
    release = json.loads((directory / "release.json").read_text())
    require(isinstance(release.get("version"), str) and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", release["version"]),
            "Invalid release version")
    require(type(release.get("build")) is int and release["build"] > 0, "Invalid release build")
    require(isinstance(release.get("bili_version"), str) and bool(release["bili_version"]), "Invalid bili version")
    artifacts = release.get("artifacts", [])
    expected = {artifact_name(target, release["version"]) for target in expected_targets}
    require(len(artifacts) == len(expected) and {item["name"] for item in artifacts} == expected,
            "Release must contain the expected platforms and architectures exactly once with matching filenames")
    sums = []
    for item in artifacts:
        target = f"{item.get('platform')}-{item.get('arch')}"
        require(target in expected_targets and item["name"] == artifact_name(target, release["version"]),
                "Artifact platform mismatch")
        file = directory / item["name"]
        data = file.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        require(len(data) == item["bytes"], "Size mismatch")
        require(digest == item["sha256"], "SHA-256 mismatch")
        sidecar = f"{digest}  {file.name}\n"
        require((directory / (file.name + ".sha256")).read_text() == sidecar, "SHA-256 sidecar mismatch")
        verify_app(data, release, target)
        scan_archive(data, markers, file.name)
        sums.append(sidecar)
    require((directory / "SHA256SUMS").read_text() == "".join(sums), "SHA256SUMS mismatch")
    return release


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("directory", type=Path)
    p.add_argument("--forbid", action="append", default=[])
    p.add_argument("--arch", choices=("amd64", "arm64"), help="Validate one macOS CI matrix artifact")
    p.add_argument("--target", action="append", choices=APP_TARGETS, help="Validate a CI target; repeat for multiple artifacts")
    args = p.parse_args()
    markers = [s.encode() for s in args.forbid]
    require(not (args.arch and args.target), "Use --arch or --target, not both")
    release = verify_release(args.directory, markers, (args.arch,) if args.arch else None,
                             expected_targets=tuple(args.target) if args.target else None)
    print(f"Verified {len(release['artifacts'])} release artifacts: version {release['version']}, build {release['build']}, "
          "nested bundle versions/platforms, sizes, SHA-256 sidecars, privacy")


if __name__ == "__main__":
    main()
