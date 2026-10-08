"""Read-only MCP initialization/tool discovery. No tool is executed."""
import asyncio
import json
import sys
from pathlib import Path
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

async def check():
    params = StdioServerParameters(command=sys.executable, args=[str(Path(__file__).with_name('hexstrike-mcp-local.py')), '--upstream', sys.argv[1], "--server", sys.argv[2]])
    async with stdio_client(params) as (reader, writer):
        async with ClientSession(reader, writer) as client:
            await client.initialize()
            result = await client.list_tools()
            if not result.tools:
                raise RuntimeError("MCP returned no tools")
            # Exercise the complete MCP -> HTTP -> executor -> result path.
            probe = await client.call_tool('execute_command', {'command': "printf 'VULNCHECKER_MCP_OK'", 'use_cache': False})
            if probe.isError or not any('VULNCHECKER_MCP_OK' in getattr(block, 'text', '') for block in probe.content):
                raise RuntimeError('MCP command round trip failed')
            print(json.dumps({"connected": True, "tools": len(result.tools), "execution": True}))

asyncio.run(asyncio.wait_for(check(), timeout=60))
