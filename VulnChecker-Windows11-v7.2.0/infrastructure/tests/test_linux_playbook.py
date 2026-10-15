"""Exercise deployment, wrapper, collection and failure detection on a mock host."""
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from run import analyze

ROOT = Path(__file__).resolve().parents[1]

class LinuxPlaybookTests(unittest.TestCase):
    @unittest.skipUnless(os.name == 'posix' and (ROOT / '.venv/bin/ansible-playbook').exists(), 'Kali Ansible integration required')
    def test_deploy_run_collect_and_detect_item_errors(self):
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = Path(tmp)
            bundle = run_dir / 'mock.tar.gz'
            with tarfile.open(bundle, 'w:gz') as archive:
                for n in range(1, 68):
                    script = 'mkdir -p ../results\n'
                    if n != 3:
                        value = json.dumps({'item_id': f'U-{n:02d}', 'final_result': 'VULNERABLE' if n == 1 else 'GOOD'})
                        script += f"printf '%s' '{value}' > ../results/{n}.json\n"
                    script += 'exit ' + ('1' if n == 2 else '0') + '\n'
                    raw = script.encode()
                    entry = tarfile.TarInfo(f'01.Unix서버/Debian/U{n:02d}_check.sh')
                    entry.size = len(raw)
                    archive.addfile(entry, io.BytesIO(raw))
            inventory = run_dir / 'inventory.yml'
            connection = '          ansible_connection: local\n'
            if os.environ.get('INFRA_TEST_SSH_KEY'):
                connection = ('          ansible_connection: ssh\n'
                              '          ansible_host: 127.0.0.1\n          ansible_port: 22222\n          ansible_user: jhs\n'
                              f'          ansible_ssh_private_key_file: {os.environ["INFRA_TEST_SSH_KEY"]}\n'
                              f'          ansible_ssh_common_args: "-o UserKnownHostsFile={os.environ["INFRA_TEST_SSH_KNOWN_HOSTS"]}"\n')
            inventory.write_text('all:\n  children:\n    linux:\n      hosts:\n        mock-linux:\n' + connection +
                                 '          ansible_become: false\n          ansible_python_interpreter: /usr/bin/python3\n          kisa_platform: Debian\n')
            status = run_dir / 'ansible-status.json'
            variables = {'controller_run_dir': str(run_dir), 'controller_bundle_tar': str(bundle)}
            process = subprocess.run([str(ROOT / '.venv/bin/ansible-playbook'), 'playbooks/check.yml', '-i', str(inventory),
                                      '-e', json.dumps(variables)], cwd=ROOT,
                                     env={**os.environ, 'ANSIBLE_CONFIG': str(ROOT / 'ansible.cfg'), 'INFRA_STATUS_PATH': str(status)},
                                     capture_output=True, text=True)
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
            stats = json.loads(status.read_text())['mock-linux']
            state = analyze(run_dir / 'mock-linux', 'linux')
            self.assertTrue(state['execution_failed'])
            self.assertTrue(state['vulnerable'])
            self.assertIn('U-02: exit 1', state['errors'])
            self.assertIn('missing JSON: U-03', state['errors'])
            workspace = Path(stats['remote_workspace']).resolve()
            self.assertEqual(workspace.parent, Path('/tmp'))
            self.assertTrue(workspace.name.startswith('kisa-infra-'))
            shutil.rmtree(workspace)

if __name__ == '__main__':
    unittest.main()
