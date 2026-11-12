"""Exercise publication using a fake GitHub CLI; never access the network."""
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import publish_release
from release_config import VERSION


COMMIT = "a" * 40
REPOSITORY = "example/misaka"
TAG = "v" + VERSION


class FakeGitHub:
    def __init__(self, directory):
        self.directory = directory
        self.calls = []
        self.releases = []
        self.assets = []
        self.upload_failure = False
        self.list_failure = False
        self.asset_change = None
        self.move_tag_after_upload = False
        self.annotated = False
        self.note_content = None

    def run(self, command):
        self.calls.append(command)
        if command[0] == "git":
            return COMMIT
        if command[:2] == ["gh", "api"]:
            endpoint = command[4]
            if "/git/ref/tags/" in endpoint:
                sha = "b" * 40 if self.annotated else COMMIT
                if self.move_tag_after_upload and self.assets:
                    sha = "c" * 40
                return json.dumps({"ref": "refs/tags/" + TAG,
                                   "object": {"type": "tag" if self.annotated else "commit", "sha": sha}})
            if "/git/tags/" in endpoint:
                return json.dumps({"object": {"type": "commit", "sha": COMMIT}})
            if endpoint.endswith("/releases?per_page=100"):
                if self.list_failure:
                    raise subprocess.CalledProcessError(1, command, stderr="synthetic network failure")
                return json.dumps([[], self.releases])
            if endpoint.endswith("/releases/123/assets?per_page=100"):
                assets = copy.deepcopy(self.assets)
                if self.asset_change:
                    self.asset_change(assets)
                return json.dumps([assets])
            if endpoint.endswith("/releases/123"):
                return json.dumps(self.releases[0])
            raise AssertionError("Unexpected endpoint: " + endpoint)
        if command[:3] == ["gh", "release", "create"]:
            self.note_content = Path(command[command.index("--notes-file") + 1]).read_text(encoding="utf-8")
            self.releases = [{"id": 123, "tag_name": TAG, "draft": True,
                              "prerelease": False}]
            return "https://github.com/example/misaka/releases/tag/" + TAG
        if command[:3] == ["gh", "release", "upload"]:
            if self.upload_failure:
                raise subprocess.CalledProcessError(1, command, stderr="synthetic upload failure")
            for name in publish_release.release_asset_names():
                path = self.directory / name
                self.assets.append({"name": name, "size": path.stat().st_size, "state": "uploaded",
                                    "digest": "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()})
            return ""
        if command[:3] == ["gh", "release", "edit"]:
            self.releases[0]["draft"] = False
            return ""
        raise AssertionError("Unexpected command: " + repr(command))

    def mutations(self, operation):
        return [call for call in self.calls if call[:3] == ["gh", "release", operation]]


class PublishReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="misaka-publish-test-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        for name in publish_release.release_asset_names():
            (self.directory / name).write_bytes(("synthetic " + name).encode())
        self.github = FakeGitHub(self.directory)
        self.runner = patch.object(publish_release, "run_command", side_effect=self.github.run).start()
        self.validation = patch.object(publish_release, "validate_assets", return_value={}).start()
        self.notes = patch.object(publish_release, "release_notes", return_value="模拟发布说明\n").start()
        self.addCleanup(patch.stopall)

    def publish(self, **changes):
        arguments = dict(tag=TAG, repository=REPOSITORY, commit=COMMIT)
        arguments.update(changes)
        publish_release.publish(self.directory, **arguments)

    def test_publishes_only_exact_assets_after_remote_verification(self):
        self.publish()
        self.validation.assert_called_once_with(self.directory)
        self.assertEqual(self.github.note_content, "模拟发布说明\n")
        create = self.github.mutations("create")[0]
        self.assertIn("--verify-tag", create)
        self.assertIn("--draft", create)
        self.assertIn("--prerelease=false", create)
        self.assertNotIn("--prerelease", create)
        self.assertNotIn("--latest=false", create)
        upload = self.github.mutations("upload")[0]
        self.assertEqual(upload[6:], [str((self.directory / name).resolve())
                                     for name in publish_release.release_asset_names()])
        self.assertNotIn("--clobber", upload)
        self.assertFalse(any("*" in argument for argument in upload))
        self.assertEqual(len(self.github.mutations("edit")), 1)
        self.assertIn("--prerelease=false", self.github.mutations("edit")[0])
        self.assertIn("--latest", self.github.mutations("edit")[0])
        self.assertFalse(self.github.releases[0]["draft"])
        self.assertFalse(self.github.releases[0]["prerelease"])

    def test_unexpected_prerelease_draft_prevents_upload(self):
        real = self.github.run
        def run(command):
            result = real(command)
            if command[:3] == ["gh", "release", "create"]:
                self.github.releases[0]["prerelease"] = True
            return result
        self.runner.side_effect = run
        with self.assertRaisesRegex(ValueError, "unambiguous draft"):
            self.publish()
        self.assertEqual(self.github.mutations("upload"), [])
        self.assertEqual(self.github.mutations("edit"), [])

    def test_prerelease_change_during_upload_prevents_publication(self):
        real = self.github.run
        def run(command):
            result = real(command)
            if command[:3] == ["gh", "release", "upload"]:
                self.github.releases[0]["prerelease"] = True
            return result
        self.runner.side_effect = run
        with self.assertRaisesRegex(ValueError, "Release changed"):
            self.publish()
        self.assertTrue(self.github.releases[0]["draft"])
        self.assertEqual(self.github.mutations("edit"), [])

    def test_published_prerelease_is_not_reported_as_success(self):
        real = self.github.run
        def run(command):
            result = real(command)
            if command[:3] == ["gh", "release", "edit"]:
                self.github.releases[0]["prerelease"] = True
            return result
        self.runner.side_effect = run
        with self.assertRaisesRegex(ValueError, "published release state"):
            self.publish()

    def test_annotated_tag_resolves_to_same_commit(self):
        self.github.annotated = True
        self.publish()
        self.assertTrue(any("/git/tags/" in " ".join(call) for call in self.github.calls))

    def test_invalid_identity_fails_before_any_commands(self):
        for changes in ({"tag": "v9.9.9"}, {"repository": "--repo=elsewhere"},
                        {"repository": "example/repo\nother"}, {"commit": "short"}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.publish(**changes)
        self.assertEqual(self.github.calls, [])

    def test_checkout_mismatch_prevents_remote_calls(self):
        self.runner.side_effect = lambda command: "b" * 40
        with self.assertRaisesRegex(ValueError, "Local checkout"):
            self.publish()
        self.assertEqual(self.runner.call_count, 1)

    def test_invalid_assets_prevent_remote_calls(self):
        self.validation.side_effect = ValueError("Invalid assets")
        with self.assertRaisesRegex(ValueError, "Invalid assets"):
            self.publish()
        self.assertTrue(all(call[0] == "git" for call in self.github.calls))

    def test_existing_published_release_is_never_modified(self):
        self.github.releases = [{"tag_name": VERSION, "draft": False}]
        with self.assertRaisesRegex(ValueError, "published release already exists"):
            self.publish()
        self.assertEqual(self.github.mutations("create"), [])
        self.assertEqual(self.github.mutations("upload"), [])
        self.assertEqual(self.github.mutations("edit"), [])

    def test_existing_draft_requires_explicit_review_before_retry(self):
        self.github.releases = [{"tag_name": TAG, "draft": True}]
        with self.assertRaisesRegex(ValueError, "draft must be reviewed"):
            self.publish()
        self.assertEqual(self.github.mutations("create"), [])

    def test_network_error_is_not_treated_as_a_missing_release(self):
        self.github.list_failure = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.assertEqual(self.github.mutations("create"), [])

    def test_failed_upload_keeps_draft_unpublished(self):
        self.github.upload_failure = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.assertTrue(self.github.releases[0]["draft"])
        self.assertEqual(self.github.mutations("edit"), [])

    def test_changed_remote_tag_prevents_publication(self):
        self.github.move_tag_after_upload = True
        with self.assertRaisesRegex(ValueError, "no longer matches"):
            self.publish()
        self.assertTrue(self.github.releases[0]["draft"])
        self.assertEqual(self.github.mutations("edit"), [])

    def test_missing_extra_duplicate_and_corrupt_assets_keep_draft(self):
        alterations = {
            "missing": lambda assets: assets.pop(),
            "extra": lambda assets: assets.append({"name": "build.log"}),
            "duplicate": lambda assets: assets.__setitem__(0, assets[1]),
            "size": lambda assets: assets[0].update(size=0),
            "digest": lambda assets: assets[0].update(digest="sha256:" + "0" * 64),
            "missing digest": lambda assets: assets[0].pop("digest"),
            "upload state": lambda assets: assets[0].update(state="starter"),
        }
        for name, change in alterations.items():
            with self.subTest(name=name):
                self.github.releases = []
                self.github.assets = []
                self.github.calls = []
                self.github.asset_change = change
                with self.assertRaisesRegex(ValueError, "asset"):
                    self.publish()
                self.assertTrue(self.github.releases[0]["draft"])
                self.assertEqual(self.github.mutations("edit"), [])

    def test_missing_remote_tag_never_creates_release(self):
        real = self.github.run
        def run(command):
            if "/git/ref/tags/" in " ".join(command):
                raise subprocess.CalledProcessError(1, command, stderr="synthetic 404")
            return real(command)
        self.runner.side_effect = run
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.assertEqual(self.github.mutations("create"), [])


if __name__ == "__main__":
    unittest.main()
