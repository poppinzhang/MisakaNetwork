#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
protoc -I proto --go_out=. --go_opt=module=github.com/MisakaNetwork/MisakaNetwork --go-grpc_out=. --go-grpc_opt=module=github.com/MisakaNetwork/MisakaNetwork proto/misaka/v1/sisters.proto
protoc -I proto --dart_out=grpc:LastOrder/lib/generated proto/misaka/v1/sisters.proto
