import copy
import datetime as dt
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import struct
import sys
import tarfile
import tempfile
import unittest

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
import prepare
import renew


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.started = renew.now()
        self.profile = {"TeamIdentifier": ["TESTTEAM"], "Entitlements": {"application-identifier": f"TESTTEAM.{renew.IOS_ID}"},
            "ProvisionedDevices": ["test-device"], "DeveloperCertificates": [b"public-test-certificate"],
            "CreationDate": self.started.replace(tzinfo=None),
            "ExpirationDate": (self.started + dt.timedelta(days=7)).replace(tzinfo=None)}
        self.previous = {"ExpirationDate": (self.started + dt.timedelta(days=6)).replace(tzinfo=None)}

    def validate(self):
        renew.validate_profile(self.profile, "TESTTEAM", renew.IOS_ID, "test-device", b"public-test-certificate", self.previous, self.started)

    def test_fresh_profile(self):
        self.validate()

    def test_reject_each_identity_mismatch(self):
        for field, value in (("TeamIdentifier", ["OTHERTEAM"]), ("ProvisionedDevices", []), ("DeveloperCertificates", [b"other-public-certificate"])):
            with self.subTest(field=field):
                original = self.profile[field]
                self.profile[field] = value
                with self.assertRaises(renew.RenewalError):
                    self.validate()
                self.profile[field] = original

    def test_reject_other_bundle(self):
        self.profile["Entitlements"]["application-identifier"] = "TESTTEAM.other-app"
        with self.assertRaisesRegex(renew.RenewalError, "identity"):
            self.validate()

    def test_command_success_without_expiry_advance_is_not_renewal(self):
        self.previous["ExpirationDate"] = self.profile["ExpirationDate"]
        with self.assertRaisesRegex(renew.RenewalError, "did-not-advance"):
            self.validate()

    def test_expired_and_cached_profiles_rejected(self):
        for field, value in (("ExpirationDate", self.started - dt.timedelta(seconds=1)),
            ("CreationDate", self.started - dt.timedelta(minutes=10))):
            with self.subTest(field=field):
                p = copy.deepcopy(self.profile)
                self.profile[field] = value.replace(tzinfo=None)
                with self.assertRaises(renew.RenewalError):
                    self.validate()
                self.profile = p

    def test_expired_previous_profile_can_be_recovered(self):
        self.previous["ExpirationDate"] = (self.started - dt.timedelta(days=10)).replace(tzinfo=None)
        self.validate()

    def test_preserve_implicit_and_explicit_keychain_groups(self):
        self.assertTrue(renew.authorized_groups({}, self.profile))
        self.profile["Entitlements"]["keychain-access-groups"] = ["TESTTEAM.*"]
        self.assertTrue(renew.authorized_groups({"keychain-access-groups": ["TESTTEAM.app"]}, self.profile))
        self.assertFalse(renew.authorized_groups({"keychain-access-groups": ["OTHERTEAM.app"]}, self.profile))


class PrivateRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def config(self):
        path = self.root / "configuration-private.json"
        path.write_text(json.dumps({"probeApp": str(self.root / "probe.app"), "iosApp": str(self.root / "ios.app"),
            "deviceIdentifier": "test-device", "deviceUDID": "test-udid", "runDirectory": str(self.root / "runs")}))
        path.chmod(0o600)
        return path

    def test_private_config(self):
        self.assertEqual(renew.read_config(self.config())["deviceIdentifier"], "test-device")

    def test_config_rejects_broad_permissions_and_symlinks(self):
        path = self.config()
        path.chmod(0o644)
        with self.assertRaises(renew.RenewalError):
            renew.read_config(path)
        path.chmod(0o600)
        link = self.root / "link"
        link.symlink_to(path)
        with self.assertRaises(OSError):
            renew.read_config(link)

    def test_config_rejects_fifo_without_blocking(self):
        path = self.root / "fifo"
        os.mkfifo(path, 0o600)
        with self.assertRaises(renew.RenewalError):
            renew.read_config(path)

    def test_config_does_not_accept_account_credentials(self):
        path = self.config()
        value = json.loads(path.read_text())
        value["password"] = None
        path.write_text(json.dumps(value))
        with self.assertRaisesRegex(renew.RenewalError, "fields"):
            renew.read_config(path)

    def test_serialize_different_run_directories_using_same_probe(self):
        probe = self.root / "SofaRenewalProbe.app"
        with renew.exclusive_probe(probe):
            with self.assertRaisesRegex(renew.RenewalError, "already-running"):
                with renew.exclusive_probe(probe):
                    self.fail("Concurrent renewal admitted")
        with renew.exclusive_probe(probe):
            pass

    def test_stdout_is_not_contaminated_by_stderr(self):
        log = renew.CommandLog(self.root)
        result = log.command("mixed", [sys.executable, "-c", "import sys; print('output'); sys.stderr.write('diagnostic')"])
        self.assertEqual(result, b"output\n")
        self.assertIn(b"diagnostic", next(self.root.glob("*.log")).read_bytes())

    def test_output_budget_and_timeout(self):
        log = renew.CommandLog(self.root)
        log.remaining_log_bytes = 8
        with self.assertRaisesRegex(renew.RenewalError, "output-limit"):
            log.command("large", [sys.executable, "-c", "print('x' * 100)"])
        with self.assertRaisesRegex(renew.RenewalError, "timeout"):
            log.command("slow", [sys.executable, "-c", "import time; time.sleep(5)"], seconds=0.03)


class SourceTests(unittest.TestCase):
    def test_mach_o_instruction_hash_rejects_changed_code(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "program"
            data = bytearray(188)
            struct.pack_into("<I", data, 0, 0xFEEDFACF)
            struct.pack_into("<I", data, 16, 1)
            struct.pack_into("<II", data, 32, 0x19, 152)
            struct.pack_into("<I", data, 96, 1)
            data[104:110] = b"__text"
            data[120:126] = b"__TEXT"
            struct.pack_into("<Q", data, 144, 4)
            struct.pack_into("<I", data, 152, 184)
            data[184:188] = b"code"
            path.write_bytes(data)
            before = renew.instruction_hash(path)
            self.assertEqual(before, hashlib.sha256(b"code").hexdigest())
            data[184:188] = b"edit"
            path.write_bytes(data)
            self.assertNotEqual(before, renew.instruction_hash(path))

    def test_pinned_patch_and_lock_hashes(self):
        manifest = json.loads((HERE / "upstream.json").read_text())
        self.assertEqual(prepare.digest(HERE / "xtool.patch"), manifest["patchSHA256"])
        self.assertEqual(prepare.digest(HERE / "Package.resolved"), manifest["resolvedSHA256"])
        self.assertEqual(len(manifest["patchedPaths"]), 6)

    def test_archive_traversal_and_links_rejected(self):
        for name, kind in (("xtool-test/../escape", tarfile.REGTYPE), ("xtool-test/link", tarfile.SYMTYPE)):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                archive = root / "test.tar.gz"
                with tarfile.open(archive, "w:gz") as output:
                    member = tarfile.TarInfo(name)
                    member.type = kind
                    member.linkname = "/outside" if kind == tarfile.SYMTYPE else ""
                    member.size = 0
                    output.addfile(member, io.BytesIO())
                with self.assertRaises(ValueError):
                    prepare.extract(archive, root / "source", "test")


if __name__ == "__main__":
    unittest.main()
