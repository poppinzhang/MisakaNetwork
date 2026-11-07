"""Exercise process-owned upstream handles with Windows sharing semantics."""
from __future__ import annotations

import io
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import bridge


class DatabaseProbe:
    def __init__(self, path: Path):
        self.handle = path.open("w", encoding="utf-8")
        self.db = self.handle
        self.close_calls = 0
        self.fail_close = False

    def close(self):
        self.close_calls += 1
        if self.fail_close:
            raise PermissionError("private-build-path-and-cookie")
        self.handle.close()


class ProcessCleanupTests(unittest.TestCase):
    def setUp(self):
        self.databases = []
        self.directories = []
        self.real_temporary_directory = tempfile.TemporaryDirectory
        self.fail_directory_cleanup = False

    def tearDown(self):
        for database in self.databases:
            database.handle.close()
        for directory in self.directories:
            directory.cleanup()

    def database(self, name):
        database = DatabaseProbe(Path(os.environ["MISAKA_RUNTIME_STATE_DIR"]) / name)
        self.databases.append(database)
        return database

    def guarded_directory(self, **kwargs):
        directory = self.real_temporary_directory(**kwargs)
        self.directories.append(directory)
        owner = self

        class SharingGuard:
            def __enter__(self):
                return directory.name

            def __exit__(self, *_):
                # POSIX permits unlinking open files. Enforce Windows behavior
                # explicitly so this regression is also caught on other hosts.
                if any(not database.handle.closed for database in owner.databases):
                    raise PermissionError("private-build-path-and-cookie")
                if owner.fail_directory_cleanup:
                    raise OSError("private-build-path-and-cookie")
                directory.cleanup()

        return SharingGuard()

    def engine(self):
        sys.modules["util"] = SimpleNamespace(
            ConfigDB=self.database("config.json"),
            main_request=SimpleNamespace(
                cookieManager=SimpleNamespace(db=self.database("cookies.json")),
            ),
        )
        return SimpleNamespace()

    def invoke(self, load_engine=None, process_request=None):
        output = io.BytesIO()
        errors = io.StringIO()
        with patch.dict(os.environ), patch.dict(sys.modules, {"util": None}), \
                patch.object(sys, "argv", ["bridge.py"]), \
                patch.object(sys, "stdin", SimpleNamespace(buffer=io.BytesIO(b'{"op":"ping"}\n'))), \
                patch.object(sys, "stdout", SimpleNamespace(buffer=output)), \
                patch.object(sys, "stderr", errors), \
                patch.object(bridge.signal, "signal"), patch.object(bridge.os, "umask"), \
                patch.object(bridge.logging, "disable"), \
                patch.object(bridge.tempfile, "TemporaryDirectory", self.guarded_directory), \
                patch.object(bridge, "load_engine", load_engine or self.engine), \
                patch.object(bridge, "process_request", process_request or bridge.process_request):
            code = bridge.main()
        self.assertEqual(errors.getvalue(), "")
        self.assertNotIn(b"private-build-path-and-cookie", output.getvalue())
        return code, [json.loads(line) for line in output.getvalue().splitlines()]

    def assert_resources_removed(self):
        self.assertTrue(self.databases)
        self.assertTrue(all(database.handle.closed for database in self.databases))
        self.assertTrue(all(database.close_calls == 1 for database in self.databases))
        self.assertTrue(all(not Path(directory.name).exists() for directory in self.directories))

    def test_success_closes_config_and_global_cookie_databases_before_cleanup(self):
        code, events = self.invoke()
        self.assertEqual(code, 0)
        self.assertEqual(len(events), 1)
        self.assertTrue(events[0]["data"]["ready"])
        self.assert_resources_removed()

    def test_failed_import_closes_resources_after_module_removal_and_during_construction(self):
        for context in ("util", "util.request.BiliRequest", "util.request.CookieManager", "util.Storage.KVDatabase"):
            with self.subTest(context=context):
                def load():
                    namespace = {"__name__": "util", "database": self.database, "SimpleNamespace": SimpleNamespace}
                    if context == "util":
                        body = (
                            "main_request = SimpleNamespace(cookieManager=SimpleNamespace(db=database('cookies.json')))\n"
                            "raise ImportError('private-build-path-and-cookie')\n"
                        )
                    else:
                        def make_self():
                            database = self.database("cookies.json")
                            if context == "util.Storage.KVDatabase":
                                return database
                            manager = SimpleNamespace(db=database)
                            return manager if context == "util.request.CookieManager" else SimpleNamespace(cookieManager=manager)
                        constructor = {"__name__": context, "make_self": make_self}
                        exec("def construct():\n    self = make_self()\n    raise ImportError('private-build-path-and-cookie')\n", constructor)
                        namespace["construct"] = constructor["construct"]
                        body = "main_request = construct()\n"
                    # Like importlib after an import failure, there is no util
                    # entry left in sys.modules; only the traceback owns it.
                    exec("ConfigDB = database('config.json')\n" + body, namespace)

                code, events = self.invoke(load_engine=load)
                self.assertEqual(code, 1)
                self.assertEqual(len(events), 1)
                self.assertEqual(events[0]["error"]["code"], "runtime_unavailable")
                self.assert_resources_removed()

    def test_close_failure_attempts_other_handles_without_replacing_confirmed_result(self):
        confirmed = {"type": "result", "ok": True, "data": {"status": "succeeded", "order_id": 12}}

        def process(request, engine, emit):
            self.databases[0].fail_close = True
            emit(confirmed)
            return 0

        code, events = self.invoke(process_request=process)
        self.assertEqual(code, 1)
        self.assertEqual(events, [confirmed])
        self.assertEqual([database.close_calls for database in self.databases], [1, 1])
        self.assertTrue(self.databases[1].handle.closed)

    def test_directory_cleanup_failure_does_not_publish_a_second_result(self):
        self.fail_directory_cleanup = True
        code, events = self.invoke()
        self.assertEqual(code, 1)
        self.assertEqual(len(events), 1)
        self.assertTrue(events[0]["data"]["ready"])
        self.assertTrue(all(database.handle.closed for database in self.databases))

    def test_cleanup_failure_without_a_result_emits_one_sanitized_error(self):
        self.fail_directory_cleanup = True
        code, events = self.invoke(process_request=lambda *_: 0)
        self.assertEqual(code, 1)
        self.assertEqual(len(events), 1)
        self.assertFalse(events[0]["ok"])
        self.assertEqual(events[0]["error"]["code"], "runtime_unavailable")

    def test_cancelled_initialization_still_closes_open_databases(self):
        def load():
            self.engine()
            raise bridge.Cancelled()

        code, events = self.invoke(load_engine=load)
        self.assertEqual(code, 130)
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["data"]["status"], "cancelled")
        self.assert_resources_removed()


if __name__ == "__main__":
    unittest.main()
