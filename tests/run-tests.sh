#!/usr/bin/env bash
# Run all opencode-zellij test suites. Exits non-zero on any failure.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
chmod +x "$HERE"/stubs/* 2>/dev/null || true

rc=0
for runner in "$HERE"/hook/*.sh "$HERE"/wrapper/*.sh; do
    [[ -f "$runner" ]] || continue
    echo "=== $(basename "$(dirname "$runner")")/$(basename "$runner") ==="
    if ! bash "$runner"; then
        rc=1
    fi
done
echo
if [[ "$rc" -eq 0 ]]; then
    echo "ALL TESTS PASSED"
else
    echo "SOME TESTS FAILED"
fi
exit "$rc"
