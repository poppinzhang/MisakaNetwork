"""Machine-readable release files keep LF bytes even with Windows text defaults."""
from contextlib import redirect_stdout
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import build_bundles
from release_config import BILI_VERSION, VERSION, artifact_name
from release_manifest import record_artifact
from test_windows_binary import pe_binary


native_path_open = Path.open


def windows_text_open(path, mode="r", buffering=-1, encoding=None, errors=None, newline=None):
    # Emulate Windows newline translation on any test host. Explicit newline
    # arguments keep their real behavior, so this exercises the on-disk bytes.
    if "w" in mode and "b" not in mode and newline is None:
        newline = "\r\n"
    return native_path_open(path, mode, buffering, encoding, errors, newline)


class ManifestNewlineTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="misaka-manifest-newlines-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def assert_lf(self, data):
        self.assertIn(b"\n", data)
        self.assertNotIn(b"\r", data)

    def test_bundle_archive_index_and_sidecar_use_lf_with_windows_defaults(self):
        runtime_root = self.root / "runtimes"
        runtime = runtime_root / "windows-amd64/misaka-runtime"
        runtime.mkdir(parents=True)
        (runtime / "misaka-runtime.exe").write_bytes(pe_binary())
        (runtime / "RUNTIME-MANIFEST.json").write_text(json.dumps(dict(
            version=VERSION, bili_version=BILI_VERSION, platform="windows", arch="amd64", protocol=1)),
            encoding="utf-8")
        output = self.root / "bundles"

        def compile_go(command, **kwargs):
            Path(command[command.index("-o") + 1]).write_bytes(pe_binary())
            return subprocess.CompletedProcess(command, 0)

        arguments = ["build_bundles.py", "--runtime-root", str(runtime_root),
                     "--output", str(output), "--targets", "windows-amd64"]
        with patch.object(Path, "open", windows_text_open), \
                patch.object(build_bundles.subprocess, "run", side_effect=compile_go), \
                patch.object(sys, "argv", arguments), redirect_stdout(io.StringIO()):
            control = self.root / "host-default.txt"
            control.write_text("host newline\n", encoding="utf-8")
            self.assertEqual(control.read_bytes(), b"host newline\r\n")
            build_bundles.main()

        package = output / "windows-amd64.tar.gz"
        checksum = hashlib.sha256(package.read_bytes()).hexdigest()
        self.assertEqual((output / (package.name + ".sha256")).read_bytes(),
                         f"{checksum}  {package.name}\n".encode())
        self.assert_lf((output / "bundles.json").read_bytes())
        with tarfile.open(package) as archive:
            self.assert_lf(archive.extractfile("manifest.json").read())

    def test_release_manifest_and_checksums_use_lf_with_windows_defaults(self):
        package = self.root / artifact_name("windows-amd64")
        package.write_bytes(b"synthetic release package")
        with patch.object(Path, "open", windows_text_open):
            record_artifact(package, "windows", "amd64", signing="synthetic-test")
        checksum = hashlib.sha256(package.read_bytes()).hexdigest()
        expected = f"{checksum}  {package.name}\n".encode()
        self.assertEqual((self.root / (package.name + ".sha256")).read_bytes(), expected)
        self.assertEqual((self.root / "SHA256SUMS").read_bytes(), expected)
        self.assert_lf((self.root / "release.json").read_bytes())


if __name__ == "__main__":
    unittest.main()
