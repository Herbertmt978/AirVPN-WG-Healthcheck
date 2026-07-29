"""Entrypoint isolation checks kept separate from setup CLI policy tests."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "bin" / "wg-healthcheck-setup"


class SetupEntrypointTests(unittest.TestCase):
    def test_entrypoint_is_thin_source_relative_and_ignores_pythonpath(self):
        self.assertLessEqual(len(SETUP.read_text(encoding="utf-8").splitlines()), 80)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bin_dir = root / "bin"
            package_parent = root / "libexec"
            hostile = root / "hostile"
            bin_dir.mkdir()
            package_parent.mkdir()
            hostile.mkdir()
            entrypoint = bin_dir / SETUP.name
            shutil.copy2(SETUP, entrypoint)
            shutil.copytree(
                ROOT / "libexec" / "wg_healthcheck_setup",
                package_parent / "wg_healthcheck_setup",
                ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
            )
            marker = root / "hostile-imported"
            (hostile / "wg_healthcheck_setup.py").write_text(
                "from pathlib import Path\n"
                f"Path({str(marker)!r}).write_text('imported', encoding='ascii')\n",
                encoding="ascii",
            )
            completed = subprocess.run(
                [sys.executable, str(entrypoint), "--help"],
                cwd=root,
                env={"PATH": os.environ.get("PATH", ""), "PYTHONPATH": str(hostile)},
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertFalse(marker.exists())
            self.assertFalse(
                (package_parent / "wg_healthcheck_setup" / "__pycache__").exists()
            )
