"""Write per-host Ansible transport/task outcomes without exposing task data."""
import json
import os
from pathlib import Path
import sys
from datetime import datetime, timezone
from ansible.plugins.callback import CallbackBase
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from failure_reasons import describe

class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = 'aggregate'
    CALLBACK_NAME = 'infra_status'
    CALLBACK_NEEDS_ENABLED = True

    def __init__(self):
        super().__init__()
        self.workspaces = {}
        self.outcomes = {}

    def save(self):
        target = os.environ.get('INFRA_STATUS_PATH')
        if target:
            path = Path(target)
            temporary = path.with_suffix('.tmp')
            temporary.write_text(json.dumps(self.outcomes, ensure_ascii=False, indent=2), encoding='utf-8')
            temporary.replace(path)

    def failure(self, result, unreachable=False):
        name = result._host.get_name()
        data = result._result
        classification = '\n'.join(str(data.get(k, ''))[:16384] for k in ('msg', 'module_stderr', 'module_stdout'))
        reason = describe(classification, result._task.get_name(), unreachable,
                          bool(data.get('_ansible_no_log') or result._task.no_log))
        variables = result._host.get_vars()
        connection = variables.get('ansible_connection', '')
        if connection in ('winrm', 'psrp'):
            scheme = variables.get('ansible_winrm_scheme' if connection == 'winrm' else 'ansible_psrp_protocol', 'https')
            host = str(variables.get('ansible_host', name))
            if ':' in host:host = '[' + host + ']'
            reason['endpoint'] = str(scheme) + '://' + host + ':' + str(variables.get('ansible_port', 5986)) + '/wsman'
            reason['action'] += ' · 요청 주소: ' + reason['endpoint']
        elif connection == 'ssh':
            host = str(variables.get('ansible_host', name))
            if ':' in host:host = '[' + host + ']'
            reason['endpoint'] = 'ssh://' + str(variables.get('ansible_user', '')) + '@' + host + ':' + str(variables.get('ansible_port', 22))
            reason['action'] += ' · 요청 주소: ' + reason['endpoint']
        reason['observed_at'] = datetime.now(timezone.utc).isoformat()
        state = self.outcomes.setdefault(name, {})
        state.setdefault('diagnostics', []).append(reason)
        key = 'unreachable' if unreachable else 'failures'
        state[key] = state.get(key, 0) + 1
        self.save()
        self._display.warning(name + ': ' + reason['reason'] + ' / ' + reason['task'] + ' / ' + reason['action'])

    def v2_runner_on_failed(self, result, ignore_errors=False):
        self.failure(result)

    def v2_runner_on_unreachable(self, result):
        self.failure(result, unreachable=True)

    def v2_runner_on_ok(self, result):
        if result._task.get_name().endswith('Wait for bounded check completion') and (result._result.get('msg') or result._result.get('rc', 0) != 0):
            self.failure(result)
        if result._task.action in ('ansible.builtin.tempfile', 'ansible.windows.win_tempfile'):
            path = result._result.get('path')
            if path:
                self.workspaces[result._host.get_name()] = path
        name = result._host.get_name()
        self.outcomes.setdefault(name, {})['last_completed_task'] = result._task.get_name()
        self.save()

    def v2_playbook_on_stats(self, stats):
        target = os.environ.get('INFRA_STATUS_PATH')
        if target:
            data = {host: stats.summarize(host) for host in stats.processed}
            for host, state in self.outcomes.items():
                data.setdefault(host, {}).update({k: v for k, v in state.items() if k not in ('failures', 'unreachable')})
            for host, path in self.workspaces.items():
                if host in data:
                    data[host]['remote_workspace'] = path
            self.outcomes = data
            self.save()
