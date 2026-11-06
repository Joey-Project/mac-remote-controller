"""Exercise pin admission and real certificate identity continuity when configured."""

import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / "development_signing.py"
SPEC = importlib.util.spec_from_file_location("development_signing", MODULE)
signing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(signing)
PIN = "A" * 40  # A public certificate fingerprint, not a credential.
CONFIG = f"CODE_SIGN_STYLE = Manual\nCODE_SIGN_IDENTITY = {PIN}\nDEVELOPMENT_TEAM = ABCDE12345\n"


class PinTests(unittest.TestCase):
    def test_rejects_ad_hoc_generic_missing_duplicate_and_extra_settings(self):
        for text in (CONFIG.replace(PIN, "-"), CONFIG.replace(PIN, "Apple Development"),
                     CONFIG.replace("CODE_SIGN_STYLE = Manual", "CODE_SIGN_STYLE = Automatic"),
                     CONFIG + "CODE_SIGN_IDENTITY = " + PIN,
                     CONFIG + "OTHER_CODE_SIGN_FLAGS = --deep\n", ""):
            with self.subTest(text=text), self.assertRaises(ValueError):
                signing.parse_config(text)

    def test_identity_selection_excludes_other_certificate_types(self):
        text = (f'  1) {PIN} "Apple Development: Example (ABCDE12345)"\n'
                f'  2) {"B" * 40} "Local Signing"\n'
                '     2 valid identities found\n')
        self.assertEqual(list(signing.identities(text)), [PIN])

    def test_configure_refuses_ambiguous_selection(self):
        with patch.object(signing, "available", return_value={PIN: "one", "B" * 40: "two"}):
            with self.assertRaisesRegex(ValueError, "Select one"):
                signing.configure()

    def test_missing_configuration_stops_before_build(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(signing, "CONFIG", Path(directory) / "missing"), \
                    patch.object(signing.subprocess, "run") as command:
                with self.assertRaisesRegex(ValueError, "configure first"):
                    signing.build("Debug")
                command.assert_not_called()

    def test_unavailable_pin_never_selects_another_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "pin.xcconfig"
            path.write_text(CONFIG)
            with patch.object(signing, "CONFIG", path), \
                    patch.object(signing, "available", return_value={"B" * 40: "other"}), \
                    patch.object(signing.subprocess, "run") as command:
                with self.assertRaisesRegex(ValueError, "unavailable"):
                    signing.build("Debug")
                command.assert_not_called()


@unittest.skipUnless(sys.platform == "darwin" and signing.CONFIG.is_file(),
                     "Real Apple Development signing requires an explicitly configured Mac")
class NativeSigningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.values = signing.read_config()

    def fixture(self, directory, number, identity=None, entitlements=None):
        app = Path(directory) / f"Fixture{number}.app"
        executable = app / "Contents/MacOS/Fixture"
        executable.parent.mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": signing.IDENTIFIER, "CFBundleExecutable": "Fixture",
            "CFBundlePackageType": "APPL", "CFBundleVersion": str(number),
        }))
        source = Path(directory) / f"fixture{number}.c"
        source.write_text(f"int main(void) {{ return {number}; }}\n")
        subprocess.run(["xcrun", "clang", str(source), "-o", str(executable)], check=True, timeout=30)
        command = ["codesign", "--sign", identity or self.values["CODE_SIGN_IDENTITY"],
                   "--options", "runtime", "--timestamp=none"]
        if entitlements is not None:
            path = Path(directory) / f"entitlements{number}.plist"
            path.write_bytes(plistlib.dumps(entitlements))
            command.extend(["--entitlements", str(path)])
        subprocess.run([*command, str(app)], check=True, capture_output=True, timeout=30)
        return app

    def test_distinct_builds_keep_the_same_requirement(self):
        with tempfile.TemporaryDirectory() as directory:
            first = signing.verify(self.fixture(directory, 1), self.values)
            second = signing.verify(self.fixture(directory, 2), self.values)
            self.assertNotEqual(first["cdhash"], second["cdhash"])
            self.assertEqual(first["designatedRequirement"], second["designatedRequirement"])

    def test_ad_hoc_app_is_not_an_installable_development_build(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.fixture(directory, 1, identity="-")
            with self.assertRaises(subprocess.CalledProcessError):
                signing.verify(app, self.values)

    def test_foreign_certificate_pin_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.fixture(directory, 1)
            values = dict(self.values, CODE_SIGN_IDENTITY=PIN)
            with self.assertRaises(subprocess.CalledProcessError):
                signing.verify(app, values)

    def test_debug_entitlement_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.fixture(directory, 1, entitlements={"com.apple.security.get-task-allow": True})
            with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                signing.verify(app, self.values)


if __name__ == "__main__":
    unittest.main()
