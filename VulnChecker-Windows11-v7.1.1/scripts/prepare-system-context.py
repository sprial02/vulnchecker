"""Managed system rules; retain unrelated project settings and instructions."""
import base64
import json
from pathlib import Path
import shutil
import sys
import time

spec = json.loads(base64.b64decode(sys.argv[1]))
work = Path(spec['work'])
work.mkdir(parents=True, exist_ok=True)
path = work / 'opencode.json'
config = json.loads(path.read_text(encoding='utf-8-sig')) if path.exists() else {}
permissions = config.get('permission', 'ask')
if isinstance(permissions, str):
    permissions = {'*': permissions}
permissions.update({'bash': 'deny', 'webfetch': 'deny'})
config['permission'] = permissions
rule = str(work / 'VULNCHECKER_WORKFLOW.md')
instructions = config.setdefault('instructions', [])
if rule not in instructions:
    instructions.append(rule)
text = '''# VulnChecker system workflow
Use HexStrike MCP for target-facing commands. Built-in bash/webfetch are disabled.
First call hexstrike_server_health and a harmless execute_command printf probe.
Do not replace an unavailable MCP with local reconnaissance or other agents.
Run one long scan at a time, in bounded batches. Wait for the result.
On timeout, execution state is UNKNOWN: never replay the scan automatically.
Report tool name/time and stop target work. Ask the user to run the UI MCP check.
If HTTP and a fresh MCP command work, reconnect hexstrike in OpenCode's /mcp menu.
Restart HexStrike only if HTTP fails and no scan is active. Check previous results
before resuming. Read target.json and follow the user's target and scope.
'''
if spec.get('web'):
    text += f'''
All target HTTP/HTTPS requests must use Burp. Use HexStrike execute_command with:
  python3 {spec['helper']} TOOL ARGS...
Supported: curl, ffuf, gobuster, nikto, sqlmap, nuclei, httpx, katana, whatweb.
Do not use specialized MCP web tools unless their Burp proxy is explicitly set.
Do not use raw absolute tool paths or direct fallback when the proxy fails.
For an unsupported tool, stop and report missing proxy support.
Nmap TCP/UDP discovery is not HTTP and does not appear in Burp.
Identify the actual HTTP/HTTPS service before web tests; port numbers are not proof.
Manual testing: Burp -> Proxy -> Intercept -> Open browser.
Keep Intercept off for unattended testing; HTTP history still records traffic.
'''
Path(rule).write_text(text, encoding='utf-8')
payload = json.dumps(config, indent=2) + '\n'
if path.exists() and path.read_text(encoding='utf-8-sig') != payload:
    shutil.copy2(path, path.with_name('opencode.json.backup-' + str(time.time_ns())))
temp = path.with_suffix('.tmp')
temp.write_text(payload)
temp.replace(path)
print(json.dumps({'prepared': True, 'web': bool(spec.get('web'))}))
