"""Single source of release metadata for packaging and validation."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION = "0.2.1"
BUILD = 8
RELEASE_DATE = "2026-11-12"
BILI_VERSION = "2.15.18"
TARGETS = ("linux-amd64", "linux-arm64", "macos-amd64", "macos-arm64")
APP_TARGETS = ("macos-amd64", "macos-arm64", "windows-amd64", "android-arm64", "android-amd64")


def artifact_name(target: str, version: str = VERSION) -> str:
    if target not in APP_TARGETS:
        raise ValueError(f"Unsupported LastOrder target: {target}")
    extension = "apk" if target.startswith("android-") else "zip"
    return f"LastOrder-{version}-{target}.{extension}"


def android_bundle_asset(name: str) -> str:
    if name not in {f"{target}.tar.gz" for target in TARGETS}:
        raise ValueError("Unsupported Android deployment bundle")
    # AAPT transparently expands .gz assets even when marked noCompress.
    return name.removesuffix(".tar.gz") + ".bundle"
