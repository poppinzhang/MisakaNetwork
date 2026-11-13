#!/usr/bin/env python3
"""Preview/reset this user's LastOrder data; never run the application or cloud APIs.

Requires macOS, Python 3.11+, and Xcode Command Line Tools (Swift).
No arguments: read-only preview. --apply: permanently delete the printed scope.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile

try:
    import pwd
except ImportError:  # Allows offline tooling to import the policy on Windows.
    pwd = None

BUNDLE = "io.misakanetwork.lastOrder"
HERE = Path(__file__).resolve().parent


class CleanupError(Exception):
    pass


def checked_path(path: Path, home: Path) -> bool:
    """Reject symlink ancestors; never resolve a deletion target through a link."""
    if not path.is_absolute() or ".." in path.parts or path == home:
        raise CleanupError("拒绝不安全的清理路径。")
    for part in [*reversed(path.parents), path]:
        try:
            info = part.lstat()
        except FileNotFoundError:
            return False
        if stat.S_ISLNK(info.st_mode):
            raise CleanupError(f"路径包含符号链接，保留并停止：{path}")
        if part != path and not stat.S_ISDIR(info.st_mode):
            raise CleanupError(f"路径的父级不是目录：{path}")
    if path.stat().st_uid != os.getuid():
        raise CleanupError(f"目标不属于当前用户，保留并停止：{path}")
    return True


def targets(home: Path, temporary: Path) -> list[Path]:
    library = home / "Library"
    return [
        # Keep macOS's protected container-management metadata, not user data.
        library / "Containers" / BUNDLE / "Data",
        library / "Application Support" / BUNDLE,
        library / "Caches" / BUNDLE,
        library / "Preferences" / f"{BUNDLE}.plist",
        library / "Saved Application State" / f"{BUNDLE}.savedState",
        # macOS keeps sandbox temporary files outside the container Data tree.
        temporary / BUNDLE,
    ]


def metadata_paths(home: Path) -> list[Path]:
    library = home / "Library"
    roots = [
        library / "Containers" / BUNDLE / "Data" / "Library"
        / "Application Support" / BUNDLE / "MisakaNetwork",
        library / "Application Support" / BUNDLE / "MisakaNetwork",
    ]
    return [root / filename for root in roots for filename in (
        "state.json", "state.json.tmp", "state-v2.json", "state-v2.json.tmp",
    )]


def legacy_accounts(home: Path) -> list[str]:
    """Read only public metadata IDs, before removing any state files."""
    result = set()
    for path in metadata_paths(home):
        if not checked_path(path, home):
            continue
        if not path.is_file() or path.stat().st_size > 16 * 1024 * 1024:
            raise CleanupError(f"旧资料格式或大小异常，保留并停止：{path}")
        try:
            state = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(state, dict):
                raise ValueError()
            for collection, prefix in (("accounts", "account"), ("tasks", "task")):
                rows = state.get(collection, [])
                if not isinstance(rows, list):
                    raise ValueError()
                for row in rows:
                    identifier = row.get("id") if isinstance(row, dict) else None
                    if not isinstance(identifier, str) or not re.fullmatch(
                        r"[A-Za-z0-9_-]{1,128}", identifier
                    ):
                        raise ValueError()
                    # Exact ID evidence, never a wildcard service/account delete.
                    result.update((f"{prefix}.{identifier}", f"v2.{prefix}.{identifier}"))
        except (ValueError, UnicodeError):
            raise CleanupError(f"旧资料无法解析，保留并停止：{path}") from None
    return sorted(result)


def ensure_stopped() -> None:
    # Only executable names, not arguments that could contain private data.
    result = subprocess.run(
        ["/bin/ps", "-U", str(os.getuid()), "-o", "comm="],
        capture_output=True, text=True, check=True,
    )
    names = {Path(line.strip()).name for line in result.stdout.splitlines()}
    active = names & {"LastOrder", "misakactl", "misaka-runtime"}
    if active:
        raise CleanupError(
            "请先退出 LastOrder 及其辅助进程，再重试；脚本不会结束任何进程。"
            "如果本机另有使用同名运行时的 Sisters，也请先完成其任务并退出。"
        )


def keychain_plan(helper: Path, accounts: list[str], apply: bool) -> dict:
    result = subprocess.run(
        [str(helper)],
        input=json.dumps({"accounts": accounts, "apply": apply}),
        text=True, capture_output=True,
    )
    if result.stderr:
        print(result.stderr.rstrip(), file=sys.stderr)
    if result.returncode:
        try:
            partial = json.loads(result.stdout)
            if isinstance(partial, dict) and all(
                type(partial.get(key)) is int and partial[key] >= 0
                for key in ("deleted", "matched")
            ) and partial["deleted"] <= partial["matched"]:
                print(
                    f"本轮钥匙串删除调用已成功返回 {partial['deleted']}/{partial['matched']} 条；"
                    "清理尚未完成，应用数据文件保留。", file=sys.stderr,
                )
        except ValueError:
            pass
        raise CleanupError(
            "钥匙串处理未完成，未开始删除数据文件。不要启动 LastOrder；"
            "核对提示后重试。"
        )
    try:
        summary = json.loads(result.stdout)
        if not isinstance(summary, dict) or any(
            type(summary.get(key)) is not int or summary[key] < 0
            for key in ("matched", "deleted", "ambiguous")
        ):
            raise ValueError()
        if (not apply and summary["deleted"] != 0) or (
            apply and (summary["ambiguous"] != 0 or summary["deleted"] != summary["matched"])
        ):
            raise ValueError()
    except ValueError:
        raise CleanupError("钥匙串辅助器返回无效结果，未开始删除数据文件。") from None
    return summary


def remove_target(path: Path, home: Path) -> None:
    if not checked_path(path, home):
        return
    if path.is_dir():
        if not shutil.rmtree.avoids_symlink_attacks:
            raise CleanupError("当前 Python 不支持安全目录删除，已停止。")
        # Symlinks *inside* Data (e.g. Documents) are unlinked, not traversed.
        shutil.rmtree(path)
    else:
        path.unlink()
    if os.path.lexists(path):
        raise CleanupError(f"目标仍然存在，清理未完成：{path}")


def run() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true", help="永久删除；默认仅预览")
    mode.add_argument("--dry-run", action="store_true", help="仅预览（默认）")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise CleanupError("此脚本仅支持 macOS。")
    if os.getuid() == 0 or os.geteuid() != os.getuid() or os.environ.get("SUDO_USER"):
        raise CleanupError("请用普通用户运行，不要使用 sudo。")
    if sys.version_info < (3, 11):
        raise CleanupError("需要 Python 3.11 或更新版本。")
    # Ignore HOME/TMPDIR overrides: use the current user's system records.
    home = Path(pwd.getpwuid(os.getuid()).pw_dir)
    temporary = Path(subprocess.check_output(
        ["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], text=True
    ).strip()).resolve(strict=True)
    if not home.is_absolute() or home == Path("/"):
        raise CleanupError("无法确认当前用户的主目录。")
    if temporary.stat().st_uid != os.getuid():
        raise CleanupError("无法确认当前用户的系统临时目录。")
    ensure_stopped()
    planned = [path for path in targets(home, temporary) if checked_path(path, home)]
    accounts = legacy_accounts(home)
    print("模式：" + ("永久删除" if args.apply else "仅预览，不删除"), flush=True)
    print("范围：LastOrder 本地资料；不操作远端任务、订单、云资源或程序本体。")
    print("请先处理远端任务和云资源。清理不会停止云计费，且会丢失部署私钥。")
    for path in planned:
        print(f"  {'将删除' if args.apply else '待清理'}：{path}")
    print(f"旧元数据提供 {len(accounts)} 个精确钥匙串账号键候选。", flush=True)

    # Compile only when the user runs this tool. Never store an inventory of
    # credentials or IDs on disk; the helper receives only IDs through stdin.
    with tempfile.TemporaryDirectory(prefix="lastorder-cleanup-") as work:
        helper = Path(work) / "keychain-helper"
        compilation = subprocess.run([
            "/usr/bin/xcrun", "swiftc", "-parse-as-library",
            "-module-cache-path", str(Path(work) / "cache"),
            str(HERE / "lastorder_keychain_cleanup.swift"), "-o", str(helper),
        ], capture_output=True, text=True)
        if compilation.returncode:
            raise CleanupError("Swift 辅助器编译失败；需要可用的 Xcode/Command Line Tools，未清理任何资料。")
        summary = keychain_plan(helper, accounts, False)
        print(f"钥匙串：确认 {summary['matched']} 条；待人工核对 {summary['ambiguous']} 条。", flush=True)
        if summary["ambiguous"]:
            print("存在无法确认归属的旧钥匙串条目，保留全部资料。请在钥匙串访问中核对。")
            return 2
        if not args.apply:
            print("预览结束。确认范围后，使用 --apply 才会删除。")
            return 0
        # Preflight all paths again before any destructive keychain call.
        ensure_stopped()
        for path in planned:
            checked_path(path, home)
        keychain_plan(helper, accounts, True)
        for path in planned:
            remove_target(path, home)
    print("已清除确认属于 LastOrder 的钥匙串条目和上述数据目录。")
    print("保留 macOS 容器管理元数据、其他应用资料、系统通用临时目录和手动导出的文件。")
    print("现在可重新打开完整 LastOrder 测试包；需重新登录、配置并部署节点。")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(run())
    except (CleanupError, OSError, subprocess.SubprocessError) as error:
        print(f"清理停止：{error}", file=sys.stderr)
        print("如果已开始删除，可能只完成了一部分；修复后重试，不要先打开 LastOrder。", file=sys.stderr)
        sys.exit(1)
