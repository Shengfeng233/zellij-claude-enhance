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
#
# When the status bar with the Move Tab hint is installed (install.sh
# --with-layout), saved status bars are switched to it, and back to the stock
# bar once it is removed. It is a file: plugin, so its permissions are granted
# here too: the dispatcher runs this script before any new server starts.

set -euo pipefail

# The resurrection hook (zellij-resurrect-hook.sh) launches this script in the
# background on EVERY command discovery, i.e. many times per second across
# sessions and panes. Without a guard that is a fork bomb: each instance loops
# over all session layouts forking a pgrep per session. flock-protect so only
# one instance does the work; concurrent duplicates exit instantly. Safe because
# the work is idempotent and anything skipped here is picked up by the next run.
exec 9>"${TMPDIR:-/tmp}/zellij-fix-statusbar.lock"
if ! flock -n 9; then
    exit 0
fi

shopt -s nullglob

fixed=0
skipped_live=0
repair_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/zellij-layout-repair.py"
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zellij"
status_bar="$HOME/.local/share/zellij-improve/plugins/status-bar.wasm"

status_bar_args=()
if [[ -f "$status_bar" ]]; then
    status_bar_args=(--status-bar "$status_bar")
    mkdir -p "$cache_dir"
    python3 "$repair_script" "${status_bar_args[@]}" --grant "$cache_dir/permissions.kdl"
fi

for layout_file in "$cache_dir"/*/session_info/*/session-layout.kdl; do
    session_name="$(basename "$(dirname "$layout_file")")"
    cache_version="$(basename "$(dirname "$(dirname "$(dirname "$layout_file")")")")"

    # Skip sessions whose server is alive ([r] avoids matching ourselves)
    # Old/new Zellij versions can have independent sessions with the same name.
    server_suffix="$(python3 -c 'import re, sys; print(re.escape(sys.argv[1]))' "/$cache_version/$session_name")"
    if pgrep -f "zellij --serve[r] .*${server_suffix}\$" > /dev/null 2>&1; then
        skipped_live=$((skipped_live + 1))
        continue
    fi

    # Pre-0.45 servers keep caches under their release number and may resume
    # them; the patched bar is built for the current release, so keep theirs.
    bar_args=("${status_bar_args[@]}")
    if [[ "$cache_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        bar_args=()
    fi
    result="$(python3 "$repair_script" "${bar_args[@]}" "$layout_file")"
    if [[ -n "$result" ]]; then
        echo "$result"
        fixed=$((fixed + 1))
    fi
done

if [[ "$skipped_live" -gt 0 ]]; then
    echo "skipped $skipped_live running session(s) - re-run after they exit if needed"
fi
echo "$fixed serialized session layout(s) normalized"
