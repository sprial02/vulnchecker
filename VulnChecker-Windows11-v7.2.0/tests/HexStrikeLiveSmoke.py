"""Verify the real core runtime using localhost health and a harmless MCP printf."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

root = Path(sys.argv[1])
repo = Path(sys.argv[2])
python = repo / '.venv-core/bin/python'
probe = subprocess.check_output([str(python), '-c',
    'import sys,importlib.util,json; print(json.dumps({"python":sys.version.split()[0],'
    '"base":sys.base_prefix,"angr":importlib.util.find_spec("angr") is not None,'
    '"pwn":importlib.util.find_spec("pwn") is not None}))'], text=True)
data = json.loads(probe)
assert data['python'].startswith('3.11.') and not data['base'].startswith('/usr/')
assert not data['angr'] and not data['pwn'], data
with tempfile.TemporaryDirectory(prefix='vc-live-core-') as folder:
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    env = dict(os.environ, HOME=folder, PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin')
    env.update(NO_PROXY='127.0.0.1,localhost', no_proxy='127.0.0.1,localhost')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with open(Path(folder) / 'server.log', 'w+') as log:
        process = subprocess.Popen([str(python), str(root / 'scripts/hexstrike-local.py'),
            '--repository', str(repo), '--port', str(port)], env=env, stdout=log, stderr=log)
        try:
            url = f'http://127.0.0.1:{port}'
            deadline = time.monotonic() + 45
            healthy = False
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    log.seek(0)
                    raise RuntimeError(log.read())
                try:
                    with opener.open(url + '/health', timeout=30) as response:
                        health = json.loads(response.read())
                        assert 'tools_status' in health or 'version' in health
                    healthy = True
                    break
                except (OSError, ValueError):
                    time.sleep(1)
            if not healthy:
                log.seek(0)
                raise RuntimeError('Local health timeout\n' + log.read())
            check = subprocess.run([str(python), str(root / 'scripts/check-mcp.py'),
                                    str(repo / 'hexstrike_mcp.py'), url],
                                   capture_output=True, text=True, timeout=90, env=env)
            assert check.returncode == 0, check.stderr
            result = json.loads(check.stdout.strip().splitlines()[-1])
            assert result['connected'] and result['execution'] and result['tools'] > 0
            print(f'PASS isolated Python {data["python"]}, core excludes optional packages, '
                  f'localhost health and MCP round trip ({result["tools"]} tools). No target scans.')
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()
