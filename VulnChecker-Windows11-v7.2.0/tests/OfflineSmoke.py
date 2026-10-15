"""Customer runners use synthetic checks only; import never executes customer files."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
INFRA = ROOT / 'infrastructure'
sys.path.insert(0, str(INFRA / 'scripts'))


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


builder = module('offline_builder', INFRA / 'scripts/build-offline.py')
importer = module('offline_importer', ROOT / 'scripts/import-offline.py')
store = module('offline_store', ROOT / 'scripts/report-store.py')


def fixture_payload(family):
    files = {'profiles.json': (INFRA / 'profiles.json').read_bytes(), 'lib/placeholder.txt': b'Fixture only',
             'AGPL-3.0.txt': (INFRA / 'licenses/AGPL-3.0.txt').read_bytes(),
             'LICENSE.upstream.txt': b'Fixture source',
             'source-compatibility.json': json.dumps({'source_revision': builder.REVISION, 'adaptations': []}).encode()}
    if family == 'posix':
        for name in ('offline-unix.py','linux-execute.py','profiles.py','run.py','prepare_source.py','source_compat.py','failure_reasons.py','discover-target.py'):
            files['scripts/' + name] = (INFRA / 'scripts' / name).read_bytes()
        for n in range(1, 68):
            record = json.dumps({'item_id': f'U-{n:02}', 'final_result': 'VULNERABLE' if n == 1 else 'GOOD', 'evidence': 'fixture only'})
            script = f"printf '%s' '{record}' > U-{n:02}.json\n" if n != 2 else 'exit 1\n'
            files[f'01.Unix서버/Debian/U{n:02}_check.sh'] = script.encode()
    else:
        files['scripts/windows-execute.ps1'] = (INFRA / 'scripts/windows-execute.ps1').read_bytes()
        for n in range(1, 19):
            record = json.dumps({'item_id': f'P-{n:02}', 'final_result': 'GOOD', 'evidence': 'fixture only'})
            files[f'07.PC/P{n:02}_check.ps1'] = ("[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'P-" + f'{n:02}' + ".json'),'" + record + "',(New-Object Text.UTF8Encoding($false)))\n").encode('utf-8-sig')
    return files


def result_zip(path, run_id='20261015T010101Z-1234abcd', extra=None, bad_hash=False):
    summary = {'run_id': run_id, 'collection_method': 'customer-offline', 'preflight': False,
               'hosts': ['192.0.2.10'], 'targets': {'192.0.2.10': {'server': '192.0.2.10','profile': 'unresolved','connection': 'local'}},
               'servers': {'192.0.2.10': {'execution_failed': True,'errors': ['fixture permission failure'],'counts': {}}},
               'failed_hosts': ['192.0.2.10'], 'vulnerable_hosts': [], 'manual_hosts': []}
    files = {'summary.json': json.dumps(summary).encode(), 'metadata.json': b'{}', 'failures.csv': b'reason\nfixture\n', 'source-compatibility.json': b'{}'}
    if extra:
        files.update(extra)
    entries = [{'path': k, 'bytes': len(v), 'sha256': hashlib.sha256(v).hexdigest()} for k, v in files.items()]
    if bad_hash:
        entries[0]['sha256'] = '0' * 64
    manifest = {'schema_version': 1,'type': 'triguard-offline-result','run_id': run_id,'files': entries}
    with zipfile.ZipFile(path, 'w') as z:
        for name, value in files.items():
            z.writestr(name, value)
        z.writestr('manifest.json', json.dumps(manifest))


class OfflineTests(unittest.TestCase):
    def test_import_integrity_idempotence_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); path = root / 'result.zip'; destination = root / 'runs'
            result_zip(path)
            self.assertEqual(importer.import_result(path,destination)['status'],'imported')
            self.assertEqual(importer.import_result(path,destination)['status'],'already_imported')
            result_zip(path,extra={'192.0.2.10/evidence.zip': b'changed'})
            with self.assertRaises(ValueError):
                importer.import_result(path,destination)
            self.assertEqual(len(list(destination.glob('*/summary.json'))),1)

    def test_bad_hash_and_paths_leave_no_partial_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); path = root / 'result.zip'; destination = root / 'runs'
            for extra, bad in [({},True),({'../escape.txt': b'bad'},False),({'vars.json': b'credentials'},False),({'C:/bad.txt': b'bad'},False)]:
                result_zip(path, extra=extra, bad_hash=bad)
                with self.assertRaises(ValueError):
                    importer.import_result(path,destination)
                self.assertEqual(list(destination.iterdir()),[])
            self.assertFalse((root/'escape.txt').exists())

    @unittest.skipUnless(os.name == 'posix','Bash required')
    def test_single_unix_script_executes_fixture_then_imports_and_indexes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); kit = root/'kit'
            with patch.object(builder,'source_files',side_effect=lambda source,family: fixture_payload(family)):
                builder.build(root,kit)
            # Root is required by the production runner. The integration harness runs in
            # an approved root test process; fixtures only write their own temp JSON.
            if os.geteuid() != 0:
                self.skipTest('Root fixture execution required')
            result = subprocess.run(['bash',str(kit/'Unix-Infrastructure.sh'),'--profile','unix-debian','--target-id','192.0.2.10'],capture_output=True,text=True,timeout=40)
            self.assertEqual(result.returncode,2,result.stdout+result.stderr)
            archive = next((kit/'results').glob('*.zip'))
            imported = importer.import_result(archive,root/'runs')
            db = store.connect(root/'db.sqlite3')
            source = store.import_infra(db,root/'runs'/imported['run_id'])
            stats = store.stats(db,source)
            self.assertEqual(stats['physical_assets'],1)
            self.assertEqual(stats['failed_assets'],1)
            self.assertEqual(stats['total_checks'],66)
            self.assertEqual(stats['counts']['VULNERABLE'],1)
            with zipfile.ZipFile(archive) as z:
                self.assertNotIn('instance.json',str(z.namelist()))
                self.assertIn('failures.csv',z.namelist())
            db.close()

    @unittest.skipUnless(os.name == 'nt','Windows PowerShell required')
    def test_single_windows_script_executes_only_synthetic_checks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);kit=root/'kit'
            with patch.object(builder,'source_files',side_effect=lambda source,family:fixture_payload(family)):
                builder.build(root,kit)
            # These payload checks only write fixture JSON. Allow this TEST-ONLY copy
            # to exercise the full runner without requesting elevation from the user.
            script=kit/'Windows-Infrastructure.ps1'
            content=script.read_text(encoding='utf-8-sig')
            content=content.replace("if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))", 'if ($false)')
            script.write_text(content,encoding='utf-8-sig')
            result=subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(kit/'Windows-Infrastructure.ps1'),
                '-Profiles','pc','-TargetId','192.0.2.20'],capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=60)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            archive=next((kit/'results').glob('*.zip'))
            imported=importer.import_result(archive,root/'runs')
            summary=json.loads((root/'runs'/imported['run_id']/'summary.json').read_text(encoding='utf-8-sig'))
            if result.returncode==0:
                self.assertEqual(summary['servers']['192.0.2.20']['counts']['GOOD'],18)
            else:
                self.assertTrue(summary['failed_hosts'])


if __name__ == '__main__':
    unittest.main()
