"""Keep every app-defined interactive control in the semantic automation API."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'apps/macos/SofaRemoteMac/App'
PROTOCOL = ROOT / 'packages/apple-core/Sources/MacSupport/LocalAutomationProtocol.swift'


class UIAutomationCoverageTests(unittest.TestCase):
    def test_every_control_has_a_stable_registered_identifier(self):
        declaration = re.search(r'public enum CompanionControl[^}]+}', PROTOCOL.read_text(), re.S)
        self.assertIsNotNone(declaration)
        cases = dict(re.findall(r'case (\w+) = "([^"]+)"', declaration.group()))
        identifiers = []
        read_only = {'numericCode', 'webPairingCode'}
        kinds = 'Button|Toggle|DisclosureGroup|TextField|SecureField|TextEditor|Picker|Slider|Stepper|Menu'
        for path in sorted(APP.glob('*.swift')):
            source = path.read_text()
            found = re.findall(r'accessibilityIdentifier\(\s*CompanionControl\.(\w+)\.rawValue\s*\)', source)
            # String literals and comments cannot create apparent Swift controls.
            syntax = re.sub(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*.*?\*/', '""', source, flags=re.S)
            interactive = re.findall(r'\b(?:' + kinds + r')\s*(?:\(|\{)', syntax)
            self.assertEqual(len(interactive), sum(item not in read_only for item in found),
                             f'{path.name}: every interactive control needs its registered ID')
            identifiers.extend(found)
        self.assertEqual(set(identifiers), set(cases))
        self.assertEqual(len(identifiers), len(set(identifiers)), 'Duplicate semantic UI identifiers')
        self.assertEqual(cases['numericCode'], 'pairing.mac.code')
        self.assertEqual(cases['webPairingCode'], 'pairing.web.code')

    def test_new_app_sources_and_cli_are_in_the_build(self):
        project = (ROOT / 'apps/macos/SofaRemoteMac.xcodeproj/project.pbxproj').read_text()
        for name in ('CompanionModel+Automation.swift', 'CompanionModel+Controls.swift'):
            self.assertEqual(project.count(name + ' in Sources'), 2)
        self.assertIn('$(CONTENTS_FOLDER_PATH)/Helpers/SofaRemoteControl', project)
        bundler = (ROOT / 'tooling/swift/bundle-media-adapters.sh').read_text()
        self.assertIn('--product SofaRemoteControl', bundler)
        self.assertIn('control_slices[@]', bundler)


if __name__ == '__main__':
    unittest.main()
