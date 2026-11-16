"""Keep the stable required Apple check closed on every non-success result."""

import itertools
from pathlib import Path
import subprocess
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "check-apple-results.sh"


class AppleResultsTests(unittest.TestCase):
    def run_results(self, *results):
        return subprocess.run(
            ["bash", str(SCRIPT), *results], capture_output=True, text=True, timeout=5,
        )

    def test_all_jobs_must_succeed(self):
        for results in itertools.product(
            ("success", "failure", "cancelled", "skipped", ""), repeat=3,
        ):
            with self.subTest(results=results):
                result = self.run_results(*results)
                self.assertEqual(result.returncode, 0 if results == ("success",) * 3 else 1)

    def test_missing_or_extra_dependencies_are_rejected(self):
        for count in (0, 1, 2, 4):
            with self.subTest(count=count):
                self.assertEqual(self.run_results(*(["success"] * count)).returncode, 64)

    def test_unknown_result_is_not_a_pass(self):
        self.assertEqual(self.run_results("success", "unknown", "success").returncode, 1)


if __name__ == "__main__":
    unittest.main()
