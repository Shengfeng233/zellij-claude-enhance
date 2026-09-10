# Sourced by interactive launchers. An automation-created Zellij server can
# inherit Codex's logging environment and pass it to every pane. Repair only
# that signature; keep an ordinary user's NO_COLOR preference intact.
if [[ -n "${ZELLIJ:-}" && "${CODEX_CI:-}" == 1 && -t 1 ]]; then
    if [[ "${NO_COLOR:-}" == 1 ]]; then
        unset NO_COLOR
    fi
    if [[ -n "${COLORTERM+x}" && -z "$COLORTERM" ]]; then
        unset COLORTERM
    fi
fi
:
