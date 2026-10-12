import importlib.util
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
spec = importlib.util.spec_from_file_location('infra_run', Path(__file__).resolve().parents[1] / 'scripts/run.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

class ResultTests(unittest.TestCase):
    def archive(self, root, missing=None, bad_rc=False, malformed=False, windows=False):
        count, prefix = (64, 'W') if windows else (67, 'U')
        files = {'execution.json': json.dumps([{'item_id': f'{prefix}-{n:02}', 'rc': 124 if bad_rc and n == 1 else 0}
                                              for n in range(1, count + 1)]).encode()}
        for n in range(1, count + 1):
            if n != missing:
                files[f'results/{n}.json'] = (b'broken' if malformed and n == 2 else json.dumps(
                    {'item_id': f'{prefix}-{n:02}', 'final_result': 'VULNERABLE' if n == 1 else 'GOOD'}).encode())
        if windows:
            with zipfile.ZipFile(root / 'evidence.zip', 'w') as archive:
                for name, data in files.items():
                    archive.writestr(name, b'\xef\xbb\xbf' + data)
        else:
            with tarfile.open(root / 'evidence.tar.gz', 'w:gz') as archive:
                for name, data in files.items():
                    info = tarfile.TarInfo(name)
                    info.size = len(data)
                    archive.addfile(info, io.BytesIO(data))

    def test_vulnerability_is_not_execution_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.archive(root)
            state = runner.analyze(root, 'linux')
            self.assertFalse(state['execution_failed'])
            self.assertTrue(state['vulnerable'])
            self.assertEqual(state['counts']['GOOD'], 66)

    def test_missing_result_detected_even_with_all_zero_exit_codes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.archive(root, missing=3)
            state = runner.analyze(root, 'linux')
            self.assertTrue(state['execution_failed'])
            self.assertIn('missing JSON: U-03', state['errors'])

    def test_timeout_fails_even_with_valid_result(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.archive(root, bad_rc=True)
            self.assertTrue(runner.analyze(root, 'linux')['execution_failed'])

    def test_invalid_json_and_missing_archive(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.assertTrue(runner.analyze(root, 'linux')['execution_failed'])
            self.archive(root, malformed=True)
            self.assertTrue(runner.analyze(root, 'linux')['execution_failed'])

    def test_windows_utf8_bom_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.archive(root, windows=True)
            self.assertFalse(runner.analyze(root, 'windows')['execution_failed'])

    def test_recursive_inventory_groups(self):
        inventory = {'windows': {'children': ['psrp', 'winrm']}, 'psrp': {'hosts': ['one']}, 'winrm': {'hosts': ['two']}}
        self.assertEqual(runner.group_hosts(inventory, 'windows'), {'one', 'two'})

if __name__ == '__main__':
    unittest.main()
