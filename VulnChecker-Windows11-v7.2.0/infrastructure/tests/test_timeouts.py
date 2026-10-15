"""Bounded hung actions, failure exports and independent-host progress."""
import csv
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from failure_reasons import describe, write_failures
import run


class FailureTests(unittest.TestCase):
    @unittest.skipUnless(importlib.util.find_spec('ansible'), 'Ansible callback runtime required')
    def test_callback_records_endpoint_without_credentials(self):
        spec=importlib.util.spec_from_file_location('callback_protocol_fixture',ROOT/'plugins/callback/infra_status.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        host=SimpleNamespace(get_name=lambda:'fixture',get_vars=lambda:{'ansible_connection':'winrm','ansible_host':'192.0.2.10','ansible_port':5985,'ansible_winrm_scheme':'https','ansible_password':'DO_NOT_LEAK'})
        result=SimpleNamespace(_host=host,_task=SimpleNamespace(get_name=lambda:'Create isolated workspace',no_log=False),_result={'msg':'ntlm: [SSL: WRONG_VERSION_NUMBER] wrong version number password=DO_NOT_LEAK'})
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'status.json'
            with patch.dict(os.environ,{'INFRA_STATUS_PATH':str(path)}):
                module.CallbackModule().failure(result,unreachable=True)
            saved=path.read_text(encoding='utf-8')
            self.assertNotIn('DO_NOT_LEAK',saved)
            reason=json.loads(saved)['fixture']['diagnostics'][0]
            self.assertEqual(reason['code'],'PROTOCOL_MISMATCH')
            self.assertEqual(reason['endpoint'],'https://192.0.2.10:5985/wsman')

    def test_actionable_classification_never_exports_raw_secrets(self):
        for message, code in [('No route to host', 'ROUTE'), ('Connection refused', 'REFUSED'),
                ('Permission denied (publickey,password)', 'AUTH'), ('Timeout exceeded', 'TIMEOUT'),
                ('sudo password is required', 'PRIVILEGE'), ('certificate verify failed', 'CERTIFICATE'),
                ('SyntaxError: future feature annotations is not defined', 'PYTHON_UNSUPPORTED'),
                ('Received message too long 1346456864', 'SSH_STDOUT_POLLUTION'),
                ('TRIGUARD_PYTHON_UNSUPPORTED: /usr/bin/python3=3.6.8 / TRIGUARD_SSH_STDOUT_POLLUTION', 'TARGET_PREREQUISITES'),
                ('Permission denied, please try again.', 'AUTH'),
                ("ntlm: HTTPSConnectionPool(host='192.0.2.10', port=5985): [SSL: WRONG_VERSION_NUMBER] wrong version number", 'PROTOCOL_MISMATCH')]:
            value = describe(message + ' password=DO_NOT_LEAK', 'fixture', hidden=True)
            self.assertEqual(value['code'], code)
            self.assertNotIn('DO_NOT_LEAK', json.dumps(value))
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'failures.csv'
            write_failures(path, {'run_id': 'qa', 'failed_hosts': ['host'], 'targets': {'host': {
                'server': '192.0.2.1', 'host': '192.0.2.1', 'port': 22, 'connection': 'ssh'}},
                'servers': {'host': {'diagnostics': [describe('Connection refused', 'connect')]}}})
            with path.open(encoding='utf-8-sig', newline='') as f:
                row = next(csv.DictReader(f))
            self.assertEqual((row['ip'], row['reason_code']), ('192.0.2.1', 'REFUSED'))
            self.assertTrue(row['requested_action'])

    @unittest.skipUnless(os.name == 'posix', 'POSIX subprocess groups required')
    def test_repeated_hung_items_stop_after_three_and_other_host_runs(self):
        with tempfile.TemporaryDirectory() as tmp:
            for host, body in [('hung', 'sleep 30\n'), ('healthy', 'exit 0\n')]:
                root = Path(tmp) / host
                folder = root / '01.Unix서버/Debian'
                folder.mkdir(parents=True)
                for n in range(1, 68):
                    (folder / f'U{n:02}_check.sh').write_text(body)
            started = time.monotonic()
            hung = subprocess.Popen([sys.executable, str(ROOT / 'scripts/linux-execute.py'), str(Path(tmp) / 'hung'), 'Debian', '1'])
            healthy = subprocess.Popen([sys.executable, str(ROOT / 'scripts/linux-execute.py'), str(Path(tmp) / 'healthy'), 'Debian', '1'])
            try:
                self.assertEqual(healthy.wait(timeout=10), 0)
                self.assertEqual(hung.wait(timeout=10), 0)
            finally:
                for process in (hung, healthy):
                    if process.poll() is None:
                        process.kill()
                        process.wait()
            records = json.loads((Path(tmp) / 'hung/execution.json').read_text())
            self.assertEqual([r['rc'] for r in records], [124] * 3 + [125] * 64)
            self.assertLess(time.monotonic() - started, 12)

    @unittest.skipUnless(os.name == 'posix' and (ROOT / '.venv/bin/ansible-playbook').exists(), 'Kali Ansible integration required')
    def test_connected_but_hung_task_times_out_next_batch_still_runs(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            inventory = directory / 'hosts.yml'
            inventory.write_text('all:\n  hosts:\n    hung:\n      ansible_connection: local\n      wait_seconds: 30\n    healthy:\n      ansible_connection: local\n      wait_seconds: 0\n')
            playbook = directory / 'check.yml'
            playbook.write_text('''- hosts: all
  gather_facts: false
  strategy: free
  serial: 1
  tasks:
    - name: fixture connected but unresponsive
      ansible.builtin.command: "sleep {{ wait_seconds }}"
      timeout: 2
    - name: fixture healthy completed
      ansible.builtin.debug:
        msg: completed
''')
            status = directory / 'status.json'
            started = time.monotonic()
            command = [str(ROOT / '.venv/bin/ansible-playbook'), '-i', str(inventory), str(playbook), '--limit', 'placeholder']
            rc = run.execute_batches(command, {**os.environ, 'ANSIBLE_CONFIG': str(ROOT / 'ansible.cfg'),
                'INFRA_STATUS_PATH': str(status)}, [['hung', 'healthy']], directory, 1)
            self.assertNotEqual(rc, 0)
            states = json.loads(status.read_text())
            self.assertEqual(states['hung']['diagnostics'][0]['code'], 'TIMEOUT')
            self.assertEqual(states['healthy']['ok'], 2)
            self.assertLess(time.monotonic() - started, 25)


if __name__ == '__main__':
    unittest.main()
