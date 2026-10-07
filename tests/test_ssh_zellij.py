"""Tests for ssh-zellij, the ssh wrapper with Ctrl+Y and automatic reconnect.

The PTY tests put a fake ssh first on PATH. It answers "ssh -G" and then acts
like a remote shell: each line typed is a command, and some commands imitate how
real ssh sessions end (logout, lost link, authentication failure, ~.).
"""
import errno
import fcntl
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "ssh-zellij"
HOOK = ROOT / "zellij-resurrect-hook.sh"

_loader = SourceFileLoader("ssh_zellij", str(TOOL))
ssh_zellij = module_from_spec(spec_from_loader("ssh_zellij", _loader))
_loader.exec_module(ssh_zellij)

FAKE_SSH = r'''#!/usr/bin/env python3
import fcntl, os, re, signal, struct, sys, termios, tty
state = os.environ["FAKE_SSH_STATE"]
args = sys.argv[1:]
if args[:1] == ["-G"]:
    alive = os.environ.get("FAKE_SSH_ALIVE", "0")
    print(f"user tester\nhostname example\nport 22\nserveraliveinterval {alive}\nconnecttimeout none")
    sys.exit(0)
with open(os.path.join(state, "calls"), "a") as calls:
    calls.write(" ".join(args) + "\n")
with open(os.path.join(state, "calls")) as calls:
    session = len(calls.readlines())
if os.isatty(0):
    tty.setraw(0)
os.write(1, f"FAKE-SESSION-{session}\r\n".encode())
buffer = b""
while True:
    data = os.read(0, 1024)
    if not data:
        sys.exit(255)
    buffer += data
    while re.search(rb"[\r\n]", buffer):
        line, buffer = re.split(rb"\r\n|\r|\n", buffer, maxsplit=1)
        command = line.decode(errors="replace").strip()
        if command.startswith("exit"):
            parts = command.split()
            os.write(1, b"logout\r\nConnection to example closed.\r\n")
            sys.exit(int(parts[1]) if len(parts) > 1 else 0)
        if command == "drop":
            os.write(1, b"Timeout, server example not responding.\r\n")
            sys.exit(255)
        if command == "deny":
            os.write(1, b"tester@example: Permission denied (publickey).\r\n")
            sys.exit(255)
        if command == "tilde":
            os.write(1, b"Connection to example closed.\r\n")
            sys.exit(255)
        if command == "hang":
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if command == "size":
            rows, cols = struct.unpack("HHHH", fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8))[:2]
            os.write(1, f"SIZE={rows}x{cols}\r\n".encode())
            continue
        os.write(1, f"ran:{command}\r\n".encode())
'''


class FakeSsh:
    """A directory with the fake ssh, and an environment that finds it first."""

    def __init__(self, test, env=None):
        self.state = tempfile.mkdtemp(prefix="ssh-zellij-test-")
        test.addCleanup(subprocess.run, ["rm", "-rf", self.state])
        bindir = os.path.join(self.state, "bin")
        os.mkdir(bindir)
        fake = os.path.join(bindir, "ssh")
        with open(fake, "w") as handle:
            handle.write(FAKE_SSH)
        os.chmod(fake, 0o755)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("SSH_ZELLIJ")}
        self.env.update(PATH=bindir + os.pathsep + os.environ["PATH"], FAKE_SSH_STATE=self.state, NO_COLOR="1")
        self.env.update(env or {})

    def calls(self):
        with open(os.path.join(self.state, "calls")) as handle:
            return [line.rstrip("\n") for line in handle]


class Pane(FakeSsh):
    """ssh-zellij running on a pseudo-terminal, like a Zellij pane."""

    def __init__(self, test, args, env=None):
        super().__init__(test, env)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execve(str(TOOL), [str(TOOL), *args], self.env)
        test.addCleanup(self.close)
        self.resize(24, 80)
        self.output = b""
        self.mark = 0

    def resize(self, rows, cols):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def close(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        except (ProcessLookupError, ChildProcessError):
            pass
        os.close(self.fd)

    def pump(self, seconds):
        deadline = time.monotonic() + seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.fd], [], [], remaining)[0]:
                return True
            try:
                chunk = os.read(self.fd, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    return False
                raise
            if not chunk:
                return False
            self.output += chunk

    def expect(self, pattern, timeout=10):
        regex = re.compile(pattern.encode())
        deadline = time.monotonic() + timeout
        while True:
            match = regex.search(self.output, self.mark)
            if match:
                self.mark = match.end()
                return match
            if time.monotonic() > deadline or not self.pump(0.1):
                match = regex.search(self.output, self.mark)
                if match:
                    self.mark = match.end()
                    return match
                raise AssertionError(f"no {pattern!r} in output:\n{self.output.decode(errors='replace')}")

    def send(self, data):
        os.write(self.fd, data.encode() if isinstance(data, str) else data)

    def exit_code(self, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.pump(0.1)
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                return os.waitstatus_to_exitcode(status)
        raise AssertionError("ssh-zellij did not exit")


class ProxyTests(unittest.TestCase):
    def test_ctrl_y_reconnects_in_place(self):
        pane = Pane(self, ["example"])
        pane.expect(r"Ctrl\+Y reconnects this pane")
        pane.expect(r"FAKE-SESSION-1")
        pane.send("before\r")
        pane.expect(r"ran:before")
        pane.send(b"\x19")
        pane.expect(r"Ctrl\+Y: reconnecting to example")
        pane.expect(r"FAKE-SESSION-2")
        pane.send("exit\r")
        self.assertEqual(pane.exit_code(), 0)
        injected = "-o ServerAliveInterval=10 -o ConnectTimeout=10 example"
        self.assertEqual(pane.calls(), [injected, injected])

    def test_ctrl_y_kills_ssh_that_ignores_sigterm(self):
        pane = Pane(self, ["example"])
        pane.expect(r"FAKE-SESSION-1")
        pane.send("hang\r")
        pane.expect(r"ran:hang")
        started = time.monotonic()
        pane.send(b"\x19")
        pane.expect(r"FAKE-SESSION-2", timeout=5)
        self.assertLess(time.monotonic() - started, 3)

    def test_lost_connection_reconnects_automatically(self):
        pane = Pane(self, ["example"])
        pane.expect(r"FAKE-SESSION-1")
        pane.send("drop\r")
        pane.expect(r"Connection to example lost \(ssh exit 255\)")
        pane.expect(r"Reconnecting in \d+s")
        pane.expect(r"FAKE-SESSION-2", timeout=10)
        pane.send("exit 3\r")
        self.assertEqual(pane.exit_code(), 3)

    def test_enter_skips_the_backoff(self):
        pane = Pane(self, ["example"])
        pane.expect(r"FAKE-SESSION-1")
        pane.send("drop\r")
        pane.expect(r"Reconnecting in \d+s")
        pane.send("\r")
        pane.expect(r"FAKE-SESSION-2", timeout=1.5)

    def test_authentication_failure_waits_for_the_user(self):
        pane = Pane(self, ["example"])
        pane.expect(r"FAKE-SESSION-1")
        pane.send("deny\r")
        pane.expect(r"not reconnecting automatically")
        pane.expect(r"Ctrl\+Y/Enter: reconnect \| q: quit")
        pane.pump(2.5)
        self.assertEqual(len(pane.calls()), 1)
        pane.send("\r")
        pane.expect(r"FAKE-SESSION-2")

    def test_q_at_the_prompt_quits_with_ssh_status(self):
        pane = Pane(self, ["example"])
        pane.expect(r"FAKE-SESSION-1")
        pane.send("deny\r")
        pane.expect(r"q: quit")
        pane.send("q")
        self.assertEqual(pane.exit_code(), 255)

    def test_escape_close_is_not_retried_automatically(self):
        pane = Pane(self, ["example"])
        pane.expect(r"FAKE-SESSION-1")
        pane.send("tilde\r")
        pane.expect(r"Ctrl\+Y/Enter: reconnect \| q: quit")
        pane.pump(2.5)
        self.assertEqual(len(pane.calls()), 1)

    def test_remote_command_is_not_rerun_automatically(self):
        pane = Pane(self, ["example", "uptime"])
        pane.expect(r"FAKE-SESSION-1")
        pane.send("drop\r")
        pane.expect(r"lost \(ssh exit 255\)")
        pane.expect(r"Ctrl\+Y/Enter: reconnect \| q: quit")
        pane.pump(2.5)
        self.assertEqual(len(pane.calls()), 1)
        pane.send("q")
        self.assertEqual(pane.exit_code(), 255)

    def test_auto_reconnect_can_be_forced_for_remote_commands(self):
        pane = Pane(self, ["example", "tmux", "attach"], env={"SSH_ZELLIJ_AUTO": "1"})
        pane.expect(r"FAKE-SESSION-1")
        pane.send("drop\r")
        pane.expect(r"FAKE-SESSION-2", timeout=10)

    def test_configured_keepalive_is_respected(self):
        pane = Pane(self, ["-o", "ConnectTimeout=5", "example"], env={"FAKE_SSH_ALIVE": "30"})
        pane.expect(r"FAKE-SESSION-1")
        self.assertEqual(pane.calls(), ["-o ConnectTimeout=5 example"])

    def test_custom_key(self):
        pane = Pane(self, ["example"], env={"SSH_ZELLIJ_KEY": "^]"})
        pane.expect(r"Ctrl\+\] reconnects this pane")
        pane.expect(r"FAKE-SESSION-1")
        pane.send(b"\x19x\r")
        pane.expect(r"ran:\x19x")
        pane.send(b"\x1d")
        pane.expect(r"FAKE-SESSION-2")

    def test_window_size_follows_the_pane(self):
        pane = Pane(self, ["example"])
        pane.expect(r"FAKE-SESSION-1")
        pane.send("size\r")
        pane.expect(r"SIZE=24x80")
        pane.resize(40, 120)
        os.kill(pane.pid, signal.SIGWINCH)
        time.sleep(0.2)
        pane.send("size\r")
        pane.expect(r"SIZE=40x120")

    def test_without_a_terminal_it_is_plain_ssh(self):
        fake = FakeSsh(self)
        result = subprocess.run([str(TOOL), "example"], input=b"exit 4\n", env=fake.env,
                                stdout=subprocess.PIPE, timeout=10)
        self.assertEqual(result.returncode, 4)
        self.assertEqual(fake.calls(), ["example"])


class ParsingTests(unittest.TestCase):
    def test_ssh_arguments(self):
        cases = {
            ("host",): ("host", []),
            ("-p", "22", "host"): ("host", []),
            ("-p22", "host", "ls", "-la"): ("host", ["ls", "-la"]),
            ("host", "-p", "2222"): ("host", []),
            ("host", "-t", "tmux", "attach"): ("host", ["tmux", "attach"]),
            ("-NL", "8080:localhost:80", "host"): ("host", []),
            ("-oServerAliveInterval=5", "host"): ("host", []),
            ("--", "host", "ls"): ("host", ["ls"]),
            ("host", "--", "-v"): ("host", ["-v"]),
            ("-V",): (None, []),
        }
        for args, expected in cases.items():
            destination, command, _ = ssh_zellij.parse_ssh_args(list(args))
            self.assertEqual((destination, command), expected, args)

    def test_keys(self):
        for spec in ("^Y", "^y", "ctrl+y", "Ctrl-Y", "C-y"):
            self.assertEqual(ssh_zellij.parse_key(spec), 0x19, spec)
        self.assertEqual(ssh_zellij.parse_key("^]"), 0x1D)
        self.assertIsNone(ssh_zellij.parse_key("none"))
        with self.assertRaises(ValueError):
            ssh_zellij.parse_key("F5")

    def test_key_encodings(self):
        find = ssh_zellij.find_key
        self.assertEqual(find(b"ab\x19cd", 0x19), (2, 3))
        self.assertEqual(find(b"\x1b[121;5u", 0x19), (0, 8))  # kitty keyboard protocol
        self.assertEqual(find(b"\x1b[121;69u", 0x19), (0, 9))  # with caps lock
        self.assertEqual(find(b"\x1b[27;5;121~", 0x19), (0, 11))  # xterm modifyOtherKeys
        self.assertIsNone(find(b"\x1b[121;5:3u", 0x19))  # key release
        self.assertIsNone(find(b"\x1b[121;7u", 0x19))  # Ctrl+Alt+Y
        self.assertIsNone(find(b"y", 0x19))

    def test_prompt_keys(self):
        action = ssh_zellij.prompt_action
        for data in (b"\r", b"r", b"\x19", b"\x1b[13u", b"\x1b[121;5u"):
            self.assertEqual(action(data, 0x19), "reconnect", data)
        for data in (b"q", b"\x03", b"\x04", b"\x1b[99;5u"):
            self.assertEqual(action(data, 0x19), "quit", data)
        self.assertIsNone(action(b"x", 0x19))

    def test_exit_classification(self):
        classify = ssh_zellij.classify
        self.assertEqual(classify(0, None, b"logout\r\nConnection to h closed.\r\n"), "exit")
        self.assertEqual(classify(255, None, b"Timeout, server h not responding.\r\n"), "lost")
        self.assertEqual(classify(255, None, b"client_loop: send disconnect: Broken pipe\r\n"), "lost")
        self.assertEqual(classify(255, None, b"Connection to h closed by remote host.\r\n"), "lost")
        self.assertEqual(classify(255, None, b"u@h: Permission denied (publickey).\r\n"), "fatal")
        self.assertEqual(classify(255, None, b"Host key verification failed.\r\n"), "fatal")
        self.assertEqual(classify(255, None, b"\x1b[0mConnection to h closed.\r\n"), "closed")
        self.assertEqual(classify(None, 9, b""), "signal")
        # An old error far up in the session output does not stop reconnecting.
        old = b"u@other: Permission denied (publickey).\r\n" + b"ok\r\n" * 5
        self.assertEqual(classify(255, None, old + b"Timeout, server h not responding.\r\n"), "lost")

    def test_keepalive_injection(self):
        unset = {"serveraliveinterval": "0", "connecttimeout": "none"}
        self.assertEqual(ssh_zellij.ssh_command(["h"], unset),
                         ["ssh", "-o", "ServerAliveInterval=10", "-o", "ConnectTimeout=10", "h"])
        self.assertEqual(ssh_zellij.ssh_command(["h"], {"serveraliveinterval": "15", "connecttimeout": "3"}),
                         ["ssh", "h"])
        # An explicit "-o ServerAliveInterval=0" means the user turned it off.
        self.assertEqual(ssh_zellij.ssh_command(["-o", "ServerAliveInterval=0", "h"], unset),
                         ["ssh", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=0", "h"])


class ResurrectHookTests(unittest.TestCase):
    def hook(self, command):
        with tempfile.TemporaryDirectory() as home:  # keep the background layout fixer away from real caches
            env = dict(os.environ, HOME=home, RESURRECT_COMMAND=command)
            return subprocess.run([str(HOOK)], env=env, capture_output=True, text=True, timeout=10).stdout.strip()

    def test_bare_ssh_is_resurrected_through_ssh_zellij(self):
        self.assertEqual(self.hook("ssh user@server.example.com"), f"{TOOL} user@server.example.com")
        self.assertEqual(self.hook("ssh -p 2222 host tmux new -A -s main"), f"{TOOL} -p 2222 host tmux new -A -s main")

    def test_other_commands_are_unchanged(self):
        for command in ("ssh", "sshfs host:/ /mnt", f"python3 {TOOL} host"):
            self.assertEqual(self.hook(command), command)

    def test_remote_claude_command_is_not_rewritten_as_local(self):
        command = "ssh host python3 /x/claude-zellij-pty.py --wrapper /x/claude-zellij --marker m -- claude"
        self.assertEqual(self.hook(command), f"{TOOL} host python3 /x/claude-zellij-pty.py "
                                             "--wrapper /x/claude-zellij --marker m -- claude")


if __name__ == "__main__":
    unittest.main()
