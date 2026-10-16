"""TXT collection contract: native results, mixed OS, partial runs, no error logs."""
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('infra_text', ROOT / 'scripts/infra-text.py')
text = importlib.util.module_from_spec(spec)
spec.loader.exec_module(text)


class Results(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.run = self.root / '20261015T100451Z-12345678'
        self.run.mkdir()
        self.output = self.root / '점검결과'

    def tearDown(self):
        self.tmp.cleanup()

    def summary(self, hosts, **extra):
        value = {'run_id': self.run.name, 'hosts': hosts, 'preflight': False,
                 'targets': {h: {'server': h, 'host': '192.0.2.1', 'profile': 'windows', 'instance': 'os'} for h in hosts},
                 'failed_hosts': hosts, 'servers': {h: {'errors': ['PRIVATE_FAILURE_LOG']} for h in hosts}}
        value.update(extra)
        (self.run / 'summary.json').write_text(json.dumps(value), encoding='utf-8')

    def archive(self, host, tar=False, native=True, rc=0):
        folder = self.run / host
        folder.mkdir()
        record = {'item_id': 'W-01', 'item_name': '계정 점검', 'final_result': 'VULNERABLE',
                  'command_result': '실제 스크립트 결과', 'command': 'inspect', 'inspection': '기준 점검'}
        files = {'execution.json': json.dumps([{'item_id': 'W-01', 'rc': rc}, {'item_id': 'W-02', 'rc': 124}]),
                 '02.Windows서버/results/20261015/host_W-01_result.json': json.dumps(record, ensure_ascii=False),
                 '02.Windows서버/results/20261015/host_W-02_result.json': json.dumps({**record, 'item_id': 'W-02', 'command_result': 'FAILED_ITEM_OUTPUT'}),
                 'execution-logs/W-01.stderr.log': 'PRIVATE_FAILURE_LOG',
                 'vars.json': '{"secret": "PRIVATE_CONFIG"}',
                 'lib/code.ps1': 'NEVER_INCLUDE_SCRIPT'}
        if native:
            files['02.Windows서버/results/20261015/host_W-01_result.txt'] = '원본 결과 내용\n최종 판정: 취약'
        if tar:
            with tarfile.open(folder / 'evidence.tar.gz', 'w:gz') as archive:
                for name, value in files.items():
                    data = value.encode('utf-8')
                    member = tarfile.TarInfo('./' + name)
                    member.size = len(data)
                    archive.addfile(member, io.BytesIO(data))
        else:
            with zipfile.ZipFile(folder / 'evidence.zip', 'w') as archive:
                for name, value in files.items():
                    archive.writestr(name, value.encode('utf-8'))

    def test_mixed_archives_one_file_includes_partial_success_only(self):
        self.summary(['unix', 'windows', 'unreachable'])
        self.archive('unix', tar=True)
        self.archive('windows')
        result = text.export_run(self.run, self.output)
        self.assertEqual(result['items'], 2)
        self.assertEqual(result['skipped_targets'], ['unreachable'])
        path = Path(result['path'])
        self.assertEqual(path.name, '인프라점검결과_20261015_190451_12345678.txt')
        body = path.read_text(encoding='utf-8-sig')
        self.assertEqual(body.count('원본 결과 내용'), 2)
        for excluded in ('FAILED_ITEM_OUTPUT', 'PRIVATE_FAILURE_LOG', 'PRIVATE_CONFIG', 'NEVER_INCLUDE_SCRIPT', 'unreachable', '증적'):
            self.assertNotIn(excluded, body)
        self.assertTrue(path.read_bytes().startswith(b'\xef\xbb\xbf'))
        self.assertIn(b'\r\n', path.read_bytes())
        text.export_run(self.run, self.output)
        self.assertEqual(len(list(self.output.glob('*.txt'))), 1)
        self.assertEqual(len(list(self.output.glob('*.tmp'))), 0)

    def test_json_fallback_is_readable(self):
        self.summary(['one'])
        self.archive('one', native=False)
        result = text.export_run(self.run, self.output)
        body = Path(result['path']).read_text(encoding='utf-8-sig')
        self.assertIn('실제 스크립트 결과', body)
        self.assertIn('판정: 취약', body)
        self.assertNotIn('FAILED_ITEM_OUTPUT', body)

    def test_no_results_or_preflight_does_not_make_txt(self):
        self.summary(['failed'])
        self.archive('failed', rc=127)
        self.assertEqual(text.export_run(self.run, self.output)['status'], 'no_results')
        self.assertEqual(list(self.output.glob('*.txt')), [])
        self.summary(['failed'], preflight=True)
        self.assertEqual(text.export_run(self.run, self.output)['status'], 'preflight')

    def test_unsafe_server_does_not_read_outside_run(self):
        self.summary(['../other'])
        with self.assertRaises(ValueError):
            text.export_run(self.run, self.output)
        self.assertEqual(list(self.output.glob('*')), [])

    def test_corrupt_archive_does_not_hide_other_server(self):
        self.summary(['corrupt', 'good'])
        (self.run / 'corrupt').mkdir()
        (self.run / 'corrupt/evidence.zip').write_bytes(b'not a zip')
        self.archive('good')
        result = text.export_run(self.run, self.output)
        self.assertEqual(result['items'], 1)
        self.assertEqual(result['skipped_targets'], ['corrupt'])


if __name__ == '__main__':
    unittest.main()
