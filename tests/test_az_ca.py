# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
"""--az must fail loudly when VIBE_DOCKER_AZ_CA names no file.

Under --az VIBE_DOCKER_AZ_CA is mounted and installed as a CA; a
dangling path would otherwise surface later as an opaque TLS failure. The check
runs before container-runtime detection, so this needs no docker.

Stdlib only, so CI's unit-test step keeps running with no install step.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

RUN_SH = Path(__file__).resolve().parent.parent / "run.sh"


class AzCaBundle(unittest.TestCase):
    def test_missing_file_is_refused(self):
        env = dict(os.environ, VIBE_DOCKER_AZ_CA="/nonexistent/tfs-ca.pem")
        with tempfile.TemporaryDirectory() as ws:
            r = subprocess.run(["bash", str(RUN_SH), "--az", ws],
                               env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("VIBE_DOCKER_AZ_CA '/nonexistent/tfs-ca.pem' is not a file", r.stderr)


if __name__ == "__main__":
    unittest.main()
