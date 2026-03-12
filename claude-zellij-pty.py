#!/usr/bin/env python3
"""PTY proxy for claude-zellij with an in-band Ctrl+Y reboot hotkey."""

from __future__ import annotations

import os
import pty
import select
import signal
import fcntl
import sys
import termios
import tty


REBOOT_KEY = b"\x19"  # Ctrl+Y


def get_winsize(fd: int) -> bytes | None:
    try:
        return fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8)
    except OSError:
        return None


def apply_winsize(fd: int, winsize: bytes | None) -> None:
    if winsize is None:
        return
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, winsize)
    except OSError:
        pass


def parse_argv(argv: list[str]) -> tuple[str, str, list[str], list[str]]:
    if len(argv) < 4 or argv[0] != "--wrapper" or argv[2] != "--marker":
        raise SystemExit("usage: claude-zellij-pty.py --wrapper <path> --marker <id> [wrapper args...] -- <child cmd...>")

    wrapper = argv[1]
    marker = argv[3]
    remainder = argv[4:]
    if "--" not in remainder:
        raise SystemExit("missing -- separator")

    sep = remainder.index("--")
    wrapper_args = remainder[:sep]
    child_cmd = remainder[sep + 1 :]
    if not child_cmd:
        raise SystemExit("missing child command")
    return wrapper, marker, wrapper_args, child_cmd


def restore_tty(fd: int, attrs: list) -> None:
    try:
        termios.tcsetattr(fd, termios.TCSADRAIN, attrs)
    except termios.error:
        pass


def wait_exit_code(pid: int) -> int:
    _, status = os.waitpid(pid, 0)
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1


def terminate_child(pid: int) -> None:
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            return
        try:
            os.waitpid(pid, 0)
            return
        except ChildProcessError:
            return
        except InterruptedError:
            continue


def main() -> int:
    wrapper, marker, wrapper_args, child_cmd = parse_argv(sys.argv[1:])

    stdin_fd = sys.stdin.fileno()
    stdout_fd = sys.stdout.fileno()
    old_tty = termios.tcgetattr(stdin_fd)
    pending_resize = False

    def handle_sigwinch(_signum: int, _frame: object) -> None:
        nonlocal pending_resize
        pending_resize = True

    pid, master_fd = pty.fork()
    if pid == 0:
        os.execvp(child_cmd[0], child_cmd)

    signal.signal(signal.SIGWINCH, handle_sigwinch)
    apply_winsize(master_fd, get_winsize(stdin_fd))
    tty.setraw(stdin_fd)

    try:
        while True:
            if pending_resize:
                pending_resize = False
                winsize = get_winsize(stdin_fd)
                apply_winsize(master_fd, winsize)
                try:
                    os.kill(pid, signal.SIGWINCH)
                except ProcessLookupError:
                    pass

            readable, _, _ = select.select([stdin_fd, master_fd], [], [], 0.25)
            if not readable:
                continue

            if stdin_fd in readable:
                data = os.read(stdin_fd, 1024)
                if not data:
                    terminate_child(pid)
                    return 0

                reboot_index = data.find(REBOOT_KEY)
                if reboot_index != -1:
                    prefix = data[:reboot_index]
                    if prefix:
                        os.write(master_fd, prefix)
                    terminate_child(pid)
                    restore_tty(stdin_fd, old_tty)
                    os.write(stdout_fd, b"\r\n[claude-zellij] rebooting current Claude session...\r\n")
                    os.execv(wrapper, [wrapper, "--zellij-marker", marker, *wrapper_args])

                os.write(master_fd, data)

            if master_fd in readable:
                try:
                    output = os.read(master_fd, 4096)
                except OSError:
                    output = b""

                if not output:
                    return wait_exit_code(pid)

                os.write(stdout_fd, output)
    finally:
        restore_tty(stdin_fd, old_tty)
        try:
            os.close(master_fd)
        except OSError:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
