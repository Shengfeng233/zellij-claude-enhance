# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Per-pane session recovery for Claude Code, Codex CLI, and opencode running inside Zellij, plus a fix for Zellij's status-bar displacement in resurrected sessions. The deliverable is six small scripts + a layout + an installer — there is no build system, no package manager, no test framework. Changes are validated by syntax checks and manual crash-recovery testing.

## Common commands

```bash
# Install / reinstall to ~/.local/bin and patch ~/.config/zellij/config.kdl
./install.sh
./install.sh --with-layout   # also installs statusbar-fixed.kdl

# Syntax checks (the only automated validation)
bash -n claude-zellij
bash -n codex-zellij
bash -n opencode-zellij
bash -n zellij-resurrect-hook.sh
bash -n zellij-fix-statusbar.sh
python3 -m py_compile claude-zellij-pty.py

# Unit-style hook tests (see README "Hook tests" for more cases)
RESURRECT_COMMAND="claude" ./zellij-resurrect-hook.sh
RESURRECT_COMMAND="claude --session-id 11111111-1111-1111-1111-111111111111" ./zellij-resurrect-hook.sh
RESURRECT_COMMAND="python3 /x/claude-zellij-pty.py --wrapper /x/claude-zellij --marker abc -- claude --session-id def" ./zellij-resurrect-hook.sh
RESURRECT_COMMAND="codex" ./zellij-resurrect-hook.sh
RESURRECT_COMMAND="codex exec do something" ./zellij-resurrect-hook.sh
RESURRECT_COMMAND="opencode" ./zellij-resurrect-hook.sh
RESURRECT_COMMAND="opencode-zellij --zellij-marker 33333333-3333-3333-3333-333333333333" ./zellij-resurrect-hook.sh
RESURRECT_COMMAND="opencode run do something" ./zellij-resurrect-hook.sh

# End-to-end crash test (destructive — kills all zellij sessions)
zellij -s test-recovery
# ...run claude-zellij in a pane, send a message...
pkill -9 zellij
zellij attach test-recovery
```

## Architecture: the three moving parts

Session recovery hinges on how these three pieces cooperate. A change in one usually requires thinking about the other two.

### 1. The wrappers (`claude-zellij`, `codex-zellij`)

Both follow the same "marker UUID + re-exec" pattern:

1. First invocation generates a UUID, then **re-execs itself** with `--zellij-marker <uuid>` prepended. This bakes the marker into the process's command line so Zellij serializes it to disk.
2. The real CLI (`claude` / `codex`) is launched as a **child process, not via `exec`**, so Zellij's command discovery doesn't pick up an MCP child or the bare CLI. For Codex the wrapper itself stays alive as pane leader; for Claude the wrapper `exec`s into the PTY proxy (see part 3), so **the proxy is the pane leader** and the serialized command is the proxy's command line — hook rule 1 rewrites it back to the wrapper.
3. A background watcher (`trap '' INT TERM HUP` so it survives signals meant for the child) records the real session ID into `~/.local/share/{claude,codex}-zellij/markers/<uuid>`:
   - Claude: polls `~/.claude/sessions/<pid>.json` — the registry each claude process keeps for itself and rewrites in place whenever its active session changes (`/resume` picker, `/resume <name-or-uuid>`, `/clear`). The watcher resolves OUR claude child through the proxy's process tree every tick (Ctrl+Y reboots replace the child), so tracking is pane-exact and works even if the user switches sessions and quits immediately without typing. Falls back to a `history.jsonl` heuristic (`/resume` display lines + next-prompt session change) when the registry doesn't exist.
   - Codex: polls `~/.codex/session_index.jsonl` for the next new entry after startup (Codex has no `--session-id`).
   - opencode: follows the codex pattern (opencode assigns its own `ses_...` IDs and `-s/--session` only resumes existing sessions, so the ID cannot be injected upfront). A background watcher polls `opencode session list --format json` for a session whose `directory == $CWD` and `created >= launch_ts`, and stores the id in the marker file. On resume, the wrapper verifies the id via `session list` and runs `opencode -s <id>`; if archived/expired, it starts a fresh tracked session. No live switch-tracking (capture-once only). The watcher runs under `set +e` and polls for ~10 min; transient `opencode session list` failures (SQLite lock contention, etc.) are retried, not fatal.
4. On re-invocation with an existing marker file, the wrapper runs `claude --resume <id>` or `codex resume <id>`, **after validating that the session still exists on disk** (`~/.claude/projects/*/<id>.jsonl`). A stored ID stops resolving when Claude's ~30-day cleanup deletes it or when the session never received a message; the wrapper then prints a notice and starts a fresh tracked session (new UUID written to the same marker file) instead of letting claude die with "No conversation found". User args are passed through on both the fresh and resume paths. Markers untouched for 45+ days are GC'd at startup.

The wrappers also have **passthrough rules** — specific flags (`-p`, `--resume`, `--continue`, `--session-id`, etc.) and subcommands (`mcp`, `doctor`, `exec`, `login`, ...) bypass the marker logic entirely and `exec` the real CLI. When adding new CLI flags/subcommands upstream, update `PASSTHROUGH_FLAGS`, `SUBCOMMANDS`, `NON_INTERACTIVE_SUBCOMMANDS`, `INTERACTIVE_SUBCOMMANDS`, and `codex_flag_takes_value()` accordingly.

### 2. The resurrection hook (`zellij-resurrect-hook.sh`)

Zellij calls this via `post_command_discovery_hook` with `RESURRECT_COMMAND` in the environment. It must print the (possibly rewritten) command to stdout.

Matching order matters:
1. `... claude-zellij-pty.py --wrapper <path> --marker <uuid> [args] -- claude ...` → `<wrapper> --zellij-marker <uuid> [args]`. This is the normal serialized form of a claude-zellij pane (the proxy is the pane leader) and **must be matched before rule 3**: the proxy command line contains `.../claude-zellij ` as the `--wrapper` value, so rule 3's glob would otherwise pass it through verbatim and replay the stale `claude --session-id` child command.
2. `claude --session-id <uuid> ...` / `claude --resume <uuid> ...` → `claude --resume <uuid> ...` if `~/.claude/projects/*/<uuid>.jsonl` exists, else `claude --continue ...`. Bare `claude` → `claude --continue` (best-effort, per-CWD).
3. `claude-zellij ...` / `codex-zellij ...` (including full-path variants) → passed through unchanged so the wrapper's own marker logic runs.
4. `codex [flags] [subcommand] ...` → if a known non-resume subcommand is present, pass through; otherwise build `codex resume --last [--cd X] --no-alt-screen`, preserving `-C/--cd` because `resume --last` is CWD-scoped.
5. `opencode-zellij ...` → passed through unchanged (joined with the wrapper-passthrough case in step 3).
6. `opencode [flags] [project]` → if a known subcommand or explicit `-s/-c/--fork` is present, pass through; otherwise inject `-c` (`opencode -c [args]`) for best-effort continue-last.
7. Everything else → unchanged.

The hook also fires `zellij-fix-statusbar.sh` in the background (silenced — the hook's stdout IS the resurrected command) to heal other dead sessions' serialized layouts.

Any change to wrapper command shape (e.g. renaming `--zellij-marker`) or to the proxy's argv layout in `launch_claude_with_hotkey()` must be reflected here.

### 3. The Ctrl+Y hot reboot proxy (`claude-zellij-pty.py`)

`claude-zellij` never runs `claude` directly — it `exec`s this Python PTY proxy, which forks a PTY, runs the claude child inside, and pipes bytes both ways. It intercepts the raw byte `\x19` (Ctrl+Y) from stdin, SIGTERMs the child, runs `zellij action clear`, and then `os.execv`s back into the wrapper with the same marker. The marker file has already been kept current by the history watcher, so the re-entry lands on `claude --resume <current-session-id>`.

SIGWINCH handling (`apply_winsize` on the master fd + forwarding SIGWINCH to the child) is load-bearing — without it Claude's TUI corrupts on Zellij pane resize.

### 4. The status-bar pinning fix (`statusbar-fixed.kdl` + `zellij-fix-statusbar.sh`)

Zellij (≤ 0.43.x) serializes live plugin panes with canonical URLs (`zellij:status-bar`) but swap-layout slots with the unprefixed alias (`status-bar`). After a session is resurrected, swap-layout application matches plugin panes to slots **by location string**; the mismatch makes the bars count as regular panes, so the next swap (manual `Alt+[`/`]` or automatic on pane open/close) sweeps the status bar into the tiled grid and leaves an empty `pane size=1 borderless=true` placeholder at the bottom. Fresh (never-resurrected) sessions are immune because both sides still carry the alias.

Two-part workaround:
- `statusbar-fixed.kdl` mirrors the built-in default layout + swap layouts (`zellij setup --dump-layout default`, `--dump-swap-layout default`) but uses `zellij:`-prefixed URLs on **both** sides, so the strings survive the serialize/resurrect round-trip. Keep every `plugin location` in this file prefixed — one unprefixed alias reintroduces the bug.
- `zellij-fix-statusbar.sh` rewrites the cached `session-layout.kdl` of every **non-running** session to the prefixed form. Run by the installer and by the hook (background) on each resurrection. It must keep skipping live sessions: their server rewrites the file and the in-memory swap layouts are already parsed.

To reproduce/verify: start a session, open ~6 panes, `kill -9` its server (never `pkill zellij` — other sessions!), `zellij attach`, then `zellij action next-swap-layout` and inspect `zellij action dump-layout` — the status-bar pane must stay the last top-level node of the tab.

## Installer invariants

`install.sh` patches three settings in `~/.config/zellij/config.kdl`: `on_force_close "detach"`, `session_serialization true`, `post_command_discovery_hook "<path>"`. All three are required for the recovery loop; removing any one silently breaks recovery. With `--with-layout` it additionally sets `default_layout "statusbar-fixed"`. It always installs and runs `zellij-fix-statusbar.sh` (safe: only touches dead sessions' caches).

Hard rules enforced by the installer (preserve these if editing):
- It **aborts** if an active `post_command_discovery_hook` pointing elsewhere already exists — never silently overwrite a user's hook.
- The `statusbar-fixed` layout is installed under its own name and never replaces the built-in `default` layout (`default_layout` is a config pointer, not a file overwrite).
- `codex-zellij` is only installed when `codex` is on PATH.
- `opencode-zellij` is only installed when `opencode` is on PATH.
- `patch_setting()` uses awk to replace the first match (commented or active) and drop duplicates; don't rewrite this with `sed -i` — it needs to handle `//`-commented variants too.

## Gotchas

- Bash `!var` inside awk heredocs triggers history expansion. Use `var == 0` style comparisons instead.
- Claude Code deletes session files after ~30 days (`cleanupPeriodDays`) and never writes a file for a session that received no messages — any stored session ID must be existence-checked (`~/.claude/projects/*/<id>.jsonl`) before building a `--resume` command.
- `zellij -l <layout> -s <name>` does NOT start a new session in 0.43 — it adds the layout as a tab to an existing session (and errors if it doesn't exist). Use `zellij -n <layout> -s <name>` for tests.
- When testing crash recovery, kill only the target session's server: `kill -9 $(pgrep -f 'zellij --serve[r].*<name>')`. The `[r]` stops pgrep from matching your own shell's command line — without it you kill the test harness itself.
- Whether Zellij serializes the wrapper or the child CLI on crash depends on Zellij's command-discovery heuristics. Codex recovery has a best-effort `codex resume --last` fallback for the case where Zellij sees the child; Claude's PTY-proxy architecture makes the wrapper the obvious pane leader.
- Claude's MCP servers (e.g. Context7) spawn as children of `claude` and have historically confused Zellij's discovery — this is the reason the wrapper runs claude as a child instead of `exec`ing it.
- The primary Claude session watcher reads `"sessionId"` from `~/.claude/sessions/<pid>.json` (present since at least claude 2.1.126); the legacy fallback keys on `"sessionId"` and `"display":"/resume ..."` in `history.jsonl`. If either format changes, the watcher needs updating.
- Claude started with `CLAUDE_CODE_CHILD_SESSION=1` in its environment does **not** write a `~/.claude/sessions/<pid>.json` entry. This bites test harnesses: a zellij server spawned from inside a Claude Code session passes that variable to every pane. Scrub `CLAUDE*` env vars (`env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION ...`) when launching test zellij sessions that need the registry.
- opencode's `-s/--session` only resumes *existing* sessions (upstream issue #17344); it cannot create a session with a caller-chosen id. This is why opencode-zellij captures the id opencode mints rather than injecting one (unlike claude-zellij).
- opencode session ids are `ses_...` (not UUIDs) and live in the SQLite db `~/.local/share/opencode/opencode.db` (table `session`). The wrapper reads them via `opencode session list --format json`; it never queries the DB directly, to avoid coupling to the schema.
- opencode's `session list` omits archived sessions in practice, so id presence == resumable.
- The opencode-zellij capture watcher polls for ~10 minutes; if the user never sends a message in that window (and opencode only creates the session row on first message), capture fails silently and that pane won't resume after a crash. The watcher prints a stderr notice when it gives up.
- Two opencode-zellij panes launched in the same CWD within the same poll window can both capture the same (first-minted) session. Known limitation; documented in README troubleshooting.
- opencode default TUI behavior and session-row creation timing (startup vs first message) must be verified (Task 7) — they determine whether the user must type before a crash for recovery to work.
- The opencode watcher subshell uses `set +e` (unlike the main wrapper's `set -euo pipefail`) so transient `opencode session list` failures retry instead of killing the watcher. Same pattern as claude-zellij's `_watch_session_registry`.
