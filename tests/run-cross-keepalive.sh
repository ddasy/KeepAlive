#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
# Compile production files unchanged, excluding only the application entry point.
source "$ROOT/scripts/swift-sources.sh"
swiftc -parse-as-library "${KA_LIBRARY_SOURCES[@]}" "$ROOT"/tests/*.swift -o "$TEST_TMP/cross-tests"
"$TEST_TMP/cross-tests"
