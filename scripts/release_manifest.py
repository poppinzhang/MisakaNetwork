"""Write checksummed release records; merge CI outputs only after validation."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil

from release_config import APP_TARGETS, BILI_VERSION, BUILD, RELEASE_DATE, ROOT, VERSION, artifact_name


def metadata() -> dict:
    return dict(version=VERSION, build=BUILD, bili_version=BILI_VERSION,
                date=RELEASE_DATE, status="incomplete", missing_targets=list(APP_TARGETS), artifacts=[])


def write_manifest(directory: Path, release: dict) -> None:
    release["artifacts"].sort(key=lambda item: item["name"])
    built = {f"{item['platform']}-{item['arch']}" for item in release["artifacts"]}
    release["missing_targets"] = [target for target in APP_TARGETS if target not in built]
    release["status"] = "incomplete" if release["missing_targets"] else "built-not-business-validated"
    (directory / "release.json").write_text(json.dumps(release, indent=2) + "\n")
    (directory / "SHA256SUMS").write_text("".join(
        f"{item['sha256']}  {item['name']}\n" for item in release["artifacts"]))


def record_artifact(path: Path, platform: str, arch: str, *, signing: str) -> dict:
    if path.name != artifact_name(f"{platform}-{arch}"):
        raise ValueError("Artifact name must match release version and target")
    manifest = path.parent / "release.json"
    release = json.loads(manifest.read_text()) if manifest.exists() else metadata()
    if any(release.get(key) != value for key, value in metadata().items()
           if key in {"version", "build", "bili_version"}):
        raise ValueError("Cannot combine artifacts from different releases")
    data = path.read_bytes()
    item = dict(name=path.name, platform=platform, arch=arch, bytes=len(data),
                sha256=hashlib.sha256(data).hexdigest(), signing=signing)
    release["artifacts"] = [old for old in release["artifacts"] if old["name"] != path.name] + [item]
    (path.parent / (path.name + ".sha256")).write_text(f"{item['sha256']}  {path.name}\n")
    write_manifest(path.parent, release)
    return release


def merge_releases(inputs: list[Path], output: Path) -> dict:
    from check_release import verify_release
    release = metadata()
    sources = []
    targets = set()
    for directory in inputs:
        candidate = json.loads((directory / "release.json").read_text())
        current = tuple(f"{item['platform']}-{item['arch']}" for item in candidate["artifacts"])
        verify_release(directory, [], expected_targets=current)
        if any(candidate.get(key) != release[key] for key in ("version", "build", "bili_version")):
            raise ValueError("Cannot combine artifacts from different releases")
        for item in candidate["artifacts"]:
            target = f"{item['platform']}-{item['arch']}"
            if target in targets:
                raise ValueError("Duplicate platform in release inputs")
            targets.add(target)
            sources.append((directory, item))
    if targets != set(APP_TARGETS):
        raise ValueError("A unified release must contain all supported LastOrder targets")
    output.mkdir(parents=True, exist_ok=True)
    for directory, item in sources:
        for name in (item["name"], item["name"] + ".sha256"):
            shutil.copy2(directory / name, output / name)
        release["artifacts"].append(item)
    write_manifest(output, release)
    verify_release(output, [])
    return release


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / f"dist/{VERSION}")
    args = parser.parse_args()
    result = merge_releases(args.inputs, args.output)
    print(f"Assembled all {len(result['artifacts'])} LastOrder release targets")


if __name__ == "__main__":
    main()
