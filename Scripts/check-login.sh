#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir="$(mktemp -d)"
trap 'rm -rf "$check_dir"' EXIT
swiftc -parse-as-library Sources/UsageKun/LoginStartupPolicy.swift Sources/UsageKun/LoginService.swift Tests/LoginChecks.swift -o "$check_dir/LoginChecks"
"$check_dir/LoginChecks"
