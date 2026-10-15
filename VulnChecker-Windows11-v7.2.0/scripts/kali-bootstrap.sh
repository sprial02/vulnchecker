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
[[ "$mode" =~ ^(web|mobile|full|binary)$ ]] || exit 2
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || exit 2
[[ "$oc_version" =~ ^(latest|[0-9]+\.[0-9]+\.[0-9]+([-+][a-zA-Z0-9.-]+)?)$ ]] || exit 2
[[ "$tool_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$tool_user" != root ]] || exit 2
[[ "$repo" == /* ]] || exit 2
export DEBIAN_FRONTEND=noninteractive
apt-get -o Acquire::Retries=3 update
packages=(ca-certificates curl)
if [[ "$reuse_python" == '-' ]]; then
  packages+=(git python3)
fi
if [[ ! -f "$repo/hexstrike_server.py" || ! -f "$repo/hexstrike_mcp.py" || ! -f "$repo/requirements.txt" ]]; then packages+=(git); fi
if [[ "$mode" != web && "$mode" != binary && "$mobile_ready" != yes ]]; then packages+=(python3); fi
if [[ "$reuse_oc" == '-' ]]; then packages+=(nodejs npm); fi
# Profile tools come from the shared catalog selected by the Windows installer.
for package in "$@"; do
  [[ "$package" =~ ^[a-z0-9][a-z0-9.+-]*$ ]] || exit 2
  packages+=("$package")
done
missing_packages=()
declare -A seen=()
for package in "${packages[@]}"; do
  [[ -z "${seen[$package]:-}" ]] || continue
  seen[$package]=1
  if [[ "$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)" != installed ]]; then
    missing_packages+=("$package")
  fi
done
failed_packages=()
if ((${#missing_packages[@]})); then
  echo "KALI PACKAGES REQUESTED: ${missing_packages[*]}"
  # Do not let one unavailable extra package prevent all other tools installing.
  if ! apt-get -o Acquire::Retries=3 install -y "${missing_packages[@]}"; then
    for package in "${missing_packages[@]}"; do
      if ! apt-get -o Acquire::Retries=3 install -y "$package"; then
        failed_packages+=("$package")
        echo "KALI PACKAGE FAILED: $package" >&2
      fi
    done
  fi
fi
if ! id "$tool_user" >/dev/null 2>&1; then
  [[ "$tool_user" == vulnchecker ]] || { echo 'Existing runtime user is missing' >&2; exit 3; }
  useradd --create-home --shell /bin/bash "$tool_user"
fi
base=$(getent passwd "$tool_user" | cut -d: -f6)
runuser -u "$tool_user" -- mkdir -p "$base/tools" "$base/work/vulnchecker"
helper="$base/tools/vulnchecker/ensure-hexstrike-python.py"
if [[ "$reuse_python" == '-' || "$mode" == binary || ( "$mode" != web && "$mode" != binary && "$mobile_ready" != yes ) ]]; then
  runuser -u "$tool_user" -- python3 -c 'import base64,pathlib,sys; folder=pathlib.Path(sys.argv[1]); folder.mkdir(parents=True,exist_ok=True); (folder/"ensure-hexstrike-python.py").write_bytes(base64.b64decode(sys.argv[2])); (folder/"hexstrike-python.json").write_bytes(base64.b64decode(sys.argv[3]))' "$base/tools/vulnchecker" '__VC_PYTHON_HELPER_BASE64__' '__VC_PYTHON_POLICY_BASE64__'
fi
if [[ -d "$repo/.git" ]]; then
  for entry in hexstrike_server.py hexstrike_mcp.py requirements.txt; do
    if [[ ! -f "$repo/$entry" ]]; then
      runuser -u "$tool_user" -- git -C "$repo" restore --source=HEAD -- "$entry"
    fi
  done
fi
if [[ "$reuse_python" != '-' ]]; then
  runuser -u "$tool_user" -- "$reuse_python" -c 'import flask, requests, mcp'
  echo "Reusing HexStrike at $repo; source commit unchanged"
else
  if [[ ! -d "$repo/.git" ]]; then
    runuser -u "$tool_user" -- git clone https://github.com/0x4m4/hexstrike-ai.git "$repo"
    runuser -u "$tool_user" -- git -C "$repo" checkout --detach "$commit"
  fi
  # Core never installs upstream's optional angr/pwntools requirements.
  runuser -u "$tool_user" -- python3 "$helper" --repository "$repo" --component core
fi
if [[ "$mode" == binary ]]; then
  runuser -u "$tool_user" -- python3 "$helper" --repository "$repo" --component binary
fi
if [[ "$mode" != web && "$mode" != binary && "$mobile_ready" != yes ]]; then
  runuser -u "$tool_user" -- python3 "$helper" --repository "$base/tools/mobile-venv" --component mobile
fi
if [[ "$reuse_oc" == skip ]]; then
  echo 'OpenCode is not required for this launch'
elif [[ "$reuse_oc" != '-' ]]; then
  runuser -u "$tool_user" -- "$reuse_oc" --version
else
  runuser -u "$tool_user" -- npm install --prefix "$base/tools/opencode" "opencode-ai@$oc_version"
  runuser -u "$tool_user" -- "$base/tools/opencode/node_modules/.bin/opencode" --version
fi
echo "Kali tool preparation complete. HexStrike tool coverage depends on the installed packages."
if ((${#failed_packages[@]})); then
  echo "KALI PACKAGES FAILED: ${failed_packages[*]}. Re-run automatic installation after checking apt/network logs." >&2
  exit 4
fi
