"""Verify MCP command dispatch can read only the selected app's APK paths."""
import asyncio
import json
import re
import shlex
import sys
from pathlib import Path
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

async def check():
    package = sys.argv[4]
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+', package):
        raise ValueError('Invalid selected package')
    params = StdioServerParameters(command=sys.executable,
        args=[str(Path.home() / 'tools/vulnchecker/hexstrike-mcp-local.py'), '--upstream', sys.argv[1], '--server', sys.argv[2]])
    command = 'cd ' + shlex.quote(sys.argv[3]) + ' && ./adb-target shell pm path ' + shlex.quote(package)
    async with stdio_client(params) as (reader, writer):
        async with ClientSession(reader, writer) as client:
            await client.initialize()
            result = await client.call_tool('execute_command',
                {'command': command, 'use_cache': False})
            if result.isError:
                raise RuntimeError('MCP Android connection check failed')
            output = []
            def collect(value):
                if isinstance(value, dict):
                    for key, item in value.items():
                        if key == 'stdout' and isinstance(item, str): output.append(item)
                        elif isinstance(item, (dict, list)): collect(item)
                elif isinstance(value, list):
                    for item in value: collect(item)
            for block in result.content:
                if getattr(block, 'type', '') == 'text':
                    try: collect(json.loads(block.text))
                    except json.JSONDecodeError: pass
            paths = [line for text in output for line in text.splitlines() if line.startswith('package:')]
            if not paths:
                raise RuntimeError('HexStrike returned no installed APK paths for the selected app')
            print(json.dumps({'connected': True, 'package': package, 'apk_paths': len(paths)}))

asyncio.run(asyncio.wait_for(check(), timeout=60))
