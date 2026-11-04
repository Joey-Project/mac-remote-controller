"""Offline installer admission tests; no system policy or administrator access."""

import importlib.util
import copy
import contextlib
import fcntl
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("canary_installer", Path(__file__).with_name("install_canary.py"))
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


class InstallerAdmissionTests(unittest.TestCase):
    def test_definition_is_only_the_inert_canary(self):
        self.assertEqual(installer.DEFINITION["mechanisms"], ["SofaRemoteUnlockCanary:canary,privileged"])
        self.assertTrue(installer.own_definition({**installer.DEFINITION, **installer.CREATOR, "created": 1, "version": 0}))
        self.assertFalse(installer.own_definition(installer.DEFINITION))
        self.assertFalse(installer.own_definition({**installer.DEFINITION, "rule": ["allow"]}))
        self.assertFalse(installer.own_definition({**installer.DEFINITION, "shared": True}))
        self.assertFalse(installer.own_definition({"class": "allow"}))

    def test_observed_macos_rule_has_exact_creator_and_no_timeout(self):
        observed = {"class": "evaluate-mechanisms", "created": 1.0, "modified": 1.0,
            "identifier": "com.apple.security", "requirement": 'identifier "com.apple.security" and anchor apple',
            "mechanisms": ["SofaRemoteUnlockCanary:canary,privileged"], "shared": False, "tries": 1, "version": 0}
        self.assertTrue(installer.own_definition(observed))
        for change in ({"identifier": "another.creator"}, {"requirement": "allow"}, {"timeout": 300},
            {"shared": True}, {"shared": 0}, {"tries": True}, {"rule": ["allow"]}):
            self.assertFalse(installer.own_definition({**observed, **change}), change)

    def test_policy_mutations_cannot_target_system_unlock(self):
        for operation in ("write", "remove"):
            with self.assertRaises(installer.Refused):
                installer.native("security", ["authorizationdb", operation, "system.login.screensaver"])
        with self.assertRaises(installer.Refused):
            installer.native("security", ["authorizationdb", "write", installer.RIGHT, "allow"])

    def test_absent_is_distinct_from_unavailable(self):
        with patch.object(installer, "native", return_value=(255, b"", b"NO (-60005)\n")):
            self.assertIsNone(installer.right_definition(installer.RIGHT))
        for value in ((255, b"", b""), (1, b"", b"timeout"), (0, b"", b"")):
            with patch.object(installer, "native", return_value=value), self.assertRaises(installer.Refused):
                installer.right_definition(installer.RIGHT)

    def test_present_definition_readback(self):
        data = plistlib.dumps(installer.DEFINITION)
        with patch.object(installer, "native", return_value=(0, data, b"YES (0)\n")):
            self.assertEqual(installer.right_definition(installer.RIGHT), installer.DEFINITION)

    def test_reviewed_fingerprint_binds_names_boundaries_and_contents(self):
        original = {"a": b"bc", "d": b"e"}
        self.assertEqual(installer.fingerprint(original), installer.fingerprint(dict(reversed(list(original.items())))))
        for changed in ({"ab": b"c", "d": b"e"}, {"a": b"b", "cd": b"e"}, {"a": b"bc", "d": b"f"}):
            self.assertNotEqual(installer.fingerprint(original), installer.fingerprint(changed))

    def test_candidate_type_permissions_and_content_budget(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "regular"
            source.write_bytes(b"approved artifact")
            source.chmod(0o600)
            self.assertEqual(installer.read_regular(source), b"approved artifact")
            alias = root / "alias"
            alias.symlink_to(source)
            with self.assertRaises(OSError):
                installer.read_regular(alias)
            with self.assertRaises(installer.Refused):
                installer.read_regular(source, maximum=4)
            source.chmod(0o666)
            with self.assertRaises(installer.Refused):
                installer.read_regular(source)


class InstallerTransactionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.plugin = self.root / "plugins/SofaRemoteUnlockCanary.bundle"
        self.probe = self.root / "tools/canary"
        self.state = self.root / "state"
        self.plugin.parent.mkdir()
        self.probe.parent.mkdir()
        self.build = self.root / "build"
        source = self.build / self.plugin.name
        for name in installer.PLUGIN_FILES:
            path = source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            body = plistlib.dumps({"CFBundleIdentifier": "com.joeyteng.sofaremote.unlock.canary-plugin",
                "CFBundleExecutable": "SofaRemoteUnlockCanary"}) if name.endswith("Info.plist") else b"inert fixture"
            path.write_bytes(body)
            path.chmod(0o600)
        (self.build / "sofa-unlock-canary").write_bytes(b"inert probe fixture")
        (self.build / "sofa-unlock-canary").chmod(0o600)
        self.expected = installer.fingerprint(installer.snapshot(source, self.build / "sofa-unlock-canary"))
        self.baseline = {"class": "rule", "rule": ["existing-vendor", "use-login-window-ui"], "k-of-n": 1}
        self.policies = {installer.RIGHT: None, "system.login.screensaver": copy.deepcopy(self.baseline)}
        self.writes = []
        self.fail_registration = False
        self.external_policy_change = False
        self.fail_signature = False
        real_read = installer.read_regular

        def read_fixture(path, maximum=8 * 1024 * 1024, private=False):
            # The transaction harness is unprivileged. Real ownership admission
            # stays covered separately; all test paths are task-owned fixtures.
            return real_read(path, maximum, private=False)

        def publish_fixture(source, destination):
            if destination.exists():
                raise FileExistsError(destination)
            os.rename(source, destination)

        def signature_fixture(path):
            if self.fail_signature:
                raise installer.Refused("signature-verification-failed")

        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        for name, value in (("PLUGIN", self.plugin), ("PROBE", self.probe), ("STATE", self.state),
            ("parent_is_protected", lambda path: None), ("publish", publish_fixture),
            ("verify_signature", signature_fixture), ("read_regular", read_fixture),
            ("right_definition", lambda name: copy.deepcopy(self.policies[name])), ("native", self.native)):
            self.stack.enter_context(patch.object(installer, name, value))

    def native(self, tool, arguments, body=None):
        self.assertEqual(tool, "security")
        operation, name = arguments[1:]
        self.assertEqual(name, installer.RIGHT, "No transaction may mutate the system screen-lock rule")
        self.writes.append(operation)
        if operation == "write":
            if self.fail_registration:
                return 1, b"", b"registration failed"
            self.policies[name] = {**plistlib.loads(body), **installer.CREATOR, "created": 1, "version": 0}
            if self.external_policy_change:
                self.policies["system.login.screensaver"] = {"class": "rule", "rule": ["new-vendor"]}
        elif operation == "remove":
            self.policies[name] = None
        else:
            self.fail("Unexpected mutation")
        return 0, b"", b""

    def test_install_and_uninstall_preserve_existing_authentication_chain(self):
        installer.install(self.build, self.expected)
        self.assertEqual(self.policies["system.login.screensaver"], self.baseline)
        self.assertTrue((self.state / "complete").is_file())
        self.assertEqual(self.plugin.stat().st_mode & 0o777, 0o755)
        self.assertEqual(self.probe.stat().st_mode & 0o7777, 0o755)
        installer.uninstall()
        self.assertFalse(self.plugin.exists())
        self.assertFalse(self.probe.exists())
        self.assertFalse(self.state.exists())
        self.assertIsNone(self.policies[installer.RIGHT])
        self.assertEqual(self.policies["system.login.screensaver"], self.baseline)

    def test_changed_build_stops_before_publication(self):
        with self.assertRaises(installer.Refused):
            installer.install(self.build, "0" * 64)
        self.assertFalse(self.state.exists())
        self.assertEqual(self.writes, [])

    def test_staging_failure_retains_intent_without_installing(self):
        self.fail_signature = True
        with self.assertRaises(installer.Refused):
            installer.install(self.build, self.expected)
        self.assertEqual(json.loads((self.state / "receipt.json").read_text())["phase"], "prepared")
        self.assertFalse(self.plugin.exists())
        self.assertEqual(self.writes, [])

    def test_registration_failure_removes_only_own_published_artifacts(self):
        self.fail_registration = True
        with self.assertRaises(installer.Refused):
            installer.install(self.build, self.expected)
        self.assertFalse(self.plugin.exists())
        self.assertFalse(self.probe.exists())
        self.assertTrue((self.state / "receipt.json").exists())
        self.assertEqual(self.policies["system.login.screensaver"], self.baseline)

    def test_external_policy_change_is_never_reset_by_rollback(self):
        self.external_policy_change = True
        with self.assertRaises(installer.Refused):
            installer.install(self.build, self.expected)
        self.assertEqual(self.policies["system.login.screensaver"], {"class": "rule", "rule": ["new-vendor"]})
        self.assertIsNone(self.policies[installer.RIGHT])
        self.assertFalse(self.plugin.exists())

    def test_foreign_canary_rule_blocks_removal(self):
        installer.install(self.build, self.expected)
        self.policies[installer.RIGHT] = {"class": "rule", "rule": ["foreign-owner"]}
        with self.assertRaises(installer.Refused):
            installer.uninstall()
        self.assertTrue(self.plugin.exists())
        self.assertEqual(self.writes, ["write"])

    def test_changed_installed_artifact_blocks_removal(self):
        installer.install(self.build, self.expected)
        self.probe.write_bytes(b"replacement fixture")
        with self.assertRaises(installer.Refused):
            installer.uninstall()
        self.assertEqual(self.probe.read_bytes(), b"replacement fixture")
        self.assertEqual(self.writes, ["write"])

    def published_incomplete_fixture(self):
        # Reproduce the first physical run: both artifacts and the OS-normalized
        # right exist, but the old installer stopped before its completion files.
        installer.install(self.build, self.expected)
        (self.state / "complete").unlink()
        (self.state / "definition.plist").unlink()

    def test_recover_observed_incomplete_installation(self):
        self.published_incomplete_fixture()
        installer.recover_incomplete(self.expected)
        self.assertFalse(self.plugin.exists())
        self.assertFalse(self.probe.exists())
        self.assertFalse(self.state.exists())
        self.assertIsNone(self.policies[installer.RIGHT])
        self.assertEqual(self.policies["system.login.screensaver"], self.baseline)

    def test_completed_installation_is_not_incomplete_recovery(self):
        installer.install(self.build, self.expected)
        with self.assertRaises(installer.Refused):
            installer.recover_incomplete(self.expected)
        self.assertTrue((self.state / "complete").is_file())
        self.assertEqual(self.writes, ["write"])

    def test_recovery_refuses_mismatched_reviewed_build(self):
        self.published_incomplete_fixture()
        with self.assertRaises(installer.Refused):
            installer.recover_incomplete("0" * 64)
        self.assertTrue(self.probe.is_file())
        self.assertEqual(self.writes, ["write"])

    def test_recovery_preserves_unknown_state(self):
        self.published_incomplete_fixture()
        unknown = self.state / "unexpected"
        unknown.write_bytes(b"preserve this evidence")
        with self.assertRaises(installer.Refused):
            installer.recover_incomplete(self.expected)
        self.assertEqual(unknown.read_bytes(), b"preserve this evidence")
        self.assertEqual(self.writes, ["write"])

    def test_recovery_preserves_replaced_artifact(self):
        self.published_incomplete_fixture()
        self.probe.write_bytes(b"replacement fixture")
        with self.assertRaises(installer.Refused):
            installer.recover_incomplete(self.expected)
        self.assertEqual(self.probe.read_bytes(), b"replacement fixture")
        self.assertEqual(self.writes, ["write"])

    def test_recovery_preserves_foreign_creator(self):
        self.published_incomplete_fixture()
        self.policies[installer.RIGHT]["identifier"] = "another.creator"
        with self.assertRaises(installer.Refused):
            installer.recover_incomplete(self.expected)
        self.assertTrue(self.plugin.is_dir())
        self.assertEqual(self.policies[installer.RIGHT]["identifier"], "another.creator")
        self.assertEqual(self.writes, ["write"])

    def test_recovery_signature_failure_preserves_state(self):
        self.published_incomplete_fixture()
        self.fail_signature = True
        with self.assertRaises(installer.Refused):
            installer.recover_incomplete(self.expected)
        self.assertTrue(self.probe.is_file())
        self.assertEqual(self.writes, ["write"])

    def test_extra_candidate_bundle_entry_stops_before_publication(self):
        source = self.build / self.plugin.name
        (source / "Contents/extra").write_bytes(b"unowned file")
        with self.assertRaises(installer.Refused):
            installer.install(self.build, self.expected)
        self.assertFalse(self.state.exists())
        self.assertEqual(self.writes, [])

    def test_uninstall_preserves_bundle_with_extra_entries(self):
        installer.install(self.build, self.expected)
        extra = self.plugin / "Contents/extra"
        extra.mkdir()
        (extra / "evidence").write_bytes(b"preserve")
        with self.assertRaises(installer.Refused):
            installer.uninstall()
        self.assertEqual((extra / "evidence").read_bytes(), b"preserve")
        self.assertTrue((self.plugin / installer.PLUGIN_FILES[1]).is_file())
        self.assertIsNotNone(self.policies[installer.RIGHT])
        self.assertEqual(self.writes, ["write"])

    def test_recovery_preserves_bundle_with_extra_entries(self):
        self.published_incomplete_fixture()
        extra = self.plugin / "Contents/MacOS/extra"
        extra.write_bytes(b"preserve")
        with self.assertRaises(installer.Refused):
            installer.recover_incomplete(self.expected)
        self.assertEqual(extra.read_bytes(), b"preserve")
        self.assertIsNotNone(self.policies[installer.RIGHT])
        self.assertEqual(self.writes, ["write"])

    @contextlib.contextmanager
    def hold_native_operation_lock(self):
        fd = os.open(self.state, os.O_RDONLY | os.O_DIRECTORY)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            yield
        finally:
            os.close(fd)

    def test_uninstall_refuses_active_grant_operation(self):
        installer.install(self.build, self.expected)
        with self.hold_native_operation_lock(), self.assertRaisesRegex(installer.Refused, "state-operation-busy"):
            installer.uninstall()
        self.assertTrue((self.state / "complete").exists())
        self.assertEqual(self.writes, ["write"])
        installer.uninstall()
        self.assertFalse(self.state.exists())

    def test_recovery_refuses_active_grant_operation(self):
        self.published_incomplete_fixture()
        with self.hold_native_operation_lock(), self.assertRaisesRegex(installer.Refused, "state-operation-busy"):
            installer.recover_incomplete(self.expected)
        self.assertTrue(self.plugin.is_dir())
        self.assertEqual(self.writes, ["write"])
        installer.recover_incomplete(self.expected)
        self.assertFalse(self.state.exists())

    def test_teardown_holds_lock_through_right_and_artifact_removal(self):
        installer.install(self.build, self.expected)
        original_native = installer.native
        original_remove = installer.remove_known_plugin
        observed = []

        def assert_locked():
            with self.assertRaises(BlockingIOError), self.hold_native_operation_lock():
                self.fail("Teardown lost the directory lock")

        def native(tool, arguments, body=None):
            if arguments[1] == "remove":
                assert_locked()
                observed.append("right")
            return original_native(tool, arguments, body)

        def remove(path):
            assert_locked()
            observed.append("bundle")
            return original_remove(path)

        with patch.object(installer, "native", native), patch.object(installer, "remove_known_plugin", remove):
            installer.uninstall()
        self.assertEqual(observed, ["right", "bundle"])

    def test_install_holds_lock_through_artifact_and_right_publication(self):
        original_publish = installer.publish
        original_native = installer.native
        observed = []

        def assert_locked():
            with self.assertRaises(BlockingIOError), self.hold_native_operation_lock():
                self.fail("Installation lost the directory lock")

        def publish(source, destination):
            assert_locked()
            observed.append("artifact")
            return original_publish(source, destination)

        def native(tool, arguments, body=None):
            assert_locked()
            observed.append("right")
            return original_native(tool, arguments, body)

        with patch.object(installer, "publish", publish), patch.object(installer, "native", native):
            installer.install(self.build, self.expected)
        self.assertEqual(observed, ["artifact", "artifact", "right"])


if __name__ == "__main__":
    unittest.main()
