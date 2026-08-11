#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STUBS="$HERE/../stubs"
WRAPPER="$REPO/opencode-zellij"
source "$HERE/../lib/assert.sh"

TMPHOME="$HERE/tmp-home"
rm -rf "$TMPHOME"; mkdir -p "$TMPHOME"
MARKER_DIR="$TMPHOME/.local/share/opencode-zellij/markers"
mkdir -p "$MARKER_DIR"
MARKER="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
MARKER_FILE="$MARKER_DIR/$MARKER"
LOG="$HERE/log-resume"

echo "opencode wrapper: resume path"

run_resume() {
    rm -f "$LOG"
    HOME="$TMPHOME" PATH="$STUBS:$PATH" \
    OPENCODE_STUB_LOG="$LOG" \
    bash "$WRAPPER" --zellij-marker "$MARKER"
}

# 1. Stored session EXISTS in stub's session list → wrapper runs `opencode -s <id>`
echo "ses_live123" > "$MARKER_FILE"
OPENCODE_STUB_SESSIONS='[{"id":"ses_live123","directory":"/tmp","created":1,"updated":2}]' \
    run_resume
assert_contains "resume hits -s ses_live123" \
    "RESUME ses_live123" "$(cat "$LOG")"

# 2. Stored session NOT in list (expired/archived) → wrapper falls back (no -s),
#    reaching the fresh path (stub logs RUN, not RESUME)
echo "ses_dead456" > "$MARKER_FILE"
OPENCODE_STUB_SESSIONS='[]' run_resume
OUT="$(cat "$LOG")"
if [[ "$OUT" == *"RESUME"* ]]; then
    echo "  FAIL: expired session should not resume"; FAIL=$((FAIL + 1))
else
    echo "  PASS: expired session does not resume"; PASS=$((PASS + 1))
fi
assert_contains "expired falls through to fresh path" "RUN" "$OUT"

# 3. Empty marker file → treated as no stored session → bare opencode (no -s)
: > "$MARKER_FILE"
OPENCODE_STUB_SESSIONS='[]' run_resume
if [[ "$(cat "$LOG")" == *"RESUME"* ]]; then
    echo "  FAIL: empty marker should not resume"; FAIL=$((FAIL + 1))
else
    echo "  PASS: empty marker does not resume"; PASS=$((PASS + 1))
fi
assert_contains "empty marker falls through to fresh path" "RUN" "$(cat "$LOG")"

report
rm -rf "$TMPHOME"
