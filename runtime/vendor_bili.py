"""Copy only reviewed upstream code; never import account/config/runtime files."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tomllib

PACKAGES = ("interface", "task", "app_cmd/config", "util", "cptoken")
SINGLE_FILES = ("app_cmd/__init__.py", "app_version.py", "LICENSE", "assets/fail_messages.json")
EXCLUDED = {"util/log/LogWeb.py", "util/log/TerminalRenderer.py"}


def vendor(source: Path, destination: Path) -> None:
    version = tomllib.loads((source / "pyproject.toml").read_text())["project"]["version"]
    if version != "2.15.17":
        raise ValueError("Review the runtime integration before changing upstream version")
    paths = list(SINGLE_FILES)
    for package in PACKAGES:
        paths.extend(str(path.relative_to(source)) for path in (source / package).rglob("*.py"))
    paths = sorted(set(paths) - EXCLUDED)
    records = []
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    for relative in paths:
        original = source / relative
        if original.is_symlink() or source.resolve() not in original.resolve().parents:
            raise ValueError("Source files must remain inside the upstream directory")
        content = original.read_bytes()
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
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
        record["sha256"] = hashlib.sha256(content).hexdigest()
        records.append(record)
    manifest = {
        "name": "biliTickerBuy", "version": version,
        "source": "https://github.com/mikumifa/biliTickerBuy",
        "license": "PolyForm Noncommercial License 1.0.0",
        "required_notice": "Copyright (c) 2023 mikumifa",
        "files": records,
    }
    (destination / "MANIFEST.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "vendor" / "biliTickerBuy")
    args = parser.parse_args()
    vendor(args.source, args.output)
