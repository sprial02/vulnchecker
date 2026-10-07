"""Stop only the exact managed Linux server instance, including orphaned WSL launches."""
import json
import os
from pathlib import Path
import signal

identity = Path.home() / "tools/vulnchecker/hexstrike-process.json"
if identity.exists():
    saved = json.loads(identity.read_text())
    proc = Path("/proc") / str(saved["pid"])
    if proc.exists():
        fields = proc.joinpath("cmdline").read_bytes().split(b"\0")
        start = proc.joinpath("stat").read_text().split()[21]
        if start == saved["start"] and saved["wrapper"].encode() in fields and saved["repository"].encode() in fields:
            os.kill(saved["pid"], signal.SIGTERM)
            print("Managed HexStrike stopped")
        else:
            raise RuntimeError("Process identity differs; no process was stopped")
