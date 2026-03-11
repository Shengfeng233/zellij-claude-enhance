#!/usr/bin/env bash
# zellij-resurrect-hook.sh
# Transform resurrected Claude/Codex commands for session recovery.
# Called by Zellij via post_command_discovery_hook with RESURRECT_COMMAND env var.

cmd="$RESURRECT_COMMAND"

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

# --- Claude ---
# Guaranteed recovery: claude --session-id <uuid> → claude --resume <uuid>
# Best-effort:        bare "claude" → claude --continue
case "$cmd" in
    claude\ *)
        read -ra words <<< "$cmd"

        # Look for --session-id and extract the UUID
        found=false
        uuid=""
        rest=()
        skip_next=false
        for ((i = 1; i < ${#words[@]}; i++)); do
            if $skip_next; then
                skip_next=false
                continue
            fi
            if [[ "${words[i]}" == "--session-id" && $((i + 1)) -lt ${#words[@]} ]]; then
                uuid="${words[i + 1]}"
                found=true
                skip_next=true
            else
                rest+=("${words[i]}")
            fi
        done

        if $found && [[ -n "$uuid" ]]; then
            print_cmd claude --resume "$uuid" "${rest[@]}"
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
