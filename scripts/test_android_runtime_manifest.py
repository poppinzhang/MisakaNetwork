"""Offline checks for missing Python payloads and incompatible Android ELFs."""
import io
import hashlib
import json
import struct
import unittest
import zipfile

from android_runtime_manifest import (
    ASSETS, CLIENT_MODULES, DEPENDENCY_LOCK, DEPENDENCY_MODULES, PYTHON_LIBRARIES,
    locked_dependencies, verify_android_runtime, verify_elf,
)


def elf_binary(abi="arm64-v8a", alignment=16384):
    data = bytearray(128)
    data[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HHI", data, 16, 3, {"arm64-v8a": 183, "x86_64": 62}[abi], 1)
    struct.pack_into("<Q", data, 32, 64)
    struct.pack_into("<HHH", data, 52, 64, 56, 1)
    struct.pack_into("<IIQQQQQQ", data, 64, 1, 5, 0, 0, 0, len(data), len(data), alignment)
    return bytes(data)


def python_archive(files):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in files.items():
            archive.writestr(name, data)
    return output.getvalue()


def runtime_assets(abi, bili_version, *, omit=None, bytecode=False):
    app = {name + ("c" if bytecode else ""): b"synthetic module" for name in CLIENT_MODULES}
    app["UPSTREAM_MANIFEST.json"] = json.dumps({"version": bili_version, "files": [
        {"path": "interface/auth.py"}, {"path": "LICENSE"},
    ]})
    app["LICENSE"] = b"synthetic license"
    app["requirements-android.lock"] = DEPENDENCY_LOCK.read_bytes()
    requirements = {name + ("c" if bytecode else ""): b"synthetic module" for name in DEPENDENCY_MODULES}
    requirements["certifi/cacert.pem"] = b"-----BEGIN CERTIFICATE-----\nsynthetic"
    for line in DEPENDENCY_LOCK.read_text().splitlines():
        if line.strip() and not line.lstrip().startswith("#"):
            name, version = line.split("==")
            requirements[f"{name}-{version}.dist-info/METADATA"] = f"Name: {name}\nVersion: {version}\n".encode()
    for files in (app, requirements):
        files.pop(omit, None)
    assets = {f"lib/{abi}/{name}": elf_binary(abi) for name in PYTHON_LIBRARIES}
    for name, files in {
        "app.imy": app,
        "requirements-common.imy": requirements,
        "bootstrap.imy": {"importer.pyc": b"synthetic module"},
        "stdlib-common.imy": {"json/__init__.pyc": b"synthetic module"},
        f"stdlib-{abi}.imy": {"_ssl.cpython-311.so": elf_binary(abi)},
    }.items():
        assets[ASSETS + name] = python_archive(files)
    assets.pop(omit, None)
    update_build_manifest(assets)
    return assets


def update_build_manifest(assets):
    assets[ASSETS + "build.json"] = json.dumps({"python_version": "3.11", "assets": {
        name.removeprefix(ASSETS): hashlib.sha1(data).hexdigest()
        for name, data in assets.items() if name.startswith(ASSETS) and name != ASSETS + "build.json"
    }}).encode()


def make_apk(assets, *, stored_aligned=False):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in assets.items():
            if stored_aligned and name.startswith("lib/"):
                info = zipfile.ZipInfo(name)
                padding = (-(archive.fp.tell() + 30 + len(name.encode()))) % 16384
                if padding < 4:
                    padding += 16384
                info.extra = struct.pack("<HH", 0xCAFE, padding - 4) + bytes(padding - 4)
                archive.writestr(info, data)
            else:
                archive.writestr(name, data)
    return output.getvalue()


class AndroidRuntimeManifestTests(unittest.TestCase):
    def verify(self, assets, abi="arm64-v8a", **kwargs):
        with zipfile.ZipFile(io.BytesIO(make_apk(assets, **kwargs))) as archive:
            verify_android_runtime(archive, abi, "synthetic-version")

    def test_both_abis_source_bytecode_and_aligned_stored_libraries(self):
        for abi in ("arm64-v8a", "x86_64"):
            for bytecode in (False, True):
                with self.subTest(abi=abi, bytecode=bytecode):
                    self.verify(runtime_assets(abi, "synthetic-version", bytecode=bytecode), abi, stored_aligned=True)

    def test_lock_comparison_ignores_checkout_line_endings_and_normalizes_names(self):
        self.assertEqual(locked_dependencies(b"# comment\r\nTyping_Extensions==4.16.0\r\n"),
                         locked_dependencies(b"typing-extensions==4.16.0\n"))

    def test_missing_runtime_client_dependencies_and_ca_fail(self):
        for omit in (f"lib/arm64-v8a/{PYTHON_LIBRARIES[0]}", ASSETS + "app.imy",
                     ASSETS + "stdlib-arm64-v8a.imy", "android_bridge.py",
                     "interface/auth.py", "qrcode/image/pure.py", "png.py",
                     "httpx/__init__.py", "h2/__init__.py", "socksio/__init__.py",
                     "certifi/cacert.pem", "LICENSE", "UPSTREAM_MANIFEST.json"):
            with self.subTest(omit=omit), self.assertRaisesRegex(ValueError, "missing"):
                self.verify(runtime_assets("arm64-v8a", "synthetic-version", omit=omit))

    def test_wrong_upstream_version_fails(self):
        with self.assertRaisesRegex(ValueError, "version mismatch"):
            self.verify(runtime_assets("arm64-v8a", "wrong-version"))

    def test_invalid_wrong_abi_and_4k_elf_fail(self):
        for data in (b"not ELF", elf_binary()[:80], elf_binary("x86_64"), elf_binary(alignment=4096)):
            with self.subTest(data=data[:7]), self.assertRaises(ValueError):
                verify_elf(data, "arm64-v8a", "synthetic.so")

    def test_misaligned_load_offset_fails(self):
        data = bytearray(elf_binary())
        struct.pack_into("<Q", data, 80, 4096)  # p_vaddr
        with self.assertRaisesRegex(ValueError, "16 KB"):
            verify_elf(data, "arm64-v8a", "synthetic.so")

    def test_native_python_extension_alignment_is_verified(self):
        assets = runtime_assets("arm64-v8a", "synthetic-version")
        assets[ASSETS + "stdlib-arm64-v8a.imy"] = python_archive({"_ssl.so": elf_binary(alignment=4096)})
        update_build_manifest(assets)
        with self.assertRaisesRegex(ValueError, "16 KB"):
            self.verify(assets)

    def test_corrupt_payload_is_rejected_against_build_manifest(self):
        assets = runtime_assets("arm64-v8a", "synthetic-version")
        assets[ASSETS + "app.imy"] = b"corrupt"
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.verify(assets)

    def test_missing_locked_distribution_metadata_is_rejected(self):
        assets = runtime_assets("arm64-v8a", "synthetic-version", omit="httpx-0.28.1.dist-info/METADATA")
        with self.assertRaisesRegex(ValueError, "dependency version mismatch: httpx"):
            self.verify(assets)

    def test_empty_upstream_manifest_and_stale_lock_are_rejected(self):
        for entry, replacement, error in (
            ("UPSTREAM_MANIFEST.json", json.dumps({"version": "synthetic-version", "files": []}).encode(), "manifest is empty"),
            ("requirements-android.lock", b"outdated-lock", "dependency lock mismatch"),
        ):
            assets = runtime_assets("arm64-v8a", "synthetic-version")
            with zipfile.ZipFile(io.BytesIO(assets[ASSETS + "app.imy"])) as app:
                files = {name: app.read(name) for name in app.namelist()}
            files[entry] = replacement
            assets[ASSETS + "app.imy"] = python_archive(files)
            update_build_manifest(assets)
            with self.subTest(entry=entry), self.assertRaisesRegex(ValueError, error):
                self.verify(assets)

    def test_bootstrap_native_library_alignment_is_verified(self):
        assets = runtime_assets("arm64-v8a", "synthetic-version")
        assets[ASSETS + "bootstrap-native/arm64-v8a/java/chaquopy.so"] = elf_binary(alignment=4096)
        update_build_manifest(assets)
        with self.assertRaisesRegex(ValueError, "16 KB"):
            self.verify(assets)

    def test_stored_native_library_requires_zip_alignment(self):
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w") as archive:
            for name, data in runtime_assets("arm64-v8a", "synthetic-version").items():
                archive.writestr(name, data)
        with zipfile.ZipFile(io.BytesIO(output.getvalue())) as archive:
            with self.assertRaisesRegex(ValueError, "APK library is not 16 KB"):
                verify_android_runtime(archive, "arm64-v8a", "synthetic-version")


if __name__ == "__main__":
    unittest.main()
