"""Portable raw datasets: isolation, retention, completeness, integrity and scale."""
import csv
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('archive', ROOT / 'scripts/report-archive.py')
archive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archive)
store = archive.store


class RawArchive(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.db = store.connect(self.root / 'index.sqlite3')
        self.library = self.root / 'raw-data'

    def tearDown(self):
        self.db.close()
        self.tmp.cleanup()

    def ingest(self, name, records):
        folder = self.root / name
        folder.mkdir(exist_ok=True)
        path = folder / 'findings.json'
        path.write_text(json.dumps({'name': name, 'findings': records}), encoding='utf-8')
        return path, store.import_json(self.db, path, 'infra')

    def test_isolated_portable_versioned_dataset(self):
        records = [{'item_id': 'U-01', 'asset': '=server', 'status': 'VULNERABLE', 'evidence': 'x' * 25000 + 'password=RAW_SECRET',
                    'images': [{'path': 'shot.png'}]}]
        folder = self.root / 'customer-one'
        folder.mkdir()
        (folder / 'shot.png').write_bytes(b'image-fixture')
        path, source = self.ingest('customer-one', records)
        self.ingest('customer-two', [{'id': 'OTHER_CUSTOMER_MARKER', 'asset': 'other'}])
        (folder / 'vars.json').write_text('NEVER_EXPORT_CREDENTIALS')
        bundle = archive.build(self.db, source, self.library)
        manifest = archive.verify(bundle)
        self.assertEqual(manifest['missing'], [])
        self.assertEqual((bundle / 'raw/findings.json').read_bytes(), path.read_bytes())
        self.assertNotIn('RAW_SECRET', (bundle / 'checks.jsonl').read_text(encoding='utf-8'))
        self.assertNotIn('OTHER_CUSTOMER_MARKER', (bundle / 'results.sqlite3').read_bytes().decode('utf-8', errors='ignore'))
        with (bundle / 'checks.csv').open(encoding='utf-8-sig', newline='') as f:
            row = next(csv.DictReader(f))
            self.assertEqual(row['asset'], "'=server")
        self.assertFalse((bundle / 'raw/vars.json').exists())
        portable = store.connect(bundle / 'results.sqlite3')
        image = portable.execute('SELECT path FROM attachments').fetchone()[0]
        self.assertTrue((bundle / image).is_file())
        self.assertEqual(portable.execute('SELECT COUNT(*) FROM sources').fetchone()[0], 1)
        portable.close()
        records[0]['status'] = 'GOOD'
        self.ingest('customer-one', records)
        second = archive.build(self.db, source, self.library)
        self.assertNotEqual(bundle, second)
        self.assertTrue(bundle.is_dir())
        shutil.rmtree(folder)
        # Already archived data can be delivered even after its original is gone.
        (second / 'unrelated.txt').write_text('DO_NOT_EXPORT')
        exported = archive.export(self.db, source, self.library, self.root / 'exports')
        with zipfile.ZipFile(exported) as z:
            self.assertIn('raw/shot.png', z.namelist())
            self.assertNotIn('unrelated.txt', z.namelist())
        (second / 'raw/shot.png').write_bytes(b'tampered')
        with self.assertRaises(ValueError):
            archive.export(self.db, source, self.library, self.root / 'exports')

    def test_infra_archives_and_missing_evidence(self):
        run = self.root / 'run'
        (run / 'one').mkdir(parents=True)
        (run / 'summary.json').write_text(json.dumps({'run_id': 'qa', 'hosts': ['one', 'missing'],
            'targets': {'one': {'server': 'server', 'instance': 'db', 'profile': 'mysql'}},
            'servers': {'one': {'counts': {'GOOD': 1}}, 'missing': {'counts': {'VULNERABLE': 2}}}}))
        with zipfile.ZipFile(run / 'one/evidence.zip', 'w') as z:
            z.writestr('D-01.json', json.dumps({'item_id': 'D-01', 'final_result': 'GOOD', 'custom_field': 'retain-me'}))
        (run / 'vars.json').write_text('DO_NOT_EXPORT')
        (run / 'failures.csv').write_text('server,reason\nmissing,timeout\n')
        source = store.import_infra(self.db, run)
        bundle = archive.build(self.db, source, self.library)
        self.assertEqual(archive.verify(bundle)['missing'], ['raw/missing/evidence'])
        self.assertEqual((bundle / 'raw/failures.csv').read_bytes(), (run / 'failures.csv').read_bytes())
        self.assertEqual((run / 'one/evidence.zip').read_bytes(), (bundle / 'raw/one/evidence.zip').read_bytes())
        restored = store.connect(self.root / 'restored.sqlite3')
        new_source = store.import_infra(restored, bundle / 'raw')
        self.assertEqual(store.stats(restored, new_source)['counts'], {'GOOD': 1, 'VULNERABLE': 2})
        self.assertEqual(restored.execute('SELECT profile_id FROM assets WHERE name="one"').fetchone()[0], 'mysql')
        restored.close()

    def test_modified_origin_requires_reindex_and_no_partial_bundle(self):
        path, source = self.ingest('changed', [{'id': 'A', 'status': 'GOOD'}])
        path.write_text('{"findings": [{"id":"A", "status":"VULNERABLE"}]}')
        with self.assertRaises(ValueError):
            archive.build(self.db, source, self.library)
        self.assertEqual(list(self.library.glob('*/*/manifest.json')), [])
        store.import_json(self.db, path, 'infra')
        archive.sync(self.db, self.library)
        self.assertIn(source, (self.library / 'index.html').read_text(encoding='utf-8'))

    def test_2000_servers_with_67_checks(self):
        path, source = self.ingest('scale', [
            {'item_id': f'U-{item:02}', 'asset': f'server-{server:04}', 'status': 'GOOD', 'evidence': 'synthetic fixture'}
            for server in range(2000) for item in range(1, 68)])
        bundle = archive.build(self.db, source, self.library)
        with (bundle / 'checks.jsonl').open(encoding='utf-8') as stream:
            self.assertEqual(sum(1 for _ in stream), 134000)
        result = json.loads((bundle / 'assessment.json').read_text(encoding='utf-8'))
        self.assertEqual(result['stats']['physical_assets'], 2000)
        archive.verify(bundle)


if __name__ == '__main__':
    unittest.main()
