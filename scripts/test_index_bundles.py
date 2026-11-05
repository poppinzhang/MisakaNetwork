import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

from build_bundles import BILI_VERSION, TARGETS, VERSION
from index_bundles import index_bundles


class BundleIndexTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="misaka-bundle-index-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        for target in TARGETS:
            self.write_bundle(target)
        self.index = self.directory / "bundles.json"
        self.index.write_text("existing index remains until all inputs pass\n")

    def write_bundle(self, target, version=VERSION, platform_override=None, duplicate=False):
        platform, arch = target.split("-")
        data = json.dumps(dict(version=version, bili_version=BILI_VERSION,
                               platform=platform_override or platform, arch=arch)).encode()
        path = self.directory / (target + ".tar.gz")
        with tarfile.open(path, "w:gz") as archive:
            for _ in range(2 if duplicate else 1):
                member = tarfile.TarInfo("manifest.json")
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        (self.directory / (path.name + ".sha256")).write_text(f"{digest}  {path.name}\n")

    def assert_rejected(self, message):
        original = self.index.read_bytes()
        with self.assertRaisesRegex(ValueError, message):
            index_bundles(self.directory)
        self.assertEqual(self.index.read_bytes(), original)

    def test_all_supported_platforms(self):
        index = index_bundles(self.directory)
        self.assertEqual(index["version"], VERSION)
        self.assertEqual(index["bili_version"], BILI_VERSION)
        self.assertEqual(len(index["artifacts"]), len(TARGETS))
        self.assertEqual(json.loads(self.index.read_text()), index)
        for item in index["artifacts"]:
            data = (self.directory / item["name"]).read_bytes()
            self.assertEqual(item["bytes"], len(data))
            self.assertEqual(item["sha256"], hashlib.sha256(data).hexdigest())

    def test_missing_bundle(self):
        (self.directory / (TARGETS[-1] + ".tar.gz")).unlink()
        self.assert_rejected("Required regular bundle")

    def test_mixed_versions(self):
        self.write_bundle(TARGETS[-1], version="0.1.0")
        self.assert_rejected("version or platform mismatch")

    def test_checksum_mismatch(self):
        (self.directory / (TARGETS[-1] + ".tar.gz.sha256")).write_text("0" * 64 + "  invalid.tar.gz\n")
        self.assert_rejected("SHA-256 sidecar mismatch")

    def test_wrong_platform(self):
        self.write_bundle(TARGETS[-1], platform_override="unsupported")
        self.assert_rejected("version or platform mismatch")

    def test_duplicate_manifests(self):
        self.write_bundle(TARGETS[-1], duplicate=True)
        self.assert_rejected("manifest missing, duplicated or invalid")

    def test_input_symlink(self):
        path = self.directory / (TARGETS[-1] + ".tar.gz")
        moved = self.directory / "moved.tar.gz"
        path.rename(moved)
        path.symlink_to(moved.name)
        self.assert_rejected("Required regular bundle")


if __name__ == "__main__":
    unittest.main()
