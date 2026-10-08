#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc VPNMenuBar/Config/*.swift VPNMenuBar/Dependencies/*.swift VPNMenuBar/Core/*.swift \
  tests/TestLogger.swift tests/LocalCredentialStoreTests.swift -o "$TEST_DIR/local-tests"
"$TEST_DIR/local-tests"
