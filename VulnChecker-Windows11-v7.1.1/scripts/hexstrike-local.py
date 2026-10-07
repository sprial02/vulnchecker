"""Launch the pinned upstream server on loopback without editing upstream files."""
import os
import argparse
import runpy
import sys
import re
import shutil
import json
from pathlib import Path
from flask import Flask

original_run = Flask.run


def loopback_run(self, *args, **kwargs):
    kwargs["host"] = "127.0.0.1"
    kwargs["debug"] = False
    kwargs["use_reloader"] = False
    return original_run(self, *args, **kwargs)


Flask.run = loopback_run
parser = argparse.ArgumentParser(add_help=False)
parser.add_argument('--repository', required=True)
parser.add_argument('--port', type=int, default=8888)
args, remaining = parser.parse_known_args()
sys.argv = ['hexstrike_server.py'] + remaining
os.environ["PATH"] = os.path.expanduser('~/tools/mobile-venv/bin:') + os.environ.get("PATH", "")
os.chdir(args.repository)
identity = Path.home() / "tools/vulnchecker/hexstrike-process.json"
identity.parent.mkdir(parents=True, exist_ok=True)
identity.write_text(json.dumps({"pid": os.getpid(), "start": Path("/proc/self/stat").read_text().split()[21],
                                "wrapper": str(Path(__file__).resolve()), "repository": args.repository}), encoding="utf-8")
# Upstream /health spawns >100 shells to run only `which`. On Windows WSL
# inherited PATH this can exceed client timeouts. Resolve these lookup-only
# commands locally; all analysis commands still use the upstream executor.
module = runpy.run_path("hexstrike_server.py", run_name="vulnchecker_hexstrike")
app = module["app"]
health = app.view_functions.get("health_check")
if health:
    globals_ = health.__globals__
    original_execute = globals_["execute_command"]

    def execute_with_fast_lookup(command, *positional, **keywords):
        match = re.fullmatch(r"which ([a-zA-Z0-9_.+-]+)", command)
        if match:
            path = shutil.which(match[1])
            return {"success": bool(path), "stdout": (path + "\n") if path else "",
                    "stderr": "", "return_code": 0 if path else 1,
                    "execution_time": 0, "cached": False}
        return original_execute(command, *positional, **keywords)

    globals_["execute_command"] = execute_with_fast_lookup
    globals_["API_PORT"] = args.port
app.run(port=args.port)
