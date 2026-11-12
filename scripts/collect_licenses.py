#!/usr/bin/env python3
"""Collect offline supplemental notices for LastOrder's license viewer.

Flutter supplies Dart/Flutter package notices separately. Inputs here are the
license trees already shipped with native runtimes, an Android APK's embedded
Python notices, the exact Go module cache, and reviewed supplemental texts.
No runtime or upstream application code is executed.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ASSET = "LastOrder/assets/licenses/third_party_licenses.json"
MANIFEST = "scripts/third_party_licenses_manifest.json"
INPUTS = (
    "go.mod", "go.sum", "runtime/requirements.lock",
    "runtime/requirements-android.lock", "runtime/requirements-build.lock",
    "runtime/NOTICE.txt", "runtime/vendor/biliTickerBuy/LICENSE",
    "runtime/vendor/biliTickerBuy/MANIFEST.json",
    "LastOrder/android/settings.gradle.kts",
)
SUPPLEMENTS = {
    "loguru": ("loguru-0.7.3-LICENSE.txt", "https://raw.githubusercontent.com/Delgan/loguru/0.7.3/LICENSE"),
    "Chaquopy": ("chaquopy-17.1.0-LICENSE.txt", "https://raw.githubusercontent.com/chaquo/chaquopy/17.1.0/LICENSE.txt"),
}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def normalized(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def is_notice(name: str) -> bool:
    return PurePosixPath(name).name.lower().startswith(
        ("license", "licence", "copying", "notice", "authors", "patents"))


class Inventory:
    def __init__(self) -> None:
        self.entries: dict[str, dict[str, str]] = {}
        self.versions: dict[str, set[str]] = {}

    def record_version(self, name: str, version: str) -> None:
        self.versions.setdefault(normalized(name), set()).add(version)

    def add(self, package: str, data: bytes) -> None:
        text = data.decode("utf-8-sig").replace("\r\n", "\n").strip()
        if not text:
            raise ValueError("empty license text: " + package)
        self.entries.setdefault(package, {})[digest(text.encode())] = text

    def runtime_file(self, name: str, data: bytes) -> None:
        if name == "DEPENDENCIES.json":
            for item in json.loads(data):
                self.record_version(item["name"], item["version"])
            return
        path = PurePosixPath(name)
        if (not is_notice(name) and name != "Python-LICENSE.txt"
                and path.parts[0] != "python-native-libraries") or name in {"NOTICE.txt", "biliTickerBuy-LICENSE.txt"}:
            return
        package = "Python" if name == "Python-LICENSE.txt" else path.parts[0]
        if package == "python-native-libraries":
            package = "Python native libraries"
        self.add(package, data)

    def runtime_directory(self, directory: Path) -> None:
        if not (directory / "DEPENDENCIES.json").is_file():
            raise ValueError("runtime license directory lacks DEPENDENCIES.json")
        for path in sorted(directory.rglob("*")):
            if path.is_file() and not path.is_symlink():
                self.runtime_file(path.relative_to(directory).as_posix(), path.read_bytes())

    def runtime_archive(self, archive: Path) -> None:
        found = False
        with zipfile.ZipFile(archive) as bundle:
            for name in sorted(bundle.namelist()):
                marker = "/runtime/licenses/"
                if marker in name and not name.endswith("/"):
                    found = True
                    self.runtime_file(name.split(marker, 1)[1], bundle.read(name))
        if not found:
            raise ValueError("archive has no runtime license directory")

    def android_archive(self, archive: Path) -> None:
        found = False
        with zipfile.ZipFile(archive) as apk:
            for name in sorted(apk.namelist()):
                if not name.startswith("assets/chaquopy/") or not name.endswith(".imy"):
                    continue
                with zipfile.ZipFile(io.BytesIO(apk.read(name))) as embedded:
                    for entry in sorted(embedded.namelist()):
                        if entry.endswith("/") or not is_notice(entry):
                            continue
                        match = re.search(r"(?:^|/)([^/]+)-([^/]+)\.dist-info/", entry)
                        if match:
                            found = True
                            self.record_version(match[1], match[2])
                            self.add(match[1], embedded.read(entry))
        if not found:
            raise ValueError("APK has no embedded Python package notices")

    def go_modules(self) -> None:
        # A populated module cache is required; collection never downloads code.
        required = set(re.findall(r"^\s*([^\s]+) v[^\s]+", (ROOT / "go.mod").read_text(), re.MULTILINE))
        result = subprocess.run(
            ["go", "list", "-mod=readonly", "-m", "-json", "all"], cwd=ROOT,
            check=True, capture_output=True, text=True,
            env=dict(os.environ, GOPROXY="off", GOSUMDB="off"),
        )
        decoder = json.JSONDecoder()
        remaining = result.stdout.strip()
        while remaining:
            module, end = decoder.raw_decode(remaining)
            remaining = remaining[end:].lstrip()
            if module["Path"] not in required:
                continue
            directory = Path(module["Dir"])
            notices = [p for p in directory.iterdir() if p.is_file() and is_notice(p.name)]
            if not notices:
                raise ValueError("Go module has no license: " + module["Path"])
            for path in sorted(notices):
                self.add(module["Path"], path.read_bytes())
        goroot = Path(subprocess.run(["go", "env", "GOROOT"], check=True, capture_output=True, text=True).stdout.strip())
        go_license = goroot / "LICENSE"
        if not go_license.is_file():
            go_license = goroot.parent / "LICENSE"  # Homebrew's libexec layout.
        self.add("Go", go_license.read_bytes())
        for path in sorted((goroot / "src/vendor").rglob("*")):
            if path.is_file() and is_notice(path.name):
                self.add("Go standard library third-party notices", path.read_bytes())

    def serialized(self) -> bytes:
        # Merge spelling variants from wheel metadata (PySocks, typing_extensions).
        grouped: dict[str, tuple[str, dict[str, str]]] = {}
        for name, texts in sorted(self.entries.items()):
            _, merged = grouped.setdefault(normalized(name), (name, {}))
            merged.update(texts)
        entries = [
            {"packages": [name], "text": "\n\n".join(texts[key] for key in sorted(texts)) + "\n"}
            for name, texts in sorted(grouped.values(), key=lambda item: item[0].lower())
        ]
        return (json.dumps(entries, ensure_ascii=False, indent=2) + "\n").encode()

    def validate_versions(self, root: Path) -> None:
        expected: dict[str, set[str]] = {}
        for name, version in locked_python_packages(root):
            expected.setdefault(normalized(name), set()).add(version)
        for name, versions in expected.items():
            if versions != self.versions.get(name, set()):
                raise ValueError("license input versions do not match locked Python package: " + name + "==" + ",".join(sorted(versions)))


def locked_python_packages(root: Path):
    for lock in ("runtime/requirements.lock", "runtime/requirements-android.lock"):
        for line in (root / lock).read_text().splitlines():
            match = re.match(r"([A-Za-z0-9_.-]+)==([^;\s]+)", line)
            if match:
                yield match[1], match[2]


def input_hashes(root: Path) -> dict[str, str]:
    paths = [*INPUTS, *("scripts/license_sources/" + data[0] for data in SUPPLEMENTS.values())]
    return {name: digest((root / name).read_bytes()) for name in paths}


def validate(root: Path = ROOT) -> None:
    manifest = json.loads((root / MANIFEST).read_text(encoding="utf-8"))
    if manifest["inputs"] != input_hashes(root):
        raise ValueError("dependency or license inputs changed; refresh supplemental licenses")
    data = (root / ASSET).read_bytes()
    if digest(data) != manifest["asset_sha256"]:
        raise ValueError("supplemental license asset hash mismatch")
    validate_coverage(root, data)


def validate_coverage(root: Path, data: bytes) -> None:
    entries = json.loads(data)
    packages = set()
    for entry in entries:
        if (not isinstance(entry.get("packages"), list) or not entry["packages"]
                or not isinstance(entry.get("text"), str) or not entry["text"].strip()):
            raise ValueError("invalid license entry")
        packages.update(normalized(name) for name in entry["packages"])
    required = {"bilitickerbuy", "python", "go", "chaquopy"}
    required.update(normalized(name) for name, _ in locked_python_packages(root))
    for match in re.finditer(r"^\s*([^\s]+) v[^\s]+", (root / "go.mod").read_text(), re.MULTILINE):
        required.add(normalized(match[1]))
    if missing := required - packages:
        raise ValueError("missing supplemental licenses: " + ", ".join(sorted(missing)))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--runtime-licenses", type=Path, action="append", default=[])
    parser.add_argument("--runtime-archive", type=Path, action="append", default=[])
    parser.add_argument("--android-apk", type=Path, action="append", default=[])
    args = parser.parse_args()
    if args.check:
        validate()
        print("Supplemental license inputs and coverage passed.")
        return
    if not args.runtime_licenses or not args.runtime_archive or not args.android_apk:
        parser.error("generation needs native runtime licenses, a Windows archive and an Android APK")
    inventory = Inventory()
    inventory.add("biliTickerBuy", (ROOT / "runtime/NOTICE.txt").read_bytes() + b"\n" + (ROOT / "runtime/vendor/biliTickerBuy/LICENSE").read_bytes())
    for package, (name, _) in SUPPLEMENTS.items():
        inventory.add(package, (ROOT / "scripts/license_sources" / name).read_bytes())
    for directory in args.runtime_licenses:
        inventory.runtime_directory(directory)
    for archive in args.runtime_archive:
        inventory.runtime_archive(archive)
    for archive in args.android_apk:
        inventory.android_archive(archive)
    inventory.go_modules()
    inventory.validate_versions(ROOT)
    data = inventory.serialized()
    validate_coverage(ROOT, data)
    (ROOT / ASSET).parent.mkdir(parents=True, exist_ok=True)
    (ROOT / ASSET).write_bytes(data)
    manifest = {
        "schema": 1,
        "scope": "Supplemental source license texts from supplied native runtime bundles, Android Python archives, Go modules and reviewed upstream texts; Flutter package notices are generated by Flutter. Not a final binary compliance audit.",
        "inputs": input_hashes(ROOT),
        "supplement_sources": {package: source for package, (_, source) in SUPPLEMENTS.items()},
        "asset_sha256": digest(data),
    }
    (ROOT / MANIFEST).write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    validate()
    print(f"Collected {len(json.loads(data))} supplemental license entries.")


if __name__ == "__main__":
    main()
