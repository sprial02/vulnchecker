"""Run in Linux with base64 inventory source as argv[1]; read-only probes."""
import base64
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

SOURCE = base64.b64decode(sys.argv.pop(1)).decode('utf-8-sig')


class InventoryTests(unittest.TestCase):
    def probe(self, complete):
        with tempfile.TemporaryDirectory(prefix='vc-inventory-test-') as folder:
            root = pathlib.Path(folder)
            script = root / 'inventory.py'
            script.write_text(SOURCE)
            repo = root / 'custom-hexstrike'
            repo.mkdir()
            (repo / '.git').mkdir()
            (repo / 'hexstrike_server.py').write_text('# preserve existing server\n')
            if complete:
                (repo / 'hexstrike_mcp.py').write_text('# existing MCP\n')
                (repo / 'requirements.txt').write_text('')
            options = {'hexstrikePath': str(repo), 'toolNames': [], 'packages': []}
            encoded = base64.b64encode(json.dumps(options).encode()).decode()
            result = subprocess.run([sys.executable, str(script), encoded],
                                    check=True, capture_output=True, text=True, timeout=30)
            data = json.loads(result.stdout)
            self.assertEqual(data['hexstrike']['path'], str(repo))
            self.assertEqual((repo / 'hexstrike_server.py').read_text(), '# preserve existing server\n')
            self.assertEqual((repo / 'hexstrike_mcp.py').exists(), complete)
            return data

    def test_partial_existing_repository_is_detected_without_rewriting_files(self):
        self.assertFalse(self.probe(False)['hexstrike']['files_ready'])

    def test_complete_repository_is_ready(self):
        self.assertTrue(self.probe(True)['hexstrike']['files_ready'])


unittest.main()
