#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc VPNMenuBar/Config/*.swift VPNMenuBar/Dependencies/*.swift VPNMenuBar/Core/*.swift \
  tests/TestLogger.swift tests/ConfigStoreTests.swift -o "$TEST_DIR/config-tests"
"$TEST_DIR/config-tests" "$@"
