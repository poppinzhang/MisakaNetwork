#!/usr/bin/env python3
"""Assemble a macOS app with local runtime, deployment helper and all offline bundles."""
from __future__ import annotations
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

from release_config import BUILD, ROOT, VERSION
from release_manifest import record_artifact
from index_bundles import index_bundles
from runtime_manifest import validate_runtime


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--app", type=Path, required=True)
    p.add_argument("--arch", choices=["arm64", "amd64"], required=True)
    p.add_argument("--runtime-root", type=Path, default=ROOT / ".build/runtime")
    p.add_argument("--bundles", type=Path, default=ROOT / ".build/bundles")
    p.add_argument("--output", type=Path, default=ROOT / f"dist/{VERSION}")
    args = p.parse_args()
    index_bundles(args.bundles)
    local_runtime = args.runtime_root / f"macos-{args.arch}" / "misaka-runtime"
    validate_runtime(local_runtime, f"macos-{args.arch}")
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="misaka-package-", dir="/tmp") as temporary:
        stage = Path(temporary)
        app = stage / "LastOrder.app"
        shutil.copytree(args.app, app, symlinks=True)
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if info.get("CFBundleShortVersionString") != VERSION or info.get("CFBundleVersion") != str(BUILD):
            raise SystemExit("App version/build number does not match this release")
        target_arch = "x86_64" if args.arch == "amd64" else "arm64"
        for binary in (app / "Contents/MacOS/LastOrder", app / "Contents/Frameworks/App.framework/App", app / "Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS", local_runtime / "misaka-runtime"):
            subprocess.run(["lipo", str(binary), "-verify_arch", target_arch], check=True)
        resources = app / "Contents/Resources"
        shutil.copytree(local_runtime, resources / "runtime", symlinks=True)
        shutil.copytree(args.bundles, resources / "bundles", symlinks=True)
        shutil.copy2(ROOT / "runtime/NOTICE.txt", resources / "NOTICE.txt")
        shutil.copy2(ROOT / "runtime/vendor/biliTickerBuy/LICENSE", resources / "BILITICKERBUY-LICENSE.txt")
        env = dict(os.environ, GOOS="darwin", GOARCH=args.arch, CGO_ENABLED="0")
        subprocess.run(["go", "build", "-trimpath", "-ldflags=-s -w -buildid=", "-o", str(resources / "misakactl"), "./cmd/misakactl"], cwd=ROOT, env=env, check=True)
        inherit = stage / "inherit.plist"
        inherit.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": True, "com.apple.security.inherit": True}))
        # Sign nested native code first. Child executables inherit the app sandbox.
        binaries = []
        for item in (resources / "runtime").rglob("*"):
            if item.is_file() and not item.is_symlink():
                magic = item.open("rb").read(4)
                if magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"):
                    binaries.append(item)
        for binary in sorted(binaries, key=lambda x: len(x.parts), reverse=True):
            command = ["codesign", "--force", "--sign", "-"]
            if binary.name == "misaka-runtime":
                command += ["--entitlements", str(inherit)]
            subprocess.run(command + [str(binary)], check=True, capture_output=True)
        subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements", str(inherit), str(resources / "misakactl")], check=True, capture_output=True)
        # Reuse Xcode's expanded app entitlements, never unexpanded project variables.
        entitlements = stage / "app.entitlements"
        result = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)], check=True, capture_output=True)
        app_entitlements = plistlib.loads(result.stdout)
        if not app_entitlements.get("com.apple.security.app-sandbox"):
            raise SystemExit("Application sandbox must remain enabled")
        entitlements.write_bytes(plistlib.dumps(app_entitlements))
        for framework in (resources / "runtime").rglob("*.framework"):
            subprocess.run(["codesign", "--force", "--sign", "-", str(framework)], check=True, capture_output=True)
        subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements", str(entitlements), str(app)], check=True, capture_output=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        archive = args.output / f"LastOrder-{VERSION}-macos-{args.arch}.zip"
        subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)], check=True)
        # Keep one expanded app for local inspection; it is not an independent release artifact.
        expanded = args.output / f"LastOrder-{args.arch}.app"
        if expanded.exists():
            shutil.rmtree(expanded)
        shutil.copytree(app, expanded, symlinks=True)
    record_artifact(archive, "macos", args.arch, signing="adhoc-not-notarized")
    print(f"Packaged {archive.name}; ad-hoc signed, not notarized")


if __name__ == "__main__":
    main()
