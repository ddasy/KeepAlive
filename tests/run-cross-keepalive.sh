#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
# Compile the actual Store and policy with a test entry point and isolated preferences.
python3 - "$ROOT" "$TEST_TMP" <<'PY'
from pathlib import Path
import sys
root, tmp = map(Path, sys.argv[1:])
source = (root / 'KeepAliveBar.swift').read_text().replace('@main\nstruct KeepAliveBarApp', 'struct KeepAliveBarApp')
source += '\n' + (root / 'tests/cross-keepalive.swift').read_text()
source = source.replace('UserDefaults.standard', 'UserDefaults(suiteName: "com.iu.keepalivebar.cross-tests")!')
(tmp / 'Tests.swift').write_text(source)
PY
swiftc -parse-as-library "$TEST_TMP/Tests.swift" -o "$TEST_TMP/cross-tests"
"$TEST_TMP/cross-tests"
