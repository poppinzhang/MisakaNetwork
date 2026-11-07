"""Release validation uses synthetic archives and never reads local credentials."""
import hashlib
import io
import json
from pathlib import Path
import plistlib
import tarfile
import tempfile
import unittest
import zipfile

from check_release import APP_CONTENTS, TARGETS, WINDOWS_CRT_DLLS, verify_release
from package_windows import validate_app_crt
from release_config import APP_TARGETS, BILI_VERSION, BUILD, VERSION, android_bundle_asset, artifact_name


def crt_binary(*, machine=0x8664, dll=True):
    data = bytearray(512)
    data[:2] = b"MZ"
    data[60:64] = (128).to_bytes(4, "little")
    data[128:132] = b"PE\0\0"
    data[132:134] = machine.to_bytes(2, "little")
    data[150:152] = (0x2000 if dll else 0).to_bytes(2, "little")
    data[152:154] = (0x20B).to_bytes(2, "little")
    return bytes(data)


def app_archive(*, target="macos-amd64", app_version=VERSION, build=str(BUILD), bundle_version=VERSION,
                bundle_platform=None, nested_sidecar=True, private_marker=False, missing_native=False,
                min_sdk=36, android_legacy_gzip_assets=False, missing_crt=None, misplaced_crt=False, crt_data=None):
    result = io.BytesIO()
    index = {"version": VERSION, "bili_version": BILI_VERSION, "artifacts": []}
    with zipfile.ZipFile(result, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        platform, arch = target.split("-")
        if platform == "macos":
            archive.writestr(APP_CONTENTS + "Info.plist", plistlib.dumps({
                "CFBundleShortVersionString": app_version, "CFBundleVersion": build}))
            prefix = APP_CONTENTS + "Resources/bundles/"
        elif platform == "windows":
            archive.writestr("LastOrder/resources/release-info.json", json.dumps(dict(
                version=app_version, build=int(build), platform=platform, arch=arch)))
            for name in ("LastOrder.exe", "flutter_windows.dll", "resources/misakactl.exe",
                         "resources/runtime/misaka-runtime.exe"):
                if not missing_native:
                    archive.writestr("LastOrder/" + name, b"synthetic native binary")
            for name in WINDOWS_CRT_DLLS:
                if name != missing_crt:
                    prefix = "LastOrder/resources/runtime/_internal/" if misplaced_crt else "LastOrder/"
                    archive.writestr(prefix + name, crt_data if crt_data is not None else crt_binary())
            prefix = "LastOrder/resources/bundles/"
        else:
            code = {"arm64": 2, "amd64": 4}[arch] * 1000 + int(build)
            archive.writestr("AndroidManifest.xml", f'<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
                f'android:versionName="{app_version}" android:versionCode="{code}">'
                f'<uses-sdk android:minSdkVersion="{min_sdk}"/></manifest>')
            abi = {"arm64": "arm64-v8a", "amd64": "x86_64"}[arch]
            for name in ("libmisaka_mobile.so", "libflutter.so"):
                if not missing_native:
                    archive.writestr(f"lib/{abi}/{name}", b"synthetic native library")
            prefix = "assets/bundles/"
        for target in TARGETS:
            platform, arch = target.split("-")
            manifest = dict(version=bundle_version, bili_version=BILI_VERSION,
                            platform=bundle_platform or platform, arch=arch)
            nested = io.BytesIO()
            with tarfile.open(fileobj=nested, mode="w:gz") as bundle:
                data = json.dumps(manifest).encode()
                member = tarfile.TarInfo("manifest.json")
                member.size = len(data)
                bundle.addfile(member, io.BytesIO(data))
                if private_marker:
                    data = b"SYNTHETIC_PRIVATE_MARKER"
                    member = tarfile.TarInfo("runtime/sample")
                    member.size = len(data)
                    bundle.addfile(member, io.BytesIO(data))
            data = nested.getvalue()
            name = target + ".tar.gz"
            digest = hashlib.sha256(data).hexdigest()
            index["artifacts"].append(dict(name=name, bytes=len(data), sha256=digest,
                                           version=VERSION, bili_version=BILI_VERSION, platform=platform, arch=arch))
            asset_name = android_bundle_asset(name) if prefix == "assets/bundles/" and not android_legacy_gzip_assets else name
            archive.writestr(prefix + asset_name, data)
            checksum = digest if nested_sidecar else "0" * 64
            archive.writestr(prefix + name + ".sha256", f"{checksum}  {name}\n")
        archive.writestr(prefix + "bundles.json", json.dumps(index))
    return result.getvalue()


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="misaka-release-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)

    def write_release(self, targets=APP_TARGETS, **kwargs):
        release = {"version": VERSION, "build": BUILD, "bili_version": BILI_VERSION, "artifacts": []}
        sums = []
        for target in targets:
            platform, arch = target.split("-")
            data = app_archive(target=target, **kwargs)
            digest = hashlib.sha256(data).hexdigest()
            name = artifact_name(target)
            (self.directory / name).write_bytes(data)
            sidecar = f"{digest}  {name}\n"
            (self.directory / (name + ".sha256")).write_text(sidecar)
            sums.append(sidecar)
            release["artifacts"].append(dict(name=name, bytes=len(data), sha256=digest, platform=platform, arch=arch))
        (self.directory / "SHA256SUMS").write_text("".join(sums))
        self.write_manifest(release)
        return release

    def write_manifest(self, release):
        (self.directory / "release.json").write_text(json.dumps(release))

    def test_complete_release(self):
        self.write_release()
        self.assertEqual(verify_release(self.directory, [])['version'], VERSION)

    def test_complete_release_requires_every_platform(self):
        self.write_release(targets=("macos-amd64", "macos-arm64"))
        with self.assertRaisesRegex(ValueError, "Release must contain"):
            verify_release(self.directory, [])

    def test_each_matrix_platform_is_validated(self):
        for target in APP_TARGETS:
            with self.subTest(target=target):
                self.write_release(targets=(target,))
                result = verify_release(self.directory, [], expected_targets=(target,))
                self.assertEqual(len(result["artifacts"]), 1)

    def test_mobile_and_windows_native_components_are_required(self):
        for target in ("windows-amd64", "android-arm64", "android-amd64"):
            with self.subTest(target=target):
                self.write_release(targets=(target,), missing_native=True)
                with self.assertRaisesRegex(ValueError, "native component missing"):
                    verify_release(self.directory, [], expected_targets=(target,))

    def test_windows_release_requires_each_crt_beside_the_executable(self):
        for name in WINDOWS_CRT_DLLS:
            with self.subTest(missing=name):
                self.write_release(targets=("windows-amd64",), missing_crt=name)
                with self.assertRaisesRegex(ValueError, "Windows CRT missing"):
                    verify_release(self.directory, [], expected_targets=("windows-amd64",))
        self.write_release(targets=("windows-amd64",), misplaced_crt=True)
        with self.assertRaisesRegex(ValueError, "Windows CRT missing"):
            verify_release(self.directory, [], expected_targets=("windows-amd64",))

    def test_windows_release_rejects_incompatible_or_invalid_crt(self):
        for data in (crt_binary(machine=0x14C), crt_binary(machine=0xAA64),
                     crt_binary(dll=False), b"not a DLL", crt_binary()[:140]):
            with self.subTest(data=data[:8]):
                self.write_release(targets=("windows-amd64",), crt_data=data)
                with self.assertRaisesRegex(ValueError, "x64 PE DLL"):
                    verify_release(self.directory, [], expected_targets=("windows-amd64",))

    def test_windows_packager_rejects_missing_and_incompatible_crt(self):
        app = self.directory / "app"
        app.mkdir()
        for name in WINDOWS_CRT_DLLS:
            (app / name).write_bytes(crt_binary())
        validate_app_crt(app)
        for name in WINDOWS_CRT_DLLS:
            with self.subTest(missing=name):
                (app / name).unlink()
                with self.assertRaisesRegex(ValueError, "Windows CRT missing"):
                    validate_app_crt(app)
                (app / name).write_bytes(crt_binary(machine=0x14C))
                with self.assertRaisesRegex(ValueError, "x64 PE DLL"):
                    validate_app_crt(app)
                (app / name).write_bytes(crt_binary())

    def test_android_legacy_gzip_asset_names_are_rejected(self):
        self.write_release(targets=("android-arm64",), android_legacy_gzip_assets=True)
        with self.assertRaisesRegex(ValueError, "Deployment bundle asset is missing"):
            verify_release(self.directory, [], expected_targets=("android-arm64",))

    def test_android_minimum_sdk_is_verified(self):
        self.write_release(targets=("android-arm64",), min_sdk=35)
        with self.assertRaisesRegex(ValueError, "minimum API"):
            verify_release(self.directory, [], expected_targets=("android-arm64",))

    def test_single_architecture_matrix_release(self):
        release = self.write_release()
        release["artifacts"] = release["artifacts"][:1]
        self.write_manifest(release)
        item = release["artifacts"][0]
        (self.directory / "SHA256SUMS").write_text(f"{item['sha256']}  {item['name']}\n")
        self.assertEqual(len(verify_release(self.directory, [], ("amd64",))["artifacts"]), 1)
        for arches in (("arm64",), ("amd64", "arm64")):
            with self.subTest(arches=arches):
                with self.assertRaisesRegex(ValueError, "Release must contain"):
                    verify_release(self.directory, [], arches)

    def test_app_version_and_build_are_verified_independently(self):
        for kwargs, message in (({"app_version": "0.1.0"}, "App version"), ({"build": "1"}, "App build")):
            with self.subTest(kwargs=kwargs):
                self.write_release(**kwargs)
                with self.assertRaisesRegex(ValueError, message):
                    verify_release(self.directory, [])

    def test_nested_bundle_version_and_platform_are_verified(self):
        for kwargs in ({"bundle_version": "0.1.0"}, {"bundle_platform": "unsupported"}):
            with self.subTest(kwargs=kwargs):
                self.write_release(**kwargs)
                with self.assertRaisesRegex(ValueError, "Nested bundle manifest"):
                    verify_release(self.directory, [])

    def test_nested_sidecar_is_verified(self):
        self.write_release(nested_sidecar=False)
        with self.assertRaisesRegex(ValueError, "Nested bundle SHA-256 sidecar"):
            verify_release(self.directory, [])

    def test_release_sidecar_is_verified(self):
        release = self.write_release()
        (self.directory / (release["artifacts"][0]["name"] + ".sha256")).write_text("incorrect\n")
        with self.assertRaisesRegex(ValueError, "SHA-256 sidecar"):
            verify_release(self.directory, [])

    def test_checksum_and_size_are_verified(self):
        for field, value, message in (("sha256", "0" * 64, "SHA-256 mismatch"), ("bytes", 1, "Size mismatch")):
            with self.subTest(field=field):
                release = self.write_release()
                release["artifacts"][0][field] = value
                self.write_manifest(release)
                with self.assertRaisesRegex(ValueError, message):
                    verify_release(self.directory, [])

    def test_artifact_path_and_duplicate_architectures_are_rejected(self):
        for replacement in ("../outside.zip", artifact_name("macos-arm64")):
            with self.subTest(replacement=replacement):
                release = self.write_release()
                release["artifacts"][0]["name"] = replacement
                self.write_manifest(release)
                with self.assertRaisesRegex(ValueError, "Release must contain"):
                    verify_release(self.directory, [])

    def test_sha256sums_is_verified(self):
        self.write_release()
        (self.directory / "SHA256SUMS").write_text("")
        with self.assertRaisesRegex(ValueError, "SHA256SUMS"):
            verify_release(self.directory, [])

    def test_nested_privacy_scan(self):
        self.write_release(private_marker=True)
        with self.assertRaisesRegex(ValueError, "Environment privacy check"):
            verify_release(self.directory, [b"SYNTHETIC_PRIVATE_MARKER"])


if __name__ == "__main__":
    unittest.main()
