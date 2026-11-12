#!/usr/bin/env python3
"""Offline release preflight and an explicit allowlist for GitHub Release assets."""
from __future__ import annotations

import argparse
from datetime import date
import json
from pathlib import Path
import re
import shutil
import tempfile
from urllib.parse import quote

from check_release import verify_release
from release_config import APP_TARGETS, BILI_VERSION, BUILD, RELEASE_DATE, ROOT, VERSION, artifact_name

# GitHub accepts release assets smaller than 2 GiB each.
MAX_ASSET_BYTES = 2 * 1024 ** 3


def release_asset_names() -> tuple[str, ...]:
    packages = tuple(artifact_name(target) for target in APP_TARGETS)
    return packages + tuple(name + ".sha256" for name in packages) + ("SHA256SUMS", "release.json")


def metadata(root: Path = ROOT) -> dict[str, str]:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", VERSION) or type(BUILD) is not int or BUILD < 1:
        raise ValueError("Invalid release_config version/build")
    date.fromisoformat(RELEASE_DATE)
    versions = re.findall(r"^version:\s*([^\s#]+)\s*$", (root / "LastOrder/pubspec.yaml").read_text(encoding="utf-8"), re.M)
    if versions != [f"{VERSION}+{BUILD}"]:
        raise ValueError("pubspec.yaml version/build must match release_config")
    return dict(version=VERSION, dist_dir=f"dist/{VERSION}", artifact_name=f"LastOrder-{VERSION}-complete")


def validate_tag(tag: str) -> None:
    if tag not in (VERSION, f"v{VERSION}"):
        raise ValueError("Release tag must match release_config VERSION, optionally prefixed with v")


def changelog_sections(root: Path) -> dict[str, str]:
    text = (root / "CHANGELOG.md").read_text(encoding="utf-8")
    sections = re.split(r"^## (.+)\s*$", text, flags=re.M)
    result = {}
    for heading, body in zip(sections[1::2], sections[2::2]):
        heading = heading.strip()
        if heading in result:
            raise ValueError("Duplicate CHANGELOG section")
        result[heading] = body.strip()
    return result


def preflight(ref: str, root: Path = ROOT) -> dict[str, str]:
    result = metadata(root)
    if not ref.startswith("refs/tags/"):
        raise ValueError("Release requires an existing tag ref; branches cannot publish")
    tag = ref.removeprefix("refs/tags/")
    validate_tag(tag)
    sections = changelog_sections(root)
    if "unstaged" not in sections:
        raise ValueError("CHANGELOG must retain an empty unstaged section")
    unstaged = re.sub(r"<!--.*?-->", "", sections["unstaged"], flags=re.S)
    unstaged = re.sub(r"^### .*$", "", unstaged, flags=re.M).strip()
    if unstaged:
        raise ValueError("Move unstaged changes into the new version before releasing")
    heading = f"{VERSION} — {RELEASE_DATE}"
    if not sections.get(heading):
        raise ValueError("CHANGELOG must contain the current version and release date")
    notes = root / f"docs/releases/{VERSION}.md"
    if not notes.is_file() or not notes.read_text(encoding="utf-8").strip():
        raise ValueError("A nonempty docs/releases/<version>.md is required")
    return dict(result, tag=tag)


def _validate_assets(directory: Path, *, exact: bool) -> dict:
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("Release assets must be in a real directory")
    names = release_asset_names()
    if exact and {path.name for path in directory.iterdir()} != set(names):
        raise ValueError("Release asset directory must contain exactly the allowlisted files")
    for name in names:
        path = directory / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Release asset must be a regular file: {name}")
        if not 0 < path.stat().st_size < MAX_ASSET_BYTES:
            raise ValueError(f"Release asset must be nonempty and smaller than 2 GiB: {name}")
    release = json.loads((directory / "release.json").read_text(encoding="utf-8"))
    expected = dict(version=VERSION, build=BUILD, bili_version=BILI_VERSION, date=RELEASE_DATE,
                    status="built-not-business-validated", missing_targets=[])
    if not isinstance(release, dict) or any(release.get(key) != value for key, value in expected.items()):
        raise ValueError("Release metadata must match the current complete release")
    release = verify_release(directory, [])
    for item in release["artifacts"]:
        if item["platform"] == "android" and item.get("signing") != "release-keystore":
            raise ValueError("GitHub Release requires release-keystore Android signing; test APKs cannot publish")
        if not isinstance(item.get("signing"), str) or not item["signing"]:
            raise ValueError("Every release artifact must declare its signing mode")
    return release


def validate_assets(directory: Path) -> dict:
    """Recheck the complete, clean upload directory immediately before publication."""
    return _validate_assets(directory, exact=True)


def stage_assets(source: Path, output: Path) -> dict:
    """Copy only final files, ignoring build intermediates without modifying the input."""
    if output.exists() or output.is_symlink():
        raise ValueError("Asset staging output must not exist; use a fresh directory")
    release = _validate_assets(source, exact=False)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="release-assets-", dir=output.parent) as temporary:
        staging = Path(temporary) / "assets"
        staging.mkdir()
        for name in release_asset_names():
            shutil.copy2(source / name, staging / name)
        validate_assets(staging)
        staging.rename(output)
    return release


def release_notes(tag: str, commit: str, repository: str, root: Path = ROOT) -> str:
    preflight(f"refs/tags/{tag}", root)
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Release commit must be a full Git commit SHA")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Repository must be OWNER/REPO")
    base = f"https://github.com/{repository}/blob/{commit}/"
    changes = changelog_sections(root)[f"{VERSION} — {RELEASE_DATE}"]
    # CHANGELOG links are relative to the repository root; Release bodies are not.
    changes = re.sub(r"(\]\()([^\s)]+)(\))", lambda match: match.group(0)
                     if re.match(r"[a-zA-Z][a-zA-Z0-9+.-]*:|[/#]", match[2])
                     else match[1] + base + quote(match[2], safe="/#") + match[3], changes)
    return (f"# MisakaNetwork {VERSION}\n\n"
            f"GitHub Actions 从标签 `{tag}`（提交 `{commit}`）构建，统一版本 **{VERSION}+{BUILD}**。\n\n"
            "Assets 提供 macOS arm64/x64、Windows x64、Android arm64/x64 五种完整 LastOrder 包，"
            "每份均内含 Linux/macOS 四种 Sisters 离线部署包。下载对应程序包即可；"
            "`.sha256`、`SHA256SUMS` 和 `release.json` 用于核对文件。\n\n"
            "本次 CI 完成源码测试、运行时离线检查和完整包核验，不代表真实登录、下单或出票验收。"
            "macOS 使用 ad-hoc 签名且未公证；Windows 未使用 Authenticode 签名；Android 使用发布密钥。"
            "本次发布为正式 Release；1.0.0 前仍属于早期研发版本。\n\n"
            f"[该版本说明与升级操作]({base}docs/releases/{VERSION}.md)\n\n"
            f"## 版本变更记录\n\n{changes}\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    info = commands.add_parser("metadata")
    info.add_argument("--github-output", type=Path)
    check = commands.add_parser("preflight")
    check.add_argument("--ref", required=True)
    check.add_argument("--github-output", type=Path)
    stage = commands.add_parser("stage")
    stage.add_argument("directory", type=Path)
    stage.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "stage":
            stage_assets(args.directory, args.output)
            print(f"Staged exactly {len(release_asset_names())} GitHub Release assets")
        else:
            result = preflight(args.ref) if args.command == "preflight" else metadata()
            if args.github_output:
                with args.github_output.open("a", encoding="utf-8") as output:
                    output.writelines(f"{key}={value}\n" for key, value in result.items())
            print(json.dumps(result))
    except (ValueError, OSError, KeyError) as error:
        parser.exit(1, f"Release preparation failed: {error}\n")


if __name__ == "__main__":
    main()
