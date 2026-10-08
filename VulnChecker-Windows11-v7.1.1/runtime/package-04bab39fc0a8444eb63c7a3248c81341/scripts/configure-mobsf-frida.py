"""Apply a guarded, reversible early-root-injection fix to managed MobSF."""
import ast
import hashlib
import pathlib
import sys
import textwrap

MARKER = '# VulnChecker suspended-root-spawn v2'
METHODS = {
    'get_script': '''
def get_script(self, nolog=False):
    """Load root hooks before resume; keep monitor/custom script delay."""
    # VulnChecker suspended-root-spawn v2
    defaults = list(self.defaults or [])
    early_root = ('root_bypass' in defaults or '*' in defaults
                  or self.package == 'com.gscaltex.energyplus')
    early = ''
    if early_root:
        early = '\\n'.join(self.get_scripts('default', ['root_bypass']))
        if '*' in defaults:
            defaults = [p.stem for p in (self.frida_dir / 'default').rglob('*.js')
                        if p.stem != 'root_bypass']
        else:
            defaults = [p for p in defaults if p != 'root_bypass']
    scripts = [self.code or '']
    scripts.extend(self.get_scripts('default', defaults))
    scripts.extend(self.get_auxiliary())
    rpc_script = ','.join(self.get_scripts('rpc', ['*']))
    combined = '\\n'.join(scripts)
    final = (f'rpc.exports = {{\\n{rpc_script}\\n}};\\n{early}\\n'
             f'setTimeout(function() {{\\n{combined}\\n}}, 1000)')
    if self.bridge_loader.is_required_and_available():
        final = self.bridge_loader.inject_bridge_support(final, 'java')
    if not nolog:
        logger.info('Frida script prepared; early root hooks=%s', early_root)
    return final
''',
    'spawn': '''
def spawn(self):
    """Suspend root-protected targets until their hooks are loaded."""
    global _FPID
    self._vulnchecker_suspended = False
    try:
        env = Environment()
        self.clean_up()
        env.run_frida_server()
        device = frida.get_device(get_device(), settings.FRIDA_TIMEOUT)
        _FPID = device.spawn([self.package])
        defaults = self.defaults or []
        if ('root_bypass' in defaults or '*' in defaults
                or self.package == 'com.gscaltex.energyplus'):
            self._vulnchecker_device = device
            self._vulnchecker_pid = _FPID
            self._vulnchecker_suspended = True
            self.write_log(self.frida_log,
                           '[VulnChecker] Spawn suspended for early root hooks\\n')
        else:
            device.resume(_FPID)
            time.sleep(1)
    except Exception:
        logger.exception('Frida spawn failed')
        raise
''',
    'session': '''
def session(self, pid, package):
    """Attach/load before resume for protected spawns, retaining MobSF RPC."""
    global _FPID
    device = None
    session = None
    script = None
    try:
        suspended = getattr(self, '_vulnchecker_suspended', False)
        if suspended:
            device = self._vulnchecker_device
            _FPID = self._vulnchecker_pid
            session = device.attach(_FPID)
        else:
            device = frida.get_device(get_device(), settings.FRIDA_TIMEOUT)
            if pid and package:
                _FPID = pid
                self.package = package
            try:
                front = device.get_frontmost_application()
                if front and front.identifier == self.package and front.pid != _FPID:
                    _FPID = front.pid
            except Exception:
                pass
            try:
                session = device.attach(_FPID)
            except Exception:
                self.spawn()
                device = getattr(self, '_vulnchecker_device', device)
                session = device.attach(_FPID)
            if not getattr(self, '_vulnchecker_suspended', False):
                time.sleep(2)
        script = session.create_script(self.get_script())
        from threading import Event
        detached = Event()
        session.on('detached', lambda *args: detached.set())
        script.on('message', self.frida_response)
        script.load()
        if getattr(self, '_vulnchecker_suspended', False):
            device.resume(self._vulnchecker_pid)
            self._vulnchecker_suspended = False
            self.write_log(self.frida_log,
                           '[VulnChecker] Root JS loaded before resume\\n')
        self.api_handler(script.exports_sync)
        # Gunicorn stdin is EOF: waiting on it unloads hooks before Java.perform.
        # Keep the script until the app exits or the device/session disconnects.
        detached.wait()
    except Exception:
        logger.exception('Frida instrumentation failed')
        self.write_log(self.frida_log,
                       '[VulnChecker] Instrumentation failed; check MobSF logs\\n')
    finally:
        if getattr(self, '_vulnchecker_suspended', False):
            # An unsuccessful injection must not leave an app suspended.
            try:
                self._vulnchecker_device.kill(self._vulnchecker_pid)
            except Exception:
                pass
            self._vulnchecker_suspended = False
        if script:
            try:
                script.unload()
            except Exception:
                pass
        if session:
            try:
                session.detach()
            except Exception:
                pass
''',
}


def patch(source):
    tree = ast.parse(source)
    classes = [node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == 'Frida']
    if len(classes) != 1:
        raise RuntimeError('Unsupported MobSF Frida class layout; source left unchanged')
    methods = {node.name: node for node in classes[0].body if isinstance(node, ast.FunctionDef)}
    for name, args in {'get_script': ['self', 'nolog'], 'spawn': ['self'],
                       'session': ['self', 'pid', 'package']}.items():
        if name not in methods or [arg.arg for arg in methods[name].args.args] != args:
            raise RuntimeError('Unsupported MobSF method signature: ' + name)
    legacy_marker = '# VulnChecker suspended-root-spawn v1'
    if MARKER in source or legacy_marker in source:
        # Also validate the bodies, rather than trusting a marker alone.
        if all(ast.dump(methods[name], include_attributes=False) == ast.dump(
                ast.parse(textwrap.dedent(code)).body[0], include_attributes=False)
               for name, code in METHODS.items()):
            return source
        legacy = dict(METHODS)
        legacy['get_script'] = legacy['get_script'].replace(MARKER, legacy_marker)
        legacy['session'] = legacy['session'].replace(
            "        from threading import Event\n        detached = Event()\n        session.on('detached', lambda *args: detached.set())\n", '').replace(
            '        # Gunicorn stdin is EOF: waiting on it unloads hooks before Java.perform.\n'
            '        # Keep the script until the app exits or the device/session disconnects.\n'
            '        detached.wait()', '        sys.stdin.read()')
        if not all(ast.dump(methods[name], include_attributes=False) == ast.dump(
                ast.parse(textwrap.dedent(code)).body[0], include_attributes=False)
               for name, code in legacy.items()):
            raise RuntimeError('Managed MobSF patch was modified; source left unchanged')
    expected = ['device.resume(_FPID)', 'session.create_script(self.get_script())',
                "scripts.extend(self.get_scripts('default', self.defaults))"]
    if legacy_marker not in source and not all(token in source for token in expected):
        raise RuntimeError('Unsupported MobSF implementation; source left unchanged')
    lines = source.splitlines(keepends=True)
    for name in sorted(METHODS, key=lambda item: methods[item].lineno, reverse=True):
        node = methods[name]
        replacement = textwrap.indent(textwrap.dedent(METHODS[name]).strip() + '\n', '    ')
        lines[node.lineno - 1:node.end_lineno] = [replacement]
    result = ''.join(lines)
    compile(result, '<managed MobSF frida_core>', 'exec')
    return result


def main():
    target = pathlib.Path('mobsf/DynamicAnalyzer/views/android/frida_core.py')
    source = target.read_text(encoding='utf-8')
    result = patch(source)
    if result == source:
        print('unchanged')
        return
    backups = pathlib.Path('/home/mobsf/.MobSF/vulnchecker-root-hooks')
    backups.mkdir(exist_ok=True)
    backup = backups / ('frida_core-' + hashlib.sha256(source.encode()).hexdigest()[:16] + '.py')
    if not backup.exists():
        backup.write_text(source, encoding='utf-8')
    temporary = target.with_suffix('.py.vulnchecker-tmp')
    temporary.write_text(result, encoding='utf-8')
    temporary.replace(target)
    print('changed')


if __name__ == '__main__':
    main()
