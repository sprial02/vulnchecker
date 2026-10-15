"""No target traffic: test proxy arguments, trust env, failure and project rules."""
import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='vc-web-smoke-') as directory:
    work = Path(directory)
    stub = work / 'tool'
    stub.write_text('#!/usr/bin/env python3\nimport json,os,sys\nprint(json.dumps({"args":sys.argv[1:],"proxy":os.environ.get("https_proxy"),"ca":os.environ.get("SSL_CERT_FILE"),"bypass":os.environ.get("no_proxy")}))\n')
    stub.chmod(0o700)
    config = work / 'proxy.json'
    config.write_text(json.dumps({'proxy': 'http://127.0.0.1:18880', 'ca': '/fixture/ca.pem', 'tools': {'curl': str(stub), 'gobuster': str(stub)}}))
    loader = "import importlib.util,sys; from pathlib import Path; s=importlib.util.spec_from_file_location('web',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); m.CONFIG=Path(sys.argv[2]); sys.argv=['web-tools.py']+sys.argv[3:]; m.main()"

    def run(*args):
        return subprocess.run([sys.executable, '-c', loader, str(root / 'scripts/web-tools.py'), str(config), *args], capture_output=True, text=True)

    result = run('curl', 'https://fixture.invalid/')
    assert result.returncode == 0, result.stderr
    data = json.loads(result.stdout)
    assert data['args'][:2] == ['--proxy', 'http://127.0.0.1:18880']
    assert data['proxy'] == 'http://127.0.0.1:18880' and data['ca'] == '/fixture/ca.pem' and data['bypass'] == ''
    assert json.loads(run('gobuster', 'dir', '-u', 'http://fixture.invalid/').stdout)['args'][:3] == ['dir', '--proxy', 'http://127.0.0.1:18880']
    assert run('curl', '-xhttp://other.invalid', 'http://fixture.invalid').returncode != 0
    assert run('nikto', '-h', 'http://fixture.invalid').returncode != 0
    print('PASS explicit tool proxy arguments, CA, localhost capture and no direct fallback')

    (work / 'opencode.json').write_text(json.dumps({'model': 'fixture/model', 'permission': {'edit': 'ask'}, 'instructions': ['custom.md']}))
    encoded = base64.b64encode(json.dumps({'work': str(work), 'web': True, 'helper': '/fixture/web-tools.py'}).encode()).decode()
    subprocess.run([sys.executable, str(root / 'scripts/prepare-system-context.py'), encoded], check=True, capture_output=True)
    saved = json.loads((work / 'opencode.json').read_text())
    assert saved['permission'] == {'edit': 'ask', 'bash': 'deny', 'webfetch': 'deny'}
    assert saved['model'] == 'fixture/model' and saved['instructions'][0] == 'custom.md'
    assert len(saved['instructions']) == 2 and list(work.glob('opencode.json.backup-*'))
    assert 'execution state is UNKNOWN' in (work / 'VULNCHECKER_WORKFLOW.md').read_text()
    print('PASS project fallback restrictions, recovery rules and preserved user config')
