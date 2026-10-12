#!/usr/bin/env bash
set -euo pipefail
umask 077
source_root="$(cd "$(dirname "$0")/.." && pwd)"
destination="$HOME/.local/share/vulnchecker-infra"
action="${1:-install}"
shift || true
mkdir -p "$destination/inventory/group_vars/all"
chmod 700 "$destination"
if [[ "$source_root" != "$destination" ]]; then
    for directory in scripts playbooks plugins tests; do
        cp -r "$source_root/$directory" "$destination/"
    done
    for file in ansible.cfg requirements.txt collections.yml README.ko.md VALIDATION.ko.md; do
        cp "$source_root/$file" "$destination/"
    done
    cp "$source_root/inventory/hosts.example.yml" "$destination/inventory/"
    if [[ ! -f "$destination/inventory/group_vars/all/settings.yml" ]]; then
        cp "$source_root/inventory/group_vars/all/settings.yml" "$destination/inventory/group_vars/all/"
    fi
fi
cd "$destination"
case "$action" in
    install) bash scripts/install-kali.sh ;;
    preflight) .venv/bin/python scripts/run.py --preflight "$@" ;;
    run) .venv/bin/python scripts/run.py "$@" ;;
    *) echo 'Use install, preflight or run' >&2; exit 2 ;;
esac
