"""Loopback reverse tunnel: Windows dials WSL, avoiding inbound firewall rules."""
import argparse
import asyncio
import json
import os
from pathlib import Path
import signal

IDENTITY = Path.home() / 'tools/vulnchecker/web-relay-process.json'


async def serve(token, proxy_port=18880, tunnel_port=18881):
    pending = asyncio.Queue(maxsize=128)

    async def proxy(reader, writer):
        finished = asyncio.Event()
        try:
            await pending.put((reader, writer, finished))
            await asyncio.wait_for(finished.wait(), timeout=600)
        finally:
            writer.close()

    async def copy(reader, writer, send_eof=True):
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
        if send_eof and writer.can_write_eof():
            writer.write_eof()
            await writer.drain()

    async def tunnel(reader, writer):
        item = None
        tasks = []
        try:
            key = await asyncio.wait_for(reader.readline(), timeout=5)
            if key.decode().strip() != token:
                return
            while True:
                item = await pending.get()
                if not item[1].is_closing():
                    break
                item[2].set()
            source, destination, finished = item
            writer.write(b'OK\n')
            await writer.drain()
            # WSL localhost forwarding may turn a TCP half-close into a full
            # close. HTTP requests are framed; keep this leg open for the reply.
            tasks = [asyncio.create_task(copy(source, writer, False)), asyncio.create_task(copy(reader, destination))]
            # EOF in one direction is a half-close, not permission to discard
            # the outstanding response (especially binary/CONNECT traffic).
            await asyncio.gather(*tasks)
        finally:
            for task in tasks:
                task.cancel()
            if tasks:
                await asyncio.gather(*tasks, return_exceptions=True)
            if item:
                item[2].set()
            writer.close()

    first = await asyncio.start_server(proxy, '127.0.0.1', proxy_port)
    second = await asyncio.start_server(tunnel, '127.0.0.1', tunnel_port)
    IDENTITY.write_text(json.dumps({'pid': os.getpid(), 'start': Path('/proc/self/stat').read_text().split()[21], 'script': str(Path(__file__).resolve())}))
    async with first, second:
        await asyncio.gather(first.serve_forever(), second.serve_forever())


def stop():
    if not IDENTITY.exists():
        return
    saved = json.loads(IDENTITY.read_text())
    proc = Path('/proc') / str(saved['pid'])
    if proc.exists():
        if proc.joinpath('stat').read_text().split()[21] != saved['start'] or saved['script'].encode() not in proc.joinpath('cmdline').read_bytes().split(b'\0'):
            raise RuntimeError('Relay process identity mismatch; not stopped')
        os.kill(saved['pid'], signal.SIGTERM)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--token')
    parser.add_argument('--stop', action='store_true')
    parser.add_argument('--proxy-port', type=int, default=18880)
    parser.add_argument('--tunnel-port', type=int, default=18881)
    parser.add_argument('--identity')
    args = parser.parse_args()
    if args.identity:
        IDENTITY = Path(args.identity)
    if args.stop:
        stop()
    elif args.token and len(args.token) == 32:
        asyncio.run(serve(args.token, args.proxy_port, args.tunnel_port))
    else:
        parser.error('token required')
