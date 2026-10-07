"""Keep synchronous upstream tools off the MCP event loop; preserve their schemas."""
import argparse
import asyncio
import runpy
import sys
from pathlib import Path
from mcp.server.fastmcp.tools import Tool

original_run = Tool.run


async def responsive_run(self, arguments, context=None, convert_result=False):
    if self.is_async:
        return await original_run(self, arguments, context, convert_result)
    # Upstream uses blocking requests/commands. Running them on the event loop
    # prevents even ping/health/cancellation from being processed during a scan.
    task = asyncio.create_task(asyncio.to_thread(
        lambda: asyncio.run(original_run(self, arguments, context, convert_result))))
    elapsed = 0
    while True:
        done, _ = await asyncio.wait({task}, timeout=10)
        if done:
            return task.result()
        elapsed += 10
        if context is not None:
            await context.report_progress(elapsed, message=f"{self.name}: running ({elapsed}s); do not submit a duplicate")


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--upstream', required=True)
    args, remaining = parser.parse_known_args()
    upstream = Path(args.upstream).resolve(strict=True)
    Tool.run = responsive_run
    sys.path.insert(0, str(upstream.parent))
    sys.argv = [str(upstream)] + remaining
    runpy.run_path(str(upstream), run_name='__main__')


if __name__ == '__main__':
    main()
