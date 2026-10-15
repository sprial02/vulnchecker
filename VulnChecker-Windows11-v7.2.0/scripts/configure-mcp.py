"""Merge only the managed MCP entry; retain provider and unrelated MCP settings."""
import json
import pathlib
import shutil
import sys
import time

path = pathlib.Path(sys.argv[1])
entry = json.load(sys.stdin)
config = json.loads(path.read_text(encoding="utf-8-sig")) if path.exists() else {}
if not isinstance(config, dict) or not isinstance(config.get("mcp", {}), dict):
    raise ValueError("Invalid OpenCode JSON configuration; original was preserved")
config.setdefault("mcp", {})["hexstrike"] = entry
config.setdefault("$schema", "https://opencode.ai/config.json")
config.setdefault("permission", "ask")
payload = json.dumps(config, ensure_ascii=False, indent=2) + "\n"
if path.exists() and path.read_text(encoding="utf-8-sig") == payload:
    sys.exit(0)
if path.exists():
    shutil.copy2(path, path.with_name(path.name + ".backup-" + str(time.time_ns())))
temp = path.with_name(path.name + ".tmp")
temp.write_text(payload, encoding="utf-8")
temp.replace(path)
