#!/usr/bin/env bash
# zellij-resurrect-hook.sh
# Transform resurrected Claude/Codex commands for session recovery.
# Called by Zellij via post_command_discovery_hook with RESURRECT_COMMAND env var.

cmd="$RESURRECT_COMMAND"

# Opportunistically heal serialized layouts of other dead sessions so their
# status bars survive resurrection (see zellij-fix-statusbar.sh). Idempotent,
# skips running sessions, and runs in the background so the hook stays fast.
# Everything is silenced: stdout of this hook IS the resurrected command.
fixer="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/zellij-fix-statusbar.sh"
if [[ -x "$fixer" ]]; then
    ("$fixer" >/dev/null 2>&1 &)
fi

print_cmd() {
    local first=true
    local arg
    for arg in "$@"; do
        if $first; then
            printf '%q' "$arg"
            first=false
        else
            printf ' %q' "$arg"
        fi
    done
    printf '\n'
}

# Claude stores sessions as ~/.claude/projects/<cwd-slug>/<session-id>.jsonl.
# A stored ID can stop resolving: Claude's cleanup deletes sessions after
# ~30 days, and a session that never received a message is never written.
session_file_exists() {
    [[ -n "${1:-}" ]] || return 1
    compgen -G "$HOME/.claude/projects/*/${1}.jsonl" > /dev/null 2>&1
}

is_uuid() {
    [[ "${1:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

codex_flag_takes_value() {
    case "$1" in
        -c|--config|-i|--image|-m|--model|--local-provider|-p|--profile|-s|--sandbox|-a|--ask-for-approval|-C|--cd|--add-dir|--enable|--disable)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

build_codex_resume_last() {
    local cd_args=("$@")
    local args=(codex resume --last)
    if [[ ${#cd_args[@]} -gt 0 ]]; then
        args+=("${cd_args[@]}")
    fi
    args+=(--no-alt-screen)
    print_cmd "${args[@]}"
}

# --- claude-zellij PTY proxy ---
# claude-zellij execs into claude-zellij-pty.py (Ctrl+Y hot reboot), so Zellij
# discovers the proxy as the pane command and serializes something like:
#   python3 .../claude-zellij-pty.py --wrapper .../claude-zellij --marker <uuid> [args...] -- claude --session-id <stale-id>
# Re-running that verbatim would relaunch the stale child command (whose
# --session-id is already in use), so rewrite it back to the wrapper, which
# re-reads the marker file and resumes the live session.
# This case must precede the wrapper passthrough below: the proxy command line
# contains ".../claude-zellij " (the --wrapper value) and would match it.
case "$cmd" in
    *claude-zellij-pty.py\ *)
        read -ra words <<< "$cmd"
        wrapper=""
        marker=""
        wrapper_args=()
        for ((i = 0; i < ${#words[@]}; i++)); do
            case "${words[i]}" in
                --wrapper)
                    wrapper="${words[i + 1]:-}"
                    i=$((i + 1))
                    ;;
                --marker)
                    marker="${words[i + 1]:-}"
                    i=$((i + 1))
                    ;;
                --)
                    break
                    ;;
                *)
                    # Words between "--marker <id>" and "--" are wrapper args
                    if [[ -n "$marker" ]]; then
                        wrapper_args+=("${words[i]}")
                    fi
                    ;;
            esac
        done
        if [[ -n "$wrapper" && -n "$marker" ]]; then
            print_cmd "$wrapper" --zellij-marker "$marker" "${wrapper_args[@]}"
            exit 0
        fi
        echo "$cmd"
        exit 0
        ;;
esac

# --- Claude ---
# Guaranteed recovery: claude --session-id <uuid> → claude --resume <uuid>
# Best-effort:        bare "claude" → claude --continue
# Either form falls back to --continue when the stored session no longer
# resolves, instead of letting claude die with "No conversation found".
case "$cmd" in
    claude\ *)
        read -ra words <<< "$cmd"

        session_id=""
        resume_id=""
        rest=()
        for ((i = 1; i < ${#words[@]}; i++)); do
            arg="${words[i]}"
            case "$arg" in
                --session-id)
                    if [[ -n "${words[i + 1]:-}" ]]; then
                        session_id="${words[i + 1]}"
                        i=$((i + 1))
                    fi
                    ;;
                -r|--resume)
                    if is_uuid "${words[i + 1]:-}"; then
                        resume_id="${words[i + 1]}"
                        i=$((i + 1))
                    else
                        # Picker form (no value) or named session: keep as-is
                        rest+=("$arg")
                    fi
                    ;;
                *)
                    rest+=("$arg")
                    ;;
            esac
        done

        target="$session_id"
        [[ -z "$target" ]] && target="$resume_id"

        if [[ -n "$target" ]]; then
            if session_file_exists "$target"; then
                print_cmd claude --resume "$target" "${rest[@]}"
            else
                print_cmd claude --continue "${rest[@]}"
            fi
            exit 0
        fi
        ;;
    claude)
        print_cmd claude --continue
        exit 0
        ;;
esac

# --- claude-zellij / codex-zellij (wrappers with embedded marker) ---
# Both wrappers handle resume internally via --zellij-marker.
# Pass through unchanged so the wrapper can look up the stored session ID.
case "$cmd" in
    claude-zellij\ *|claude-zellij|codex-zellij\ *|codex-zellij)
        echo "$cmd"
        exit 0
        ;;
    */claude-zellij\ *|*/claude-zellij|*/codex-zellij\ *|*/codex-zellij)
        # Full-path variant (e.g. /home/user/.local/bin/claude-zellij)
        echo "$cmd"
        exit 0
        ;;
esac

# --- Codex (bare, without wrapper) ---
# Best-effort: "codex resume --last --no-alt-screen" (filters by CWD).
# Preserve -C/--cd because "resume --last" uses cwd-based lookup.
# Subcommands (exec, review, login, etc.) pass through unchanged.
codex_subcommands="exec e review login logout mcp mcp-server app-server completion sandbox debug apply a resume fork cloud features help"

case "$cmd" in
    codex\ *)
        read -ra words <<< "$cmd"
        cd_args=()
        first_non_flag=""
        skip_next=false
        expecting_cd_value=false

        for ((i = 1; i < ${#words[@]}; i++)); do
            arg="${words[i]}"

            if $skip_next; then
                if $expecting_cd_value; then
                    cd_args+=("$arg")
                    expecting_cd_value=false
                fi
                skip_next=false
                continue
            fi

            case "$arg" in
                --cd=*)
                    cd_args+=("$arg")
                    continue
                    ;;
                -C|--cd)
                    cd_args+=("$arg")
                    skip_next=true
                    expecting_cd_value=true
                    continue
                    ;;
                --)
                    if ((i + 1 < ${#words[@]})); then
                        first_non_flag="${words[i + 1]}"
                    fi
                    break
                    ;;
                --*=*)
                    continue
                    ;;
                -*)
                    if codex_flag_takes_value "$arg"; then
                        skip_next=true
                    fi
                    continue
                    ;;
                *)
                    first_non_flag="$arg"
                    ;;
            esac

            for subcmd in $codex_subcommands; do
                if [[ "$first_non_flag" == "$subcmd" ]]; then
                    echo "$cmd"
                    exit 0
                fi
            done
            break
        done

        build_codex_resume_last "${cd_args[@]}"
        exit 0
        ;;
    codex)
        build_codex_resume_last
        exit 0
        ;;
esac

# Everything else: pass through unchanged
echo "$cmd"
