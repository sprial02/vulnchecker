"""Stop OpenCode using only the dedicated workspace config, including children."""
import os
from pathlib import Path
import signal
import sys
import time

config = sys.argv[1].encode()
snapshot = {}
for folder in Path('/proc').iterdir():
    if not folder.name.isdigit():
        continue
    try:
        fields = folder.joinpath('stat').read_text().rsplit(') ', 1)[1].split()
        args = folder.joinpath('cmdline').read_bytes().split(b'\0')
        env = folder.joinpath('environ').read_bytes().split(b'\0')
        owned = bool(args and Path(os.fsdecode(args[0])).name == 'opencode'
                     and b'OPENCODE_CONFIG=' + config in env)
        snapshot[int(folder.name)] = (int(fields[1]), fields[19], owned)
    except (OSError, ValueError):
        continue
targets = [pid for pid, (_, _, owned) in snapshot.items() if owned]
for pid in targets:
    targets.extend(child for child, (parent, _, _) in snapshot.items()
                   if parent == pid and child not in targets and child != os.getpid())
for sig in (signal.SIGTERM, signal.SIGKILL):
    for pid in reversed(targets):
        try:
            start = Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()[19]
            if start == snapshot[pid][1]:
                os.kill(pid, sig)
        except (FileNotFoundError, ProcessLookupError):
            pass
    if sig == signal.SIGTERM and targets:
        time.sleep(1)
print(f'Managed OpenCode: stopped {len(targets)} processes')
