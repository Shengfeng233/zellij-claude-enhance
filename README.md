# zellij-claude-enhance

Automatic session recovery for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [Codex CLI](https://github.com/openai/codex) running inside [Zellij](https://zellij.dev/).

## The Problem

If you run multiple Claude Code or Codex instances across Zellij tabs and panes, an unexpected WSL shutdown, terminal crash, or `pkill -9 zellij` wipes out every conversation. Zellij can resurrect panes and re-run the last command in each, but by default it just runs `claude` or `codex` again — starting a fresh session instead of resuming the one you were working in.

With 8+ AI panes open, reconnecting each one manually is painful.

## The Solution

Two thin wrapper scripts — `claude-zellij` and `codex-zellij` — plus a Zellij resurrection hook that together give you **per-pane session recovery**:

| Tool | Wrapper | Recovery |
|---|---|---|
| Claude Code | `claude-zellij` | Per-pane UUID tracking + `/resume` change detection |
| Codex CLI | `codex-zellij` | Per-pane session capture + inline mode (`--no-alt-screen`) |
| Bare `claude` | (none needed) | Best-effort fallback via `claude --continue` |
| Bare `codex` | (none needed) | Best-effort fallback via `codex resume --last` |

After a crash, just reattach (`zellij attach <session>`) and every AI pane picks up exactly where it left off.

## Demo

### 1. Before crash — 4 Claude instances running

![Before crash](figures/01-before-crash.png)

Four `claude-zellij` panes (Test1–Test4) each hold an independent conversation in the same Zellij session.

### 2. After crash — Zellij resurrection pending

![Resurrection pending](figures/02-resurrection-pending.png)

After `pkill -9 zellij` and `zellij attach`, Zellij reconstructs each pane with the correct recovery command. Panes launched via `claude-zellij` show `claude --resume <session-id>` or re-exec the wrapper with the marker UUID. Press **Enter** to resume.

### 3. After recovery — conversations restored

![After recovery](figures/03-after-recovery.png)

All four conversations are back exactly where they left off — each pane resumes its own session, not somebody else's.

## How It Works

Both wrappers follow the same architecture:

```
1. Generate a marker UUID
2. Re-exec the wrapper with --zellij-marker <uuid> baked into the command line
3. Start the AI CLI as a child process (NOT exec)
4. A background watcher captures/tracks the real session ID
5. Zellij serializes "wrapper --zellij-marker <uuid> ..." to disk
6. On resurrection, the wrapper reads the stored session ID and resumes
```

### Why not just `exec`?

The original approach used `exec claude --session-id <uuid>`, which replaces the wrapper process with Claude. This caused two issues:

- **MCP server interference**: Claude spawns MCP servers (e.g., Context7) as child processes. Zellij's command discovery could pick up an MCP process instead of Claude, corrupting the resurrected command.
- **`/resume` blindness**: If you use `/resume` inside Claude to switch conversations mid-session, the original `--session-id` becomes stale. On crash recovery, you'd land on the wrong conversation.

By running the CLI as a child process and keeping the wrapper alive, Zellij serializes the wrapper command (with its marker UUID), and the wrapper tracks session changes in real time.

### Claude: `/resume` tracking

`claude-zellij` monitors `~/.claude/history.jsonl` in a background watcher. When it detects a `/resume` command from the current session, it extracts the target session ID (from explicit UUID or by observing the next entry's session change) and updates the marker file. On resurrection, `claude --resume` uses the correct — possibly changed — session ID.

### Codex: session ID capture

Codex doesn't support `--session-id`, so `codex-zellij` captures the session ID from `~/.codex/session_index.jsonl` after Codex starts. The wrapper also forces `--no-alt-screen` for all interactive sessions, which works better with Zellij's pane model.

## Prerequisites

- [Zellij](https://zellij.dev/) 0.43+
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`claude`) and/or [Codex CLI](https://github.com/openai/codex) (`codex`)
- `uuidgen` (pre-installed on most Linux distributions)
- Bash 4+

## Quick Start

```bash
git clone https://github.com/Shengfeng233/zellij-claude-enhance.git
cd zellij-claude-enhance
./install.sh

# Now use these instead of bare claude/codex:
claude-zellij
codex-zellij
```

If Zellij crashes or WSL shuts down, just reattach:

```bash
zellij attach <session-name>
# Every AI pane resumes automatically
```

## Installation

### Basic (recovery only)

```bash
./install.sh
```

### With optional status-bar layout fix

```bash
./install.sh --with-layout
```

### What the installer does

1. Copies `claude-zellij`, `codex-zellij`, and `zellij-resurrect-hook.sh` to `~/.local/bin/`
   - `codex-zellij` is only installed if `codex` is found on PATH
2. Backs up `~/.config/zellij/config.kdl`
3. Patches three Zellij config settings:

| Setting | Value | Purpose |
|---|---|---|
| `on_force_close` | `"detach"` | Detach instead of quit on crash |
| `session_serialization` | `true` | Serialize pane commands to disk |
| `post_command_discovery_hook` | path to hook script | Transform commands on resurrection |

4. Optionally installs `statusbar-fixed.kdl` layout (with `--with-layout`)

The installer **will not** silently overwrite an existing `post_command_discovery_hook`. If a conflict is detected, it aborts with a clear error.

### PATH

If `~/.local/bin` is not on your PATH, add to your shell profile:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Usage

### Claude Code

```bash
# Per-pane recovery — UUID injected automatically:
claude-zellij
claude-zellij --dangerously-skip-permissions
claude-zellij --model sonnet "review this code"

# Pass-through (no UUID, no recovery):
claude-zellij -p "one-shot prompt"
claude-zellij --resume <existing-id>
claude-zellij doctor
claude-zellij mcp
```

Recovery flow:

```
claude-zellij --dangerously-skip-permissions
  → re-exec: claude-zellij --zellij-marker <marker> --dangerously-skip-permissions
  → child:   claude --session-id <uuid> --dangerously-skip-permissions
  → watcher: monitors ~/.claude/history.jsonl for /resume
  → Zellij serializes the wrapper command
  → crash → reattach → wrapper reads marker → claude --resume <session-id>
```

If you use `/resume` inside Claude to switch conversations, the watcher detects the session change and updates the stored ID. Resurrection lands on the correct conversation.

### Codex CLI

```bash
# Per-pane recovery + inline mode:
codex-zellij
codex-zellij --full-auto
codex-zellij --model o3 "refactor this"

# Interactive subcommands get --no-alt-screen injected:
codex-zellij resume --last
codex-zellij fork --last

# Non-interactive commands pass through unchanged:
codex-zellij exec "one-shot prompt"
codex-zellij review
codex-zellij login
```

Recovery flow:

```
codex-zellij --full-auto
  → re-exec: codex-zellij --zellij-marker <uuid> --full-auto
  → child:   codex --no-alt-screen --full-auto
  → watcher: captures session ID from ~/.codex/session_index.jsonl
  → crash → reattach → wrapper reads marker → codex resume <session-id> --no-alt-screen
```

### Bare CLI fallback

Commands run without the wrapper still get best-effort recovery:

- `claude` → `claude --continue` (resumes most recent conversation in CWD)
- `codex` → `codex resume --last --no-alt-screen` (resumes most recent session in CWD, preserves `-C/--cd`)

This works for single-pane setups. For multiple AI panes in the same directory, use the wrappers.

### What is NOT recovered

Non-AI commands pass through the hook unchanged:

```bash
npm exec @upstash/context7-mcp   # unchanged
vim                                # unchanged
claude -p "one-shot"               # non-interactive, nothing to resume
codex exec "one-shot"              # non-interactive, nothing to resume
```

## Optional: Status-Bar Layout

If Zellij's status bar moves during pane create/close, the included `statusbar-fixed.kdl` explicitly pins tab bar (top) and status bar (bottom).

```bash
./install.sh --with-layout
zellij -l statusbar-fixed -s test   # try it

# To make permanent, add to config.kdl:
# default_layout "statusbar-fixed"
```

## Verification

### Syntax check

```bash
bash -n ~/.local/bin/claude-zellij
bash -n ~/.local/bin/codex-zellij
bash -n ~/.local/bin/zellij-resurrect-hook.sh
```

### Hook tests

```bash
# Claude
RESURRECT_COMMAND="claude" ~/.local/bin/zellij-resurrect-hook.sh
# → claude --continue

RESURRECT_COMMAND="claude --session-id 11111111-1111-1111-1111-111111111111" \
  ~/.local/bin/zellij-resurrect-hook.sh
# → claude --resume 11111111-1111-1111-1111-111111111111

# Codex
RESURRECT_COMMAND="codex" ~/.local/bin/zellij-resurrect-hook.sh
# → codex resume --last --no-alt-screen

RESURRECT_COMMAND="codex exec do something" ~/.local/bin/zellij-resurrect-hook.sh
# → codex exec do something  (unchanged)

# Other
RESURRECT_COMMAND="npm exec @upstash/context7-mcp" ~/.local/bin/zellij-resurrect-hook.sh
# → npm exec @upstash/context7-mcp  (unchanged)
```

### End-to-end crash test

> **Warning**: This kills all running Zellij sessions. Only run when you have no important work open.

```bash
# 1. Start a test session
zellij -s test-recovery

# 2. Run claude-zellij (or codex-zellij), send a message

# 3. From ANOTHER terminal:
pkill -9 zellij

# 4. Reattach:
zellij attach test-recovery

# 5. The pane should show the resume command — press Enter to continue
```

## Files

| File | Installed to | Description |
|---|---|---|
| `claude-zellij` | `~/.local/bin/claude-zellij` | Claude wrapper with marker UUID + `/resume` tracking |
| `codex-zellij` | `~/.local/bin/codex-zellij` | Codex wrapper with marker UUID + session capture + inline mode |
| `zellij-resurrect-hook.sh` | `~/.local/bin/zellij-resurrect-hook.sh` | Zellij resurrection hook for Claude/Codex commands |
| `statusbar-fixed.kdl` | `~/.config/zellij/layouts/statusbar-fixed.kdl` | Optional layout with pinned status bar |
| `install.sh` | *(run from repo)* | Installer and config patcher |

## Uninstalling

```bash
rm ~/.local/bin/claude-zellij ~/.local/bin/codex-zellij ~/.local/bin/zellij-resurrect-hook.sh
rm -rf ~/.local/share/claude-zellij ~/.local/share/codex-zellij
rm ~/.config/zellij/layouts/statusbar-fixed.kdl  # if installed

# Restore config from backup
ls ~/.config/zellij/config.kdl.backup.*  # find your backup
cp ~/.config/zellij/config.kdl.backup.<timestamp> ~/.config/zellij/config.kdl
```

## Troubleshooting

### `command not found`

Add `~/.local/bin` to PATH — see [PATH section](#path).

### `post_command_discovery_hook already exists`

Another hook is configured. Either merge the hooks manually or remove the existing one from `config.kdl` and re-run `./install.sh`.

### Claude doesn't resume after crash

1. Verify you used `claude-zellij`, not bare `claude`
2. Check config: `grep -E 'session_serialization|post_command_discovery_hook' ~/.config/zellij/config.kdl`
3. Test the hook manually (see [Hook tests](#hook-tests))

### Codex resumes wrong session

If Zellij serializes the child process (`codex`) instead of the wrapper (`codex-zellij`), recovery falls back to `codex resume --last` which picks the most recent session per CWD. Multiple panes in the same directory may get the same session. Run the crash test to check which behavior you get.

### Codex history not scrollable

`codex-zellij` forces `--no-alt-screen`, but Codex still renders its own TUI viewport. Use `Ctrl+T` inside Codex to browse the full transcript. This is an upstream Codex limitation.

### Multiple Claude panes resume the same conversation

This happens with bare `claude` (falls back to `--continue`). Use `claude-zellij` for per-pane recovery.

## License

MIT
