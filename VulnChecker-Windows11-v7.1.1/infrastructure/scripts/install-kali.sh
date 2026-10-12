#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
if ! python3 -m venv .venv; then
    echo 'python3-venv가 필요합니다: sudo apt-get install python3-venv' >&2
    exit 1
fi
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/ansible-galaxy collection install -r collections.yml -p collections
.venv/bin/python scripts/prepare_source.py
.venv/bin/python -m pip freeze > installed-requirements.txt
.venv/bin/ansible-galaxy collection list > installed-collections.txt
.venv/bin/ansible-playbook playbooks/check.yml --syntax-check -i inventory/hosts.example.yml
echo '설치 완료. inventory/hosts.yml 및 Vault를 설정하세요.'
