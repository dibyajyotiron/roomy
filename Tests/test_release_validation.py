import importlib.util
import json
from pathlib import Path
import plistlib
import stat
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("release_validation", ROOT / "scripts/release-validation.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseValidationTests(unittest.TestCase):
    commit = "a" * 40
    mole = "b" * 40
    version = "1.2.3"

    def check(self, extra=None, dirty=False):
        with tempfile.TemporaryDirectory(prefix="roomy-release-fixture-") as folder:
            path = Path(folder) / "fixture.zip"
            with zipfile.ZipFile(path, "w") as z:
                prefix = "Roomy.app/Contents/"
                z.writestr(prefix + "Resources/BuildInfo.json", json.dumps({"sourceCommit": self.commit,
                    "dirty": dirty, "version": self.version, "moleCommit": self.mole}))
                z.writestr(prefix + "Info.plist", plistlib.dumps({"CFBundleIdentifier": "app.roomy.Roomy",
                    "CFBundleShortVersionString": self.version}))
                z.writestr(prefix + "Resources/mole/ROOMY_MOLE_COMMIT", self.mole)
                if extra:
                    extra(z)
            release.archive_info(path, self.version, self.commit, self.mole)

    def test_expected_archive(self):
        self.check()

    def test_dirty_source_rejected(self):
        with self.assertRaisesRegex(ValueError, "provenance"):
            self.check(dirty=True)

    def test_parent_traversal_rejected(self):
        with self.assertRaisesRegex(ValueError, "archive path"):
            self.check(lambda z: z.writestr("Roomy.app/../../escape", "fixture"))

    def test_absolute_path_rejected(self):
        with self.assertRaisesRegex(ValueError, "archive path"):
            self.check(lambda z: z.writestr("/tmp/escape", "fixture"))

    @staticmethod
    def link(z, name, target):
        entry = zipfile.ZipInfo(name)
        entry.create_system = 3
        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
        z.writestr(entry, target)

    def test_escaping_symlink_rejected(self):
        with self.assertRaisesRegex(ValueError, "symlink escapes"):
            self.check(lambda z: self.link(z, "Roomy.app/link", "../../outside"))

    def test_internal_sparkle_style_symlink_allowed(self):
        self.check(lambda z: self.link(z, "Roomy.app/Contents/Frameworks/Sparkle.framework/Versions/Current", "B"))

    def test_writing_through_symlink_rejected(self):
        def entries(z):
            self.link(z, "Roomy.app/link", "Contents")
            z.writestr("Roomy.app/link/file", "fixture")
        with self.assertRaisesRegex(ValueError, "writes through"):
            self.check(entries)

    def valid_ci(self):
        checks = [{"id": 1, "name": "Build Roomy", "head_sha": self.commit,
                   "app": {"id": 15368}, "status": "completed", "conclusion": "success"}]
        runs = [{"id": 1, "path": ".github/workflows/build.yml", "head_sha": self.commit,
                 "head_branch": "main", "event": "push", "status": "completed", "conclusion": "success"}]
        return checks, runs

    def test_matching_ci_accepted(self):
        self.assertTrue(release.ci_passed(*self.valid_ci(), self.commit))

    def test_other_app_cannot_spoof_check(self):
        checks, runs = self.valid_ci()
        checks[0]["app"]["id"] = 123
        self.assertFalse(release.ci_passed(checks, runs, self.commit))

    def test_newer_failed_or_pending_check_wins(self):
        for status, conclusion in [("completed", "failure"), ("in_progress", None)]:
            checks, runs = self.valid_ci()
            checks.append(dict(checks[0], id=2, status=status, conclusion=conclusion))
            self.assertFalse(release.ci_passed(checks, runs, self.commit))

    def test_pull_request_run_cannot_authorize_release(self):
        checks, runs = self.valid_ci()
        runs[0]["event"] = "pull_request"
        self.assertFalse(release.ci_passed(checks, runs, self.commit))

    def test_wrong_commit_cannot_authorize_release(self):
        self.assertFalse(release.ci_passed(*self.valid_ci(), "c" * 40))

    def test_published_checksums_must_agree_with_signed_assets(self):
        assets = {f"Roomy-{self.version}.pkg": "d" * 64, f"Roomy-{self.version}.zip": "e" * 64}
        valid = "".join(f"{digest}  {name}\n" for name, digest in assets.items())
        release.check_checksum_list(valid, self.version, assets)
        with self.assertRaisesRegex(ValueError, "disagrees"):
            release.check_checksum_list(valid.replace("e" * 64, "f" * 64), self.version, assets)
        with self.assertRaisesRegex(ValueError, "duplicate"):
            release.check_checksum_list(valid + valid, self.version, assets)

    def test_terminal_installer_contains_same_trusted_verifier(self):
        installer = (ROOT / "scripts/install.sh").read_text()
        embedded = installer.split("<<'ROOMY_VERIFY_SWIFT'\n", 1)[1].split("ROOMY_VERIFY_SWIFT\n", 1)[0]
        self.assertEqual(embedded, (ROOT / "scripts/verify-release.swift").read_text())


if __name__ == "__main__":
    unittest.main()
