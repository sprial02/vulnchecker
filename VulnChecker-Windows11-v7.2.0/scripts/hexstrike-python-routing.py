"""Route only upstream's binary-analysis Python calls into the optional venv."""
from pathlib import Path
import re
import shlex


def route_binary_python(command, repository):
    match = re.match(r'^python3\s+(?:/tmp/(?:angr_analysis|pwntools_exploit)\.py(?:\s|$)|-c\s+[\'"].*(?:import angr|from pwn import))', command)
    if not match:
        return command
    python = Path(repository) / '.venv-binary/bin/python'
    if not python.is_file():
        raise RuntimeError('Optional binary analysis is not installed. Run VulnChecker.ps1 -Action Launch -Tool BinaryAnalysisTools first.')
    return shlex.quote(str(python)) + command[len('python3'):]
