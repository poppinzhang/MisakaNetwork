"""Inspect the embedded Android client and 16 KB native libraries in an APK.

This verifies packaging, not execution: the Android integration test must still
exercise Chaquopy on an API 36 device or emulator.
"""
import io
import hashlib
import json
from pathlib import Path
import re
import struct
import zipfile
from email.parser import BytesParser


CLIENT_MODULES = (
    "android_bridge.py", "bridge.py", "interface/__init__.py",
    "interface/auth.py", "interface/common.py", "interface/config.py",
    "interface/project.py", "interface/search.py", "util/request/BiliRequest.py",
)
DEPENDENCY_MODULES = (
    "anyio/__init__.py", "h11/__init__.py", "h2/__init__.py", "hpack/__init__.py",
    "httpcore/__init__.py", "httpx/__init__.py", "hyperframe/__init__.py",
    "certifi/__init__.py", "charset_normalizer/__init__.py", "idna/__init__.py",
    "loguru/__init__.py", "ntplib.py", "png.py", "socks.py", "qrcode/__init__.py",
    "qrcode/image/pure.py", "requests/__init__.py", "tinydb/__init__.py",
    "urllib3/__init__.py", "socksio/__init__.py", "typing_extensions.py",
)
PYTHON_LIBRARIES = ("libpython3.11.so", "libchaquopy_java.so")
ASSETS = "assets/chaquopy/"
PAGE_SIZE = 16384
DEPENDENCY_LOCK = Path(__file__).resolve().parents[1] / "runtime/requirements-android.lock"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def verify_elf(data: bytes, abi: str, label: str) -> None:
    """Both supported ABIs use ELF64 little endian program headers."""
    invalid = "Invalid Android ELF library: " + label
    require(len(data) >= 64 and data[:7] == b"\x7fELF\x02\x01\x01", invalid)
    kind, machine = struct.unpack_from("<HH", data, 16)
    require(kind == 3 and machine == {"arm64-v8a": 183, "x86_64": 62}[abi], invalid)
    offset = struct.unpack_from("<Q", data, 32)[0]
    size, count = struct.unpack_from("<HH", data, 54)
    require(size >= 56 and count > 0 and offset >= 64 and offset + size * count <= len(data), invalid)
    loads = 0
    for index in range(count):
        values = struct.unpack_from("<IIQQQQQQ", data, offset + index * size)
        kind, _, file_offset, address, _, file_size, _, alignment = values
        if kind != 1:  # PT_LOAD
            continue
        loads += 1
        require(file_offset + file_size <= len(data), invalid)
        require(alignment >= PAGE_SIZE and alignment & (alignment - 1) == 0 and
                (address - file_offset) % PAGE_SIZE == 0,
                "Android ELF is not 16 KB aligned: " + label)
    require(loads > 0, invalid)


def verify_apk_native(archive: zipfile.ZipFile, abi: str) -> None:
    for item in archive.infolist():
        if not item.filename.startswith("lib/") or not item.filename.endswith(".so"):
            continue
        require(item.filename.split("/")[1] == abi, "Unexpected Android native ABI")
        verify_elf(archive.read(item), abi, item.filename)
        if item.compress_type == zipfile.ZIP_STORED:
            # Check the local header, whose padding may differ from the central
            # directory. Stored .so data is mmap'ed directly from the APK.
            archive.fp.seek(item.header_offset)
            header = archive.fp.read(30)
            require(len(header) == 30 and header[:4] == b"PK\x03\x04", "Invalid APK local header")
            name_size, extra_size = struct.unpack_from("<HH", header, 26)
            data_offset = item.header_offset + 30 + name_size + extra_size
            require(data_offset % PAGE_SIZE == 0,
                    "Android APK library is not 16 KB aligned: " + item.filename)


def read_python_archive(archive: zipfile.ZipFile, name: str) -> dict[str, bytes]:
    require(name in archive.namelist(), "Android Python asset missing: " + name)
    try:
        with zipfile.ZipFile(io.BytesIO(archive.read(name))) as nested:
            names = nested.namelist()
            require(len(names) == len(set(names)), "Duplicate Android Python archive members")
            return {item.filename: nested.read(item) for item in nested.infolist() if not item.is_dir()}
    except zipfile.BadZipFile as error:
        raise ValueError("Invalid Android Python archive: " + name) from error


def require_module(files: dict[str, bytes], name: str) -> None:
    # Chaquopy normally replaces source modules with adjacent .pyc files.
    require(bool(files.get(name) or files.get(name + "c")), "Android Python module missing: " + name)


def normalized_name(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def locked_dependencies(data: bytes) -> dict[str, str]:
    dependencies = {}
    for line in data.decode().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = re.fullmatch(r"([A-Za-z0-9_.-]+)==([A-Za-z0-9_.+-]+)", line)
        require(match is not None, "Android Python dependency lock mismatch")
        name, version = match.groups()
        name = normalized_name(name)
        require(name not in dependencies, "Android Python dependency lock mismatch")
        dependencies[name] = version
    return dependencies


def verify_android_runtime(archive: zipfile.ZipFile, abi: str, bili_version: str) -> None:
    for library in PYTHON_LIBRARIES:
        require(f"lib/{abi}/{library}" in archive.namelist(), "Android Python library missing: " + library)
    verify_apk_native(archive, abi)
    require(ASSETS + "build.json" in archive.namelist(), "Android Python build manifest missing")
    build = json.loads(archive.read(ASSETS + "build.json"))
    require(build.get("python_version") == "3.11", "Android Python version mismatch")
    require(isinstance(build.get("assets"), dict) and bool(build["assets"]), "Android Python asset manifest is empty")
    for name, digest in build["assets"].items():
        require(ASSETS + name in archive.namelist(), "Android Python asset missing: " + name)
        require(hashlib.sha1(archive.read(ASSETS + name)).hexdigest() == digest,
                "Android Python asset checksum mismatch: " + name)
    app = read_python_archive(archive, ASSETS + "app.imy")
    for name in CLIENT_MODULES:
        require_module(app, name)
    require("UPSTREAM_MANIFEST.json" in app, "Android upstream manifest missing")
    manifest = json.loads(app["UPSTREAM_MANIFEST.json"])
    require(manifest.get("version") == bili_version, "Android upstream version mismatch")
    require(isinstance(manifest.get("files"), list) and bool(manifest["files"]), "Android upstream file manifest is empty")
    for record in manifest["files"]:
        name = record["path"]
        if name.endswith(".py"):
            require_module(app, name)
        else:
            require(name in app, "Android upstream resource missing: " + name)
    requirements = read_python_archive(archive, ASSETS + "requirements-common.imy")
    for name in DEPENDENCY_MODULES:
        require_module(requirements, name)
    require(b"-----BEGIN CERTIFICATE-----" in requirements.get("certifi/cacert.pem", b""),
            "Android Python CA bundle missing")
    expected_lock = locked_dependencies(DEPENDENCY_LOCK.read_bytes())
    require(locked_dependencies(app.get("requirements-android.lock", b"")) == expected_lock,
            "Android Python dependency lock mismatch")
    metadata = {}
    for name, data in requirements.items():
        if name.endswith(".dist-info/METADATA"):
            fields = BytesParser().parsebytes(data)
            metadata[normalized_name(fields.get("Name", ""))] = fields.get("Version")
    for name, version in expected_lock.items():
        require(metadata.get(name) == version, "Android Python dependency version mismatch: " + name)
    # These archives carry the importer and standard library; native modules in
    # .imy archives are extracted by Chaquopy, so only ELF alignment applies.
    for suffix in ("bootstrap.imy", "stdlib-common.imy", f"stdlib-{abi}.imy"):
        contents = read_python_archive(archive, ASSETS + suffix)
        require(bool(contents), "Android Python archive is empty: " + suffix)
        for name, data in contents.items():
            if name.endswith(".so"):
                verify_elf(data, abi, suffix + "/" + name)
    for name in archive.namelist():
        if name.startswith(ASSETS) and name.endswith(".so"):
            verify_elf(archive.read(name), abi, name)
        if name.startswith(ASSETS + "requirements-") and name.endswith(".imy") and name != ASSETS + "requirements-common.imy":
            for member, data in read_python_archive(archive, name).items():
                if member.endswith(".so"):
                    verify_elf(data, abi, name + "/" + member)
