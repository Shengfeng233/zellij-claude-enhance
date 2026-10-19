#!/usr/bin/env bash
# Rebuild status-bar.wasm: Zellij's stock status bar plus the Move Tab hint.
#
# Fetches the Zellij release named in ZELLIJ_VERSION, applies
# move-tab-hint.patch and builds the plugin with the Rust toolchain that
# release pins. rustup and the toolchain go into a temporary directory;
# nothing outside it and this directory is changed. Rerun after bumping
# ZELLIJ_VERSION together with upgrade-zellij.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(<"$HERE/ZELLIJ_VERSION")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git clone --quiet --depth 1 --branch "v$VERSION" \
    https://github.com/zellij-org/zellij.git "$work/zellij"
git -C "$work/zellij" apply "$HERE/move-tab-hint.patch"

toolchain="$(sed -n 's/^channel = "\(.*\)"$/\1/p' "$work/zellij/rust-toolchain.toml")"
export RUSTUP_HOME="$work/rustup" CARGO_HOME="$work/cargo" RUSTUP_TOOLCHAIN="$toolchain"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --quiet \
    --no-modify-path --profile minimal --default-toolchain "$toolchain" --target wasm32-wasip1

(cd "$work/zellij/default-plugins/status-bar" && "$CARGO_HOME/bin/cargo" build --release --locked)
install -m 644 "$work/zellij/target/wasm32-wasip1/release/status-bar.wasm" "$HERE/status-bar.wasm"
echo "Built $HERE/status-bar.wasm for Zellij $VERSION"
