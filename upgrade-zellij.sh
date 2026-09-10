#!/usr/bin/env bash
# Install the tested upstream scrollback fix without stopping existing servers.
set -euo pipefail

VERSION=0.45.1
SHA256=40bcc2e03f5d5ae8e054e39f676081fe12ab70871506996ba595834c3718eefc
ASSET=zellij-x86_64-unknown-linux-musl.tar.gz
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HOME/.local/share/zellij-improve"
ARCHIVE=""
case "${1:-}" in
    --archive)
        [[ $# == 2 ]] || { echo "Usage: $0 [--archive FILE]" >&2; exit 1; }
        ARCHIVE="$2"
        ;;
    -h|--help)
        echo "Usage: $0 [--archive FILE]"
        echo "Installs Zellij $VERSION for Linux x86_64; retains the previous binary for live sessions."
        exit 0
        ;;
    "") ;;
    *) echo "Usage: $0 [--archive FILE]" >&2; exit 1 ;;
esac

[[ "$(uname -s)/$(uname -m)" == Linux/x86_64 ]] || {
    echo "This pinned release installer supports Linux x86_64." >&2
    exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if [[ -n "$ARCHIVE" ]]; then
    cp "$ARCHIVE" "$tmp/$ASSET"
else
    curl --fail --location --retry 3 \
        "https://github.com/zellij-org/zellij/releases/download/v$VERSION/$ASSET" \
        --output "$tmp/$ASSET"
fi
printf '%s  %s\n' "$SHA256" "$tmp/$ASSET" | sha256sum --check --status
tar -xzf "$tmp/$ASSET" -C "$tmp" zellij
[[ "$("$tmp/zellij" --version)" == "zellij $VERSION" ]]

mkdir -p "$ROOT/versions/$VERSION" "$HOME/.local/bin"
# The dispatcher can be reinstalled without mistaking itself for a legacy binary.
existing="$(command -v zellij || true)"
if [[ -n "$existing" ]] && ! grep -q '^# Use the upgraded Zellij outside sessions\.' "$existing"; then
    old_version="$("$existing" --version)"
    old_version="${old_version#zellij }"
    [[ "$old_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo "Unrecognized existing Zellij version: $old_version" >&2
        exit 1
    }
    if [[ "$old_version" != "$VERSION" ]]; then
        mkdir -p "$ROOT/versions/$old_version"
        cp "$existing" "$ROOT/versions/$old_version/zellij"
        chmod +x "$ROOT/versions/$old_version/zellij"
        ln -sfn "versions/$old_version" "$ROOT/previous"
    fi
fi

# Replace atomically: the prior binary may still be executing.
install -m 755 "$tmp/zellij" "$ROOT/versions/$VERSION/zellij.new"
mv "$ROOT/versions/$VERSION/zellij.new" "$ROOT/versions/$VERSION/zellij"
ln -sfn "versions/$VERSION" "$ROOT/current"
install -m 755 "$SCRIPT_DIR/zellij-dispatch" "$HOME/.local/bin/zellij.new"
mv "$HOME/.local/bin/zellij.new" "$HOME/.local/bin/zellij"

echo "Installed Zellij $VERSION at $ROOT/current/zellij"
echo "New terminals use the upgraded Zellij via ~/.local/bin/zellij."
echo "Running sessions keep their existing server and client version until recreated."
echo "For an existing shell, run 'hash -r' to refresh command lookup."
