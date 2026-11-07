"""Copy only reviewed upstream code; never import account/config/runtime files."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib

UPSTREAM_VERSION = "2.15.18"
UPSTREAM_TAG = "v2.15.18"
UPSTREAM_REVISION = "227ebf73f5af3eec0019984a7cbcb722977453e8"
# The upstream release tag advanced without updating its package metadata.
UPSTREAM_PACKAGE_VERSION = "2.15.17"
PACKAGES = ("interface", "task", "app_cmd/config", "util", "cptoken")
SINGLE_FILES = ("app_cmd/__init__.py", "app_version.py", "LICENSE", "assets/fail_messages.json")
EXCLUDED = {"util/log/LogWeb.py", "util/log/TerminalRenderer.py"}


def git(source: Path, *args: str) -> bytes:
    try:
        return subprocess.run(
            ["git", "-C", str(source), *args], check=True, capture_output=True,
            env=dict(os.environ, GIT_NO_REPLACE_OBJECTS="1"),
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        raise ValueError("Cannot read the pinned upstream Git revision") from None


def read_snapshot(source: Path) -> dict[str, bytes]:
    """Read original Git blobs, independent of worktree files and attributes."""
    revision = git(source, "rev-parse", "--verify", UPSTREAM_REVISION + "^{commit}").decode().strip()
    if revision != UPSTREAM_REVISION:
        raise ValueError("Upstream revision does not match the reviewed commit")
    entries = git(source, "ls-tree", "-rz", "--full-tree", revision)
    files: dict[str, bytes] = {}
    for entry in entries.split(b"\0"):
        if not entry:
            continue
        metadata, raw_path = entry.split(b"\t", 1)
        path = raw_path.decode("utf-8")
        included = path in (*SINGLE_FILES, "pyproject.toml") or (
            path.endswith(".py") and any(path.startswith(package + "/") for package in PACKAGES)
        )
        if not included or path in EXCLUDED:
            continue
        mode, kind, object_id = metadata.decode("ascii").split()
        if mode not in {"100644", "100755"} or kind != "blob":
            raise ValueError("Upstream source files must be regular Git blobs")
        files[path] = git(source, "cat-file", "blob", object_id)
    required = {*SINGLE_FILES, "pyproject.toml", "util/__init__.py", "interface/common.py"}
    if not required <= files.keys():
        raise ValueError("Pinned upstream source is missing required files")
    try:
        version = tomllib.loads(files.pop("pyproject.toml").decode("utf-8"))["project"]["version"]
    except (UnicodeDecodeError, tomllib.TOMLDecodeError, KeyError, TypeError):
        raise ValueError("Invalid upstream package metadata") from None
    if version != UPSTREAM_PACKAGE_VERSION:
        raise ValueError("Review the runtime integration before changing upstream version")
    return files


def vendor(source: Path, destination: Path) -> None:
    files = read_snapshot(source)
    records = []
    for relative, content in sorted(files.items()):
        record = {"path": relative, "upstream_sha256": hashlib.sha256(content).hexdigest()}
        if relative == "util/__init__.py":
            text = content.decode("utf-8")
            before = "def get_exec_path() -> str:\n"
            after = before + '    if os.environ.get("MISAKA_RUNTIME_STATE_DIR"):\n        return os.environ["MISAKA_RUNTIME_STATE_DIR"]\n'
            if text.count(before) != 1:
                raise ValueError("Upstream execution-directory hook changed")
            text = text.replace(before, after)
            before = "loguru_config(LOG_DIR, log_file_name, enable_console=True, file_colorize=False)"
            after = 'if os.environ.get("MISAKA_RUNTIME_STATE_DIR"):\n    loguru.logger.remove()\nelse:\n    ' + before
            if text.count(before) != 1:
                raise ValueError("Upstream logging hook changed")
            content = text.replace(before, after).encode("utf-8")
            record["patch"] = "Use process-private state directory and disable raw upstream logging when embedded."
        elif relative == "interface/common.py":
            text = content.decode("utf-8")
            before = "def _cookie_store_path(cookies_path: str | Path | None) -> str | None:\n"
            after = before + '    import os\n    if os.environ.get("MISAKA_RUNTIME_STATE_DIR"):\n        return None  # Embedded bridge keeps account cookies in memory.\n'
            if text.count(before) != 1:
                raise ValueError("Upstream cookie storage hook changed")
            content = text.replace(before, after).encode("utf-8")
            record["patch"] = "Use in-memory cookie storage when embedded."
        files[relative] = content
        record["sha256"] = hashlib.sha256(content).hexdigest()
        records.append(record)
    manifest = {
        "name": "biliTickerBuy", "version": UPSTREAM_VERSION,
        "tag": UPSTREAM_TAG, "revision": UPSTREAM_REVISION,
        "package_version": UPSTREAM_PACKAGE_VERSION,
        "source": "https://github.com/mikumifa/biliTickerBuy",
        "license": "PolyForm Noncommercial License 1.0.0",
        "required_notice": "Copyright (c) 2023 mikumifa",
        "files": records,
    }
    if destination.is_symlink() or destination.exists() and not destination.is_dir():
        raise ValueError("Vendor destination must be a directory, not a symlink")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=".bili-vendor-", dir=destination.parent))
    previous = temporary / "previous"
    installed = False
    try:
        stage = temporary / "snapshot"
        stage.mkdir()
        for relative, content in files.items():
            target = stage / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
        (stage / "MANIFEST.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        if destination.exists():
            destination.rename(previous)
        try:
            stage.rename(destination)
            installed = True
        except OSError:
            if previous.exists():
                try:
                    previous.rename(destination)
                except OSError as error:
                    raise OSError(f"Could not restore the vendor snapshot; recover it from {previous}") from error
            raise
    finally:
        # If even rollback fails, retain the previous snapshot for recovery.
        if installed or not previous.exists():
            shutil.rmtree(temporary)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "vendor" / "biliTickerBuy")
    args = parser.parse_args()
    vendor(args.source, args.output)
