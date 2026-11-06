import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("harden_mole", ROOT / "scripts/harden-mole.py")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class MolePolicyTests(unittest.TestCase):
    def fixture(self, root):
        base = root / "libexec/lib/core/base.sh"
        base.parent.mkdir(parents=True)
        base.write_text("#!/bin/bash\nreadonly MOLE_BASE_LOADED=1\ndeclare -a SAFETY_WHITELIST_PATTERNS=(\n)\n")
        (base.parent / "sudo.sh").write_text("\n".join(
            name + '() {\n /usr/bin/touch "$MARKER"; return 0;\n}' for name in policy.AUTH_FUNCTIONS))
        tasks = root / "libexec/lib/optimize/tasks.sh"
        tasks.parent.mkdir(parents=True)
        tasks.write_text('opt_quarantine_cleanup() {\n /usr/bin/touch "$MARKER";\n}\n')
        return base

    def test_cached_sudo_and_child_shell_are_denied(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            base = self.fixture(root)
            marker = root / "sudo-executed"
            sudo = root / "sudo"
            sudo.write_text('#!/bin/sh\n/usr/bin/touch "$MARKER"\n')
            sudo.chmod(0o700)
            policy.harden(root)
            result = subprocess.run(["/bin/bash", "-c",
                'source "$1"; sudo -n true; a=$?; /bin/bash -c "sudo -n true"; b=$?; [ "$a:$b" = 1:1 ]',
                "test", str(base)], env={"PATH": folder + ":/usr/bin:/bin", "MARKER": str(marker)}, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertFalse(marker.exists())
            for name in policy.AUTH_FUNCTIONS:
                result = subprocess.run(["/bin/bash", "-c", 'source "$1"; ' + name,
                    "test", str(base.parent / "sudo.sh")], env={"MARKER": str(marker)}, capture_output=True)
                self.assertEqual(result.returncode, 1)
                self.assertFalse(marker.exists(), "Authorization must not collect a password or touch credentials")
            self.assertNotIn("MOLE_TEST_NO_AUTH=1", base.read_text())
            self.assertIn('"$HOME/.ssh/*"', base.read_text())
            self.assertIn('QuarantineEventsV2*', base.read_text())
            result = subprocess.run(["/bin/bash", "-c",
                'opt_msg() { :; }; optimize_task_result() { :; }; MOLE_OPTIMIZE_OUTCOME_SKIPPED=skip; source "$1"; opt_quarantine_cleanup',
                "test", str(root / "libexec/lib/optimize/tasks.sh")], env={"MARKER": str(marker)}, capture_output=True)
            self.assertEqual(result.returncode, 0)
            self.assertFalse(marker.exists(), "Optimize must preserve security history independently of the clean keep list")

    def test_changed_upstream_layout_fails_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            base = root / "libexec/lib/core/base.sh"
            base.parent.mkdir(parents=True)
            base.write_text("# unexpected upstream\n")
            with self.assertRaises(ValueError):
                policy.harden(root)

    def test_absolute_sudo_is_also_blocked(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            base = self.fixture(root)
            child = root / "libexec/child.sh"
            child.write_text('/usr/bin/sudo -u "$SUDO_USER" -- "$@"\n')
            policy.harden(root)
            self.assertNotIn("/usr/bin/sudo", child.read_text())

    def test_unreviewed_sudo_bypass_fails_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            base = root / "libexec/lib/core/base.sh"
            base.parent.mkdir(parents=True)
            base.write_text("readonly MOLE_BASE_LOADED=1\ncommand sudo true\n")
            with self.assertRaises(ValueError):
                policy.harden(root)
