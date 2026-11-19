"""Exercise default installation and probe adoption without lock requirements."""
import datetime as dt
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import renew


class LockObservationTests(unittest.TestCase):
    def runner(self):
        run = object.__new__(renew.Run)
        run.manual_recovery = False
        run.summary = {}
        return run

    def test_observation_errors_and_untyped_values_stay_unknown(self):
        run = self.runner()
        for value in ("false", 0):
            with patch.object(run, "locked", return_value=value):
                self.assertIsNone(run.record_mac_lock("test"))
        with patch.object(run, "locked", side_effect=renew.RenewalError("command-timeout")):
            self.assertIsNone(run.record_mac_lock("test"))
        self.assertIsNone(run.summary["macLockStates"]["test"])

    def test_wifi_receipt_acceptance_ignores_lock_but_requires_completion(self):
        complete = dict(target="ios", status="passed", installationCommandSucceeded=True,
                        installedAppReadback=True, transport="localNetwork")
        for state in (False, True, None):
            self.assertTrue(renew.completed_wifi_install_receipt(dict(complete, bothDevicesLocked=state)))
        self.assertTrue(renew.completed_wifi_install_receipt(complete))
        for key, value in [("target", "mac"), ("status", "failed"), ("installationCommandSucceeded", False),
                           ("installedAppReadback", False), ("transport", "wired")]:
            self.assertFalse(renew.completed_wifi_install_receipt(dict(complete, **{key: value})))

    def test_default_install_allows_lock_changes_and_records_unknown(self):
        for mac_state, before_state, after_state, expected in [
            (False, False, False, False), (True, False, True, True),
            (None, True, True, None), (True, None, None, None),
        ]:
            run = self.runner()
            run.root = Path("unused")
            run.config = {"deviceIdentifier": "test-device"}
            states = [dict(transport="localNetwork", locked=state, appCount=1)
                      for state in (before_state, after_state)]
            with patch.object(run, "verify_signature"), patch.object(run, "command") as command, \
                patch.object(run, "device", side_effect=states), patch.object(run, "locked", return_value=mac_state):
                run.install(Path("candidate.app"))
            self.assertEqual(sum(call.args[0] == "install" for call in command.call_args_list), 1)
            self.assertTrue(run.summary["installedAppReadback"])
            self.assertIs(run.summary["bothDevicesLocked"], expected)
            self.assertIs(run.summary["phoneLockedBefore"], before_state)

    def test_missing_post_install_app_still_fails(self):
        run = self.runner()
        run.root = Path("unused")
        run.config = {"deviceIdentifier": "test-device"}
        states = [dict(transport="localNetwork", locked=False, appCount=count) for count in (1, 0)]
        with patch.object(run, "verify_signature"), patch.object(run, "command"), \
            patch.object(run, "device", side_effect=states), patch.object(run, "locked", return_value=False):
            with self.assertRaisesRegex(renew.RenewalError, "post-install-state-mismatch"):
                run.install(Path("candidate.app"))
        self.assertNotIn("installedAppReadback", run.summary)

    def test_mac_adoption_needs_authentication_in_every_lock_state(self):
        for state in (False, True, None):
            for authenticated in (False, True):
                with self.subTest(state=state, authenticated=authenticated), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    run = self.runner()
                    run.root, run.probe = root, root / "probe.app"
                    candidate = root / "candidate.app"
                    candidate.mkdir()
                    run.summary["candidateSHA256"] = "test-code-digest"
                    profile = {"Entitlements": {"application-identifier": "TESTTEAM." + renew.MAC_ID},
                        "ExpirationDate": (renew.now() + dt.timedelta(days=1)).replace(tzinfo=None)}
                    response = json.dumps({"authenticatedToApple": authenticated}).encode()
                    with patch.object(run, "verify_signature"), patch.object(run, "profile", return_value=profile), \
                        patch.object(run, "issue", return_value=(root / "profile", profile, b"public-cert")), \
                        patch.object(run, "resign", return_value=candidate), patch.object(run, "command", return_value=response), \
                        patch.object(run, "locked", return_value=state), patch.object(renew, "atomic_exchange") as publish:
                        if authenticated:
                            run.execute("mac-adopt")
                            publish.assert_called_once()
                            self.assertTrue(run.summary["macProbeUpdated"])
                        else:
                            with self.assertRaisesRegex(renew.RenewalError, "candidate-session-check-failed"):
                                run.execute("mac-adopt")
                            publish.assert_not_called()

    def test_only_lock_query_failure_is_nonfatal(self):
        for failed_action in ("lockState", "details", "apps"):
            with tempfile.TemporaryDirectory() as directory:
                run = self.runner()
                run.root = Path(directory)
                run.config = {"deviceIdentifier": "test-device"}
                def command(label, args, **kwargs):
                    if label == "device-" + failed_action:
                        raise renew.RenewalError("command-failed")
                    value = {"connectionProperties": {"transportType": "localNetwork"}} if label == "device-details" else {
                        "apps": [{"bundleIdentifier": renew.IOS_ID}]}
                    Path(args[args.index("--json-output") + 1]).write_text(json.dumps({"result": value}))
                with patch.object(run, "command", side_effect=command):
                    if failed_action == "lockState":
                        result = run.device("before")
                        self.assertIsNone(result["locked"])
                        self.assertEqual(result["appCount"], 1)
                    else:
                        with self.assertRaises(renew.RenewalError):
                            run.device("before")


if __name__ == "__main__":
    unittest.main()
