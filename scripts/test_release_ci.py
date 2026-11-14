"""Offline release gates use synthetic packages and never contact GitHub."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from release_ci import (metadata, preflight, release_asset_names, release_notes,
                        stage_assets, validate_assets)
from release_config import APP_TARGETS, BUILD, RELEASE_DATE, VERSION, artifact_name
from release_manifest import record_artifact
from test_check_release import app_archive


class ReleaseCITests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="misaka-release-ci-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "LastOrder").mkdir()
        (self.root / "LastOrder/pubspec.yaml").write_text(f"name: lastorder\nversion: {VERSION}+{BUILD}\n")
        (self.root / "docs/releases").mkdir(parents=True)
        (self.root / f"docs/releases/{VERSION}.md").write_text("Synthetic release notes\n")
        self.changelog = self.root / "CHANGELOG.md"
        self.changelog.write_text(f"# ChangeLog\n\n## unstaged\n\n## {VERSION} — {RELEASE_DATE}\n\n"
                                  "### 改进\n\n- Synthetic change.\n", encoding="utf-8")

    def packages(self):
        directory = self.root / "packages"
        directory.mkdir()
        for target in APP_TARGETS:
            package = directory / artifact_name(target)
            package.write_bytes(app_archive(target=target))
            platform, arch = target.split("-")
            record_artifact(package, platform, arch,
                            signing="release-keystore" if platform == "android" else "synthetic-test")
        return directory

    def mutate_manifest(self, directory, mutate):
        path = directory / "release.json"
        release = json.loads(path.read_text())
        mutate(release)
        path.write_text(json.dumps(release))

    def test_metadata_and_both_existing_tag_conventions(self):
        info = metadata(self.root)
        self.assertEqual(info["dist_dir"], f"dist/{VERSION}")
        self.assertEqual(info["artifact_name"], f"LastOrder-{VERSION}-complete")
        for tag in (VERSION, "v" + VERSION):
            self.assertEqual(preflight("refs/tags/" + tag, self.root), dict(info, tag=tag))

    def test_branches_wrong_versions_and_shell_characters_cannot_publish(self):
        for ref in ("refs/heads/main", VERSION, "refs/tags/v99.0.0", "refs/tags/" + VERSION + "\nextra=value",
                    "refs/tags/$(true)", "refs/tags/v" + VERSION + "+1"):
            with self.subTest(ref=ref), self.assertRaises(ValueError):
                preflight(ref, self.root)

    def test_inconsistent_pubspec_is_rejected_before_builds(self):
        (self.root / "LastOrder/pubspec.yaml").write_text(f"version: {VERSION}+{BUILD + 1}\n")
        with self.assertRaisesRegex(ValueError, "pubspec"):
            metadata(self.root)

    def test_unstaged_changes_block_release_but_not_package(self):
        self.changelog.write_text(self.changelog.read_text(encoding="utf-8").replace(
            "## unstaged", "## unstaged\n\n### 改进\n\n- Not released"), encoding="utf-8")
        metadata(self.root)
        with self.assertRaisesRegex(ValueError, "unstaged"):
            preflight("refs/tags/" + VERSION, self.root)

    def test_empty_unstaged_headings_and_comments_are_allowed(self):
        self.changelog.write_text(self.changelog.read_text(encoding="utf-8").replace(
            "## unstaged", "## unstaged\n\n<!-- release placeholder -->\n### 改进\n"), encoding="utf-8")
        preflight("refs/tags/" + VERSION, self.root)

    def test_missing_release_notes_wrong_date_and_duplicate_sections_are_rejected(self):
        original = self.changelog.read_text(encoding="utf-8")
        for content in (original.replace(RELEASE_DATE, "2000-01-01"), original + "\n## unstaged\n"):
            self.changelog.write_text(content, encoding="utf-8")
            with self.assertRaises(ValueError):
                preflight("refs/tags/" + VERSION, self.root)
        self.changelog.write_text(original, encoding="utf-8")
        (self.root / f"docs/releases/{VERSION}.md").unlink()
        with self.assertRaisesRegex(ValueError, "docs/releases"):
            preflight("refs/tags/" + VERSION, self.root)

    def test_only_final_assets_are_staged_and_sources_remain_untouched(self):
        source = self.packages()
        (source / "expanded.app").mkdir()
        for extra in ("debug.log", "linux-amd64.tar.gz", "signing.keystore", "old.zip"):
            (source / extra).write_text("synthetic intermediate")
        destination = self.root / "clean"
        result = stage_assets(source, destination)
        self.assertEqual(len(result["artifacts"]), 5)
        self.assertEqual({path.name for path in destination.iterdir()}, set(release_asset_names()))
        self.assertEqual(len(release_asset_names()), 12)
        for name in release_asset_names():
            self.assertEqual((source / name).read_bytes(), (destination / name).read_bytes())
        self.assertTrue((source / "debug.log").is_file())
        validate_assets(destination)

    def test_existing_output_is_not_overwritten(self):
        source = self.packages()
        destination = self.root / "clean"
        destination.mkdir()
        sentinel = destination / "important.txt"
        sentinel.write_text("keep")
        with self.assertRaisesRegex(ValueError, "must not exist"):
            stage_assets(source, destination)
        self.assertEqual(sentinel.read_text(), "keep")

    def test_publisher_rejects_even_one_unexpected_file(self):
        source = self.packages()
        (source / "log.txt").write_text("synthetic log")
        with self.assertRaisesRegex(ValueError, "exactly"):
            validate_assets(source)

    def test_missing_and_corrupt_assets_fail_before_staging(self):
        source = self.packages()
        package = source / artifact_name(APP_TARGETS[0])
        package.unlink()
        with self.assertRaisesRegex(ValueError, "regular file"):
            stage_assets(source, self.root / "missing")
        package.write_bytes(b"bad archive")
        with self.assertRaisesRegex(ValueError, "Size mismatch"):
            stage_assets(source, self.root / "corrupt")
        for name in ("missing", "corrupt"):
            self.assertFalse((self.root / name).exists())

    def test_symlink_asset_is_rejected(self):
        source = self.packages()
        package = source / artifact_name(APP_TARGETS[0])
        original = package.read_bytes()
        package.unlink()
        outside = self.root / "outside.zip"
        outside.write_bytes(original)
        try:
            package.symlink_to(outside)
        except (OSError, NotImplementedError):
            self.skipTest("Creating symbolic links is unavailable")
        with self.assertRaisesRegex(ValueError, "regular file"):
            stage_assets(source, self.root / "symlink")
        self.assertFalse((self.root / "symlink").exists())

    def test_wrong_metadata_and_debug_signing_cannot_publish(self):
        source = self.packages()
        original = (source / "release.json").read_bytes()
        for field, value in (("version", "99.0.0"), ("build", BUILD + 1), ("bili_version", "different"),
                             ("date", "2000-01-01"), ("status", "incomplete"), ("missing_targets", [APP_TARGETS[0]])):
            with self.subTest(field=field):
                self.mutate_manifest(source, lambda release: release.update({field: value}))
                with self.assertRaisesRegex(ValueError, "metadata"):
                    validate_assets(source)
                (source / "release.json").write_bytes(original)
        for signing in ("debug-test-only", None, ""):
            with self.subTest(signing=signing):
                self.mutate_manifest(source, lambda release: [item.update(signing=signing)
                    for item in release["artifacts"] if item["platform"] == "android"])
                with self.assertRaisesRegex(ValueError, "release-keystore"):
                    validate_assets(source)
        self.assertFalse((self.root / "clean").exists())

    def test_github_asset_size_limit_is_checked_locally(self):
        source = self.packages()
        with patch("release_ci.MAX_ASSET_BYTES", 1), self.assertRaisesRegex(ValueError, "2 GiB"):
            validate_assets(source)

    def test_release_notes_include_scope_signing_and_commit_pinned_links(self):
        self.changelog.write_text(self.changelog.read_text(encoding="utf-8") +
                                  "\n[Details](docs/example.md) [External](https://example.com)\n", encoding="utf-8")
        commit = "a" * 40
        notes = release_notes(VERSION, commit, "example/project", self.root)
        self.assertIn(f"https://github.com/example/project/blob/{commit}/docs/example.md", notes)
        self.assertIn("[External](https://example.com)", notes)
        self.assertIn("不代表真实登录", notes)
        self.assertIn("Android 使用发布密钥", notes)
        self.assertIn("本次发布为正式 Release", notes)
        self.assertIn("Windows x64 五种 Sisters 离线部署包", notes)
        self.assertNotIn("标记为预发布", notes)
        self.assertIn(f"{VERSION}+{BUILD}", notes)


if __name__ == "__main__":
    unittest.main()
