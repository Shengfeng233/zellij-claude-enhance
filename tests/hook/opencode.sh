#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
HOOK="$REPO/zellij-resurrect-hook.sh"
source "$HERE/../lib/assert.sh"

echo "opencode hook rules"

# Bare opencode → opencode -c
assert_eq "bare opencode → -c" \
    "opencode -c" \
    "$(RESURRECT_COMMAND="opencode" "$HOOK")"

# opencode with a project path (TUI form, not subcommand) → inject -c, keep path
assert_eq "opencode /tmp/proj → -c /tmp/proj" \
    "opencode -c /tmp/proj" \
    "$(RESURRECT_COMMAND="opencode /tmp/proj" "$HOOK")"

# opencode -m sonnet (TUI flag, not passthrough) → inject -c
assert_eq "opencode -m sonnet → -c -m sonnet" \
    "opencode -c -m sonnet" \
    "$(RESURRECT_COMMAND="opencode -m sonnet" "$HOOK")"

# Value-flag value that happens to equal a subcommand name — must inject -c,
# NOT pass through (sonnet isn't a subcommand, but `run` is).
assert_eq "opencode -m run → -c -m run (value not subcommand)" \
    "opencode -c -m run" \
    "$(RESURRECT_COMMAND="opencode -m run" "$HOOK")"

# opencode-zellij (any form) → passthrough unchanged
assert_eq "opencode-zellij unchanged" \
    "opencode-zellij --zellij-marker abc123" \
    "$(RESURRECT_COMMAND="opencode-zellij --zellij-marker abc123" "$HOOK")"

assert_eq "bare opencode-zellij unchanged" \
    "opencode-zellij" \
    "$(RESURRECT_COMMAND="opencode-zellij" "$HOOK")"

assert_eq "full-path opencode-zellij unchanged" \
    "/home/user/.local/bin/opencode-zellij --zellij-marker abc" \
    "$(RESURRECT_COMMAND="/home/user/.local/bin/opencode-zellij --zellij-marker abc" "$HOOK")"

# opencode explicit -s (user resuming) → unchanged
assert_eq "opencode -s passthrough" \
    "opencode -s ses_xxx" \
    "$(RESURRECT_COMMAND="opencode -s ses_xxx" "$HOOK")"

# opencode -c (explicit continue) → unchanged
assert_eq "opencode -c passthrough" \
    "opencode -c" \
    "$(RESURRECT_COMMAND="opencode -c" "$HOOK")"

# opencode subcommands → unchanged
for sub in run serve mcp attach auth providers agent models stats export session db; do
    assert_eq "opencode $sub passthrough" \
        "opencode $sub arg" \
        "$(RESURRECT_COMMAND="opencode $sub arg" "$HOOK")"
done

# Non-opencode command → unchanged (sanity)
assert_eq "unrelated command unchanged" \
    "vim foo.txt" \
    "$(RESURRECT_COMMAND="vim foo.txt" "$HOOK")"

report
