import argparse
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "configure.py"
SPEC = importlib.util.spec_from_file_location("configure", SOURCE)
configure = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(configure)


class ConfigurationTests(unittest.TestCase):
    def arguments(self, **changes):
        fields = dict(hostname="remote.example.com", address="192.168.1.10", port=47625,
                      interface="en0", certificate_chain=Path("/private/fullchain.pem"),
                      private_key=Path("/private/privkey.pem"), zone_id=None, record_id=None)
        fields.update(changes)
        return argparse.Namespace(**fields)

    def test_setup_is_disabled_and_contains_no_credentials(self):
        value = configure.configuration(self.arguments())
        self.assertFalse(value["enabled"])
        self.assertNotIn("token", json.dumps(value))
        self.assertEqual(value["interfaceName"], "en0")

    def test_public_wildcard_bonjour_and_partial_dns_configuration_are_rejected(self):
        for changes in ({"address": "8.8.8.8"}, {"address": "0.0.0.0"},
                        {"hostname": "mac.local"}, {"hostname": "remote.EXAMPLE.com"},
                        {"port": 443}, {"zone_id": "a" * 32}):
            with self.assertRaises(ValueError):
                configure.configuration(self.arguments(**changes))

    def test_existing_settings_are_never_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            configure.write_configuration(root, {"enabled": True})
            with self.assertRaises(FileExistsError):
                configure.write_configuration(root, {"enabled": False})
            self.assertTrue(json.loads((root / "configuration.json").read_text())["enabled"])
            self.assertEqual((root / "configuration.json").stat().st_mode & 0o777, 0o600)

    def test_insecure_root_is_not_silently_chmodded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o755)
            with self.assertRaises(ValueError):
                configure.write_configuration(root, {})
            self.assertEqual(root.stat().st_mode & 0o777, 0o755)


if __name__ == "__main__":
    unittest.main()
