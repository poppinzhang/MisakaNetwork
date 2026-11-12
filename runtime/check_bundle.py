"""Offline packaged-runtime checks; never log in or place an order."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess


def check(binary: Path) -> None:
    requests = [
        ({"op": "ping"}, 0, None),
        ({"op": "validate", "params": {"config": {}}}, 0, None),
        ({"op": "run", "params": {"config": {}, "cookies": []}}, 1, "invalid_cookies"),
        ({"op": "unsupported"}, 1, "unknown_operation"),
    ]
    for request, expected, error in requests:
        result = subprocess.run([str(binary.resolve())], input=json.dumps(request) + "\n", text=True, capture_output=True, timeout=30)
        assert result.returncode == expected, "Unexpected bridge exit code"
        assert not result.stderr, "Bridge wrote unexpected stderr"
        events = [json.loads(line) for line in result.stdout.splitlines()]
        assert len(events) == 1 and events[0].get("type") == "result", "Expected one structured result"
        event = events[0]
        if error:
            assert not event["ok"] and event["error"]["code"] == error
        elif request["op"] == "ping":
            assert event["data"] == {"version": "0.2.3", "bili_version": "2.15.18", "protocol": 1, "ready": True}
        else:
            assert not event["data"]["ok"] and event["data"]["errors"]
    print("Packaged runtime: 4 offline checks passed; no login or ordering requests executed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    check(parser.parse_args().binary)
