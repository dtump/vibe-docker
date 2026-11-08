# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
"""The .git/config overlay must never follow a symlink.

The workspace is writable from inside the container, and run.sh copies
`<ws>/.git/config` on the host before mounting the copy back in. If a link at
`.git` or `.git/config` were followed, that copy would carry an arbitrary host
file into the container. This runs the real run.sh against a stub container
runtime that records its argv, so no image or engine is needed.

Stdlib only, so CI's unit-test step keeps running with no install step.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUN_SH = ROOT / "run.sh"

STUB = """#!/bin/sh
# Record only the final `run --rm` (the agent container); every other call
# (stale-resource prune, etc.) is a silent no-op.
[ "$1 $2" = "run --rm" ] && printf '%s\\n' "$@" > "$ARGV_OUT"
exit 0
"""


class GitConfigOverlayTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        stub = self.bin / "docker"
        stub.write_text(STUB)
        stub.chmod(0o755)
        self.secret = self.tmp / "secret"
        self.secret.write_text("host-only\n")

    def tearDown(self):
        subprocess.run(["rm", "-rf", str(self.tmp)], check=False)

    def overlay_mounted(self, ws: Path) -> bool:
        argv_out = self.tmp / "argv"
        env = {
            "HOME": str(self.home),
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "VIBE_DOCKER_RUNTIME": "docker",
            "ARGV_OUT": str(argv_out),
        }
        subprocess.run(["bash", str(RUN_SH), str(ws)], env=env, check=True,
                       capture_output=True)
        return f"/workspaces/{ws.name}/.git/config" in argv_out.read_text()

    def test_real_git_dir_is_overlaid(self):
        ws = self.tmp / "real"
        (ws / ".git").mkdir(parents=True)
        (ws / ".git" / "config").write_text("[core]\n")
        self.assertTrue(self.overlay_mounted(ws))

    def test_symlinked_config_is_not_overlaid(self):
        ws = self.tmp / "linkcfg"
        (ws / ".git").mkdir(parents=True)
        (ws / ".git" / "config").symlink_to(self.secret)
        self.assertFalse(self.overlay_mounted(ws))

    def test_symlinked_git_dir_is_not_overlaid(self):
        target = self.tmp / "elsewhere"
        target.mkdir()
        (target / "config").write_text("host-only\n")
        ws = self.tmp / "linkdir"
        ws.mkdir()
        (ws / ".git").symlink_to(target)
        self.assertFalse(self.overlay_mounted(ws))


if __name__ == "__main__":
    unittest.main()
