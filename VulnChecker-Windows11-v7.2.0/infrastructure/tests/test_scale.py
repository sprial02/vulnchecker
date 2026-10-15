import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import run


class ScaleTests(unittest.TestCase):
    def test_user_interruption_does_not_start_next_batch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            with patch.object(run.subprocess,'call',return_value=130) as execute:
                with self.assertRaises(KeyboardInterrupt):
                    run.execute_batches(['ansible-playbook','--limit','all'],{'INFRA_STATUS_PATH':str(root/'status.json')},[['one','two']],root,1)
            self.assertEqual(execute.call_count,1)

    def test_large_inventory_uses_limit_file_and_records_controls(self):
        hosts = [f'server-{i:05}' for i in range(1200)]
        inventory = {'linux': {'hosts': hosts[::2]}, 'windows': {'hosts': hosts[1::2]}}
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def execute(command, env):
                limit = command[command.index('--limit') + 1]
                self.assertTrue(limit.startswith('@'))
                selected = Path(limit[1:]).read_text().splitlines()
                self.assertLessEqual(len(selected), 100)
                self.assertTrue(set(selected) <= set(hosts))
                self.assertEqual(command[command.index('--forks') + 1], '20')
                self.assertEqual(json.loads(command[command.index('-e') + 1])['infra_batch_size'], 100)
                Path(env['INFRA_STATUS_PATH']).write_text(json.dumps({h: {'ok': 2} for h in selected}))
                return 0
            with patch.object(run, 'ROOT', root), patch.object(run.os, 'chdir'), patch.object(run.os, 'umask'), \
                    patch.object(sys, 'argv', ['run.py', '--preflight']), \
                    patch.object(run.subprocess, 'check_output', return_value=json.dumps(inventory)), \
                    patch.object(run.subprocess, 'call', side_effect=execute):
                self.assertEqual(run.main(), 0)
            summary = json.loads(next((root / 'runs').glob('*/summary.json')).read_text(encoding='utf-8'))
            self.assertEqual(len(summary['servers']), 1200)
            self.assertEqual(summary['failed_hosts'], [])
            self.assertEqual(summary['batch_size'], 100)

    def test_invalid_concurrency_rejected_before_inventory_access(self):
        with patch.object(sys, 'argv', ['run.py', '--forks', '1000']), \
                patch.object(run.subprocess, 'check_output') as inventory:
            with self.assertRaises(SystemExit):
                run.main()
            inventory.assert_not_called()


if __name__ == '__main__':
    unittest.main()
