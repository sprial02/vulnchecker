"""Read-only MCP initialization/tool discovery. No tool is executed."""
import asyncio
import json
import sys
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

async def check():
    params = StdioServerParameters(command=sys.executable, args=[sys.argv[1], "--server", sys.argv[2]])
    async with stdio_client(params) as (reader, writer):
        async with ClientSession(reader, writer) as client:
            await client.initialize()
            result = await client.list_tools()
            if not result.tools:
                raise RuntimeError("MCP returned no tools")
            print(json.dumps({"connected": True, "tools": len(result.tools)}))

asyncio.run(asyncio.wait_for(check(), timeout=60))
