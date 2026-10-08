#!/usr/bin/env python3
"""Explicit Burp routing for supported HTTP tools; no direct fallback."""
import base64
import json
import os
from pathlib import Path
import shutil
import ssl
import sys
import urllib.request
import http.client
import time

FLAGS = {'curl': '--proxy', 'ffuf': '-x', 'gobuster': '--proxy',
         'nikto': '-useproxy', 'sqlmap': '--proxy', 'nuclei': '-proxy',
         'httpx': '-http-proxy', 'katana': '-proxy', 'whatweb': '--proxy'}
ROOT = Path.home() / 'tools/vulnchecker'
CONFIG = ROOT / 'web-proxy.json'


def proxy_environment(config):
    env = dict(os.environ)
    for key in ('HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy'):
        env[key] = config['proxy']
    for key in ('REQUESTS_CA_BUNDLE', 'SSL_CERT_FILE', 'CURL_CA_BUNDLE'):
        env[key] = config['ca']
    env['NO_PROXY'] = env['no_proxy'] = ''
    return env


def configure(encoded):
    spec = json.loads(base64.b64decode(encoded))
    proxy = spec['proxy']
    def fetch(url):
        # Separate connections, always through the selected proxy.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({'http': proxy}))
        request = urllib.request.Request(url, headers={'Connection': 'close'})
        with opener.open(request, timeout=10) as response:
            return response.read()

    if b'Burp' not in fetch('http://burp/'):
        raise RuntimeError('Kali proxy endpoint is not Burp')
    pem = None
    last_error = None
    for attempt in range(2):
        for url in ('http://burpsuite/cert', 'http://burp/cert'):
            try:
                pem = ssl.DER_cert_to_PEM_cert(fetch(url))
                ssl.create_default_context(cadata=pem)
                break
            except (OSError, ValueError, http.client.HTTPException) as error:
                pem = None
                last_error = error
        if pem:
            break
        time.sleep(0.5)
    if not pem:
        raise RuntimeError(f'Burp CA download failed through {proxy}: {last_error}. Check the Burp listener and restart the managed web relay.')
    ROOT.mkdir(parents=True, exist_ok=True)
    # Keep the standard trusted CAs and add Burp only for these managed tools.
    ca = ROOT / 'burp-ca-bundle.pem'
    ca.write_text(Path('/etc/ssl/certs/ca-certificates.crt').read_text() + '\n' + pem)
    ssl.create_default_context(cafile=str(ca))  # Reject invalid certificate data.
    search = os.pathsep.join(p for p in os.get_exec_path() if Path(p) != ROOT / 'web-bin')
    tools = {name: shutil.which(name, path=search) for name in FLAGS}
    tools = {name: path for name, path in tools.items() if path}
    config = {'proxy': proxy, 'ca': str(ca), 'tools': tools}
    temp = CONFIG.with_suffix('.tmp')
    temp.write_text(json.dumps(config))
    temp.replace(CONFIG)
    print(json.dumps({'connected': True, 'proxy': proxy, 'tools': sorted(tools)}))


def main():
    if len(sys.argv) > 2 and sys.argv[1] == '--configure':
        configure(sys.argv[2])
        return
    config = json.loads(CONFIG.read_text())
    tool = Path(sys.argv[0]).name
    args = sys.argv[1:]
    if tool not in FLAGS:
        if not args or args[0] not in FLAGS:
            raise SystemExit('Supported web tools: ' + ', '.join(FLAGS))
        tool, args = args[0], args[1:]
    executable = config['tools'].get(tool)
    if not executable:
        raise SystemExit(f'{tool} is not installed; no direct fallback')
    # Always set a proxy explicitly: several Go/Perl tools ignore proxy env vars.
    if any(arg.startswith(('--proxy', '-proxy', '--noproxy', '-http-proxy', '-useproxy', '-x')) for arg in args):
        raise SystemExit('Proxy override is disabled in the managed Burp web route')
    if tool == 'curl':
        args = ['--noproxy', '', '--cacert', config['ca']] + args
    env = proxy_environment(config)
    if tool == 'gobuster' and args:
        command = [executable, args[0], FLAGS[tool], config['proxy']] + args[1:]
    else:
        command = [executable, FLAGS[tool], config['proxy']] + args
    os.execve(executable, command, env)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, http.client.HTTPException) as error:
        raise SystemExit(str(error))
