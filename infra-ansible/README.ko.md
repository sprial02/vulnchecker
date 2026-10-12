# 서버 인프라 보안 설정 점검 (독립 추가 모듈)

기존 VulnChecker 코드·GUI·설치 목록을 변경하지 않는 별도 실행기입니다. Kali에서 Ansible Core로 Linux에는 SSH, Windows Server에는 WinRM 또는 PSRP로 접속하여 KISA 원본 점검 스크립트를 전달·실행하고 결과를 회수합니다. 자동 보안 설정 조치는 하지 않습니다.

## 1. 설치

별도 배포 ZIP은 `Build-Package.ps1`로 생성합니다. 실제 자격 증명과 결과는 제외합니다. 검증 내역은 `VALIDATION.ko.md`를 참고하세요.

Windows PowerShell에서 이 폴더로 이동하고 실행합니다.

```powershell
.\Start-Infrastructure.ps1 -Action install
```

기본 배포판은 `kali-linux`이며 `-Distribution`으로 변경할 수 있습니다. Kali 내부의 `~/.local/share/vulnchecker-infra`에 전용 가상환경·컬렉션을 설치합니다. 기존 HexStrike/OpenCode의 Python 환경은 사용하지 않습니다. `python3-venv`가 없으면 Kali에서 `sudo apt-get install python3-venv`를 실행하세요. 프로젝트는 Ansible 설정 파일 자동 로딩과 권한 보호를 위해 Windows 마운트 대신 Kali 홈에서 실행합니다.

Kali 단독 환경은 폴더 전체를 복사한 뒤 다음과 같이 실행합니다.

```bash
bash scripts/install-kali.sh
```

Ansible Core 2.19 계열, ansible.windows 3.x, pywinrm, pypsrp를 설치하며 실제 버전은 `installed-requirements.txt`, `installed-collections.txt`에 기록합니다. Python 3.11 이상이 필요합니다. 재설치는 같은 계열 내 버전을 갱신할 수 있으므로 운영 환경 복제 시 설치 기록으로 버전을 고정하세요.

KISA 원본: https://github.com/rebugui/KISA-CIIP-2026

검토 고정 커밋: `d081fc1e75a2be207eb2e57632e5e5f398e273b1`. `vendor`에 별도 다운로드하며 기존 소스가 수정되었거나 커밋이 다르면 덮어쓰지 않고 중단합니다. 원본은 AGPL-3.0이며 재배포 시 원본 라이선스 조건을 확인하세요. 원본 내용은 수정하지 않고 전송 시 셸 파일의 줄바꿈과 PowerShell UTF-8 BOM만 정규화합니다.

## 2. 인벤토리와 비밀번호

```bash
cd ~/.local/share/vulnchecker-infra
cp inventory/hosts.example.yml inventory/hosts.yml
chmod 600 inventory/hosts.yml
.venv/bin/ansible-vault create inventory/group_vars/all/vault.yml
```

Vault 편집기에 아래 키와 실제 값을 입력합니다. 비밀번호를 명령줄이나 평문 인벤토리에 기록하지 마세요.

```yaml
vault_windows_password: '실제 Windows 비밀번호'
# 필요할 경우 호스트/그룹 vars에서 연결하여 사용
vault_linux_become_password: '실제 sudo 비밀번호'
```

Linux는 `linux`, Windows는 `windows` 그룹에만 넣고 각 서버를 고유한 영문 별칭으로 정의합니다. Linux `kisa_platform`은 `Debian` 또는 `RedHat`을 직접 지정합니다. Ubuntu는 Debian 계열, RHEL/Rocky/Alma 계열은 RedHat 기준 적용 가능성을 먼저 확인하세요. AIX/HP-UX/Solaris는 이번 모듈 지원 범위에서 제외합니다.

SSH 대상에는 Python 3, bash, tar, KISA가 사용하는 OS 명령이 필요합니다. 점검 전용 계정에 충분한 sudo 권한을 부여하고 `ansible_become: true`를 사용합니다. sudo 비밀번호가 필요하면 `--ask-become-pass` 또는 암호화 변수 `ansible_become_password: '{{ vault_linux_become_password }}'`를 사용하세요. SSH 키는 Kali에 저장하고 `chmod 600`을 적용합니다. 최초 접속은 `ssh audit@서버주소`로 호스트 키 지문을 확인한 뒤 known_hosts에 등록하세요. 호스트 키 검증을 끄지 않습니다.

Windows Server 2019 이상과 PowerShell 5.1, 원격 관리자 토큰이 필요합니다. 예제는 HTTPS 5986 및 NTLM 인증이며 인증서의 이름과 CA를 검증합니다. 내부 CA가 있으면 전용 venv의 requests 인증서 번들 환경변수 `REQUESTS_CA_BUNDLE=/경로/ca.pem`을 설정하세요. WinRM과 PSRP 설정은 `hosts.example.yml`에 각각 포함되어 있습니다. 계정은 도메인 계정 `DOMAIN\user` 또는 로컬 계정 `SERVER\user`처럼 명시합니다.

WinRM HTTP 5985만 제공하는 승인된 환경에서는 해당 그룹을 아래처럼 변경할 수 있습니다. 인증서 검증 무시나 Basic 인증을 사용할 필요가 없습니다.

```yaml
# WinRM 그룹
ansible_port: 5985
ansible_winrm_scheme: http
ansible_winrm_transport: ntlm
ansible_winrm_message_encryption: always
# PSRP 그룹에는 위 WinRM 변수 대신 아래를 설정
# ansible_port: 5985
# ansible_psrp_protocol: http
# ansible_psrp_auth: ntlm
# ansible_psrp_message_encryption: always
```

원격 WinRM이 꺼져 있으면 대상 서버 관리자가 승인된 GPO/HTTPS 인증서와 관리망 방화벽 허용 규칙으로 설정해야 합니다. 로컬 계정의 UAC 토큰 필터링, 원격 관리 권한, 방화벽 문제는 사전 점검에서 확인합니다. 이 실행기는 서버의 WinRM/방화벽/UAC 설정을 변경하지 않습니다.

## 3. 접속 사전 확인과 실행

Kali에서:

```bash
cd ~/.local/share/vulnchecker-infra
.venv/bin/python scripts/run.py --preflight --ask-vault-pass
.venv/bin/python scripts/run.py --ask-vault-pass
# 특정 서버만
.venv/bin/python scripts/run.py --hosts linux-debian-01,windows-winrm-01 --ask-vault-pass
```

Windows에서 같은 실행을 시작할 수도 있습니다.

```powershell
.\Start-Infrastructure.ps1 -Action preflight --ask-vault-pass
.\Start-Infrastructure.ps1 -Action run --hosts windows-winrm-01 --ask-vault-pass
```

Vault 비밀번호는 실행 시 입력합니다. 파일 기반 자동화를 원하면 Kali에서 권한 600으로 Vault 비밀번호 파일을 만들고 `ANSIBLE_VAULT_PASSWORD_FILE` 환경변수에 경로를 지정하세요. inventory 조회와 playbook 실행에서 각각 Vault 암호를 요청할 수 있습니다. `--ask-pass`는 SSH 로그인 암호, `--ask-become-pass`는 sudo 암호입니다. Windows 비밀번호는 Vault를 사용하세요.

Linux는 U-01~U-67, Windows는 W-01~W-64를 개별 자식 프로세스로 실행합니다. 원본 일괄 실행기가 개별 오류를 정상 종료로 처리할 수 있어 전용 wrapper를 사용합니다. 각 항목의 종료 코드·로그·JSON 존재 여부·판정 필드를 검증하며 원본 점검 로직은 그대로 사용합니다. 기본 항목 시간 제한은 90초, 서버 실행 시간 제한은 7200초입니다. `inventory/group_vars/all/settings.yml`에서 조정하세요. 서버당 일괄 시간 제한은 항목 수 × 항목 시간 제한보다 충분히 길어야 합니다.

실제 Kali 서버 검증에서 U-25의 전체 파일 권한 검색이 90초를 초과하여 해당 호스트에만 `kisa_item_timeout: 300`을 적용했습니다. 큰 파일 시스템에서는 검색 시간이 늘어날 수 있습니다. 시간 초과는 정상 판정으로 처리하지 않습니다.

고정 커밋의 Debian U-64에는 `set -euo pipefail` 상태에서 `grep -i security`가 일치 항목 없이 종료하면 전체 점검이 중단되는 문제가 확인됐습니다. 보안 업데이트 문자열이 없는 환경에서 종료 코드 1과 JSON 누락이 발생할 수 있습니다. 원본은 보존하며 실행기는 이를 실패로 기록합니다. 이 항목의 패치 정책과 적용 이력은 수동으로 확인하고, 원본 수정 또는 새 커밋 적용 시 판단 기준과 결과를 다시 검증하세요.

## 4. 실패 서버만 재실행

실행마다 `runs/<UTC시각-ID>/summary.json`과 대상별 `evidence.tar.gz` 또는 `evidence.zip`을 생성합니다. 원본 JSON/TXT와 실행 로그는 증적 압축에 포함됩니다. 요약에는 각 서버의 판정 개수와 실패 사유를 기록합니다.

```bash
# 이전 실행 폴더를 지정: 실행 실패 서버만 다시 실행
.venv/bin/python scripts/run.py --retry-from runs/이전실행폴더 --ask-vault-pass
# 실패 서버 중 특정 서버만 선택
.venv/bin/python scripts/run.py --retry-from runs/이전실행폴더 --hosts windows-winrm-01 --ask-vault-pass
# 설정 조치 후 취약 항목이 발견된 서버만 다시 점검
.venv/bin/python scripts/run.py --retry-from runs/이전실행폴더 --retry-kind vulnerable --ask-vault-pass
# 수동 확인 판정 서버만
.venv/bin/python scripts/run.py --retry-from runs/이전실행폴더 --retry-kind manual --ask-vault-pass
```

`failed_hosts.txt`는 연결 불가, 권한/태스크 오류, 비정상 종료, 시간 초과, 누락/깨진 JSON 또는 잘못된 판정이 있는 서버 목록입니다. `vulnerable_hosts.txt`는 `VULNERABLE` 판정 서버, `manual_hosts.txt`는 `MANUAL` 판정 서버입니다. 취약점 발견과 실행 실패를 구분하며 둘 다 해당할 수 있습니다. 수동 판정에는 원본 스크립트 내부에서 처리한 예외가 포함될 수 있으므로 원본 증적을 검토하세요. 재실행은 선택한 서버의 전체 항목을 다시 점검하며 새 결과 폴더를 만듭니다. 과거 결과를 덮어쓰지 않습니다. 재실행 대상이 없으면 원격 접속 없이 종료합니다.

실행 실패가 있으면 실행기 종료 코드는 1, 모두 실행 완료면 0입니다. 취약점 발견 자체는 실행 오류가 아닙니다. 강제 종료/접속 단절 시 결과가 불완전할 수 있으며, 자동 반복 재시도는 하지 않습니다. preflight 결과를 retry-from으로 지정하면 연결 실패 서버만 대상으로 실제 점검할 수 있습니다.

## 5. YAML 직접 사용

실행기는 전송 파일과 실행 폴더 경로를 만든 후 아래 YAML을 실행합니다.

```bash
.venv/bin/ansible-playbook playbooks/preflight.yml -i inventory/hosts.yml --ask-vault-pass
# 이미 실행기가 생성한 전송 파일을 사용하여 직접 실행하는 예
.venv/bin/ansible-playbook playbooks/check.yml -i inventory/hosts.yml \
  --limit windows-winrm-01 -e @runs/이전실행폴더/vars.json --ask-vault-pass
```

일반 운영에서는 결과 폴더 충돌 방지와 실패 목록 작성을 위해 `scripts/run.py`를 사용하세요. 직접 YAML 실행은 요약 작성/재실행 목록 관리를 제공하지 않습니다.

## 6. 증적 관리와 검증 범위

점검 증적에는 계정·서비스·보안 설정 정보가 들어갈 수 있습니다. Kali 실행 폴더는 700, 파일은 기본 600으로 만들며 Windows 원격 폴더는 Administrators/SYSTEM으로 ACL을 제한합니다. Windows 점검 계정에 관리자 토큰이 없으면 실행하지 마세요. 대상 임시 폴더 `kisa-infra-*`는 접속 실패 복구와 수동 확인을 위해 유지합니다. 보존 기한에 따라 서버 관리자가 삭제하세요. 실행 중 작업이 남아 있는지 확인한 후 삭제해야 합니다. 결과 압축은 원격 경로를 기록한 Ansible 출력과 함께 보관하세요. `runs`, 실제 inventory, Vault, vendor, venv는 배포 대상에 포함하지 않습니다.

KISA 원본 스크립트의 개별 판단 정확성·환경별 부작용·Windows API의 원격 세션 제한은 이 실행기가 보증하지 않습니다. MANUAL/N/A 및 누락 결과를 검토하세요. 최초 적용 전에 파일럿 서버로 검증하세요. SSH/WinRM/PSRP가 실제 성공했는지와 원본 점검이 완주했는지는 별도로 기록합니다.

공식 연결 문서: https://docs.ansible.com/projects/ansible/latest/os_guide/windows_winrm.html

로컬 자동 검증:

```bash
.venv/bin/python -m unittest discover -s tests -v
.venv/bin/ansible-playbook playbooks/check.yml --syntax-check -i inventory/hosts.example.yml
.venv/bin/ansible-playbook playbooks/preflight.yml --syntax-check -i inventory/hosts.example.yml
```
