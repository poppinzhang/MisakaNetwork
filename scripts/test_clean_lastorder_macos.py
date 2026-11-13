"""Cleanup safety tests use synthetic files and mocked OS/keychain operations only."""
from contextlib import ExitStack, contextmanager, redirect_stderr, redirect_stdout
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

if os.name == "posix":
    import clean_lastorder_macos as cleanup


@unittest.skipUnless(os.name == "posix", "macOS cleanup file operations require POSIX")
class CleanupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="misaka-cleanup-fixture-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.home = self.root / "synthetic-user"
        self.home.mkdir()
        self.temporary = self.root / "synthetic-temp"
        self.temporary.mkdir()

    def metadata(self, index=0, content=None):
        path = cleanup.metadata_paths(self.home)[index]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(content or {}), encoding="utf-8")
        return path

    def test_all_metadata_generations_and_pending_writes_contribute_exact_ids(self):
        for index in range(8):
            self.metadata(index, {"accounts": [{"id": f"account_{index}"}],
                                  "tasks": [{"id": f"task-{index}"}]})
        accounts = cleanup.legacy_accounts(self.home)
        self.assertEqual(len(accounts), 32)
        self.assertIn("account.account_0", accounts)
        self.assertIn("v2.account.account_7", accounts)
        self.assertIn("task.task-0", accounts)
        self.assertIn("v2.task.task-7", accounts)
        self.assertNotIn("v2.cloud.preview.v1", accounts)

    def test_duplicate_ids_deduplicate_and_private_fields_are_ignored(self):
        state = {"accounts": [{"id": "abc", "cookie": "synthetic-secret"}],
                 "tasks": [{"id": "xyz", "private": "synthetic-secret"}]}
        self.metadata(0, state)
        self.metadata(2, state)
        self.assertEqual(cleanup.legacy_accounts(self.home),
                         ["account.abc", "task.xyz", "v2.account.abc", "v2.task.xyz"])

    def test_no_metadata_is_an_empty_whitelist(self):
        self.assertEqual(cleanup.legacy_accounts(self.home), [])

    def test_bad_metadata_is_not_silently_discarded(self):
        path = self.metadata()
        values = ["{bad", "[]", '{"accounts":{}}', '{"tasks":[{}]}',
                  '{"accounts":[{"id":"../outside"}]}',
                  json.dumps({"accounts": [{"id": "x" * 129}]}),
                  '{"tasks":[{"id":true}]}']
        for value in values:
            with self.subTest(value=value):
                path.write_text(value, encoding="utf-8")
                with self.assertRaises(cleanup.CleanupError):
                    cleanup.legacy_accounts(self.home)
                self.assertEqual(path.read_text(encoding="utf-8"), value)

    def test_oversized_metadata_is_rejected_without_reading_contents(self):
        path = self.metadata()
        with path.open("wb") as stream:
            stream.truncate(16 * 1024 * 1024 + 1)
        with self.assertRaises(cleanup.CleanupError):
            cleanup.legacy_accounts(self.home)

    def test_metadata_symlink_is_rejected(self):
        outside = self.root / "outside.json"
        outside.write_text('{"accounts":[{"id":"outside"}]}')
        path = cleanup.metadata_paths(self.home)[0]
        path.parent.mkdir(parents=True)
        path.symlink_to(outside)
        with self.assertRaises(cleanup.CleanupError):
            cleanup.legacy_accounts(self.home)
        self.assertTrue(outside.is_file())

    def test_missing_target_is_harmless_but_relative_home_and_dotdot_are_rejected(self):
        self.assertFalse(cleanup.checked_path(self.home / "missing", self.home))
        for target in (Path("relative"), self.home, self.home / ".." / "outside"):
            with self.subTest(target=target), self.assertRaises(cleanup.CleanupError):
                cleanup.checked_path(target, self.home)

    def test_symlink_parent_never_reaches_external_data(self):
        outside = self.root / "outside"
        outside.mkdir()
        sentinel = outside / "sentinel"
        sentinel.write_text("keep")
        (self.home / "linked").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(cleanup.CleanupError):
            cleanup.remove_target(self.home / "linked" / "sentinel", self.home)
        self.assertEqual(sentinel.read_text(), "keep")

    def test_internal_symlinks_are_unlinked_without_deleting_their_targets(self):
        if not cleanup.shutil.rmtree.avoids_symlink_attacks:
            self.skipTest("Platform lacks fd-based directory deletion")
        outside = self.root / "outside"
        outside.mkdir()
        sentinel = outside / "sentinel"
        sentinel.write_text("keep")
        target = self.home / "synthetic-data"
        target.mkdir()
        (target / "Documents").symlink_to(outside, target_is_directory=True)
        (target / "ordinary-file").write_text("delete")
        cleanup.remove_target(target, self.home)
        self.assertFalse(target.exists())
        self.assertEqual(sentinel.read_text(), "keep")

    def test_fixed_scope_preserves_other_apps_exports_and_container_metadata(self):
        if not cleanup.shutil.rmtree.avoids_symlink_attacks:
            self.skipTest("Platform lacks fd-based directory deletion")
        scopes = cleanup.targets(self.home, self.temporary)
        self.assertEqual(len(scopes), 6)
        self.assertEqual(scopes[-1], self.temporary / cleanup.BUNDLE)
        for index, target in enumerate(scopes):
            if target.suffix == ".plist":
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("synthetic")
            else:
                target.mkdir(parents=True, exist_ok=True)
                (target / f"synthetic-{index}").write_text("delete")
        survivors = [
            self.home / "Library/Application Support/other.application/keep",
            self.home / "Library/Containers" / cleanup.BUNDLE / ".management-metadata",
            self.home / "exported-cookie.json",
            self.temporary / "misaka-runtime-unattributed/keep",
        ]
        for target in survivors:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("keep")
        for target in scopes:
            cleanup.remove_target(target, self.home)
        self.assertTrue(all(path.read_text() == "keep" for path in survivors))

    def test_owner_mismatch_blocks_deletion(self):
        target = self.home / "keep"
        target.write_text("keep")
        with patch.object(cleanup.os, "getuid", return_value=os.getuid() + 10000):
            with self.assertRaises(cleanup.CleanupError):
                cleanup.remove_target(target, self.home)
        self.assertEqual(target.read_text(), "keep")

    def test_failed_removal_never_reports_target_deleted(self):
        target = self.home / "keep"
        target.write_text("keep")
        with patch.object(Path, "unlink"):
            with self.assertRaises(cleanup.CleanupError):
                cleanup.remove_target(target, self.home)
        self.assertEqual(target.read_text(), "keep")

    def test_keychain_requests_pass_only_ids_through_stdin(self):
        response = SimpleNamespace(returncode=0, stderr="", stdout=json.dumps(
            {"matched": 1, "deleted": 0, "ambiguous": 0}))
        with patch.object(cleanup.subprocess, "run", return_value=response) as call:
            cleanup.keychain_plan(Path("/synthetic/helper"), ["v2.account.synthetic"], False)
        self.assertEqual(call.call_args.args[0], ["/synthetic/helper"])
        self.assertEqual(json.loads(call.call_args.kwargs["input"]),
                         {"accounts": ["v2.account.synthetic"], "apply": False})

    def test_bad_keychain_responses_raise(self):
        malformed = ["bad-json", "[]", "{}",
                     '{"matched":true,"deleted":0,"ambiguous":0}',
                     '{"matched":0,"deleted":-1,"ambiguous":0}']
        for response in malformed:
            with self.subTest(response=response), patch.object(
                cleanup.subprocess, "run",
                return_value=SimpleNamespace(returncode=0, stderr="", stdout=response),
            ), self.assertRaises(cleanup.CleanupError):
                cleanup.keychain_plan(Path("/synthetic/helper"), [], False)
        with patch.object(cleanup.subprocess, "run", return_value=SimpleNamespace(
            returncode=1, stderr="", stdout="{}"
        )), self.assertRaises(cleanup.CleanupError):
            cleanup.keychain_plan(Path("/synthetic/helper"), [], True)

    def test_failed_keychain_call_reports_cause_and_partial_count(self):
        result = SimpleNamespace(
            returncode=1,
            stderr="SecKeychainItemDelete failed (OSStatus -25244): synthetic error\n",
            stdout=json.dumps({"deleted": 1, "matched": 3, "ambiguous": 0}),
        )
        output = io.StringIO()
        with patch.object(cleanup.subprocess, "run", return_value=result), redirect_stderr(output):
            with self.assertRaises(cleanup.CleanupError):
                cleanup.keychain_plan(Path("/synthetic/helper"), [], True)
        self.assertIn("OSStatus -25244", output.getvalue())
        self.assertIn("1/3", output.getvalue())
        self.assertIn("应用数据文件保留", output.getvalue())

    def test_contradictory_keychain_counts_are_not_success(self):
        cases = [
            (False, {"matched": 1, "deleted": 1, "ambiguous": 0}),
            (True, {"matched": 2, "deleted": 1, "ambiguous": 0}),
            (True, {"matched": 1, "deleted": 1, "ambiguous": 1}),
        ]
        for apply, summary in cases:
            with self.subTest(apply=apply, summary=summary), patch.object(
                cleanup.subprocess, "run", return_value=SimpleNamespace(
                    returncode=0, stderr="", stdout=json.dumps(summary)
                ),
            ), self.assertRaises(cleanup.CleanupError):
                cleanup.keychain_plan(Path("/synthetic/helper"), [], apply)

    @contextmanager
    def isolated_run(self, args, summaries):
        """All process/keychain/deletion calls are mocked; only temp fixtures exist."""
        uid = os.getuid() or 501
        actual_stat = Path.stat

        def synthetic_stat(path, *args, **kwargs):
            if path == self.temporary:
                return SimpleNamespace(st_uid=uid)
            return actual_stat(path, *args, **kwargs)

        events = []
        summary_iter = iter(summaries)

        def keychain(_helper, _accounts, apply):
            events.append(("keychain", apply))
            result = next(summary_iter)
            if isinstance(result, Exception):
                raise result
            return result

        with ExitStack() as stack:
            stack.enter_context(patch.object(cleanup.sys, "argv", ["cleanup", *args]))
            stack.enter_context(patch.object(cleanup.sys, "platform", "darwin"))
            stack.enter_context(patch.object(cleanup.os, "getuid", return_value=uid))
            stack.enter_context(patch.object(cleanup.os, "geteuid", return_value=uid))
            stack.enter_context(patch.dict(cleanup.os.environ, {}, clear=True))
            stack.enter_context(patch.object(cleanup.pwd, "getpwuid", return_value=SimpleNamespace(pw_dir=str(self.home))))
            stack.enter_context(patch.object(cleanup.subprocess, "check_output", return_value=str(self.temporary)))
            stack.enter_context(patch.object(Path, "stat", synthetic_stat))
            process = stack.enter_context(patch.object(cleanup.subprocess, "run", return_value=SimpleNamespace(returncode=0)))
            stack.enter_context(patch.object(cleanup, "ensure_stopped", side_effect=lambda: events.append(("stopped",))))
            stack.enter_context(patch.object(cleanup, "checked_path", return_value=True))
            stack.enter_context(patch.object(cleanup, "legacy_accounts", return_value=["v2.account.synthetic"]))
            stack.enter_context(patch.object(cleanup, "keychain_plan", side_effect=keychain))
            removal = stack.enter_context(patch.object(cleanup, "remove_target", side_effect=lambda *args: events.append(("delete",))))
            output = io.StringIO()
            stack.enter_context(redirect_stdout(output))
            stack.enter_context(redirect_stderr(output))
            yield events, removal, process, output

    def test_default_and_explicit_preview_never_apply_or_delete(self):
        for args in ([], ["--dry-run"]):
            with self.subTest(args=args), self.isolated_run(args, [
                {"matched": 2, "deleted": 0, "ambiguous": 0}
            ]) as (events, removal, _, output):
                self.assertEqual(cleanup.run(), 0)
                self.assertEqual(events, [("stopped",), ("keychain", False)])
                removal.assert_not_called()
                self.assertIn("预览结束", output.getvalue())

    def test_ambiguous_preview_blocks_apply_and_file_deletion(self):
        with self.isolated_run(["--apply"], [
            {"matched": 2, "deleted": 0, "ambiguous": 1}
        ]) as (events, removal, _, _):
            self.assertEqual(cleanup.run(), 2)
            self.assertNotIn(("keychain", True), events)
            removal.assert_not_called()

    def test_apply_rechecks_stopped_and_cleans_keys_before_files(self):
        with self.isolated_run(["--apply"], [
            {"matched": 2, "deleted": 0, "ambiguous": 0},
            {"matched": 2, "deleted": 2, "ambiguous": 0},
        ]) as (events, removal, _, _):
            self.assertEqual(cleanup.run(), 0)
            self.assertEqual(events[:4], [("stopped",), ("keychain", False),
                                         ("stopped",), ("keychain", True)])
            self.assertEqual(removal.call_count, 6)
            self.assertTrue(all(event == ("delete",) for event in events[4:]))

    def test_keychain_apply_failure_preserves_files(self):
        with self.isolated_run(["--apply"], [
            {"matched": 2, "deleted": 0, "ambiguous": 0},
            cleanup.CleanupError("synthetic failure"),
        ]) as (_, removal, _, output):
            with self.assertRaises(cleanup.CleanupError):
                cleanup.run()
            removal.assert_not_called()
            self.assertNotIn("已清除", output.getvalue())

    def test_compile_failure_does_not_query_or_delete(self):
        with self.isolated_run(["--apply"], []) as (events, removal, process, _):
            process.return_value.returncode = 1
            with self.assertRaises(cleanup.CleanupError):
                cleanup.run()
            self.assertEqual(events, [("stopped",)])
            removal.assert_not_called()


class KeychainPolicyTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"),
                         "Pure Swift policy harness requires macOS and Xcode tools")
    def test_synthetic_keychain_ownership_policy(self):
        scripts = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory(prefix="misaka-cleanup-policy-") as work:
            root = Path(work)
            binary = root / "policy-test"
            compilation = subprocess.run([
                "/usr/bin/xcrun", "swiftc", "-parse-as-library",
                "-D", "LASTORDER_CLEANUP_TESTING",
                "-module-cache-path", str(root / "cache"),
                str(scripts / "lastorder_keychain_cleanup.swift"),
                str(scripts / "lastorder_keychain_policy_test.swift"),
                "-o", str(binary),
            ], capture_output=True, text=True)
            self.assertEqual(compilation.returncode, 0, compilation.stderr)
            # The define removes the production @main. Only pure, synthetic
            # classification cases run: no keychain or cleanup API is called.
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("31", result.stdout)
            self.assertIn("8 synthetic deletion-status checks", result.stdout)


if __name__ == "__main__":
    unittest.main()
