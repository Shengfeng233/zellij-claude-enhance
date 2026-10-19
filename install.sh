#!/usr/bin/env bash
# install.sh
# Install Claude/Codex recovery scripts for Zellij session resurrection.
#
# Usage:
#   ./install.sh              Install recovery only
#   ./install.sh --with-layout  Install recovery + statusbar-fixed.kdl layout
#                               (its status bar also lists Move Tab, Alt i / Alt o)
#   ./install.sh --with-layout --stock-status-bar  Same layout, Zellij's own bar

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/zellij"
LAYOUT_DIR="$CONFIG_DIR/layouts"
CONFIG_FILE="$CONFIG_DIR/config.kdl"
HOOK_PATH="$BIN_DIR/zellij-resurrect-hook.sh"
STATUS_BAR_WASM="$HOME/.local/share/zellij-improve/plugins/status-bar.wasm"

WITH_LAYOUT=false
STOCK_STATUS_BAR=false
for arg in "$@"; do
    case "$arg" in
        --with-layout) WITH_LAYOUT=true ;;
        --stock-status-bar) STOCK_STATUS_BAR=true ;;
        -h|--help)
            echo "Usage: $0 [--with-layout [--stock-status-bar]]"
            echo "  --with-layout       Also install statusbar-fixed.kdl layout; its status bar"
            echo "                      also lists Move Tab (Alt i / Alt o)"
            echo "  --stock-status-bar  Use Zellij's own status bar in that layout"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            echo "Usage: $0 [--with-layout [--stock-status-bar]]" >&2
            exit 1
            ;;
    esac
done
if $STOCK_STATUS_BAR && ! $WITH_LAYOUT; then
    echo "--stock-status-bar only applies together with --with-layout" >&2
    exit 1
fi

# --- Helper: patch a single setting in config.kdl ---
# Replaces the first matching line (commented or active) and drops later duplicates.
# If no match is found, appends the setting at the end.
patch_setting() {
    local key="$1"
    local value="$2"
    local config="$3"
    local replacement="${key} ${value}"
    local tmp="${config}.tmp.$$"

    awk -v key="$key" -v replacement="$replacement" '
    BEGIN { found = 0 }
    {
        # Match lines like:  key ..., // key ..., or //key ...
        if (match($0, "^[[:space:]]*//*[[:space:]]*" key "[[:space:]]") ||
            match($0, "^[[:space:]]*" key "[[:space:]]")) {
            if (found == 0) {
                print replacement
                found = 1
            }
            # Drop duplicates (both commented and active)
            next
        }
        print
    }
    END {
        if (found == 0) {
            print replacement
        }
    }
    ' "$config" > "$tmp"
    mv "$tmp" "$config"
}

# --- Pre-flight checks ---
if ! command -v zellij &>/dev/null; then
    echo "ERROR: zellij not found on PATH" >&2
    exit 1
fi

if ! command -v uuidgen &>/dev/null; then
    echo "ERROR: uuidgen not found on PATH (needed by claude-zellij)" >&2
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 not found on PATH (needed by claude-zellij hot reboot support)" >&2
    exit 1
fi

# --- Create directories ---
mkdir -p "$BIN_DIR"
mkdir -p "$CONFIG_DIR"
mkdir -p "$LAYOUT_DIR"

# --- Install scripts ---
echo "Installing zellij-color-env.sh -> $BIN_DIR/zellij-color-env.sh"
cp "$SCRIPT_DIR/zellij-color-env.sh" "$BIN_DIR/zellij-color-env.sh"

echo "Installing zellij-layout-repair.py -> $BIN_DIR/zellij-layout-repair.py"
cp "$SCRIPT_DIR/zellij-layout-repair.py" "$BIN_DIR/zellij-layout-repair.py"

echo "Installing claude-zellij -> $BIN_DIR/claude-zellij"
cp "$SCRIPT_DIR/claude-zellij" "$BIN_DIR/claude-zellij"
chmod +x "$BIN_DIR/claude-zellij"

echo "Installing claude-zellij-pty.py -> $BIN_DIR/claude-zellij-pty.py"
cp "$SCRIPT_DIR/claude-zellij-pty.py" "$BIN_DIR/claude-zellij-pty.py"
chmod +x "$BIN_DIR/claude-zellij-pty.py"

if command -v codex &>/dev/null; then
    echo "Installing codex-zellij -> $BIN_DIR/codex-zellij"
    cp "$SCRIPT_DIR/codex-zellij" "$BIN_DIR/codex-zellij"
    chmod +x "$BIN_DIR/codex-zellij"
else
    echo "Skipping codex-zellij (codex not found on PATH)"
fi

# The resurrection hook upgrades bare ssh panes to ssh-zellij when it is
# installed next to the hook.
if command -v ssh &>/dev/null; then
    echo "Installing ssh-zellij -> $BIN_DIR/ssh-zellij"
    cp "$SCRIPT_DIR/ssh-zellij" "$BIN_DIR/ssh-zellij"
    chmod +x "$BIN_DIR/ssh-zellij"
else
    echo "Skipping ssh-zellij (ssh not found on PATH)"
fi

echo "Installing zellij-resurrect-hook.sh -> $HOOK_PATH"
cp "$SCRIPT_DIR/zellij-resurrect-hook.sh" "$HOOK_PATH"
chmod +x "$HOOK_PATH"

echo "Installing zellij-fix-statusbar.sh -> $BIN_DIR/zellij-fix-statusbar.sh"
cp "$SCRIPT_DIR/zellij-fix-statusbar.sh" "$BIN_DIR/zellij-fix-statusbar.sh"
chmod +x "$BIN_DIR/zellij-fix-statusbar.sh"

# --- Status bar with the Move Tab hint (statusbar-fixed layout only) ---
# Zellij's built-in bar never lists MoveTab (Alt i / Alt o) and cannot be
# replaced, so the layout loads a patched build (status-bar/) as a file:
# plugin. The build is tied to the Zellij release series it was compiled
# against; any other version keeps the stock bar. Check the binary new
# sessions use, not the dispatcher, which follows the current session.
if $WITH_LAYOUT; then
    status_bar_version="$(<"$SCRIPT_DIR/status-bar/ZELLIJ_VERSION")"
    new_session_zellij="$HOME/.local/share/zellij-improve/current/zellij"
    [[ -x "$new_session_zellij" ]] || new_session_zellij="$(command -v zellij)"
    zellij_version="$("$new_session_zellij" --version)"
    zellij_version="${zellij_version#zellij }"
    if ! $STOCK_STATUS_BAR && [[ "${zellij_version%.*}" == "${status_bar_version%.*}" ]]; then
        echo "Installing status bar with Move Tab hint -> $STATUS_BAR_WASM"
        mkdir -p "$(dirname "$STATUS_BAR_WASM")"
        install -m 644 "$SCRIPT_DIR/status-bar/status-bar.wasm" "$STATUS_BAR_WASM.new"
        mv "$STATUS_BAR_WASM.new" "$STATUS_BAR_WASM"
    else
        if ! $STOCK_STATUS_BAR; then
            echo "Using the stock status bar: the Move Tab hint build targets Zellij" \
                "$status_bar_version, new sessions use $zellij_version."
        fi
        rm -f "$STATUS_BAR_WASM"
    fi
fi

# Heal serialized layouts of dead sessions (status-bar resurrection bug).
# Only touches sessions that are not running; safe to repeat. It also grants
# the patched status bar its permissions and switches saved sessions to it.
echo "Normalizing serialized session layouts (status-bar fix)..."
"$BIN_DIR/zellij-fix-statusbar.sh" | sed 's/^/  /'

# --- Patch config.kdl ---
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "WARNING: $CONFIG_FILE does not exist. Creating minimal config." >&2
    touch "$CONFIG_FILE"
fi

# Back up before modifying
BACKUP="${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
cp "$CONFIG_FILE" "$BACKUP"
echo "Config backup: $BACKUP"

# Check for existing post_command_discovery_hook conflict
existing_hook=$(grep -E '^[[:space:]]*post_command_discovery_hook[[:space:]]' "$CONFIG_FILE" 2>/dev/null || true)
if [[ -n "$existing_hook" ]]; then
    # There's an active (uncommented) hook line
    if echo "$existing_hook" | grep -qF "$HOOK_PATH"; then
        echo "post_command_discovery_hook already points to our hook. No change needed."
    else
        echo "ERROR: An active post_command_discovery_hook already exists:" >&2
        echo "  $existing_hook" >&2
        echo "Cannot safely overwrite. Please resolve manually." >&2
        echo "Restoring config from backup." >&2
        cp "$BACKUP" "$CONFIG_FILE"
        exit 1
    fi
else
    # No active hook — safe to install
    patch_setting "post_command_discovery_hook" "\"$HOOK_PATH\"" "$CONFIG_FILE"
    echo "Patched: post_command_discovery_hook"
fi

# Patch on_force_close and session_serialization
patch_setting "on_force_close" '"detach"' "$CONFIG_FILE"
echo "Patched: on_force_close \"detach\""

patch_setting "session_serialization" "true" "$CONFIG_FILE"
echo "Patched: session_serialization true"

# Mouse events must reach Zellij to scroll individual panes.
patch_setting "mouse_mode" "true" "$CONFIG_FILE"
echo "Patched: mouse_mode true"

# Zellij 0.45 defaults to titles-only. Keep the full borders and the frame's
# scroll-position display used by this setup.
patch_setting "pane_frames" "true" "$CONFIG_FILE"
patch_setting "pane_frame_style" '"full"' "$CONFIG_FILE"
echo "Patched: full pane frames"

# Remove the obsolete shortcut workaround from earlier installations. It cannot
# recover history discarded by partial scroll regions; upgrading Zellij can.
scroll_tmp="${CONFIG_FILE}.scroll.$$"
awk '
    $0 == "// BEGIN zellij-improve scroll navigation" { managed = 1; next }
    $0 == "// END zellij-improve scroll navigation" { managed = 0; next }
    managed == 0 { print }
' "$CONFIG_FILE" > "$scroll_tmp"
mv "$scroll_tmp" "$CONFIG_FILE"

# New interactive shells in an already-contaminated server also need the
# repair before launching bare codex/claude. Do not rewrite existing rc files.
for shell_rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f "$shell_rc" ]] || continue
    if ! grep -qF '# zellij-improve: repair inherited automation color settings' "$shell_rc"; then
        cp "$shell_rc" "${shell_rc}.backup.zellij-colors.$(date +%Y%m%d_%H%M%S)"
        cat >> "$shell_rc" <<'SHELL_COLOR_ENV'

# zellij-improve: repair inherited automation color settings
if [[ -n "${ZELLIJ:-}" && -f "$HOME/.local/bin/zellij-color-env.sh" ]]; then
    . "$HOME/.local/bin/zellij-color-env.sh"
fi
SHELL_COLOR_ENV
        echo "Installed color environment repair in $shell_rc (backup saved)."
    fi
done

# --- Optional layout ---
if $WITH_LAYOUT; then
    echo "Installing statusbar-fixed.kdl -> $LAYOUT_DIR/statusbar-fixed.kdl"
    if [[ -f "$STATUS_BAR_WASM" ]]; then
        # An absolute file: URL serializes unchanged, like the zellij: form.
        sed "s#location=\"zellij:status-bar\"#location=\"file:$STATUS_BAR_WASM\"#" \
            "$SCRIPT_DIR/statusbar-fixed.kdl" > "$LAYOUT_DIR/statusbar-fixed.kdl"
    else
        cp "$SCRIPT_DIR/statusbar-fixed.kdl" "$LAYOUT_DIR/statusbar-fixed.kdl"
    fi
    patch_setting "default_layout" '"statusbar-fixed"' "$CONFIG_FILE"
    echo "Patched: default_layout \"statusbar-fixed\" (keeps the status bar pinned)"
fi

# --- Post-install checks ---
echo ""
echo "=== Post-install verification ==="

# Check syntax
echo "Checking script syntax..."
syntax_ok=true
if ! bash -n "$BIN_DIR/claude-zellij"; then
    syntax_ok=false
fi
if ! python3 -m py_compile "$BIN_DIR/claude-zellij-pty.py"; then
    syntax_ok=false
fi
if [[ -f "$BIN_DIR/codex-zellij" ]] && ! bash -n "$BIN_DIR/codex-zellij"; then
    syntax_ok=false
fi
# compile() instead of py_compile: the script has no .py suffix, and
# py_compile would leave an oddly named .pyc in ~/.local/bin/__pycache__.
if [[ -f "$BIN_DIR/ssh-zellij" ]] && ! python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$BIN_DIR/ssh-zellij"; then
    syntax_ok=false
fi
if ! bash -n "$HOOK_PATH"; then
    syntax_ok=false
fi
if ! bash -n "$BIN_DIR/zellij-fix-statusbar.sh"; then
    syntax_ok=false
fi

if $syntax_ok; then
    echo "  Scripts: OK"
else
    echo "  Scripts: SYNTAX ERROR" >&2
fi

# Verify patched settings
echo "Checking patched config settings..."
for setting in on_force_close session_serialization post_command_discovery_hook mouse_mode pane_frames pane_frame_style; do
    if grep -qE "^[[:space:]]*${setting}[[:space:]]" "$CONFIG_FILE" 2>/dev/null; then
        line=$(grep -E "^[[:space:]]*${setting}[[:space:]]" "$CONFIG_FILE" | head -1)
        echo "  $line"
    else
        echo "  WARNING: $setting not found in config" >&2
    fi
done

if $WITH_LAYOUT; then
    if [[ -f "$STATUS_BAR_WASM" ]]; then
        echo "  status bar: Move Tab hint ($STATUS_BAR_WASM)"
    else
        echo "  status bar: stock (zellij:status-bar)"
    fi
fi

# Run zellij setup --check
echo ""
echo "Running zellij setup --check..."
if zellij setup --check 2>&1; then
    echo "  Zellij config check: OK"
else
    echo "  WARNING: zellij setup --check reported issues (see above)" >&2
fi

# Check PATH
echo ""
if echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    echo "PATH check: $BIN_DIR is on PATH. Good."
else
    echo "WARNING: $BIN_DIR is NOT on your PATH." >&2
    echo "  Add to your shell profile:  export PATH=\"$BIN_DIR:\$PATH\"" >&2
fi

echo ""
echo "=== Installation complete ==="
echo "Use 'claude-zellij' instead of 'claude' for guaranteed session recovery."
echo "Inside a claude-zellij pane, press Ctrl+Y to reboot Claude into the same conversation."
echo "Use 'codex-zellij' instead of 'codex' for session recovery and inline mode."
if [[ -f "$BIN_DIR/ssh-zellij" ]]; then
    echo "Use 'ssh-zellij <host>' instead of 'ssh <host>': Ctrl+Y reconnects a dead or hung pane,"
    echo "and lost connections reconnect automatically."
fi
echo "Normal Codex formatting with mouse scrolling requires Zellij >= 0.44.1 (tested: 0.45.1)."
echo "Use ./upgrade-zellij.sh to install the tested release; existing servers must be recreated."
