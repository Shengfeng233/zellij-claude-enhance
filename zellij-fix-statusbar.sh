#!/usr/bin/env bash
# zellij-fix-statusbar.sh
# Heal serialized session layouts so the status/tab bar survives resurrection.
#
# zellij (<= 0.43.x) serializes live plugin panes with canonical URLs
# ("zellij:status-bar") but swap-layout slots with the unprefixed alias
# ("status-bar"). After resurrection the location strings no longer match, so
# the first swap-layout application treats the bars as regular panes and
# sweeps the status bar into the tiled grid.
#
# This script normalizes both spellings to the canonical "zellij:" form in the
# cached session-layout.kdl of every session that is not currently running.
# Live sessions are skipped: their in-memory layout is already parsed and the
# server would overwrite the file on its next serialization tick anyway.

set -euo pipefail

shopt -s nullglob

fixed=0
skipped_live=0

for layout_file in "$HOME"/.cache/zellij/*/session_info/*/session-layout.kdl; do
    session_name="$(basename "$(dirname "$layout_file")")"

    # Skip sessions whose server is alive ([r] avoids matching ourselves)
    if pgrep -f "zellij --serve[r] .*/${session_name}\$" > /dev/null 2>&1; then
        skipped_live=$((skipped_live + 1))
        continue
    fi

    if grep -qE 'location="(tab-bar|status-bar|compact-bar)"' "$layout_file"; then
        sed -i \
            -e 's/location="tab-bar"/location="zellij:tab-bar"/g' \
            -e 's/location="status-bar"/location="zellij:status-bar"/g' \
            -e 's/location="compact-bar"/location="zellij:compact-bar"/g' \
            "$layout_file"
        echo "fixed: $session_name"
        fixed=$((fixed + 1))
    fi
done

if [[ "$skipped_live" -gt 0 ]]; then
    echo "skipped $skipped_live running session(s) - re-run after they exit if needed"
fi
echo "$fixed serialized session layout(s) normalized"
