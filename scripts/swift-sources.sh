#!/bin/bash
# Source this file from build/test scripts. Keep one source inventory for both.
KA_SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Sources/KeepAliveBar"
KA_APP_ENTRY="$KA_SOURCE_ROOT/App/KeepAliveBarApp.swift"
KA_LIBRARY_SOURCES=()
for KA_SOURCE in "$KA_SOURCE_ROOT"/*/*.swift; do
    [[ -f "$KA_SOURCE" ]] || continue
    [[ "$KA_SOURCE" == "$KA_APP_ENTRY" ]] || KA_LIBRARY_SOURCES+=("$KA_SOURCE")
done
if [[ ! -f "$KA_APP_ENTRY" || ${#KA_LIBRARY_SOURCES[@]} -eq 0 ]]; then
    echo "Swift sources missing under $KA_SOURCE_ROOT" >&2
    return 1
fi
