import json
from pathlib import Path
import tempfile
import unittest

from release_config import BILI_VERSION, VERSION
from runtime_manifest import validate_runtime


class RuntimeManifestTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="misaka-runtime-manifest-test-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        (self.directory / "misaka-runtime").write_bytes(b"synthetic executable")
        self.expected = dict(version=VERSION, bili_version=BILI_VERSION, platform="linux", arch="amd64", protocol=1)

    def write(self, **overrides):
        (self.directory / "RUNTIME-MANIFEST.json").write_text(json.dumps(self.expected | overrides))

    def test_current_runtime_is_accepted(self):
        self.write()
        self.assertEqual(validate_runtime(self.directory, "linux-amd64"), self.expected)

    def test_cached_legacy_runtime_requires_rebuild(self):
        with self.assertRaisesRegex(ValueError, "manifest is missing"):
            validate_runtime(self.directory, "linux-amd64")
        self.write(version="0.1.1")
        with self.assertRaisesRegex(ValueError, "version or platform"):
            validate_runtime(self.directory, "linux-amd64")

    def test_wrong_architecture_and_dependency_version_are_rejected(self):
        for overrides in (dict(arch="arm64"), dict(platform="macos"), dict(bili_version="2.0.0"), dict(protocol=2)):
            with self.subTest(overrides=overrides):
                self.write(**overrides)
                with self.assertRaisesRegex(ValueError, "version or platform"):
                    validate_runtime(self.directory, "linux-amd64")

    def test_windows_requires_exe_suffix(self):
        self.write(platform="windows")
        with self.assertRaisesRegex(ValueError, "executable is missing"):
            validate_runtime(self.directory, "windows-amd64")
        (self.directory / "misaka-runtime").rename(self.directory / "misaka-runtime.exe")
        self.assertEqual(validate_runtime(self.directory, "windows-amd64")["platform"], "windows")


if __name__ == "__main__":
    unittest.main()
