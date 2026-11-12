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


def github_write_json(endpoint: str, *, method: str, body: dict):
    # Keep structured request bodies out of command-line quoting and preserve
    # JSON booleans, Unicode and newlines in release notes. Never retry writes.
    with tempfile.TemporaryDirectory(prefix="misaka-release-request-") as temporary:
        request_path = Path(temporary) / "request.json"
        request_path.write_text(json.dumps(body, ensure_ascii=False), encoding="utf-8")
        return json.loads(run_command([
            "gh", "api", "--hostname", "github.com", endpoint,
            "--header", "Accept: application/vnd.github+json",
            "--header", "Content-Type: application/json",
            "--method", method, "--input", str(request_path),
        ]))


def matches_release(response, *, tag: str, draft: bool, release_id: int | None = None) -> bool:
    return (isinstance(response, dict) and type(response.get("id")) is int
            and response["id"] > 0 and (release_id is None or response["id"] == release_id)
            and response.get("tag_name") == tag and response.get("draft") is draft
            and response.get("prerelease") is False)


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

    verify_remote_tag(tag, repository, commit)
    # The creation response identifies this exact draft. REST's tag endpoint
    # only returns published releases, and the list may not show a new draft.
    created = github_write_json(f"repos/{repository}/releases", method="POST", body={
        "tag_name": tag, "target_commitish": commit, "name": f"MisakaNetwork {VERSION}",
        "body": notes, "draft": True, "prerelease": False,
    })
    if not matches_release(created, tag=tag, draft=True):
        raise ValueError("New release is not an unambiguous draft; refusing to upload")
    release_id = created["id"]
    confirmed = github_json(f"repos/{repository}/releases/{release_id}")
    if not matches_release(confirmed, tag=tag, draft=True, release_id=release_id):
        raise ValueError("New release is not an unambiguous draft; refusing to upload")
    # Use one explicit argument per allowlisted file. Neither shell globbing nor
    # --clobber may be used here, even when the staging directory was verified.
    # gh upload supports drafts via its GraphQL lookup, unlike REST /tags.
    repo_argument = "github.com/" + repository
    run_command(["gh", "release", "upload", tag, "--repo", repo_argument,
                 *(str((directory / name).resolve()) for name in release_asset_names())])

    current = github_json(f"repos/{repository}/releases/{release_id}")
    if not matches_release(current, tag=tag, draft=True, release_id=release_id):
        raise ValueError("Release changed while uploading; refusing to publish")
    assets = github_json(f"repos/{repository}/releases/{release_id}/assets?per_page=100", paginate=True)
    verify_remote_assets(directory, assets)
    verify_remote_tag(tag, repository, commit)
    updated = github_write_json(f"repos/{repository}/releases/{release_id}", method="PATCH", body={
        "draft": False, "prerelease": False, "make_latest": "true",
    })
    if not matches_release(updated, tag=tag, draft=False, release_id=release_id):
        raise ValueError("Could not confirm the published release state")
    published = github_json(f"repos/{repository}/releases/{release_id}")
    if not matches_release(published, tag=tag, draft=False, release_id=release_id):
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
