"""Configure MobSF's supported upstream proxy; preserve its other settings."""
import pathlib
import shutil
import socket
import subprocess
import sys
import time

path = pathlib.Path('/home/mobsf/.MobSF/config.py')
begin = '# VulnChecker upstream BEGIN'
end = '# VulnChecker upstream END'
if '--install-ca' in sys.argv:
    import contextlib
    import io
    import os
    from hashlib import md5
    from OpenSSL import crypto
    sys.path.insert(0, os.getcwd())
    os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'mobsf.MobSF.settings')
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        import django
        django.setup()
        from mobsf.DynamicAnalyzer.views.android.environment import Environment, get_ca_file
        Environment('host.docker.internal:5555').install_mobsf_ca('install')
    certificate = pathlib.Path(get_ca_file()).read_bytes()
    subject = crypto.load_certificate(crypto.FILETYPE_PEM, certificate).get_subject().der()
    filename = hex(int.from_bytes(md5(subject).digest()[:4], 'little')).lstrip('0x') + '.0'
    installed = subprocess.run(['/usr/bin/adb', '-s', 'host.docker.internal:5555', 'shell', 'cat', '/system/etc/security/cacerts/' + filename], check=True, capture_output=True, timeout=30).stdout
    if installed.strip() != certificate.strip():
        raise RuntimeError('MobSF CA installation verification failed')
    print('MobSF CA installed and contents verified')
elif '--probe-proxy' in sys.argv:
    try:
        with socket.create_connection(('127.0.0.1', 1337), timeout=2):
            pass
    except OSError:
        arguments = ['httptools', '-m', 'capture', '-p', '1337', '-n', 'vulnchecker-connection-test']
        if '--direct' not in sys.argv:
            arguments.extend(['-u', 'http://host.docker.internal:8080'])
        subprocess.Popen(arguments, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        time.sleep(4)
else:
    # Burp's upstream responses can contain keep-alive headers forbidden by
    # HTTP/2. Use HTTP/1.1 for this managed capture chain, including MobSF's
    # subsequent per-app capture sessions. Preserve other mitmproxy options.
    import yaml
    proxy_config = pathlib.Path.home() / '.mitmproxy' / 'config.yaml'
    proxy_config.parent.mkdir(parents=True, exist_ok=True)
    proxy_text = proxy_config.read_text() if proxy_config.exists() else ''
    proxy_options = yaml.safe_load(proxy_text) or {}
    if not isinstance(proxy_options, dict):
        raise RuntimeError('mitmproxy configuration is not a mapping')
    proxy_changed = proxy_options.get('http2') is not False
    if proxy_changed:
        if proxy_config.exists():
            shutil.copy2(proxy_config, proxy_config.with_name('config.yaml.backup-' + str(time.time_ns())))
        proxy_options['http2'] = False
        proxy_config.write_text(yaml.safe_dump(proxy_options, sort_keys=False))
    text = path.read_text()
    if begin in text:
        first = text.index(begin)
        last = text.index(end, first) + len(end)
        text = text[:first] + text[last:]
    enabled = '--disable' not in sys.argv
    block = "\n" + begin + "\nUPSTREAM_PROXY_ENABLED = " + str(enabled) + "\nUPSTREAM_PROXY_TYPE = 'http'\nUPSTREAM_PROXY_IP = 'host.docker.internal'\nUPSTREAM_PROXY_PORT = 8080\nUPSTREAM_PROXY_SSL_VERIFY = '0'\n" + end + "\n"
    payload = text.rstrip() + block
    compile(payload, str(path), 'exec')
    original = path.read_text()
    if payload != original:
        shutil.copy2(path, path.with_name('config.py.backup-' + str(time.time_ns())))
        temporary = path.with_name('config.py.tmp')
        temporary.write_text(payload)
        temporary.replace(path)
    print('changed' if payload != original or proxy_changed else 'unchanged')
