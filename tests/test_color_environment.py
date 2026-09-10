"""Regression tests for automation environment leaking into interactive panes."""
import errno
import json
import os
from pathlib import Path
import pty
import select
import subprocess
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = '''source "$1"
python3 -c 'import json, os; print(json.dumps({k: os.environ.get(k) for k in ["NO_COLOR", "COLORTERM"]}))'
'''


def launch(overrides, terminal=True):
    env = os.environ.copy()
    for key in ("ZELLIJ", "CODEX_CI", "NO_COLOR", "COLORTERM"):
        env.pop(key, None)
    env.update(overrides)
    command = ["bash", "-c", SCRIPT, "bash", str(ROOT / "zellij-color-env.sh")]
    if not terminal:
        return json.loads(subprocess.check_output(command, env=env, timeout=5))
    master, slave = pty.openpty()
    process = subprocess.Popen(command, env=env, stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    output = bytearray()
    try:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if not select.select([master], [], [], 0.1)[0]:
                continue
            try:
                chunk = os.read(master, 4096)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            output.extend(chunk)
        else:
            raise TimeoutError("Color environment test did not exit")
        assert process.wait(timeout=1) == 0, output
        return json.loads(output)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)


class ColorEnvironmentTests(unittest.TestCase):
    def test_automation_created_interactive_pane(self):
        self.assertEqual(
            launch(dict(ZELLIJ="0", CODEX_CI="1", NO_COLOR="1", COLORTERM="")),
            dict(NO_COLOR=None, COLORTERM=None),
        )

    def test_user_color_preference_is_preserved(self):
        self.assertEqual(
            launch(dict(ZELLIJ="0", NO_COLOR="1", COLORTERM="truecolor")),
            dict(NO_COLOR="1", COLORTERM="truecolor"),
        )

    def test_noninteractive_tool_output_is_unchanged(self):
        self.assertEqual(
            launch(dict(ZELLIJ="0", CODEX_CI="1", NO_COLOR="1", COLORTERM=""), False),
            dict(NO_COLOR="1", COLORTERM=""),
        )

    def test_other_terminals_are_unchanged(self):
        self.assertEqual(
            launch(dict(CODEX_CI="1", NO_COLOR="1", COLORTERM="")),
            dict(NO_COLOR="1", COLORTERM=""),
        )


if __name__ == "__main__":
    unittest.main()
