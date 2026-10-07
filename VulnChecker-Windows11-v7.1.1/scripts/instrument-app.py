"""Spawn, attach, load hooks, then resume. Keep the session alive."""
import contextlib
import io
import json
import os
from pathlib import Path
import signal
import sys
import threading
import frida
sys.path.insert(0, os.getcwd())

if len(sys.argv) == 2 and sys.argv[1] == '--stop':
    identity = Path('/tmp/vulnchecker/frida-session.json')
    if identity.exists():
        saved = json.loads(identity.read_text())
        proc = Path('/proc') / str(saved['pid'])
        if proc.exists() and proc.joinpath('stat').read_text().split()[21] == saved['start']:
            if b'/tmp/vulnchecker/instrument-app.py' in proc.joinpath('cmdline').read_bytes().split(b'\0'):
                os.kill(saved['pid'], signal.SIGTERM)
    sys.exit(0)
identifier, package, script_file = sys.argv[1:4]
duration = float(sys.argv[4]) if len(sys.argv) > 4 else None
identity = Path('/tmp/vulnchecker/frida-session.json')
identity.write_text(json.dumps({'pid': os.getpid(), 'start': Path('/proc/self/stat').read_text().split()[21]}))
code = Path(script_file).read_text(encoding="utf-8")
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "mobsf.MobSF.settings")
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    import django
    django.setup()
    from mobsf.DynamicAnalyzer.views.common.frida import get_bridge_loader
    if int(frida.__version__.split('.')[0]) >= 17:
        bridge = get_bridge_loader()
        if bridge.is_required_and_available():
            code = bridge.inject_bridge_support(code, "java")
        else:
            raise RuntimeError('Frida 17 Java bridge is unavailable in MobSF')
stop = threading.Event()
signal.signal(signal.SIGTERM, lambda *_: stop.set())
signal.signal(signal.SIGINT, lambda *_: stop.set())
device = frida.get_device_manager().add_remote_device('127.0.0.1:27042')
if device.query_system_parameters().get('access') != 'full':
    raise RuntimeError('Frida full/root access is required for spawn injection')
pid = device.spawn([package])
resumed = False
script_failed = threading.Event()
def on_message(message, data):
    print(json.dumps(message, ensure_ascii=False), flush=True)
    if message.get('type') == 'error':
        script_failed.set()
        stop.set()
try:
    session = device.attach(pid)
    session.on("detached", lambda *args: (print(json.dumps({"detached": str(args)}), flush=True), stop.set()))
    script = session.create_script(code)
    script.on("message", on_message)
    script.load()
    device.resume(pid)
    resumed = True
    print(json.dumps({"spawned": package, "pid": pid, "script_loaded": True}), flush=True)
    stop.wait(duration)
    try:
        session.detach()
    except frida.InvalidOperationError:
        pass
finally:
    # A failed load must not leave an app suspended forever.
    if not resumed:
        device.resume(pid)
    if identity.exists():
        saved = json.loads(identity.read_text())
        if saved.get('pid') == os.getpid():
            identity.unlink()
if script_failed.is_set():
    raise RuntimeError('Frida JavaScript hook initialization failed; session detached')
