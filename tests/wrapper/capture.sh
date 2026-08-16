#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WRAPPER="$REPO/opencode-zellij"
source "$HERE/../lib/assert.sh"

TMPHOME="$HERE/tmp-home"
TMPSTUBS="$HERE/tmp-stubs"
MARKER="cccccccc-cccc-cccc-cccc-cccccccccccc"
CANDIDATE_ID="ses_captured"

cleanup() { rm -rf "$TMPHOME" "$TMPSTUBS"; }
trap cleanup EXIT

# Capture the CWD the wrapper will see (it does CWD="$(pwd)").
RUN_CWD="$(pwd)"

# ----------------------------------------------------------------------
# Case 1: fresh path captures the session id on the first poll.
# ----------------------------------------------------------------------
rm -rf "$TMPHOME" "$TMPSTUBS"
mkdir -p "$TMPHOME/.local/share/opencode-zellij/markers" "$TMPSTUBS"

# Build a temp opencode stub that:
#  - serves a live session in RUN_CWD with created=now (>= wrapper's launch_ts)
#  - sleeps 8s for non-session-list calls, keeping the wrapper alive for capture
# $CANDIDATE_ID and $RUN_CWD bake in at write time; $(date) and $now run at call time.
cat > "$TMPSTUBS/opencode" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "session" && "\${2:-}" == "list" ]]; then
    now=\$(date +%s%3N)
    printf '[{"id":"$CANDIDATE_ID","directory":"$RUN_CWD","created":%s,"updated":%s}]\n' "\$now" "\$now"
    exit 0
fi
sleep 8
STUB
chmod +x "$TMPSTUBS/opencode"

# Reuse the deterministic uuidgen stub.
cp "$HERE/../stubs/uuidgen" "$TMPSTUBS/uuidgen"
chmod +x "$TMPSTUBS/uuidgen"

echo "opencode wrapper: fresh path captures session id"

HOME="$TMPHOME" PATH="$TMPSTUBS:$PATH" \
    UUIDGEN_STUB_VALUE="$MARKER" \
    bash "$WRAPPER" 2>/dev/null || true

MARKER_FILE="$TMPHOME/.local/share/opencode-zellij/markers/$MARKER"
if [[ -f "$MARKER_FILE" ]]; then
    assert_eq "watcher captured session id" \
        "$CANDIDATE_ID" "$(cat "$MARKER_FILE")"
else
    echo "  FAIL: marker file not created at $MARKER_FILE"
    FAIL=$((FAIL + 1))
fi

# ----------------------------------------------------------------------
# Case 2: transient opencode session-list failures must not kill the
# watcher (regression test for C1: set +e in start_session_watcher).
# The stub fails the first 2 session-list calls (nonzero exit + stderr),
# then serves the live session. The watcher must retry and still capture.
# ----------------------------------------------------------------------
rm -rf "$TMPHOME" "$TMPSTUBS"
mkdir -p "$TMPHOME/.local/share/opencode-zellij/markers" "$TMPSTUBS"
echo 2 > "$TMPSTUBS/.failcount"   # fail the first 2 session-list calls
cat > "$TMPSTUBS/opencode" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "session" && "\${2:-}" == "list" ]]; then
    fails=\$(cat "\$TMPSTUBS/.failcount" 2>/dev/null || echo 0)
    if [[ "\$fails" -gt 0 ]]; then
        echo \$((fails - 1)) > "\$TMPSTUBS/.failcount"
        echo "transient opencode error" >&2
        exit 1
    fi
    now=\$(date +%s%3N)
    printf '[{"id":"$CANDIDATE_ID","directory":"$RUN_CWD","created":%s,"updated":%s}]\n' "\$now" "\$now"
    exit 0
fi
sleep 8
STUB
chmod +x "$TMPSTUBS/opencode"
cp "$HERE/../stubs/uuidgen" "$TMPSTUBS/uuidgen"; chmod +x "$TMPSTUBS/uuidgen"

echo "opencode wrapper: fresh path survives transient session-list failures"

HOME="$TMPHOME" PATH="$TMPSTUBS:$PATH" TMPSTUBS="$TMPSTUBS" \
    UUIDGEN_STUB_VALUE="$MARKER" \
    bash "$WRAPPER" 2>/dev/null || true

MARKER_FILE="$TMPHOME/.local/share/opencode-zellij/markers/$MARKER"
if [[ -f "$MARKER_FILE" ]]; then
    assert_eq "watcher captured after transient failures" \
        "$CANDIDATE_ID" "$(cat "$MARKER_FILE")"
else
    echo "  FAIL: marker file not created (watcher died on transient failure?)"
    FAIL=$((FAIL + 1))
fi

report
