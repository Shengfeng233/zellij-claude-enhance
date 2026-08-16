#!/usr/bin/env bash
# install.sh
# Install Claude/Codex/opencode recovery scripts for Zellij session resurrection.
#
# Usage:
#   ./install.sh              Install recovery only
#   ./install.sh --with-layout  Install recovery + statusbar-fixed.kdl layout

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/zellij"
LAYOUT_DIR="$CONFIG_DIR/layouts"
CONFIG_FILE="$CONFIG_DIR/config.kdl"
HOOK_PATH="$BIN_DIR/zellij-resurrect-hook.sh"

WITH_LAYOUT=false
for arg in "$@"; do
    case "$arg" in
        --with-layout) WITH_LAYOUT=true ;;
        -h|--help)
            echo "Usage: $0 [--with-layout]"
            echo "  --with-layout  Also install statusbar-fixed.kdl layout"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            echo "Usage: $0 [--with-layout]" >&2
            exit 1
            ;;
    esac
done

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

if command -v opencode &>/dev/null; then
    echo "Installing opencode-zellij -> $BIN_DIR/opencode-zellij"
    cp "$SCRIPT_DIR/opencode-zellij" "$BIN_DIR/opencode-zellij"
    chmod +x "$BIN_DIR/opencode-zellij"
else
    echo "Skipping opencode-zellij (opencode not found on PATH)"
fi

echo "Installing zellij-resurrect-hook.sh -> $HOOK_PATH"
cp "$SCRIPT_DIR/zellij-resurrect-hook.sh" "$HOOK_PATH"
chmod +x "$HOOK_PATH"

echo "Installing zellij-fix-statusbar.sh -> $BIN_DIR/zellij-fix-statusbar.sh"
cp "$SCRIPT_DIR/zellij-fix-statusbar.sh" "$BIN_DIR/zellij-fix-statusbar.sh"
chmod +x "$BIN_DIR/zellij-fix-statusbar.sh"

# Heal serialized layouts of dead sessions (status-bar resurrection bug).
# Only touches sessions that are not running; safe to repeat.
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

# --- Optional layout ---
if $WITH_LAYOUT; then
    echo "Installing statusbar-fixed.kdl -> $LAYOUT_DIR/statusbar-fixed.kdl"
    cp "$SCRIPT_DIR/statusbar-fixed.kdl" "$LAYOUT_DIR/statusbar-fixed.kdl"
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
if [[ -f "$BIN_DIR/opencode-zellij" ]] && ! bash -n "$BIN_DIR/opencode-zellij"; then
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
for setting in on_force_close session_serialization post_command_discovery_hook; do
    if grep -qE "^[[:space:]]*${setting}[[:space:]]" "$CONFIG_FILE" 2>/dev/null; then
        line=$(grep -E "^[[:space:]]*${setting}[[:space:]]" "$CONFIG_FILE" | head -1)
        echo "  $line"
    else
        echo "  WARNING: $setting not found in config" >&2
    fi
done

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
echo "Use 'codex-zellij' instead of 'codex' for best-effort session recovery with inline mode enabled."
echo "Use 'opencode-zellij' instead of 'opencode' for per-pane session recovery via opencode -s."
