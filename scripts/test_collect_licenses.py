import io
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from collect_licenses import ASSET, INPUTS, MANIFEST, ROOT, SUPPLEMENTS, Inventory, validate, validate_coverage


class LicenseCollectionTests(unittest.TestCase):
    def test_committed_inventory_matches_inputs_and_all_locked_dependencies(self):
        validate()

    def test_original_bili_notice_and_license_are_included_verbatim(self):
        entries = json.loads((ROOT / ASSET).read_text(encoding="utf-8"))
        bili = next(entry["text"] for entry in entries if entry["packages"] == ["biliTickerBuy"])
        for name in ("runtime/NOTICE.txt", "runtime/vendor/biliTickerBuy/LICENSE"):
            self.assertIn((ROOT / name).read_text(encoding="utf-8").strip(), bili)

    def test_stale_dependency_and_modified_asset_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = [*INPUTS, ASSET, MANIFEST,
                     *("scripts/license_sources/" + data[0] for data in SUPPLEMENTS.values())]
            for name in paths:
                destination = root / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes((ROOT / name).read_bytes())
            validate(root)
            (root / "go.mod").write_text("module changed\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "inputs changed"):
                validate(root)
            (root / "go.mod").write_bytes((ROOT / "go.mod").read_bytes())
            (root / ASSET).write_text("[]\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                validate(root)

    def test_missing_conditional_dependency_is_rejected(self):
        entries = json.loads((ROOT / ASSET).read_bytes())
        entries = [entry for entry in entries if entry["packages"] != ["colorama"]]
        with self.assertRaisesRegex(ValueError, "colorama"):
            validate_coverage(ROOT, json.dumps(entries).encode())

    def test_runtime_collection_preserves_native_notices_and_python(self):
        inventory = Inventory()
        inventory.runtime_file("Python-LICENSE.txt", b"Python license")
        inventory.runtime_file("python-native-libraries/zlib.txt", b"zlib notice")
        inventory.runtime_file("example/example.dist-info/LICENCE", b"MIT text")
        inventory.runtime_file("example/example.dist-info/METADATA", b"Do not show metadata")
        entries = json.loads(inventory.serialized())
        self.assertEqual({entry["packages"][0] for entry in entries},
                         {"Python", "Python native libraries", "example"})
        self.assertNotIn("Do not show metadata", inventory.serialized().decode())

    def test_old_runtime_inventory_cannot_refresh_new_dependency_license(self):
        inventory = Inventory()
        inventory.runtime_file("DEPENDENCIES.json", b'[{"name":"example", "version":"1.0"}]')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "runtime").mkdir()
            (root / "runtime/requirements.lock").write_text("example==2.0\n")
            (root / "runtime/requirements-android.lock").write_text("")
            with self.assertRaisesRegex(ValueError, "example==2.0"):
                inventory.validate_versions(root)
            inventory.record_version("example", "2.0")
            with self.assertRaisesRegex(ValueError, "example==2.0"):
                inventory.validate_versions(root)
            inventory.versions["example"] = {"2.0"}
            inventory.validate_versions(root)

    def test_android_nested_licenses_and_spelling_variants_are_deduplicated(self):
        with tempfile.TemporaryDirectory() as temporary:
            embedded = io.BytesIO()
            with zipfile.ZipFile(embedded, "w") as wheel:
                wheel.writestr("PySocks-1.7.1.dist-info/LICENSE", "same license\r\n")
                wheel.writestr("pypng-0.20220715.0.dist-info/LICENCE", "PNG license")
            apk = Path(temporary) / "app.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr("assets/chaquopy/requirements-common.imy", embedded.getvalue())
            inventory = Inventory()
            inventory.add("pysocks", b"same license\n")
            inventory.android_archive(apk)
            entries = json.loads(inventory.serialized())
            self.assertEqual(len(entries), 2)
            self.assertEqual(sum(entry["text"].count("same license") for entry in entries), 1)

    def test_invalid_archives_and_empty_licenses_fail(self):
        inventory = Inventory()
        with self.assertRaisesRegex(ValueError, "empty license"):
            inventory.add("example", b"\n")
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "empty.zip"
            with zipfile.ZipFile(archive, "w"):
                pass
            with self.assertRaisesRegex(ValueError, "no runtime license"):
                inventory.runtime_archive(archive)
            with self.assertRaisesRegex(ValueError, "no embedded Python"):
                inventory.android_archive(archive)


if __name__ == "__main__":
    unittest.main()
