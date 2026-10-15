# ⑦ 인프라 점검 실행 소스

VulnChecker Start.cmd의 ⑦ 인프라 점검 탭에서 사용합니다. 설치·서버 등록·실행·결과 조회·실패 서버 선택 재실행은 UI로 처리합니다. 사용자 안내는 ../docs/INFRASTRUCTURE.ko.html을 참고하세요.

Ansible YAML은 playbooks/check.yml과 playbooks/preflight.yml입니다. scripts/gui-bridge.py가 Windows UI와 Kali 전용 환경을 연결합니다. SSH/WinRM/PSRP 접속을 지원하고, 원본 KISA 커밋 d081fc1e75a2be207eb2e57632e5e5f398e273b1을 유지합니다. 원본은 별도 다운로드되며 배포 ZIP에 자격 증명과 증적을 넣지 않습니다.

## 고객 자체 실행 방식

원격 접속을 제공받기 어려우면 ⑦ 대량 등록 / 실행 설정 → **고객 실행본 저장**으로 `TriGuard-Infrastructure-Offline.zip`을 저장해 고객에게 전달합니다. Unix는 단일 `Unix-Infrastructure.sh`(Bash/Python 3.8+), Windows는 단일 `Windows-Infrastructure.ps1`(Windows PowerShell 5.1)로 실행하며 서버에 Ansible·SSH·WinRM·인터넷·AI 키가 필요하지 않습니다. 원본 소스와 라이선스를 내장하고, 실행/결과 전달 안내 HTML/TXT와 대응 소스도 동봉합니다. [고객에게 전달할 상세 설명서](../docs/CUSTOMER-OFFLINE.ko.md)를 참고하세요.

반환 ZIP은 **고객 실행 결과 가져오기**에서 여러 개를 선택할 수 있습니다. WSL 없이 로컬 보고서 런타임으로 ZIP 경로·파일 목록·크기·해시·메타데이터를 검사하고 `infra-runs`에 원자적으로 보관합니다. 검사 실패 파일은 반영하지 않으며 동일 실행 ID의 다른 내용은 덮어쓰지 않습니다. 정상 파일과 실패 파일이 섞여 있으면 정상 파일은 가져오고 실패 파일의 사유를 표시합니다. 결과 이력·레포트·RAW 보관을 재사용하지만 서로 다른 회차의 자동 보고서 병합은 제공하지 않습니다.

실행본 재생성: Python과 Git이 있는 개발 환경에서 `python infrastructure/scripts/build-offline.py`를 실행합니다. 기본적으로 깨끗한 고정 커밋을 준비하며 `--source <검증된 체크아웃>`과 `--output <출력 폴더>`를 지정할 수도 있습니다. 고객 실행 시에는 다운로드하거나 설치하지 않습니다.


## 1,000대 이상 운영

⑦ → 대량 등록 / 실행 설정 → CSV 양식 저장에서 빈 UTF-8 CSV와 작성 안내 TXT를 받아 고객에게 두 파일을 전달합니다. 작성된 CSV는 CSV 일괄 등록으로 읽습니다. Host, User, Connection, Platform, Port는 모든 행에서 필수이며 활성 서버는 인증 정보도 필요합니다. Alias는 선택이며 비우면 Host를 이름으로 사용합니다. IP 자체도 서버 이름으로 등록할 수 있습니다(IPv6 내부 이름은 ip6- 및 하이픈). Connection은 ssh/winrm/psrp, SSH Platform은 Auto/Debian/RedHat/AIX/HP-UX/Solaris, Windows는 Windows입니다. 플랫폼을 지정하기 어렵다면 SSH는 Auto를 사용하세요. Enabled/TrustNewHostKey는 true/false입니다. 암호 빈칸은 기존 암호를 유지합니다. 모든 행 검증 후 한 번 저장하므로 잘못된 CSV는 기존 서버 목록을 바꾸지 않습니다. 서버 이름이 같으면 설정을 갱신합니다. 저장 암호는 현재 Windows 계정의 DPAPI로 암호화되며 CSV 원본은 암호화하지 않습니다.

처음에는 10대 접속/권한 확인 후 동시 작업 20, 배치 100으로 시작합니다. 1,000대는 OS별 최대 100대씩 순차 배치로 진행하며, 각 배치 안에서는 서버별로 독립 진행합니다. 배치는 OS별로 별도 프로세스로 실행하므로 한 배치가 전부 실패해도 다음 배치와 다음 OS를 계속 진행합니다. 동시 작업 수는 Ansible 작업 프로세스 수이며 배치 크기가 동시에 점검될 수 있는 서버 수의 상한입니다. CPU·메모리·대상 부하·대역폭을 측정하고 조절하세요. 숫자만으로 1,000대 처리 성능을 보장하지 않습니다. Windows와 Linux 플레이는 순차 실행합니다. 실패 서버만 재실행할 수 있고, 실행 설정은 request.json/summary.json에 기록됩니다.

Linux는 계정·접속 암호만으로 SSH 접속할 수 있습니다. 로그인용 SSH 키는 선택 사항이며 키 파일을 비워 두면 비밀번호 인증을 사용합니다. 최초 서버 호스트 키는 OpenSSH accept-new로 자동 저장하고, 기존 서버 키 변경은 차단합니다. sshpass가 없으면 실행 시 자동 설치합니다. Windows는 WinRM 또는 PSRP의 HTTPS 5986, 신뢰할 수 있는 인증서 및 관리 계정을 준비합니다. 활성 신규 Windows 행은 Password를 입력해야 합니다. 활성 신규 SSH 행은 Password 또는 KeyFile이 필요하며, 기존 행은 저장 암호와 키를 재사용할 수 있습니다. Enabled=false인 준비 행은 인증 정보 없이 등록할 수 있습니다. 필수 값의 공백·중복 이름·잘못된 포트·지원하지 않는 열을 검사하고 오류 행 번호와 항목을 표시합니다. 접속/권한 확인에서 실패한 서버를 먼저 정정하세요.

대수가 더 커지거나 망이 분리되면 망/지역/OS별로 CSV를 분리하여 해당 망의 Linux 관리 서버에서 동일 CLI를 실행할 수 있습니다. infrastructure 폴더를 Linux에 복사하고 python3-venv, git, openssh-client를 준비한 뒤 bash scripts/install-kali.sh를 실행합니다. inventory/hosts.yml와 Vault를 설정하고 아래 명령으로 실행합니다. CLI는 WSL에 종속되지 않습니다. 여러 관리 서버를 사용할 경우 각 서버의 결과 폴더를 별도로 보관하세요. 현재 Windows GUI는 로컬 Kali WSL 컨트롤러를 사용하며 원격 관리 서버 통합 실행/결과 병합은 제공하지 않습니다.

```bash
.venv/bin/python scripts/run.py --inventory inventory/hosts.yml --vault-password-file /secure/vault-password --forks 20 --batch-size 100 --preflight
.venv/bin/python scripts/run.py --inventory inventory/hosts.yml --vault-password-file /secure/vault-password --forks 20 --batch-size 100
```

## 항목 결과 검증 및 U-64 호환 수정

Ansible의 `failed=0`은 접속·배포·실행 래퍼·증적 수집이 완료됐다는 뜻입니다. 각 점검 스크립트의 종료 코드와 결과 JSON은 별도로 검증합니다. 67개 중 한 항목이 종료 코드 1로 끝나거나 JSON이 없으면 해당 서버를 재실행 대상으로 유지하고 화면에는 **항목 미완전**으로 표시합니다. 최종 로그에는 누락 항목과 종료 코드를 표시합니다. 취약 판정 자체는 실행 실패가 아닙니다.

고정된 원본의 Debian U-64는 `grep`의 0건 조회 코드 1을 `set -e / pipefail`에서 오류로 처리하고, 긴 `apt` 출력을 `head`로 자를 때도 파이프 오류가 날 수 있습니다. 실행 번들을 만들 때 해당 부분만 호환 수정합니다. 원본 Git 체크아웃은 수정하지 않으며 `source-compatibility.json`에 수정 ID, 원본/실행본 SHA256과 이유를 보관합니다. 보안 문자열 개수는 0도 정상 값으로 처리하고 `apt` 조회 자체가 실패하면 결과를 만들지 않고 계속 실패로 표시합니다. 과거 실행 결과를 자동으로 고치거나 누락된 판정을 만들어 넣지 않습니다.

## WSL 설치 오류와 한글 출력

WSL의 구형 런처는 WSL_UTF8 설정을 무시하고 UTF-16LE를 출력할 수 있습니다. 표준 출력/오류를 각각 원시 바이트로 수집해 UTF-8/UTF-16LE를 구분합니다. WSL 사전 확인에는 15초 제한을 적용합니다. Ansible 설치 / 확인 버튼은 필요한 관리자 권한을 요청하고 WSL 구성 요소와 Kali를 준비합니다. WSL이 없으면 `wsl --install --no-distribution --web-download`, Kali가 없으면 `wsl --install --distribution kali-linux --web-download --no-launch`를 Windows에서 자동 실행합니다. 기존 배포판은 재설치하지 않습니다. WSL 옵션은 불필요한 따옴표 없이 전달하며 공백이 있는 경로와 Linux 명령 인수는 따옴표로 보호합니다. `/bin/bash: --install: command not found`는 WSL 옵션이 Linux 명령으로 전달되던 호출 오류로 수정했습니다. 재부팅이 필요하면 실패 대신 재부팅 필요 상태(종료 코드 3010)를 표시합니다. 재부팅 후 같은 버튼을 다시 실행하면 Kali와 Ansible 설치를 이어갑니다. 자동 재부팅은 하지 않습니다. 다운로드 정책·가상화 설정·WSL2 커널 문제는 오류 로그를 확인하세요.

근거: [Ansible 실행 전략](https://docs.ansible.com/projects/ansible-core/2.17/playbook_guide/playbooks_strategies.html), [WSL 명령](https://learn.microsoft.com/en-us/windows/wsl/basic-commands).

## OS 및 서비스 자동 감지와 점검 대상 선택

⑦에서 SSH 또는 Windows(WinRM/PSRP) 접속 정보를 저장하고 **OS / 서비스 자동 감지**를 누릅니다. 기존 암호 또는 SSH 키 접속을 그대로 사용합니다. 완료 후 선택 창이 열리며, 후보를 체크하고 다음 구성 창에서 **구성 적용 → 전체 저장**을 누릅니다. 이후 선택 서버 점검은 저장한 구성만 실행합니다. 별도 구성이 없는 서버의 실행 버튼은 OS와 표준 경로에서 확인된 Web/WAS를 자동 감지하여 실행하고, 미설정 DB는 실행에서 제외했다는 로그와 보고서 수행 제약을 남깁니다.

점검 종류는 Unix OS, Windows 서버, Web/WAS, DBMS, PC로 구분합니다. 현재 원본 지원은 Unix 5종(각67), Windows64, Apache/Nginx/Tomcat/IIS(각26), MySQL/PostgreSQL/Oracle/MSSQL(각26), PC18입니다. 합계 15개 프로필625개 항목이며 모든 항목을 한 서버에 실행하는 뜻은 아닙니다. 제품은 이 원본 지원 목록에서 선택합니다. 다른 제품을 비슷한 프로필로 대체 점검하지 않습니다.

예를 들어 한 Debian 서버에는 os(Unix OS), was-prod(WAS), db-prod(DBMS)를 함께 저장할 수 있습니다. 서비스 여러 개는 서로 다른 인스턴스 ID와 설치 경로, 또는 DB 주소·포트·DB명으로 등록합니다. 각각 별도 작업공간, 종료 코드, 판정, 증적, 재실행 대상을 갖습니다. DB 점검 계정·암호는 SSH 계정과 별도입니다. DB 암호는 Windows DPAPI와 Kali Vault로 보호하며 수집 전 supplied password를 로그에서 제거합니다. 빈 DB 암호 입력은 기존 저장값을 유지합니다.

자동 감지는 OS 식별 정보와 표준 설정 경로·프로세스/서비스 등록을 읽습니다. 원본 lib/platform_detector.sh에는 일부 OS 판별 함수만 있으며 모든 OS·서비스를 자동 선택하는 통합 실행기는 없습니다. 앱의 새 감지기가 Kali/Debian 파생 배포판, RedHat 계열, AIX/HP-UX/Solaris, Windows 서버/PC를 구분합니다. 표준 경로 밖의 WAS, 컨테이너, 중지 서비스, 원격 DB의 자동 발견을 보장하지 않습니다. 후보와 범위를 확인하고 수동 구성을 추가할 수 있습니다.

Unix 실행 대상은 Bash와 Python3가 필요합니다. 경로와 실행 계정을 구성 창에 지정할 수 있습니다. 대상 DB 클라이언트(mysql/psql/sqlplus/sqlcmd)와 접근 권한도 필요합니다. 고객 서버에 클라이언트를 임의 설치하지 않습니다. Windows OS/PC/IIS 원본은 PowerShell로 실행하지만, 원본의 MSSQL 등 DBMS와 IIS 외 Web/WAS는 Bash입니다. Windows에서 발견한 해당 서비스는 별도 SSH/Bash 실행 환경과 DB/설치 정보를 등록해야 하며 자동으로 PowerShell로 변환하지 않습니다.

설치 루트 지정은 알려진 원본 설정 파일 검색 경로를 해당 인스턴스로 연결합니다. 패키지·프로세스 등 일부 원본 항목은 호스트 전체 범위이며, IIS 원본도 서버 전체 구성 점검입니다. 개별 서비스의 완전한 프로세스 격리를 뜻하지 않습니다. 각 실행 요약의 limitations에 이 범위 제약을 보관합니다.

보고서는 **물리 서버 수**와 **OS/서비스 점검 대상 수**를 구분합니다. 동일 서버 OS·WAS·DB 결과는 별도 행이며, MySQL D-01과 Oracle D-01처럼 다른 프로필의 항목 ID가 같아도 합치지 않습니다. Excel의 다른 프로필 열은 ‘범위 외’, 같은 프로필의 미수집 결과는 ‘결과 없음’으로 표시합니다. 판정을 임의로 양호나 해당 없음으로 대체하지 않습니다.

## 접속 정지 방지와 담당자 확인 자료

### SSH 로그인은 되는데 Red Hat 점검이 실패할 때

현재 Ansible 2.19의 대상 Python 지원 범위는 3.8~3.13입니다. RHEL의 Python 3.6.8만 있으면 SSH 인증이 성공해도 원격 모듈에서 `future feature annotations is not defined` 오류가 발생합니다. 시스템 Python이나 `/usr/libexec/platform-python`을 교체하지 말고 서버 담당자가 승인한 별도 런타임을 준비하세요. 점검기는 지정 경로와 표준 Python 경로에서 지원 버전이 이미 존재하면 이를 선택하며 설치하지 않습니다. [Ansible 지원 버전](https://docs.ansible.com/projects/ansible/latest/reference_appendices/release_and_maintenance.html)

PAM 후킹이나 로그인 초기화가 비대화형 SSH의 표준 출력에 안내 문구를 쓰면 SFTP가 `Received message too long`으로 실패할 수 있습니다. 서버 담당자는 인증 기능을 유지하면서 해당 안내를 로그로 보내도록 수정해야 합니다. 단순히 전송 방식을 바꾸거나 PAM을 해제하는 것으로 처리하지 마세요. 담당자는 같은 점검 계정으로 `ssh user@server 'printf READY'`를 실행해 표준 출력에 READY만 나오는지 확인하고, SFTP의 `pwd`도 확인하세요. SSH 자체 경고가 표준 오류에 표시되는 것과는 구분합니다.

접속/권한 확인·자동 감지·실제 점검은 파일 전송 전에 읽기 전용 SSH 명령으로 Python과 비대화형 표준 출력을 검사합니다. 실패 사유에 감지한 Python 버전·출력 오염·요청 접속 주소와 담당자 조치를 표시하고 해당 서버를 중단합니다. 두 문제가 함께 있으면 모두 표시합니다. 조치 후 접속/권한 확인부터 다시 실행하세요. 고객 자체 실행본은 SSH 전송이 필요 없지만 Unix 실행본도 Python 3.8 이상은 필요합니다.

Windows CSV의 Protocol을 비우면 Port=5985는 http, Port=5986은 https로 선택합니다. 다른 Windows 포트는 Protocol도 입력해야 하며, 명시한 Protocol은 그대로 사용합니다. GUI에서 기본 포트를 바꾸면 HTTP/HTTPS도 함께 맞춥니다. 사용자 지정 포트는 프로토콜을 바꿔도 덮어쓰지 않습니다.

`Enter-PSSession -ComputerName <IP>`에 `-UseSSL`을 지정하지 않으면 기본 HTTP/5985를 사용합니다. 같은 서버에 도구가 HTTPS/5985로 접속하면 `[SSL: WRONG_VERSION_NUMBER]`가 날 수 있습니다. 이 경우 새 실패 기록은 **HTTP/HTTPS 접속 방식과 서버 포트 불일치** 및 실제 요청 주소를 표시합니다. HTTP에서도 기존 NTLM 메시지 암호화(always)는 유지하며, 인증서 검증을 꺼서 해결하지 않습니다. [Microsoft 접속 포트 안내](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/enter-pssession?view=powershell-5.1) · [Ansible WinRM 메시지 암호화](https://docs.ansible.com/projects/ansible/latest/os_guide/windows_winrm.html)

- SSH 접속 대기 15초, 재접속 재시도 없음, 접속 후 응답 단절은 keepalive 15초/2회로 감지합니다. 접속 허용 여부를 ICMP 응답만으로 판단하지 않습니다.
- 준비/전송/권한/증적 수집 등 일반 작업에는 작업당 120초 제한을 적용합니다. WinRM/PSRP도 접속/읽기 대기를 제한합니다. Ansible 설정의 task_timeout과 SSH 인수를 사용합니다.
- 실제 점검은 비동기로 실행하고 완료 상태를 별도로 조회합니다. 조회 요청에도 일반 작업 제한을 적용하여 SSH 연결 후 원격 명령이 멈춰도 무기한 대기하지 않습니다. 정상적으로 오래 실행되는 점검은 별도의 전체 실행 제한(항목 제한×해당 프로필 항목 수+300초, 최소 600초)으로 관리합니다.
- 개별 항목은 기본 90초(서버별 10~3600초). 3개 항목이 연속 시간 초과되면 해당 대상의 나머지는 건너뛰고 종료합니다. rc=124는 시간 초과, rc=125는 연속 시간 초과로 건너뜀입니다. 양호/해당 없음으로 바꾸지 않습니다. 이미 비동기로 시작한 작업은 네트워크 단절 시 즉시 원격 종료를 보장할 수 없으며 설정된 원격 실행 제한까지 남을 수 있습니다.
- 자동 감지 실패 서버는 지원 OS를 추측하여 점검하지 않고 실패 사유와 함께 건너뜁니다. 정상 감지된 서버와 후속 배치는 계속합니다. 사용자 중단은 계속 실행 요청으로 취급하지 않습니다.

점검 결과 표에 실패 단계/분류/확인 요청 사항을 표시합니다. **담당자 확인용 실패 CSV**는 선택 회차의 failures.csv를 엽니다. 서버 이름·접속 IP/포트·접속 방식·인스턴스·프로필·실패 단계·사유 코드·담당자 확인 요청을 포함합니다. 이 CSV는 RAW 보관함에도 함께 보관합니다. 네트워크 경로 없음, 접속 거부, 인증 실패, 권한 부족, 인증서/호스트 키 오류, 시간 초과 등을 구분하며 원인이 확인되지 않으면 원인 미확인으로 표시합니다. 방화벽 또는 서버의 정확한 장애 원인은 담당자 로그 확인이 필요합니다. 오류 분류에는 원격 명령의 원문 출력이나 입력 암호를 복사하지 않습니다.

[Ansible 작업 시간 제한](https://docs.ansible.com/projects/ansible/latest/reference_appendices/config.html#default-task-timeout) · [비동기 실행과 완료 조회](https://docs.ansible.com/projects/ansible/latest/playbooks_async.html)
