"""Write per-host Ansible transport/task outcomes without exposing task data."""
import json
import os
from pathlib import Path
from ansible.plugins.callback import CallbackBase

class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = 'aggregate'
    CALLBACK_NAME = 'infra_status'
    CALLBACK_NEEDS_ENABLED = True

    def __init__(self):
        super().__init__()
        self.workspaces = {}

    def v2_runner_on_ok(self, result):
        if result._task.action in ('ansible.builtin.tempfile', 'ansible.windows.win_tempfile'):
            path = result._result.get('path')
            if path:
                self.workspaces[result._host.get_name()] = path

    def v2_playbook_on_stats(self, stats):
        target = os.environ.get('INFRA_STATUS_PATH')
        if target:
            data = {host: stats.summarize(host) for host in stats.processed}
            for host, path in self.workspaces.items():
                if host in data:
                    data[host]['remote_workspace'] = path
            Path(target).write_text(json.dumps(data, indent=2), encoding='utf-8')
