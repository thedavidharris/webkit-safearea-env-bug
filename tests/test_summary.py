import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('summary', Path(__file__).parents[1] / 'scripts/summarize.py')
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)


class SummaryTests(unittest.TestCase):
    def test_timeout_and_missing_probe_are_not_successes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.joinpath('run-1-prime.log').write_text('PROBE ' + json.dumps({'event': 'prime-timeout', 'strategy': 'prime'}))
            report = summary.summarize(root)
            self.assertIn('MISSING INITIAL PROBE', report)
            self.assertIn('prime-timeout', report)
            self.assertNotIn('prime-ready', report)

    def test_first_checkpoint_and_zero_insets_survive_console_prefix(self):
        with tempfile.TemporaryDirectory() as directory:
            initial = dict(event='initial', nativeMs=12.5, strategy='inject', env=dict(top=0, right=0, bottom=0, left=0))
            Path(directory, 'run-1-inject.log').write_text('console PROBE ' + json.dumps(initial) + '\r\nPROBE broken')
            report = summary.summarize(directory)
            self.assertIn('12.5', report)
            self.assertIn('0/0/0/0', report)
            self.assertNotIn('MISSING INITIAL PROBE', report)


if __name__ == '__main__':
    unittest.main()
