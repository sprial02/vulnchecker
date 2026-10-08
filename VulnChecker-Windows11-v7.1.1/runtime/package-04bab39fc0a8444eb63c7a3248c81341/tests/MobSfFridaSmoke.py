"""Offline regression checks for the managed MobSF spawn/inject lifecycle."""
import ast
import importlib.util
import logging
from pathlib import Path
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location(
    'managed_patch', Path(__file__).parents[1] / 'scripts/configure-mobsf-frida.py')
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)


class Lifecycle(unittest.TestCase):
    def make_target(self, package='com.gscaltex.energyplus', defaults=None, fail=False):
        events = []
        script = SimpleNamespace(exports_sync=None,
            on=lambda *args: None, unload=lambda: events.append('unload'))
        def load():
            events.append('load')
            if fail:
                raise RuntimeError('injection rejected')
        script.load = load
        def on_session(event, callback):
            # A live session must remain connected until the app detaches.
            from threading import Timer
            Timer(0.02, lambda: (events.append('app-detached'), callback())).start()
        session = SimpleNamespace(create_script=lambda code: script,
                                  on=on_session,
                                  detach=lambda: events.append('detach'))
        device = SimpleNamespace(spawn=lambda args: events.append('spawn') or 123,
            attach=lambda pid: events.append(('attach', pid)) or session,
            resume=lambda pid: events.append(('resume', pid)),
            kill=lambda pid: events.append(('kill', pid)),
            get_frontmost_application=lambda: SimpleNamespace(identifier='other.app', pid=999))
        scope = {'logger': logging.getLogger('test'), 'settings': SimpleNamespace(FRIDA_TIMEOUT=10),
            'frida': SimpleNamespace(get_device=lambda *args: device), 'get_device': lambda: 'device',
            'Environment': lambda: SimpleNamespace(run_frida_server=lambda: None),
            'time': SimpleNamespace(sleep=lambda seconds: events.append(('sleep', seconds))),
            'sys': SimpleNamespace(stdin=SimpleNamespace(read=lambda: events.append('wait')))}
        for code in patcher.METHODS.values():
            exec(code, scope)
        target_type = type('Target', (), {name: scope[name] for name in patcher.METHODS})
        target = target_type()
        target.package, target.defaults = package, defaults or []
        target.code, target.frida_log = '', 'log'
        target.clean_up = lambda: None
        target.write_log = lambda *args: None
        target.frida_response = lambda *args: None
        target.api_handler = lambda *args: None
        target.get_scripts = lambda kind, selected: [name.upper() for name in selected]
        target.get_auxiliary = lambda: []
        target.bridge_loader = SimpleNamespace(is_required_and_available=lambda: False)
        return target, events

    def test_energyplus_automatically_injects_before_resume(self):
        target, events = self.make_target()
        target.spawn()
        self.assertEqual(events, ['spawn'])
        target.session(None, None)
        self.assertEqual(events[:4], ['spawn', ('attach', 123), 'load', ('resume', 123)])
        self.assertNotIn(('sleep', 2), events)
        self.assertLess(events.index('app-detached'), events.index('unload'))

    def test_other_app_root_checkbox_uses_early_injection(self):
        target, events = self.make_target('customer.app', ['root_bypass', 'api_monitor'])
        code = target.get_script()
        self.assertLess(code.index('ROOT_BYPASS'), code.index('setTimeout'))
        self.assertGreater(code.index('API_MONITOR'), code.index('setTimeout'))
        self.assertEqual(code.count('ROOT_BYPASS'), 1)
        target.spawn()
        target.session(None, None)
        self.assertEqual(events[:4], ['spawn', ('attach', 123), 'load', ('resume', 123)])

    def test_failed_injection_cleans_up_only_its_own_spawn(self):
        target, events = self.make_target(fail=True)
        with self.assertLogs('test', level='ERROR'):
            target.spawn()
            target.session(None, None)
        self.assertIn(('kill', 123), events)
        self.assertNotIn(('resume', 123), events)
        self.assertIn('detach', events)

    def test_non_root_workflow_keeps_normal_spawn(self):
        target, events = self.make_target('customer.app', ['api_monitor'])
        target.spawn()
        self.assertEqual(events[:2], ['spawn', ('resume', 123)])
        target.session(None, None)
        self.assertIn(('attach', 123), events)
        self.assertNotIn(('attach', 999), events)

    def test_patch_is_idempotent_and_rejects_modified_managed_code(self):
        source = '''class Frida:
    def get_script(self, nolog=False):
        scripts.extend(self.get_scripts('default', self.defaults))
    def spawn(self):
        device.resume(_FPID)
    def session(self, pid, package):
        session.create_script(self.get_script())
'''
        updated = patcher.patch(source)
        ast.parse(updated)
        self.assertEqual(patcher.patch(updated), updated)
        with self.assertRaises(RuntimeError):
            patcher.patch(updated.replace('time.sleep(2)', 'time.sleep(9)'))
        with self.assertRaises(RuntimeError):
            patcher.patch(source.replace('pid, package', 'pid'))


if __name__ == '__main__':
    unittest.main()
