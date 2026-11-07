"""Unified-release assembly and Android signing fail closed on incomplete input."""
import json
from pathlib import Path
import tempfile
import unittest

from check_release import verify_release
from package_android import SIGNING_KEYS, signing_mode, stage_bundles
from release_config import APP_TARGETS, BUILD, RELEASE_DATE, artifact_name
from release_manifest import merge_releases, record_artifact
from test_check_release import app_archive
import test_index_bundles
from release_config import TARGETS, android_bundle_asset


class ReleaseManifestTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="misaka-manifest-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def stage(self, targets):
        directories = []
        for target in targets:
            directory = self.root / target
            directory.mkdir(exist_ok=True)
            file = directory / artifact_name(target)
            file.write_bytes(app_archive(target=target))
            platform, arch = target.split("-")
            record_artifact(file, platform, arch, signing="synthetic-test")
            directories.append(directory)
        return directories

    def test_complete_aggregation_is_verified(self):
        inputs = self.stage(APP_TARGETS)
        output = self.root / "complete"
        release = merge_releases(inputs, output)
        self.assertEqual(len(release["artifacts"]), len(APP_TARGETS))
        self.assertEqual(release["status"], "built-not-business-validated")
        self.assertEqual(release["missing_targets"], [])
        self.assertEqual(release["date"], RELEASE_DATE)
        self.assertEqual(verify_release(output, [])["build"], BUILD)

    def test_partial_build_records_missing_targets_and_incomplete_status(self):
        directory = self.stage(APP_TARGETS[:1])[0]
        release = json.loads((directory / "release.json").read_text())
        self.assertEqual(release["status"], "incomplete")
        self.assertEqual(release["missing_targets"], list(APP_TARGETS[1:]))
        self.assertEqual(release["date"], RELEASE_DATE)

    def test_incomplete_status_clears_only_after_last_supported_target(self):
        directory = self.root / "all"
        directory.mkdir()
        for index, target in enumerate(APP_TARGETS):
            file = directory / artifact_name(target)
            file.write_bytes(app_archive(target=target))
            platform, arch = target.split("-")
            release = record_artifact(file, platform, arch, signing="synthetic-test")
            self.assertEqual(release["status"], "incomplete" if index + 1 < len(APP_TARGETS) else "built-not-business-validated")
            self.assertEqual(release["missing_targets"], list(APP_TARGETS[index + 1:]))

    def test_missing_and_duplicate_targets_do_not_publish_manifest(self):
        inputs = self.stage(APP_TARGETS)
        for candidates, message in ((inputs[:-1], "all supported"), (inputs + inputs[:1], "Duplicate")):
            with self.subTest(message=message):
                output = self.root / "incomplete"
                with self.assertRaisesRegex(ValueError, message):
                    merge_releases(candidates, output)
                self.assertFalse((output / "release.json").exists())

    def test_mixed_version_record_is_rejected(self):
        directory = self.stage(APP_TARGETS[:1])[0]
        manifest = directory / "release.json"
        data = json.loads(manifest.read_text())
        data["version"] = "0.1.4"
        manifest.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "different releases"):
            record_artifact(directory / artifact_name(APP_TARGETS[0]), "macos", "amd64", signing="test")

    def test_android_assets_keep_original_gzip_payload_under_opaque_name(self):
        source = self.root / "bundles"
        source.mkdir()
        fixture = test_index_bundles.BundleIndexTests()
        fixture.directory = source
        for target in TARGETS:
            fixture.write_bundle(target)
        assets = self.root / "android-assets"
        assets.mkdir()
        (assets / "obsolete.tar.gz").write_bytes(b"stale asset")
        stage_bundles(source, assets)
        self.assertFalse((assets / "obsolete.tar.gz").exists())
        index = json.loads((assets / "bundles.json").read_text())
        for item in index["artifacts"]:
            asset = assets / android_bundle_asset(item["name"])
            self.assertEqual(asset.read_bytes(), (source / item["name"]).read_bytes())
            self.assertTrue(asset.read_bytes().startswith(b"\x1f\x8b"))
            self.assertTrue((assets / (item["name"] + ".sha256")).is_file())
            self.assertFalse((assets / item["name"]).exists())

    def test_android_signing_is_explicit_and_complete(self):
        with self.assertRaisesRegex(ValueError, "requires signing"):
            signing_mode({}, False)
        self.assertEqual(signing_mode({}, True), "debug-test-only")
        with self.assertRaisesRegex(ValueError, "all four|All four"):
            signing_mode({SIGNING_KEYS[0]: "missing"}, True)
        keystore = self.root / "test.keystore"
        env = dict(zip(SIGNING_KEYS, (str(keystore), "synthetic", "test", "synthetic")))
        with self.assertRaisesRegex(ValueError, "does not exist"):
            signing_mode(env, False)
        keystore.write_bytes(b"synthetic test key placeholder")
        self.assertEqual(signing_mode(env, False), "release-keystore")


if __name__ == "__main__":
    unittest.main()
