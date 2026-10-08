"""No network target: exercise slow synchronous MCP tools and concurrent liveness."""
import asyncio
from datetime import timedelta
import importlib.util
from pathlib import Path
import sys
import tempfile
import time
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]


async def check():
    with tempfile.TemporaryDirectory(prefix='vc-mcp-smoke-') as folder:
        upstream = Path(folder) / 'fixture.py'
        upstream.write_text('''from mcp.server.fastmcp import FastMCP
import time
mcp = FastMCP('fixture')
@mcp.tool()
def slow() -> str:
    time.sleep(65)
    return 'completed-once'
@mcp.tool()
def health() -> str:
    return 'alive'
mcp.run()
''')
        params = StdioServerParameters(command=sys.executable, args=[str(root / 'scripts/hexstrike-mcp-local.py'), '--upstream', str(upstream)])
        async with stdio_client(params) as (reader, writer):
            async with ClientSession(reader, writer, read_timeout_seconds=timedelta(seconds=90)) as client:
                await client.initialize()
                tools = await client.list_tools()
                assert {tool.name for tool in tools.tools} == {'health', 'slow'}
                events = []

                async def progress(value, total, message):
                    events.append(value)

                slow = asyncio.create_task(client.call_tool('slow', {}, progress_callback=progress))
                await asyncio.sleep(1)
                started = time.monotonic()
                health = await asyncio.wait_for(client.call_tool('health', {}), timeout=3)
                assert 'alive' in health.content[0].text
                assert time.monotonic() - started < 3
                result = await slow
                assert not result.isError and 'completed-once' in result.content[0].text
                assert len(events) >= 6, events
                print('PASS 65s MCP call, concurrent health, original schemas and progress notifications')


asyncio.run(check())
