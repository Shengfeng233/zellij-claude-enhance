# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Per-pane session recovery for Claude Code and Codex CLI running inside Zellij, Ctrl+Y reconnect for ssh panes, plus fixes for scrollback, inherited color settings, and status-bar displacement. The deliverable is small recovery and installation scripts plus a layout. There is no build system or package manager. Changes are validated by syntax checks, Python standard-library regression tests, and manual terminal/crash-recovery testing.

## Common commands

```bash
# Install / reinstall to ~/.local/bin and patch ~/.config/zellij/config.kdl
./install.sh
./install.sh --with-layout   # also installs statusbar-fixed.kdl (+ Move Tab status bar on Zellij 0.45.x)

# Rebuild the Move Tab status bar after bumping status-bar/ZELLIJ_VERSION (temp Rust toolchain, ~3 min):
./status-bar/build.sh

# Regression tests (color environment, layout repair, ssh-zellij PTY proxy + hook rule):
python3 -m unittest discover -s tests -v

# Syntax checks:
bash -n claude-zellij
bash -n codex-zellij
bash -n zellij-resurrect-hook.sh
bash -n zellij-fix-statusbar.sh
python3 -m py_compile claude-zellij-pty.py
python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' ssh-zellij

# Unit-style hook tests (see README "Hook tests" for more cases)
RESURRECT_COMMAND="claude" ./zellij-resurrect-hook.sh
RESURRECT_COMMAND="claude --session-id 11111111-1111-1111-1111-111111111111" ./zellij-resurrect-hook.sh
RESURRECT_COMMAND="python3 /x/claude-zellij-pty.py --wrapper /x/claude-zellij --marker abc -- claude --session-id def" ./zellij-resurrect-hook.sh
RESURRECT_COMMAND="codex" ./zellij-resurrect-hook.sh
RESURRECT_COMMAND="codex exec do something" ./zellij-resurrect-hook.sh
RESURRECT_COMMAND="ssh user@server.example.com" ./zellij-resurrect-hook.sh

# End-to-end crash test (destructive — kills all zellij sessions)
zellij -s test-recovery
# ...run claude-zellij in a pane, send a message...
pkill -9 zellij
zellij attach test-recovery
```

## Architecture: the moving parts

Session recovery hinges on how the wrappers, the resurrection hook and the PTY proxy cooperate. A change in one usually requires thinking about the other two.

### 1. The wrappers (`claude-zellij`, `codex-zellij`)

Both follow the same "marker UUID + re-exec" pattern:

1. First invocation generates a UUID, then **re-execs itself** with `--zellij-marker <uuid>` prepended. This bakes the marker into the process's command line so Zellij serializes it to disk.
2. The real CLI (`claude` / `codex`) is launched as a **child process, not via `exec`**, so Zellij's command discovery doesn't pick up an MCP child or the bare CLI. For Codex the wrapper itself stays alive as pane leader; for Claude the wrapper `exec`s into the PTY proxy (see part 3), so **the proxy is the pane leader** and the serialized command is the proxy's command line — hook rule 1 rewrites it back to the wrapper.
3. A background watcher (`trap '' INT TERM HUP` so it survives signals meant for the child) records the real session ID into `~/.local/share/{claude,codex}-zellij/markers/<uuid>`:
   - Claude: polls `~/.claude/sessions/<pid>.json` — the registry each claude process keeps for itself and rewrites in place whenever its active session changes (`/resume` picker, `/resume <name-or-uuid>`, `/clear`). The watcher resolves OUR claude child through the proxy's process tree every tick (Ctrl+Y reboots replace the child), so tracking is pane-exact and works even if the user switches sessions and quits immediately without typing. Falls back to a `history.jsonl` heuristic (`/resume` display lines + next-prompt session change) when the registry doesn't exist.
   - Codex: polls `~/.codex/session_index.jsonl` for the next new entry after startup (Codex has no `--session-id`).
4. On re-invocation with an existing marker file, the wrapper runs `claude --resume <id>` or `codex resume <id>`, **after validating that the session still exists on disk** (`~/.claude/projects/*/<id>.jsonl`). A stored ID stops resolving when Claude's ~30-day cleanup deletes it or when the session never received a message; the wrapper then prints a notice and starts a fresh tracked session (new UUID written to the same marker file) instead of letting claude die with "No conversation found". User args are passed through on both the fresh and resume paths. Markers untouched for 45+ days are GC'd at startup.

The wrappers also have **passthrough rules** — specific flags (`-p`, `--resume`, `--continue`, `--session-id`, etc.) and subcommands (`mcp`, `doctor`, `exec`, `login`, ...) bypass the marker logic entirely and `exec` the real CLI. When adding new CLI flags/subcommands upstream, update `PASSTHROUGH_FLAGS`, `SUBCOMMANDS`, `NON_INTERACTIVE_SUBCOMMANDS`, `INTERACTIVE_SUBCOMMANDS`, and `codex_flag_takes_value()` accordingly.

### 2. The resurrection hook (`zellij-resurrect-hook.sh`)

Zellij calls this via `post_command_discovery_hook` with `RESURRECT_COMMAND` in the environment. It must print the (possibly rewritten) command to stdout.

Matching order matters:
0. `ssh <args>` → `<hook dir>/ssh-zellij <args>` (rest of the line verbatim) when ssh-zellij is installed next to the hook. It comes first so a remote command mentioning claude/codex is never rewritten as a local one. Bare `ssh` with no arguments is left alone.
1. `... claude-zellij-pty.py --wrapper <path> --marker <uuid> [args] -- claude ...` → `<wrapper> --zellij-marker <uuid> [args]`. This is the normal serialized form of a claude-zellij pane (the proxy is the pane leader) and **must be matched before rule 3**: the proxy command line contains `.../claude-zellij ` as the `--wrapper` value, so rule 3's glob would otherwise pass it through verbatim and replay the stale `claude --session-id` child command.
2. `claude --session-id <uuid> ...` / `claude --resume <uuid> ...` → `claude --resume <uuid> ...` if `~/.claude/projects/*/<uuid>.jsonl` exists, else `claude --continue ...`. Bare `claude` → `claude --continue` (best-effort, per-CWD).
3. `claude-zellij ...` / `codex-zellij ...` (including full-path variants) → passed through unchanged so the wrapper's own marker logic runs.
4. `codex [flags] [subcommand] ...` → if a known non-resume subcommand is present, pass through; preserve explicit resume/fork with inline mode enabled; otherwise build `codex resume --last [--cd X] --no-alt-screen`, preserving `-C/--cd` because `resume --last` is CWD-scoped.
5. Everything else → unchanged.

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

### 5. The ssh reconnect proxy (`ssh-zellij`)

A plain ssh pane freezes when the network path dies (sleep, Wi-Fi/VPN change, Tailscale dropping the local 100.x address): with `ServerAliveInterval` unset ssh waits for the kernel (~15 min of retransmission with unacknowledged keystrokes, 2 h of TCP keepalive when idle), and raw mode sends every key, Ctrl+C included, into the dead socket. Zellij has no action that restarts or signals a pane's process, so the fix lives in the pane.

`ssh-zellij` is a single Python script (no bash wrapper, no marker): a PTY proxy that runs `ssh` on a private PTY whose termios and size are copied from the pane, so the remote PTY gets the same modes as with plain ssh.
- Ctrl+Y (`SSH_ZELLIJ_KEY`) at any time: SIGTERM+SIGCONT to ssh's process group, SIGKILL after 0.5 s, reset terminal modes, start ssh again. The key is also recognized in kitty CSI-u and modifyOtherKeys encodings (other terminals; Zellij 0.45.1 sends the raw byte even in kitty mode).
- ssh exit is classified from its status and the last 3 output lines: not 255 → exit with it (normal logout); 255 + auth/host-key/config message → wait for a key (auto-retry could trigger fail2ban); 255 + `Connection to X closed.` (`~.` or a logout returning 255) → wait for a key; other 255 → lost → automatic reconnect with backoff 1..30 s (reset after a session lasted 60 s), only when there is no remote command (`SSH_ZELLIJ_AUTO` overrides).
- `ServerAliveInterval=10` / `ConnectTimeout=10` are injected only when `ssh -G` reports them unset and the arguments don't mention them. ssh drops the link on the 4th unanswered probe, so detection takes ~40 s.
- Passthrough (`exec ssh`) when stdin/stdout is not a TTY, no destination is found, `ssh -G` rejects the arguments, or `-f/-G/-O/-Q/-V/-W` is given. `parse_ssh_args()` mirrors OpenSSH's getopt loop, which keeps parsing options after the destination; update `VALUE_OPTIONS` if ssh gains options.
- Serialization: a shell pane running it is discovered as `python3 .../ssh-zellij <args>` and passes through the hook unchanged; a bare `ssh` pane is upgraded by hook rule 0.

Verify against a real sshd without touching remote machines: run a user-level `/usr/sbin/sshd -f <cfg> -E <log>` on 127.0.0.1 with a scratch host key and `authorized_keys` (`UsePAM no`, `StrictModes no`), then simulate a dead link by SIGSTOPping the per-connection `sshd` processes under the listener. TCP stays up, so plain ssh hangs forever while ssh-zellij detects the loss through ServerAlive probes.

### 6. The Move Tab status bar (`status-bar/`)

Zellij binds `MoveTab` to `Alt i` / `Alt o`, but the built-in status bar's hint lists are hard-coded per action and never include it. `zellij:` plugins always load from the binary's embedded assets (a plugin-dir copy is ignored), so the hint needs a patched build loaded as a `file:` plugin. `status-bar/move-tab-hint.patch` (against the tag in `status-bar/ZELLIJ_VERSION`) adds `<i|o> Move Tab` to the normal-mode `Alt` group (appended last; prefers short labels plus the hint over long labels without it, never displaces an upstream entry) and `Move tab` to the tab- and move-mode lists, and calls `request_permission(ReadApplicationState, ChangeApplicationState)` because only `zellij:` plugins get permissions implicitly. `status-bar.wasm` is the committed build; `build.sh` reproduces it (byte differences come from embedded build paths).

- `install.sh --with-layout` installs it to `~/.local/share/zellij-improve/plugins/status-bar.wasm` only when the Zellij new sessions use (`zellij-improve/current/zellij`, not the dispatcher) matches its release series, and rewrites `location="zellij:status-bar"` in the installed layout to the absolute `file:` URL. Otherwise (or `--stock-status-bar`) it removes the plugin and installs the repo layout unchanged. The repo's `statusbar-fixed.kdl` keeps `zellij:status-bar`.
- Use an absolute path: `file:` locations are shell-expanded at parse time and serialized as `file:<abs>`, so live panes and swap slots match after resurrection like the `zellij:` form (verified: kill -9, resurrect, 3x next-swap-layout, bar stays last).
- Zellij keys permission grants by the bare plugin path in `~/.cache/zellij/permissions.kdl` (`$XDG_CACHE_HOME`). Without a grant the bar shows a y/n prompt in its one-row, unselectable pane that cannot be answered. `zellij-fix-statusbar.sh` therefore re-grants it on every run (dispatcher, hook, installer) while the plugin file exists.
- `zellij-layout-repair.py --status-bar <wasm>` normalizes dead sessions' saved bars: the patched URL is first turned back into `zellij:status-bar` so the stock-template regexes still match, then every `zellij:status-bar` becomes the installed `file:` URL. Without `--status-bar` (plugin removed) saved patched bars revert to `zellij:status-bar`. The fixer passes `--status-bar` only for `contract_version_*` cache dirs (0.45+); release-numbered dirs (`0.43.1/`) belong to legacy servers the plugin was not built for and stay stock.
- When bumping `upgrade-zellij.sh`'s version, bump `status-bar/ZELLIJ_VERSION`, refresh the patch if it no longer applies, rebuild, and reinstall with `--with-layout`. A plugin built against another release may fail to load, which would leave an error in place of the bar.

## Installer invariants

`install.sh` patches recovery settings in `~/.config/zellij/config.kdl`: `on_force_close "detach"`, `session_serialization true`, `post_command_discovery_hook "<path>"`. All three are required for the recovery loop; removing any one silently breaks recovery. It also enables `mouse_mode true` and removes the obsolete managed scroll-shortcut block from earlier installations. Codex scrolling with normal rich output requires Zellij >= 0.44.1; tested with 0.45.1. `upgrade-zellij.sh` installs a pinned, checksum-verified release and `zellij-dispatch` routes actions inside old sessions to their ancestor server executable. Servers cannot be upgraded by detach/reattach; migrate into a new server while retaining old processes. Do not force `tui.raw_output_mode=true`: it expands tool output and sacrifices the compact display the user wants. Test actual multi-screen conversation history, not shell output printed before Codex starts. With `--with-layout` it additionally sets `default_layout "statusbar-fixed"`. It always installs and runs `zellij-fix-statusbar.sh` (safe: only touches dead sessions' caches), which uses `zellij-layout-repair.py` and backs up changed files. The dispatcher also runs it before loading saved sessions. Besides plugin aliases it repairs the stock bare `new_tab_template { pane cwd="/" }` and removes the dump's top-level common-root cwd after making saved paths absolute. Both defects must be fixed for restored tabs to retain their bar and inherit cwd. Live detection must include the cache/socket version because old/new servers can share a session name. Bash's outer-shell executable cache may require `hash -r` after installation; inspect the actual client executable, not just PATH.

Hard rules enforced by the installer (preserve these if editing):
- It **aborts** if an active `post_command_discovery_hook` pointing elsewhere already exists — never silently overwrite a user's hook.
- The `statusbar-fixed` layout is installed under its own name and never replaces the built-in `default` layout (`default_layout` is a config pointer, not a file overwrite).
- The Move Tab status bar is installed only with `--with-layout` and a matching Zellij release series; without `--with-layout` the plugin and the installed layout are left as they are, so the layout never points at a missing plugin.
- `codex-zellij` is only installed when `codex` is on PATH; `ssh-zellij` only when `ssh` is on PATH (hook rule 0 checks that it exists next to the hook).
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
