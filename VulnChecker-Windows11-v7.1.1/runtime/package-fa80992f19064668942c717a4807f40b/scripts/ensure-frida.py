"""Use MobSF's own version/ABI provisioning and verify the live server."""
import contextlib
import io
import json
import os
import subprocess
import sys
import time
import frida
sys.path.insert(0, os.getcwd())

identifier = sys.argv[1]
adb = ["/usr/bin/adb", "-s", identifier]
def command(*args, check=True):
    return subprocess.run(adb + list(args), text=True, capture_output=True, check=check, timeout=60).stdout.strip()

if command("shell", "id", "-u") != "0":
    raise RuntimeError("ADB root is required")
version = command("shell", "/system/fd_server", "--version", check=False)
if version != frida.__version__:
    running = command("shell", "pidof", "fd_server", check=False)
    if running:
        raise RuntimeError("Different Frida server is running. Stop the current analysis before repair.")
    # Use the project's version-aware official download/provisioning code.
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "mobsf.MobSF.settings")
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        import django
        django.setup()
        from mobsf.DynamicAnalyzer.views.android.environment import Environment
        Environment(identifier).frida_setup()
    version = command("shell", "/system/fd_server", "--version", check=False)
    if version != frida.__version__:
        # GitHub release API can be rate-limited; use the same official release
        # asset directly, with HTTPS verification, never a third-party mirror.
        import lzma
        import pathlib
        import requests
        from django.conf import settings
        abi = command('shell', 'getprop', 'ro.product.cpu.abi')
        architecture = {'x86_64': 'x86_64', 'x86': 'x86', 'arm64-v8a': 'arm64', 'armeabi-v7a': 'arm'}.get(abi)
        if not architecture:
            raise RuntimeError('Unsupported Frida server ABI: ' + abi)
        name = f'frida-server-{frida.__version__}-android-{architecture}'
        url = f'https://github.com/frida/frida/releases/download/{frida.__version__}/{name}.xz'
        response = requests.get(url, timeout=120)
        response.raise_for_status()
        path = pathlib.Path(settings.DWD_DIR) / name
        path.write_bytes(lzma.decompress(response.content))
        command('push', str(path), '/system/fd_server')
        command('shell', 'chmod', '755', '/system/fd_server')
        version = command('shell', '/system/fd_server', '--version')
        if version != frida.__version__:
            raise RuntimeError('Frida server provisioning failed or version differs')
if not command("shell", "pidof", "fd_server", check=False):
    # Some adb shell transports wait forever on inherited daemon descriptors.
    # Detach with every descriptor redirected rather than capturing -D output.
    command("shell", "nohup /system/fd_server -P -l 127.0.0.1:27042 > /data/local/tmp/vulnchecker-frida.log 2>&1 < /dev/null &")
    time.sleep(3)
command('forward', 'tcp:27042', 'tcp:27042')
device = frida.get_device_manager().add_remote_device('127.0.0.1:27042')
try:
    parameters = device.query_system_parameters()
    # Process discovery alone can succeed in jailed mode. Application discovery
    # exercises the Android runtime helper used by Java spawn/instrumentation.
    applications = device.enumerate_applications()
    # Exercise spawn/attach too: process listing can pass while linker support
    # is broken. Cache only within this container and Android boot/version.
    from pathlib import Path
    signature = version + ':' + command('shell', 'cat', '/proc/sys/kernel/random/boot_id')
    probe = Path('/tmp/vulnchecker/frida-validated')
    if not probe.exists() or probe.read_text() != signature:
        pid = device.spawn(['com.android.settings'])
        try:
            session = device.attach(pid)
            device.resume(pid)
            session.detach()
        except Exception:
            try:
                device.resume(pid)
            except Exception:
                pass
            raise
        probe.write_text(signature)
except Exception as error:
    diagnostic = command('shell', 'cat', '/data/local/tmp/vulnchecker-frida.log', check=False)
    crash = command('logcat', '-d', '-b', 'crash', '-t', '65', check=False)
    diagnostic += '\n' + '\n'.join(line for line in crash.splitlines() if 'Abort message:' in line)
    raise RuntimeError(str(error) + '\n' + diagnostic) from error
if parameters.get('access') != 'full':
    raise RuntimeError('Frida is in jailed mode; root server connection did not succeed')
processes = device.enumerate_processes()
if not processes:
    raise RuntimeError("Frida returned no processes")
# Extend MobSF's selected root_bypass hook in the same analysis session.
import hashlib
from pathlib import Path
target = Path('mobsf/DynamicAnalyzer/tools/frida_scripts/android/default/root_bypass.js')
original = target.read_text(encoding='utf-8')
begin, end = '// VulnChecker root hooks BEGIN', '// VulnChecker root hooks END'
base = original
if begin in base:
    first = base.index(begin)
    last = base.index(end, first) + len(end)
    base = base[:first] + base[last:]
addition = Path('/tmp/vulnchecker/root-bypass.js').read_text(encoding='utf-8')
payload = base.rstrip() + '\n' + begin + '\n' + addition + '\n' + end + '\n'
if payload != original:
    backup = Path('/home/mobsf/.MobSF/vulnchecker-root-hooks')
    backup.mkdir(exist_ok=True)
    saved = backup / ('root_bypass-' + hashlib.sha256(base.encode()).hexdigest()[:16] + '.js')
    if not saved.exists():
        saved.write_text(base, encoding='utf-8')
    target.write_text(payload, encoding='utf-8')
print(json.dumps({"version": version, "abi": command("shell", "getprop", "ro.product.cpu.abi"), "processes": len(processes), "access": parameters['access'], "mobsf_root_hooks": True, "connected": True}))
