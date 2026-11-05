#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
go test -race ./...
python3 -m unittest discover -s runtime/tests -v
python3 -m unittest discover -s scripts -p 'test_*.py' -v
(cd LastOrder && flutter analyze && flutter test)
