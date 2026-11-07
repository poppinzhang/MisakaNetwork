from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import vendor_bili


@unittest.skipUnless(shutil.which("git"), "Git is required to verify upstream snapshots")
class VendorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "upstream"
        self.source.mkdir()
        self.destination = self.root / "vendor"
        self.destination.mkdir()
        (self.destination / "existing.txt").write_bytes(b"keep existing snapshot")
        self.files = {
            "pyproject.toml": '[project]\nversion = "2.15.17"\n',
            "app_cmd/__init__.py": "# command package\n",
            "app_cmd/config/BuyConfig.py": "# configuration\n",
            "app_version.py": "# version helper\n",
            "LICENSE": "synthetic license\n",
            "assets/fail_messages.json": "[]\n",
            "interface/__init__.py": "# interface\n",
            "interface/common.py": "def _cookie_store_path(cookies_path: str | Path | None) -> str | None:\n    return cookies_path\n",
            "util/__init__.py": (
                "import os\n"
                "def get_exec_path() -> str:\n    return '.'\n"
                "loguru_config(LOG_DIR, log_file_name, enable_console=True, file_colorize=False)\n"
            ),
            "task/buy.py": "# purchase engine\n",
            "cptoken/__init__.py": "# token helper\n",
            "util/log/LogWeb.py": "# excluded web logger\n",
            "util/log/TerminalRenderer.py": "# excluded terminal renderer\n",
            "cookies.json": '{"synthetic": "cookie"}\n',
            "config.json": '{"synthetic": "configuration"}\n',
            "interface/cookies.json.bak": "synthetic backup\n",
            "other/private.py": "# not allowlisted\n",
        }
        for relative, content in self.files.items():
            self.write_source(relative, content)
        self.git("init", "-q")
        self.git("config", "core.symlinks", "true")
        self.git("config", "core.autocrlf", "false")
        self.revision = self.commit()
        self.pinned_revision = patch.object(vendor_bili, "UPSTREAM_REVISION", self.revision)
        self.pinned_revision.start()
        self.addCleanup(self.pinned_revision.stop)

    def write_source(self, relative, content):
        target = self.source / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        # Snapshot hashes and patch hooks describe Git bytes, not host newlines.
        target.write_text(content, encoding="utf-8", newline="\n")

    def git(self, *args):
        return subprocess.run(
            ["git", "-C", str(self.source), "-c", "user.name=Vendor Tests",
             "-c", "user.email=vendor-tests@example.invalid", "-c", "commit.gpgsign=false",
             "-c", f"core.hooksPath={os.devnull}", *args],
            check=True, capture_output=True,
        ).stdout.decode().strip()

    def commit(self):
        self.git("add", "--all")
        self.git("commit", "-q", "-m", "Synthetic upstream source")
        return self.git("rev-parse", "HEAD")

    def assert_original_preserved(self):
        self.assertEqual(list(self.destination.iterdir()), [self.destination / "existing.txt"])
        self.assertEqual((self.destination / "existing.txt").read_bytes(), b"keep existing snapshot")
        self.assertFalse(list(self.root.glob(".bili-vendor-*")))

    def assert_rejected(self, message):
        with self.assertRaisesRegex(ValueError, message):
            vendor_bili.vendor(self.source, self.destination)
        self.assert_original_preserved()

    def test_pinned_snapshot_ignores_new_commits_worktree_and_untracked_files(self):
        self.write_source("task/buy.py", "# newer commit\n")
        self.commit()
        self.write_source("interface/common.py", "# unreviewed worktree\n")
        self.write_source("util/private.py", "# untracked private data\n")
        self.write_source("pyproject.toml", '[project]\nversion="wrong"\n')
        # A local archive filter must not suppress or transform pinned blobs.
        self.write_source(".git/info/attributes", "task/buy.py export-ignore\n")
        vendor_bili.vendor(self.source, self.destination)
        manifest = json.loads((self.destination / "MANIFEST.json").read_text())
        self.assertEqual(manifest["version"], "2.15.18")
        self.assertEqual(manifest["tag"], "v2.15.18")
        self.assertEqual(manifest["revision"], self.revision)
        self.assertEqual(manifest["package_version"], "2.15.17")
        self.assertEqual(manifest["source"], "https://github.com/mikumifa/biliTickerBuy")
        self.assertEqual((self.destination / "task/buy.py").read_text(), self.files["task/buy.py"])
        excluded = {
            "pyproject.toml", "util/log/LogWeb.py", "util/log/TerminalRenderer.py",
            "cookies.json", "config.json", "interface/cookies.json.bak", "other/private.py",
        }
        records = {record["path"]: record for record in manifest["files"]}
        self.assertEqual(set(records), self.files.keys() - excluded)
        actual = {path.relative_to(self.destination).as_posix() for path in self.destination.rglob("*") if path.is_file()}
        self.assertEqual(actual, set(records) | {"MANIFEST.json"})
        for relative, record in records.items():
            self.assertEqual(record["upstream_sha256"], hashlib.sha256(self.files[relative].encode()).hexdigest())
            self.assertEqual(record["sha256"], hashlib.sha256((self.destination / relative).read_bytes()).hexdigest())
            if relative in {"util/__init__.py", "interface/common.py"}:
                self.assertIn("patch", record)
                self.assertNotEqual(record["sha256"], record["upstream_sha256"])
            else:
                self.assertNotIn("patch", record)
                self.assertEqual(record["sha256"], record["upstream_sha256"])
        self.assertIn('return os.environ["MISAKA_RUNTIME_STATE_DIR"]', (self.destination / "util/__init__.py").read_text())
        self.assertIn("loguru.logger.remove()", (self.destination / "util/__init__.py").read_text())
        self.assertIn("return None  # Embedded bridge", (self.destination / "interface/common.py").read_text())

    def test_missing_commit_preserves_destination(self):
        with patch.object(vendor_bili, "UPSTREAM_REVISION", "0" * 40):
            self.assert_rejected("pinned upstream Git revision")

    def test_package_version_mismatch_preserves_destination(self):
        self.write_source("pyproject.toml", '[project]\nversion="2.15.18"\n')
        with patch.object(vendor_bili, "UPSTREAM_REVISION", self.commit()):
            self.assert_rejected("Review the runtime integration")

    def test_invalid_package_metadata_preserves_destination(self):
        for metadata in ("invalid toml", "[project]\n", '[project]\nversion=[]\n'):
            with self.subTest(metadata=metadata):
                self.write_source("pyproject.toml", metadata)
                with patch.object(vendor_bili, "UPSTREAM_REVISION", self.commit()):
                    self.assert_rejected("metadata|Review the runtime integration")

    def test_missing_required_source_preserves_destination(self):
        (self.source / "interface/common.py").unlink()
        with patch.object(vendor_bili, "UPSTREAM_REVISION", self.commit()):
            self.assert_rejected("missing required files")

    def test_changed_patch_hooks_preserve_destination(self):
        cases = (
            ("util/__init__.py", "def get_exec_path() -> str:", "def get_exec_path():", "execution-directory hook"),
            ("util/__init__.py", "enable_console=True", "enable_console=False", "logging hook"),
            ("interface/common.py", "def _cookie_store_path", "def changed_cookie_store_path", "cookie storage hook"),
        )
        for relative, before, after, message in cases:
            with self.subTest(hook=message):
                for path in {case[0] for case in cases}:
                    self.write_source(path, self.files[path])
                self.write_source(relative, self.files[relative].replace(before, after))
                with patch.object(vendor_bili, "UPSTREAM_REVISION", self.commit()):
                    self.assert_rejected(message)

    def test_committed_source_symlink_preserves_destination(self):
        source = self.source / "task/buy.py"
        source.unlink()
        try:
            source.symlink_to("../cookies.json")
        except OSError:
            self.skipTest("Creating symbolic links is unavailable")
        with patch.object(vendor_bili, "UPSTREAM_REVISION", self.commit()):
            self.assert_rejected("regular Git blobs")

    def test_destination_symlink_is_rejected_without_touching_target(self):
        alias = self.root / "alias"
        try:
            alias.symlink_to(self.destination, target_is_directory=True)
        except OSError:
            self.skipTest("Creating symbolic links is unavailable")
        with self.assertRaisesRegex(ValueError, "not a symlink"):
            vendor_bili.vendor(self.source, alias)
        self.assertTrue(alias.is_symlink())
        self.assert_original_preserved()

    def test_failed_replacement_restores_existing_snapshot(self):
        rename = Path.rename

        def fail_install(path, target):
            if path.name == "snapshot":
                raise OSError("synthetic rename failure")
            return rename(path, target)

        with patch.object(Path, "rename", fail_install), self.assertRaisesRegex(OSError, "synthetic rename failure"):
            vendor_bili.vendor(self.source, self.destination)
        self.assert_original_preserved()

    def test_failed_rollback_retains_previous_snapshot_for_recovery(self):
        rename = Path.rename

        def fail_install_and_rollback(path, target):
            if path.name in {"snapshot", "previous"}:
                raise OSError("synthetic filesystem failure")
            return rename(path, target)

        with patch.object(Path, "rename", fail_install_and_rollback), self.assertRaisesRegex(OSError, "recover it from") as failure:
            vendor_bili.vendor(self.source, self.destination)
        preserved = list(self.root.glob(".bili-vendor-*/previous/existing.txt"))
        self.assertEqual(len(preserved), 1)
        self.assertEqual(preserved[0].read_bytes(), b"keep existing snapshot")
        self.assertIn(str(preserved[0].parent), str(failure.exception))


if __name__ == "__main__":
    unittest.main()
