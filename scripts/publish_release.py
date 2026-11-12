#!/usr/bin/env python3
"""Publish only a verified, complete release through GitHub CLI.

This command performs remote writes. Tests replace the command runner; ordinary
metadata, staging and packaging commands never import or invoke this publisher.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

from release_ci import release_asset_names, release_notes, validate_assets
from release_config import ROOT, VERSION


def run_command(arguments: list[str]) -> str:
    return subprocess.run(arguments, cwd=ROOT, check=True, capture_output=True,
                          text=True, encoding="utf-8").stdout.strip()


def github_json(endpoint: str, *, paginate: bool = False):
    command = ["gh", "api", "--hostname", "github.com", endpoint,
               "--header", "Accept: application/vnd.github+json"]
    if paginate:
        command.extend(("--paginate", "--slurp"))
    result = json.loads(run_command(command))
    if paginate:
        if not isinstance(result, list) or any(not isinstance(page, list) for page in result):
            raise ValueError("GitHub returned an invalid paginated response")
        return [item for page in result for item in page]
    return result


def validate_identity(tag: str, repository: str, commit: str) -> None:
    if tag not in (VERSION, "v" + VERSION):
        raise ValueError("Release tag must match the configured version")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*", repository):
        raise ValueError("Repository must use OWNER/REPO format")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Release commit must be a full lowercase Git SHA")


def validate_checkout(tag: str, commit: str) -> None:
    for reference in ("HEAD", f"refs/tags/{tag}^{{commit}}"):
        actual = run_command(["git", "rev-parse", "--verify", reference])
        if actual != commit:
            raise ValueError("Local checkout and tag must match the release commit")


def verify_remote_tag(tag: str, repository: str, commit: str) -> None:
    response = github_json(f"repos/{repository}/git/ref/tags/{tag}")
    if not isinstance(response, dict) or response.get("ref") != f"refs/tags/{tag}":
        raise ValueError("Remote release tag is missing or invalid")
    target = response.get("object")
    # Annotated tags may point to another annotated tag. Bound the traversal and
    # validate object identifiers before using them in another endpoint.
    seen = set()
    for _ in range(16):
        if not isinstance(target, dict) or not re.fullmatch(r"[0-9a-f]{40}", str(target.get("sha", ""))):
            raise ValueError("Remote release tag has an invalid target")
        sha = target["sha"]
        if target.get("type") == "commit":
            if sha != commit:
                raise ValueError("Remote release tag no longer matches the built commit")
            return
        if target.get("type") != "tag" or sha in seen:
            raise ValueError("Remote release tag does not resolve to a commit")
        seen.add(sha)
        tagged = github_json(f"repos/{repository}/git/tags/{sha}")
        target = tagged.get("object") if isinstance(tagged, dict) else None
    raise ValueError("Remote release tag has too many nested annotations")


def list_version_releases(repository: str) -> list[dict]:
    releases = github_json(f"repos/{repository}/releases?per_page=100", paginate=True)
    if any(not isinstance(item, dict) for item in releases):
        raise ValueError("GitHub returned an invalid release list")
    return [item for item in releases if item.get("tag_name") in (VERSION, "v" + VERSION)]


def verify_remote_assets(directory: Path, assets: list[dict]) -> None:
    expected = release_asset_names()
    if (not isinstance(assets, list) or any(not isinstance(item, dict) for item in assets)
            or len(assets) != len(expected)
            or {item.get("name") for item in assets} != set(expected)):
        raise ValueError("GitHub release asset names do not match the exact publication list")
    for item in assets:
        path = directory / item["name"]
        with path.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        if (item.get("state") != "uploaded" or item.get("size") != path.stat().st_size
                or item.get("digest") != "sha256:" + digest):
            raise ValueError("GitHub release asset size, state or SHA-256 mismatch: " + path.name)


def publish(directory: Path, *, tag: str, repository: str, commit: str) -> None:
    validate_identity(tag, repository, commit)
    validate_checkout(tag, commit)
    validate_assets(directory)
    notes = release_notes(tag, commit, repository)
    verify_remote_tag(tag, repository, commit)
    # Include drafts and every page. Never confuse a network/permission error
    # with a missing release, and never overwrite an older published version.
    existing = list_version_releases(repository)
    if existing:
        if any(item.get("draft") is not True for item in existing):
            raise ValueError("A published release already exists for this version; it will not be overwritten")
        raise ValueError("An existing draft must be reviewed and removed before rerunning publication")

    repo_argument = "github.com/" + repository
    with tempfile.TemporaryDirectory(prefix="misaka-release-notes-") as temporary:
        notes_path = Path(temporary) / "release-notes.md"
        notes_path.write_text(notes, encoding="utf-8")
        command = ["gh", "release", "create", tag, "--repo", repo_argument,
                   "--verify-tag", "--draft", "--prerelease=false", "--title", f"MisakaNetwork {VERSION}",
                   "--notes-file", str(notes_path)]
        run_command(command)

    drafts = list_version_releases(repository)
    if (len(drafts) != 1 or drafts[0].get("tag_name") != tag
            or drafts[0].get("draft") is not True
            or drafts[0].get("prerelease") is not False
            or type(drafts[0].get("id")) is not int or drafts[0]["id"] <= 0):
        raise ValueError("New release is not an unambiguous draft; refusing to upload")
    release_id = drafts[0]["id"]
    # Use one explicit argument per allowlisted file. Neither shell globbing nor
    # --clobber may be used here, even when the staging directory was verified.
    run_command(["gh", "release", "upload", tag, "--repo", repo_argument,
                 *(str((directory / name).resolve()) for name in release_asset_names())])

    current = github_json(f"repos/{repository}/releases/{release_id}")
    if (not isinstance(current, dict) or current.get("id") != release_id
            or current.get("tag_name") != tag or current.get("draft") is not True
            or current.get("prerelease") is not False):
        raise ValueError("Release changed while uploading; refusing to publish")
    assets = github_json(f"repos/{repository}/releases/{release_id}/assets?per_page=100", paginate=True)
    verify_remote_assets(directory, assets)
    verify_remote_tag(tag, repository, commit)
    run_command(["gh", "release", "edit", tag, "--repo", repo_argument,
                 "--verify-tag", "--draft=false", "--prerelease=false", "--latest"])
    published = github_json(f"repos/{repository}/releases/{release_id}")
    if (not isinstance(published, dict) or published.get("id") != release_id
            or published.get("tag_name") != tag or published.get("draft") is not False
            or published.get("prerelease") is not False):
        raise ValueError("Could not confirm the published release state")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()
    try:
        publish(args.directory, tag=args.tag, repository=args.repo, commit=args.commit)
    except subprocess.CalledProcessError as error:
        # Avoid dumping raw GitHub output or a command containing temporary paths.
        raise SystemExit(f"Release command failed (exit {error.returncode}); inspect the workflow and any draft before retrying") from error
    except (ValueError, OSError) as error:
        raise SystemExit(str(error)) from error
    print(f"Published {args.tag} with {len(release_asset_names())} verified assets")


if __name__ == "__main__":
    main()
