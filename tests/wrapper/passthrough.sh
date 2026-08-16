#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STUBS="$HERE/../stubs"
WRAPPER="$REPO/opencode-zellij"
source "$HERE/../lib/assert.sh"

# Isolate HOME so the wrapper's marker dir doesn't touch the real one.
TMPHOME="$HERE/tmp-home"
rm -rf "$TMPHOME"; mkdir -p "$TMPHOME"
mkdir -p "$TMPHOME/.local/share/opencode-zellij/markers"

LOG="$HERE/log-passthrough"
rm -f "$LOG"

echo "opencode wrapper: passthrough + marker"

run_wrapper() {
    HOME="$TMPHOME" PATH="$STUBS:$PATH" \
    OPENCODE_STUB_LOG="$LOG" UUIDGEN_STUB_VALUE="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" \
    bash "$WRAPPER" "$@"
}

# 1. Subcommand passthrough: stub sees "run do thing", NO marker file created
run_wrapper run do thing
assert_eq "subcommand passthrough (stub argv)" \
    "RUN run do thing" \
    "$(cat "$LOG")"

# Reset log between cases
rm -f "$LOG"
# 2. Help flag passthrough
run_wrapper -h
assert_eq "opencode -h passthrough (stub argv)" \
    "RUN -h" \
    "$(cat "$LOG")"

rm -f "$LOG"
# 3. Explicit -s passthrough (user resuming — bypass marker)
run_wrapper -s ses_existing
assert_eq "opencode -s passthrough (stub argv)" \
    "RESUME ses_existing" \
    "$(cat "$LOG")"

rm -f "$LOG"
# 4. mcp subcommand passthrough
run_wrapper mcp list
assert_eq "opencode mcp passthrough (stub argv)" \
    "RUN mcp list" \
    "$(cat "$LOG")"

rm -f "$LOG"
# 5. Bare wrapper: NOT passthrough → generates marker, re-execs, runs stub opencode.
#    Stub should be invoked (no -s, since no marker file). (Marker file content
#    is asserted in Task 5; here we only assert the stub ran.)
run_wrapper 2>/dev/null || true
assert_contains "bare wrapper runs stub opencode" \
    "RUN" "$(cat "$LOG")"

report
rm -rf "$TMPHOME"
