# 설치 및 연동 검증 기록

## v7.2.0 UI 통합 검증

2026-10-12에 실행기를 기존 VulnChecker의 ⑦ 인프라 점검 탭으로 통합했습니다. 아래의 기존 독립 실행 검증 기록은 최초 점검 이력입니다.

- Start.cmd가 불러오는 Core 모듈에 서버 설정/실행/GUI 기능을 연결했습니다. 설정 입력은 같은 Windows 계정의 DPAPI로 암호화하며, 실행 시 UI 전용 Kali Vault를 사용합니다.
- 이전에 검증한 Linux/Windows 접속 정보를 현재 UI로 가져왔고 실제 암호를 소스나 배포 ZIP에 넣지 않았습니다.
- 통합 접속 사전 확인 ID `20261012T110757Z-89dcd355`: Linux SSH/sudo와 Windows WinRM/관리자 확인 모두 성공.
- 통합 전체 점검 ID `20261012T111005Z-1679afb1`: 두 서버의 원본 점검 및 결과 회수 완료. Linux GOOD 39 / VULNERABLE 22 / MANUAL 4 / N/A 1 / U-64 실행 실패, Windows GOOD 33 / VULNERABLE 20 / MANUAL 11 / 실행 실패 없음. 판정은 점검 시점에 따라 달라질 수 있습니다.
- 통합 백그라운드 작업의 실패 서버 선택 재실행 ID `20261012T111458Z-fe1f8fb3`: Linux만 선택됐고 Windows는 재실행하지 않았습니다. U-64 원본 오류는 실패로 유지됩니다.
- 새 GUI 검사: 7번 탭, 서버 설정과 암호 마스킹/빈칸 유지, 접속 종류별 입력 활성화, HTTP/HTTPS 포트, 결과 표시, 체크된 정상 서버 제외, 선택 실패 서버의 작업 전달, 화면 잘림 없음 확인.
- 기존 GUI 검사 및 회귀 검사 91개 통과. 실제 화면을 렌더링해 서버 등록/실행과 결과/재실행 배치를 확인했습니다.
- 통합 배포 ZIP의 Start.cmd, GUI 모듈, 연결 코드, YAML, 가이드를 확인하고 실제 암호·인벤토리·실행 증적 제외를 검증했습니다.

검증일: 2026-10-12 (Asia/Seoul)

기존 `VulnChecker-Windows11-v7.1.1` 모듈을 수정하지 않고 독립 폴더 `infra-ansible`과 Kali 전용 환경을 추가했습니다.

## 실제 설치

- Kali WSL `kali-linux`, 사용자 `jhs`, 설치 경로 `~/.local/share/vulnchecker-infra`.
- Ansible Core 2.19.14, ansible.windows 3.8.0, pywinrm 0.5.0, pypsrp 0.9.1.
- 전용 venv를 사용하고 기존 도구의 venv에 설치하지 않았습니다.
- `python3-venv` 설치 과정에서 Kali 패키지 관리자가 관련 Python 의존성을 함께 갱신했습니다. 검증 당시 전용 환경의 Python은 3.14입니다. 기존 애플리케이션 전체 회귀 검증은 이번 작업 범위에서 수행하지 않았습니다.
- KISA 고정 커밋 `d081fc1e75a2be207eb2e57632e5e5f398e273b1` 다운로드 및 원본 변경 없음 확인.

## 실제 Windows 서버

사용자가 제공한 서버·계정으로 테스트했습니다. 자격 증명은 Kali의 Ansible Vault 암호문과 사용자 전용 Vault 키 파일에 저장하며 소스·배포 ZIP·결과 요약에는 포함하지 않았습니다.

- TCP 5985 접속 가능, 5986 연결 불가. HTTP + NTLM 메시지 암호화를 사용했습니다.
- WinRM과 PSRP 모두 연결 확인 및 관리자 토큰 확인 성공.
- Windows PowerShell 5.1 한글 경로 및 프로세스 종료 코드 수집 문제를 수정한 뒤, 이전 실패 서버 목록을 이용해 선택 재실행했습니다.
- 최종 WinRM 실행: 64개 항목 모두 종료 코드 0, JSON 64개 검증 및 결과 압축 회수 성공.
- 원본 판정: GOOD 33, VULNERABLE 20, MANUAL 11. 실행 실패 서버 없음.
- PSRP는 접속/관리자 확인 및 실행 증적 조회까지 검증했습니다. PSRP로 64개 전체 점검을 별도 반복하지 않았습니다.

원본의 MANUAL에는 원격 Windows API 제약이나 스크립트 내부 예외 처리도 포함될 수 있으므로 증적을 검토해야 합니다. 위 개수는 원본 스크립트 판정이며 KISA 항목별 판단 정확성에 대한 별도 감사 결과가 아닙니다.

최종 실행 ID: `20261012T104916Z-4c1ea15c`. 실제 대상 정보와 증적은 배포 제외인 `runs`에만 보관합니다.

## 실패 서버 선택 재실행

정상 WinRM/PSRP 대상과 로컬 접속 불가 모의 대상 `test-down`을 같은 사전 점검에 포함했습니다. 실패 목록에는 `test-down`만 기록되었고, `--retry-from` 실행의 대상도 `test-down` 하나만 선택됐습니다. 정상 대상은 다시 실행하지 않았습니다. 대상이 없는 실패 목록은 원격 연결 없이 정상 종료하는 것도 확인했습니다.

## Linux 및 자동 검증

- 추가로 제공된 실제 Kali 2026.3 서버에서 SSH 로그인, Python 실행, sudo root 권한 확인에 성공했습니다. SSH ED25519 키를 전용 known_hosts에 고정하고 검증을 유지했습니다. 로그인 및 sudo 비밀번호는 Ansible Vault로 암호화했습니다.
- 실제 서버에서 원본 Debian 항목 67개를 실행하고 증적 회수에 성공했습니다. 1차 실행 ID `20261012T105339Z-4dcd85bd`: GOOD 40, VULNERABLE 20, MANUAL 4, N/A 1, 실행 실패 2개(U-25, U-64). JSON 결과 65개를 회수했습니다.
- U-25는 전체 파일 권한 검색이 기본 90초를 초과했습니다. 해당 호스트에만 항목 제한을 300초로 늘려 실패 서버 선택 재실행을 진행했고, 재실행에서 정상 완료(GOOD)했습니다.
- 최종 Linux 실행 ID `20261012T105725Z-4e28602d`: GOOD 41, VULNERABLE 20, MANUAL 4, N/A 1, 실행 실패 1개(U-64). JSON 66개와 항목별 실행 로그를 회수했습니다. Ansible 연결/태스크 실패는 없었으며 원본 항목 오류를 감지해 실행기 종료 코드는 1입니다.
- 최종 재실행의 대상 목록에는 `test-linux`만 포함됐으며 기존 Windows 서버는 재실행하지 않았습니다. 기본 인벤토리에 Linux 서버를 추가하여 이후 전체 실행 또는 `--hosts test-linux` 선택 실행이 가능합니다.
- U-64는 보안 업데이트 문자열이 없는 경우 `grep -i security`의 종료 코드 1이 `set -euo pipefail`에 의해 전파되어 결과 저장 전에 종료되는 원본 문제를 실제 추적 로그로 확인했습니다. 원본은 수정하지 않았으며 실패로 기록합니다. 패치 정책과 적용 이력은 수동 확인이 필요합니다.
- Kali loopback에 키 인증 전용 임시 SSH 서버를 띄워 Linux 모의 항목 67개 전달·실행·압축·회수를 검증했습니다. 호스트 키 검증을 유지했으며 테스트 후 임시 SSH 서버를 종료했습니다.
- 모의 항목 중 비정상 종료와 결과 누락을 각각 주입했고, 두 오류를 모두 실행 실패로 감지했습니다. VULNERABLE 판정과 실행 실패가 별도로 기록되는 것도 확인했습니다.
- 자동 테스트 7개 통과. SSH 전송 통합 테스트 별도 통과.
- 점검/사전 확인 YAML 구문 검사 통과, PowerShell 파서 검사 통과, Windows 실행기에서 실제 사전 확인 성공.

Linux는 제공된 Kali/Debian 계열 서버에서 검증했습니다. 다른 배포판의 OS 명령 가용성과 Windows HTTPS 인증서·도메인 Kerberos 설정은 해당 대상 환경에서 추가 검증해야 합니다.

현재 설치 환경에서 Linux만 재점검하려면 Windows의 `infra-ansible` 폴더에서 다음과 같이 실행합니다. 실제 자격 증명과 전용 호스트 키 파일은 Kali 홈에만 있으며 배포 ZIP에 포함되지 않습니다.

```powershell
.\Start-Infrastructure.ps1 -Action run --hosts test-linux --vault-password-file .vault-password-test
```
