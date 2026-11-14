"""Offline bundles preserve the native runtime and select the target Go binary."""
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from build_bundles import build
from release_config import BILI_VERSION, TARGETS, VERSION
from test_windows_binary import pe_binary


class BuildBundleTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="misaka-build-bundle-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.runtime_root = self.root / "runtimes"
        self.output = self.root / "bundles"

    def native_runtime(self, target):
        platform, arch = target.split("-")
        runtime = self.runtime_root / target / "misaka-runtime"
        runtime.mkdir(parents=True)
        executable = "misaka-runtime.exe" if platform == "windows" else "misaka-runtime"
        (runtime / executable).write_bytes(pe_binary() if platform == "windows" else b"synthetic native runtime")
        (runtime / "_internal").mkdir()
        (runtime / "_internal/dependency").write_bytes(b"synthetic bundled dependency")
        (runtime / "RUNTIME-MANIFEST.json").write_text(json.dumps(dict(
            version=VERSION, bili_version=BILI_VERSION, platform=platform, arch=arch, protocol=1)))
        return runtime

    def test_every_target_has_the_correct_executable_and_complete_runtime(self):
        self.assertIn("windows-amd64", TARGETS)
        for target in TARGETS:
            with self.subTest(target=target):
                platform, arch = target.split("-")
                self.native_runtime(target)
                executable = "sisters.exe" if platform == "windows" else "sisters"

                def compile_go(command, *, cwd, env, check):
                    self.assertEqual(env["GOOS"], "darwin" if platform == "macos" else platform)
                    self.assertEqual(env["GOARCH"], arch)
                    self.assertEqual(env["CGO_ENABLED"], "0")
                    self.assertIn("-trimpath", command)
                    binary = Path(command[command.index("-o") + 1])
                    self.assertEqual(binary.name, executable)
                    binary.write_bytes(pe_binary() if platform == "windows" else b"synthetic Sisters executable")
                    return subprocess.CompletedProcess(command, 0)

                with patch("build_bundles.subprocess.run", side_effect=compile_go) as run:
                    result = build(target, self.runtime_root, self.output)
                run.assert_called_once()
                path = self.output / (target + ".tar.gz")
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
                self.assertEqual(result["sha256"], digest)
                self.assertEqual(result["bytes"], path.stat().st_size)
                self.assertEqual((self.output / (path.name + ".sha256")).read_text(),
                                 f"{digest}  {path.name}\n")
                with tarfile.open(path) as archive:
                    self.assertEqual(archive.extractfile(executable).read(),
                                     pe_binary() if platform == "windows" else b"synthetic Sisters executable")
                    runtime_executable = "misaka-runtime.exe" if platform == "windows" else "misaka-runtime"
                    self.assertEqual(archive.extractfile("runtime/" + runtime_executable).read(),
                                     pe_binary() if platform == "windows" else b"synthetic native runtime")
                    self.assertEqual(archive.extractfile("runtime/_internal/dependency").read(),
                                     b"synthetic bundled dependency")
                    self.assertIn("NOTICE.txt", archive.getnames())
                    self.assertIn("BILITICKERBUY-LICENSE.txt", archive.getnames())
                    manifest = json.load(archive.extractfile("manifest.json"))
                    self.assertEqual(manifest, dict(version=VERSION, bili_version=BILI_VERSION,
                                                    platform=platform, arch=arch))
                    self.assertTrue(all(member.uid == member.gid == 0 and
                                        member.uname == member.gname == "" for member in archive.getmembers()))

    def test_windows_stale_or_missing_runtime_fails_before_compiling(self):
        runtime = self.native_runtime("windows-amd64")
        for missing in ("RUNTIME-MANIFEST.json", "misaka-runtime.exe"):
            with self.subTest(missing=missing):
                path = runtime / missing
                original = path.read_bytes()
                path.unlink()
                with patch("build_bundles.subprocess.run") as run, self.assertRaises(ValueError):
                    build("windows-amd64", self.runtime_root, self.output)
                run.assert_not_called()
                self.assertFalse(self.output.exists())
                path.write_bytes(original)

    def test_unsupported_windows_architecture_is_rejected(self):
        with patch("build_bundles.subprocess.run") as run, self.assertRaisesRegex(ValueError, "Unsupported"):
            build("windows-arm64", self.runtime_root, self.output)
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
