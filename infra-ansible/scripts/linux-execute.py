"""Run each original check in a separate process, preserving its output and rc."""
import argparse
import json
from pathlib import Path
import subprocess
import os
import signal

def main():
    p = argparse.ArgumentParser()
    p.add_argument('root', type=Path)
    p.add_argument('platform', choices=['Debian', 'RedHat'])
    p.add_argument('timeout', type=int)
    a = p.parse_args()
    os.umask(0o077)
    folder = a.root / '01.Unix서버' / a.platform
    logs = a.root / 'execution-logs'
    logs.mkdir()
    records = []
    for n in range(1, 68):
        item = f'U-{n:02d}'
        script = folder / f'U{n:02d}_check.sh'
        with (logs / f'{item}.log').open('wb') as out:
            try:
                process = subprocess.Popen(['/bin/bash', str(script)], cwd=folder,
                                        stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT,
                                        start_new_session=True, env={**os.environ, 'LC_ALL': 'C.UTF-8'})
                rc = process.wait(timeout=a.timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                rc = 124
            except OSError as e:
                out.write(str(e).encode())
                rc = 127
        records.append({'item_id': item, 'rc': rc})
        (a.root / 'execution.json').write_text(json.dumps(records), encoding='utf-8')

if __name__ == '__main__':
    main()
