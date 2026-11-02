"""Explicit recovery does not relax the daily locked-Wi-Fi acceptance path."""
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import renew


class ManualRecoveryTests(unittest.TestCase):
    def runner(self, manual):
        run = object.__new__(renew.Run)
        run.manual_recovery = manual
        return run

    def test_manual_accepts_unlocked_mac_without_unlocking_it(self):
        run = self.runner(True)
        with patch.object(run, "locked", return_value=False):
            self.assertFalse(run.require_mac_lock())

    def test_daily_still_requires_locked_mac(self):
        run = self.runner(False)
        with patch.object(run, "locked", return_value=False), self.assertRaises(renew.RenewalError):
            run.require_mac_lock()

    def test_unknown_mac_state_is_not_unlocked(self):
        for manual in (False, True):
            run = self.runner(manual)
            with patch.object(run, "locked", return_value=None), self.assertRaises(renew.RenewalError):
                run.require_mac_lock()

    def test_manual_accepts_paired_usb_and_wifi_locked_or_unlocked(self):
        run = self.runner(True)
        for transport in ("wired", "localNetwork"):
            for locked in (False, True):
                run.require_phone_state({"transport": transport, "locked": locked})

    def test_daily_still_requires_both_wifi_and_locked_phone(self):
        run = self.runner(False)
        for state in ({"transport": "wired", "locked": True}, {"transport": "localNetwork", "locked": False}):
            with self.assertRaises(renew.RenewalError):
                run.require_phone_state(state)
        run.require_phone_state({"transport": "localNetwork", "locked": True})

    def test_manual_unknown_transport_or_lock_state_refused(self):
        run = self.runner(True)
        for state in ({"transport": None, "locked": True}, {"transport": "wired", "locked": None},
            {"transport": "", "locked": False}, {"transport": "unknown", "locked": True}):
            with self.assertRaises(renew.RenewalError):
                run.require_phone_state(state)

    def test_manual_cannot_change_mac_probe(self):
        run = self.runner(True)
        for action in ("mac-candidate", "mac-adopt"):
            with self.assertRaisesRegex(renew.RenewalError, "ios-only"):
                run.execute(action)


if __name__ == "__main__":
    unittest.main()
