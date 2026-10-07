#!/usr/bin/env bash
set -Eeuo pipefail
mode=${1:?profile required}
commit=${2:?commit required}
oc_version=${3:?OpenCode version required}
tool_user=${4:?runtime user required}
repo=${5:?HexStrike path required}
reuse_python=${6:?Python reuse selection required}
reuse_oc=${7:?OpenCode reuse selection required}
mobile_ready=${8:?mobile readiness required}
shift 8
[[ "$mode" =~ ^(web|mobile|full)$ ]] || exit 2
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || exit 2
[[ "$oc_version" =~ ^(latest|[0-9]+\.[0-9]+\.[0-9]+([-+][a-zA-Z0-9.-]+)?)$ ]] || exit 2
[[ "$tool_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$tool_user" != root ]] || exit 2
[[ "$repo" == /* ]] || exit 2
export DEBIAN_FRONTEND=noninteractive
apt-get update
packages=(ca-certificates curl git python3 python3-venv python3-pip python3-dev build-essential libffi-dev libssl-dev nodejs npm)
if [[ "$mode" != mobile ]]; then
  packages+=(nmap ffuf sqlmap nikto nuclei gobuster feroxbuster)
fi
if [[ "$mode" != web ]]; then
  packages+=(jadx apktool)
fi
for package in "$@"; do
  [[ "$package" =~ ^[a-z0-9][a-z0-9.+-]*$ ]] || exit 2
  packages+=("$package")
done
missing_packages=()
for package in "${packages[@]}"; do
  if [[ "$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)" != installed ]]; then
    missing_packages+=("$package")
  fi
done
if ((${#missing_packages[@]})); then apt-get install -y "${missing_packages[@]}"; fi
if ! id "$tool_user" >/dev/null 2>&1; then
  [[ "$tool_user" == vulnchecker ]] || { echo 'Existing runtime user is missing' >&2; exit 3; }
  useradd --create-home --shell /bin/bash "$tool_user"
fi
base=$(getent passwd "$tool_user" | cut -d: -f6)
runuser -u "$tool_user" -- mkdir -p "$base/tools" "$base/work/vulnchecker"
if [[ "$reuse_python" != '-' ]]; then
  runuser -u "$tool_user" -- "$reuse_python" -c 'import flask, requests, mcp'
  echo "Reusing HexStrike at $repo; source commit unchanged"
else
  if [[ ! -d "$repo/.git" ]]; then
    runuser -u "$tool_user" -- git clone https://github.com/0x4m4/hexstrike-ai.git "$repo"
    runuser -u "$tool_user" -- git -C "$repo" checkout --detach "$commit"
  fi
  # Repair dependencies without changing an existing repository's commit.
  runuser -u "$tool_user" -- python3 -m venv "$repo/.venv"
  runuser -u "$tool_user" -- "$repo/.venv/bin/python" -m pip install -r "$repo/requirements.txt"
  runuser -u "$tool_user" -- "$repo/.venv/bin/python" -m pip check
fi
if [[ "$mode" != web && "$mobile_ready" != yes ]]; then
  runuser -u "$tool_user" -- python3 -m venv "$base/tools/mobile-venv"
  runuser -u "$tool_user" -- "$base/tools/mobile-venv/bin/python" -m pip install frida-tools objection
  runuser -u "$tool_user" -- "$base/tools/mobile-venv/bin/python" -m pip check
fi
if [[ "$reuse_oc" != '-' ]]; then
  runuser -u "$tool_user" -- "$reuse_oc" --version
else
  runuser -u "$tool_user" -- npm install --prefix "$base/tools/opencode" "opencode-ai@$oc_version"
  runuser -u "$tool_user" -- "$base/tools/opencode/node_modules/.bin/opencode" --version
fi
echo "Kali tool preparation complete. HexStrike tool coverage depends on the installed packages."
