"""Check Docker COPY inputs satisfy the runtime builder's Python imports."""
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

from release_config import ROOT


class RuntimeContainerTests(unittest.TestCase):
    def test_copied_builder_can_load_its_entrypoint(self):
        with tempfile.TemporaryDirectory(prefix="misaka-container-contract-") as directory:
            root = Path(directory)
            entrypoint = None
            for line in (ROOT / "scripts/Dockerfile.runtime").read_text().splitlines():
                if line.startswith("COPY "):
                    source, target = shlex.split(line)[1:]
                    matches = list(ROOT.glob(source))
                    self.assertTrue(matches, "Docker COPY source must exist")
                    destination = root / target.lstrip("/")
                    for path in matches:
                        if path.is_dir():
                            shutil.copytree(path, destination, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
                        else:
                            output = destination / path.name if target.endswith("/") else destination
                            output.parent.mkdir(parents=True, exist_ok=True)
                            shutil.copy2(path, output)
                elif line.startswith("ENTRYPOINT "):
                    entrypoint = json.loads(line.removeprefix("ENTRYPOINT "))
            self.assertIsNotNone(entrypoint)
            result = subprocess.run([sys.executable, str(root / entrypoint[1].lstrip("/")), "--help"],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("--verify-existing", result.stdout)


if __name__ == "__main__":
    unittest.main()
