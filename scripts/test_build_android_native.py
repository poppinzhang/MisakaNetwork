"""Validate Android source staging without requiring an Android SDK."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import build_android_native


class AndroidSourceStagingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="misaka-android-source-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.runtime = self.root / "runtime"
        self.vendor = self.runtime / "vendor/biliTickerBuy"
        self.vendor.mkdir(parents=True)
        self.source = self.vendor / "interface.py"
        self.source.write_bytes(b"# synthetic upstream source\n")
        self.manifest = {"files": [{"path": "interface.py", "sha256": hashlib.sha256(self.source.read_bytes()).hexdigest()}]}
        self.write_manifest()
        for name in ("bridge.py", "android_bridge.py", "requirements-android.lock", "NOTICE.txt"):
            (self.runtime / name).write_text("synthetic " + name)
        self.project = self.root / "LastOrder"
        self.target = self.project / "android/app/src/main/python"
        self.target.mkdir(parents=True)
        (self.target / "previous.py").write_text("keep me until validation succeeds")
        self.patcher = patch.object(build_android_native, "ROOT", self.root)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)

    def write_manifest(self):
        (self.vendor / "MANIFEST.json").write_text(json.dumps(self.manifest))

    def assert_rejected_preserving_existing(self, message):
        with self.assertRaisesRegex(ValueError, message):
            build_android_native.stage_python(self.project)
        self.assertTrue((self.target / "previous.py").is_file())
        self.assertFalse(self.target.with_name("python.pending").exists())

    def test_verified_upstream_and_locked_dependencies_are_staged(self):
        build_android_native.stage_python(self.project)
        self.assertEqual((self.target / "interface.py").read_bytes(), self.source.read_bytes())
        self.assertEqual((self.target / "requirements-android.lock").read_text(), "synthetic requirements-android.lock")
        self.assertFalse((self.target / "previous.py").exists())

    def test_tampered_upstream_hash_is_rejected(self):
        self.source.write_text("changed upstream content")
        self.assert_rejected_preserving_existing("hash mismatch")

    def test_upstream_symlink_is_rejected(self):
        self.source.unlink()
        self.source.symlink_to(self.runtime / "bridge.py")
        self.assert_rejected_preserving_existing("hash mismatch")

    def test_manifest_path_traversal_is_rejected(self):
        for path in ("../outside.py", "/outside.py", "interface/../../outside.py"):
            with self.subTest(path=path):
                self.manifest["files"][0]["path"] = path
                self.write_manifest()
                self.assert_rejected_preserving_existing("unsafe upstream manifest path")


if __name__ == "__main__":
    unittest.main()
