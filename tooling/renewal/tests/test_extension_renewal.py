"""Renew only the bundled WidgetKit extension, preserving both signed payloads."""
import copy
import datetime as dt
import json
import os
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import renew

CERTIFICATE = b"public-test-certificate"


def executable(path, instructions=b"code"):
    data = bytearray(188)
    struct.pack_into("<I", data, 0, 0xFEEDFACF)
    struct.pack_into("<I", data, 16, 1)
    struct.pack_into("<II", data, 32, 0x19, 152)
    struct.pack_into("<I", data, 96, 1)
    data[104:110] = b"__text"
    data[120:126] = b"__TEXT"
    struct.pack_into("<Q", data, 144, 4)
    struct.pack_into("<I", data, 152, 184)
    data[184:188] = instructions
    path.write_bytes(data)


def profile(bundle, days=7):
    return {"TeamIdentifier": ["TESTTEAM"],
        "Entitlements": {"application-identifier": f"TESTTEAM.{bundle}"},
        "ProvisionedDevices": ["test-device"], "DeveloperCertificates": [CERTIFICATE],
        "CreationDate": renew.now().replace(tzinfo=None),
        "ExpirationDate": (renew.now() + dt.timedelta(days=days)).replace(tzinfo=None)}


class SigningRun(renew.Run):
    def __init__(self, root):
        self.root = root
        root.mkdir()
        self.summary = {}
        self.events = []
        self.corrupt_widget_on_sign = False

    def verify_signature(self, app):
        self.events.append(("verify", app.name))

    def entitlements(self, app):
        bundle = plistlib.loads((app / "Info.plist").read_bytes())["CFBundleIdentifier"]
        return profile(bundle)["Entitlements"]

    def command(self, label, argv, **kwargs):
        if label in ("resign", "resign-widget"):
            self.events.append(("sign", Path(argv[-1]).name))
            if label == "resign-widget" and self.corrupt_widget_on_sign:
                executable(Path(argv[-1]) / "SofaRemoteWidgets", b"edit")
        elif label == "candidate-certificate":
            prefix = next(value.split("=", 1)[1] for value in argv if value.startswith("--extract-certificates="))
            Path(prefix + "0").write_bytes(CERTIFICATE)
        else:
            raise AssertionError(label)
        return b""


class ExtensionRenewalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "SofaRemoteiOS.app"
        self.app.mkdir()
        (self.app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": renew.IOS_ID}))
        executable(self.app / "SofaRemoteiOS")
        self.main_profile = profile(renew.IOS_ID)
        self.main_path = self.root / "main-profile"
        self.main_path.write_bytes(plistlib.dumps(self.main_profile))
        (self.app / "embedded.mobileprovision").write_bytes(b"old-main-profile")
        self.child_profile = profile(renew.WIDGET_ID)
        self.child_path = self.root / "widget-profile"
        self.child_path.write_bytes(plistlib.dumps(self.child_profile))

    def widget(self):
        child = self.app / renew.WIDGET_PATH
        child.mkdir(parents=True)
        (child / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": renew.WIDGET_ID, "CFBundleExecutable": "SofaRemoteWidgets",
            "NSExtension": {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}}))
        (child / "embedded.mobileprovision").write_bytes(b"old-widget-profile")
        executable(child / "SofaRemoteWidgets")
        return child

    def sign(self, run, profiles=None):
        return run.resign(self.app, self.main_path, self.main_profile, CERTIFICATE,
            extension_profiles=profiles)

    def child_profiles(self):
        return {renew.WIDGET_PATH: (self.child_path, self.child_profile, CERTIFICATE)}

    def test_legacy_app_requires_no_extension_profile_or_command(self):
        run = SigningRun(self.root / "run")
        candidate = self.sign(run)
        self.assertEqual([e for e in run.events if e[0] == "sign"], [("sign", self.app.name)])
        self.assertEqual(run.summary["extensionSignaturesVerified"], 0)
        self.assertEqual((candidate / "embedded.mobileprovision").read_bytes(), self.main_path.read_bytes())

    def test_widget_signs_first_and_profiles_and_original_code_stay_distinct(self):
        child = self.widget()
        run = SigningRun(self.root / "run")
        original = renew.instruction_hash(child / "SofaRemoteWidgets")
        candidate = self.sign(run, self.child_profiles())
        self.assertEqual([e for e in run.events if e[0] == "sign"],
            [("sign", child.name), ("sign", self.app.name)])
        self.assertEqual(run.summary["extensionSignaturesVerified"], 1)
        self.assertEqual((candidate / renew.WIDGET_PATH / "embedded.mobileprovision").read_bytes(), self.child_path.read_bytes())
        self.assertEqual((candidate / "embedded.mobileprovision").read_bytes(), self.main_path.read_bytes())
        self.assertEqual(renew.instruction_hash(candidate / renew.WIDGET_PATH / "SofaRemoteWidgets"), original)
        self.assertEqual((child / "embedded.mobileprovision").read_bytes(), b"old-widget-profile")

    def test_missing_and_extra_profile_sets_are_rejected_before_signing(self):
        for has_widget in (False, True):
            with self.subTest(has_widget=has_widget):
                if has_widget:
                    self.widget()
                run = SigningRun(self.root / str(has_widget))
                with self.assertRaisesRegex(renew.RenewalError, "profile-set-mismatch"):
                    self.sign(run, {} if has_widget else self.child_profiles())
                self.assertFalse(any(e[0] == "sign" for e in run.events))

    def test_widget_certificate_or_team_cannot_differ_from_app(self):
        self.widget()
        for field in ("certificate", "team"):
            with self.subTest(field=field):
                altered = copy.deepcopy(self.child_profile)
                certificate = CERTIFICATE
                if field == "certificate":
                    certificate = b"other-public-certificate"
                else:
                    altered["TeamIdentifier"] = ["OTHERTEAM"]
                run = SigningRun(self.root / field)
                with self.assertRaisesRegex(renew.RenewalError, "identity-mismatch"):
                    self.sign(run, {renew.WIDGET_PATH: (self.child_path, altered, certificate)})
                self.assertFalse(any(e[0] == "sign" for e in run.events))

    def test_wrong_widget_profile_identity_stops_before_outer_signing(self):
        self.widget()
        self.child_profile["Entitlements"]["application-identifier"] = "TESTTEAM.other-app"
        run = SigningRun(self.root / "run")
        with self.assertRaisesRegex(renew.RenewalError, "entitlement-authorization"):
            self.sign(run, self.child_profiles())
        self.assertFalse(any(e[0] == "sign" for e in run.events))

    def test_changed_widget_instructions_stop_outer_signing(self):
        self.widget()
        run = SigningRun(self.root / "run")
        run.corrupt_widget_on_sign = True
        with self.assertRaisesRegex(renew.RenewalError, "signed-payload-changed"):
            self.sign(run, self.child_profiles())
        self.assertNotIn(("sign", self.app.name), run.events)

    def test_metadata_only_change_does_not_reject_unchanged_widget_code(self):
        child = self.widget()
        os.utime(child / "SofaRemoteWidgets", (1, 1))
        run = SigningRun(self.root / "run")
        self.sign(run, self.child_profiles())
        self.assertTrue(run.summary["entitlementsAndInstructionsPreserved"])

    def test_reject_unknown_nested_or_symlinked_extensions(self):
        child = self.widget()
        unknown = self.app / "PlugIns/Other.appex"
        unknown.mkdir()
        with self.assertRaisesRegex(renew.RenewalError, "unsupported-ios-extensions"):
            renew.ios_extensions(self.app)
        unknown.rmdir()
        nested = child / "Nested.appex"
        nested.mkdir()
        with self.assertRaisesRegex(renew.RenewalError, "unsupported-ios-extensions"):
            renew.ios_extensions(self.app)
        nested.rmdir()
        executable_file = child / "SofaRemoteWidgets"
        executable_file.unlink()
        executable_file.symlink_to(self.app / "SofaRemoteiOS")
        with self.assertRaisesRegex(renew.RenewalError, "invalid-widget-bundle-file"):
            renew.ios_extensions(self.app)

    def test_reject_different_widget_kind_even_with_expected_filename(self):
        child = self.widget()
        info = plistlib.loads((child / "Info.plist").read_bytes())
        info["NSExtension"]["NSExtensionPointIdentifier"] = "unrelated-extension"
        (child / "Info.plist").write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(renew.RenewalError, "unexpected-widget-identity"):
            renew.ios_extensions(self.app)

    def test_widget_expiration_must_advance_independently_of_main_app(self):
        old = copy.deepcopy(self.child_profile)
        with self.assertRaisesRegex(renew.RenewalError, "did-not-advance"):
            renew.validate_profile(self.child_profile, "TESTTEAM", renew.WIDGET_ID,
                "test-device", CERTIFICATE, old, renew.now())

    def pipeline(self):
        run = object.__new__(renew.Run)
        run.manual_recovery = False
        run.probe = self.root / "unused-probe"
        run.config = {"iosApp": str(self.app)}
        run.summary = {}
        return run

    def test_failed_widget_profile_does_not_sign_or_install_partial_candidate(self):
        self.widget()
        run = self.pipeline()
        issued = (self.main_path, self.main_profile, CERTIFICATE)
        with patch.object(run, "verify_signature"), \
            patch.object(run, "profile", return_value=profile(renew.MAC_ID)), \
            patch.object(run, "issue", side_effect=[issued, renew.RenewalError("widget-profile-failed")]), \
            patch.object(run, "resign") as sign, patch.object(run, "install") as install:
            with self.assertRaisesRegex(renew.RenewalError, "widget-profile-failed"):
                run.execute("ios-install")
            sign.assert_not_called()
            install.assert_not_called()

    def test_unsupported_extension_is_rejected_before_issuing_any_profile(self):
        self.widget().rename(self.app / "PlugIns/Other.appex")
        run = self.pipeline()
        with patch.object(run, "verify_signature"), \
            patch.object(run, "profile", return_value=profile(renew.MAC_ID)), \
            patch.object(run, "issue") as issue:
            with self.assertRaisesRegex(renew.RenewalError, "unsupported-ios-extensions"):
                run.execute("ios-candidate")
            issue.assert_not_called()

    def test_widget_issue_uses_separate_output_and_preserves_main_receipt(self):
        child = self.widget()
        run = object.__new__(renew.Run)
        run.root = self.root / "run"
        run.root.mkdir()
        run.config = {"deviceUDID": "test-device"}
        run.executable = self.root / "unused-probe"
        run.summary = {"target": "ios", "expiration": "main-expiration"}
        old = profile(renew.WIDGET_ID, days=1)
        issued = profile(renew.WIDGET_ID)
        commands = []

        def command(label, argv, **kwargs):
            commands.append(argv)
            if label == "read-certificate":
                prefix = next(v.split("=", 1)[1] for v in argv if v.startswith("--extract-certificates="))
                Path(prefix + "0").write_bytes(CERTIFICATE)
            elif label == "issue-profile":
                config = json.loads(Path(kwargs["environment"]["SOFA_RENEWAL_PROBE_CONFIG"]).read_text())
                out = Path(config["outputDirectory"])
                out.mkdir()
                (out / "probe.mobileprovision").write_bytes(b"new-widget-profile")
            return b""

        with patch.object(run, "profile", side_effect=[old, issued]), \
            patch.object(run, "verify_signature"), patch.object(run, "require_mac_lock"), \
            patch.object(run, "command", side_effect=command):
            path, result, certificate = run.issue("widget", child)
        self.assertEqual(path.parent.parent, run.root / "widget-issuance")
        self.assertEqual(commands[-1][-1], "widget-profile")
        self.assertEqual(run.summary["target"], "ios")
        self.assertEqual(run.summary["expiration"], "main-expiration")
        self.assertEqual(run.summary["extensionProfiles"][0]["bundleIdentifier"], renew.WIDGET_ID)
        self.assertEqual(result, issued)
        self.assertEqual(certificate, CERTIFICATE)


if __name__ == "__main__":
    unittest.main()
