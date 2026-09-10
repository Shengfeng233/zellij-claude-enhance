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
repair_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/zellij-layout-repair.py"

for layout_file in "$HOME"/.cache/zellij/*/session_info/*/session-layout.kdl; do
    session_name="$(basename "$(dirname "$layout_file")")"
    cache_version="$(basename "$(dirname "$(dirname "$(dirname "$layout_file")")")")"

    # Skip sessions whose server is alive ([r] avoids matching ourselves)
    # Old/new Zellij versions can have independent sessions with the same name.
    server_suffix="$(python3 -c 'import re, sys; print(re.escape(sys.argv[1]))' "/$cache_version/$session_name")"
    if pgrep -f "zellij --serve[r] .*${server_suffix}\$" > /dev/null 2>&1; then
        skipped_live=$((skipped_live + 1))
        continue
    fi

    result="$(python3 "$repair_script" "$layout_file")"
    if [[ -n "$result" ]]; then
        echo "$result"
        fixed=$((fixed + 1))
    fi
done

if [[ "$skipped_live" -gt 0 ]]; then
    echo "skipped $skipped_live running session(s) - re-run after they exit if needed"
fi
echo "$fixed serialized session layout(s) normalized"
