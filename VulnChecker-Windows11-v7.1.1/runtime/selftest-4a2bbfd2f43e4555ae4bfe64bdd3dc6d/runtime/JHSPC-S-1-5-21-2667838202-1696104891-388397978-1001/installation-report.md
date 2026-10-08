# 기존 설치 점검 결과

확인 시각: 2026-10-08T18:47:51.4941865+09:00

설치 여부와 실행 준비 상태를 구분합니다. 미탐지는 정해진 검색 범위에서 찾지 못했다는 뜻이며, 미확인은 접근/엔진 상태 때문에 판단할 수 없다는 뜻입니다.

| 도구 | 설치 상태 | 발견 위치 | 확인 근거 / 다음 작업 |
| --- | --- | --- | --- |
| Burp Community | 설치됨 | existing.exe | 등록 정보와 실제 실행 파일 확인 |
| Docker Desktop | 설치됨 | existing.exe | 등록 정보와 실제 실행 파일 확인 |
| Java (SDK 가상 기기 생성용) | 설치됨 | existing-java | Standalone Java 또는 기존 JBR 재사용; Studio 설치 안 함 |
| WSL | 설치됨 |  | 배포판 등록 정보는 현재 Windows 사용자 기준 |
| Kali 배포판 | 미탐지 | kali-linux | 현재 계정에 해당 배포판 미등록 |
| opencode | 미탐지 |  | Kali 배포판 설치 후 필요 |
| nmap | 미탐지 |  | Kali 배포판 설치 후 필요 |
| tcpdump | 미탐지 |  | Kali 배포판 설치 후 필요 |
| tshark | 미탐지 |  | Kali 배포판 설치 후 필요 |
| nc | 미탐지 |  | Kali 배포판 설치 후 필요 |
| socat | 미탐지 |  | Kali 배포판 설치 후 필요 |
| dig | 미탐지 |  | Kali 배포판 설치 후 필요 |
| whois | 설치됨 / 준비 필요 | C:\Users\spria\AppData\Local\Microsoft\WindowsApps\whois.exe | Windows에 설치됨. Kali 연동에 필요한 Linux 설치 여부는 별도로 확인. |
| curl | 설치됨 / 준비 필요 |  | Windows에 설치됨. Kali 연동에 필요한 Linux 설치 여부는 별도로 확인. |
| openssl | 설치됨 / 준비 필요 | C:\Program Files\OpenSSL-Win64\bin\openssl.exe | Windows에 설치됨. Kali 연동에 필요한 Linux 설치 여부는 별도로 확인. |
| ffuf | 미탐지 |  | Kali 배포판 설치 후 필요 |
| sqlmap | 미탐지 |  | Kali 배포판 설치 후 필요 |
| nikto | 미탐지 |  | Kali 배포판 설치 후 필요 |
| nuclei | 미탐지 |  | Kali 배포판 설치 후 필요 |
| gobuster | 미탐지 |  | Kali 배포판 설치 후 필요 |
| feroxbuster | 미탐지 |  | Kali 배포판 설치 후 필요 |
| whatweb | 미탐지 |  | Kali 배포판 설치 후 필요 |
| wafw00f | 미탐지 |  | Kali 배포판 설치 후 필요 |
| testssl | 미탐지 |  | Kali 배포판 설치 후 필요 |
| sslscan | 미탐지 |  | Kali 배포판 설치 후 필요 |
| dirsearch | 미탐지 |  | Kali 배포판 설치 후 필요 |
| wfuzz | 미탐지 |  | Kali 배포판 설치 후 필요 |
| masscan | 미탐지 |  | Kali 배포판 설치 후 필요 |
| enum4linux-ng | 미탐지 |  | Kali 배포판 설치 후 필요 |
| smbclient | 설치됨 / 준비 필요 | C:\Users\spria\AppData\Local\Programs\Python\Python313\Scripts\smbclient.py | Windows에 설치됨. Kali 연동에 필요한 Linux 설치 여부는 별도로 확인. |
| smbmap | 미탐지 |  | Kali 배포판 설치 후 필요 |
| impacket-secretsdump | 미탐지 |  | Kali 배포판 설치 후 필요 |
| nxc | 미탐지 |  | Kali 배포판 설치 후 필요 |
| hydra | 미탐지 |  | Kali 배포판 설치 후 필요 |
| john | 미탐지 |  | Kali 배포판 설치 후 필요 |
| hashcat | 미탐지 |  | Kali 배포판 설치 후 필요 |
| msfconsole | 미탐지 |  | Kali 배포판 설치 후 필요 |
| searchsploit | 미탐지 |  | Kali 배포판 설치 후 필요 |
| jadx | 미탐지 |  | Kali 배포판 설치 후 필요 |
| apktool | 미탐지 |  | Kali 배포판 설치 후 필요 |
| adb | 설치됨 / 준비 필요 | C:\Windows\adb.exe | Windows에 설치됨. Kali 연동에 필요한 Linux 설치 여부는 별도로 확인. |
| apksigner | 미탐지 |  | Kali 배포판 설치 후 필요 |
| binwalk | 미탐지 |  | Kali 배포판 설치 후 필요 |
| r2 | 미탐지 |  | Kali 배포판 설치 후 필요 |
| gdb | 미탐지 |  | Kali 배포판 설치 후 필요 |
| yara | 미탐지 |  | Kali 배포판 설치 후 필요 |
| strings | 설치됨 / 준비 필요 | C:\Users\spria\AppData\Local\Microsoft\WindowsApps\strings.exe | Windows에 설치됨. Kali 연동에 필요한 Linux 설치 여부는 별도로 확인. |
| frida | 설치됨 / 준비 필요 | C:\Users\spria\AppData\Local\Programs\Python\Python313\Scripts\frida.exe | Windows에 설치됨. Kali 연동에 필요한 Linux 설치 여부는 별도로 확인. |
| objection | 미탐지 |  | Kali 배포판 설치 후 필요 |
| HexStrike | 미탐지 |  | Kali 내부 탐지 불가 |
| Android SDK / Emulator | 미탐지 |  | 환경변수·기본 SDK·전용 SDK·PATH 검사 |
| Android AVD | 미탐지 |  | 기존 AVD 탐지. 요청 API 30 루트 후보: . 동적 분석은 전용 VulnChecker_API30에서 검증하며 기존 AVD는 변경하지 않음. |
| Google Play 다운로드 기기 (선택 설치) | 설치됨 / 준비 필요 | VulnChecker_Play_API30 | 앱 가져오기 탭에서 필요할 때 설치. 다운로드 시 SDK 드라이브 6GB 여유 공간 검사. 루팅 기기와 분리. |
| Docker 엔진 | 미확인 |  | 설치 여부와 별개로 엔진 정지/접근 불가. 재설치 판정하지 않음. |
| MobSF Docker 이미지 | 미확인 |  | Docker 엔진이 정지했거나 접근 불가하면 이미지 설치 여부는 미확인. |

추가 설치/준비 예상: 22.9GB. 여유 공간 포함 기준: 28GB. 실제 다운로드·작업 공간에 따라 달라질 수 있습니다.

MobSF 이미지는 Docker 엔진이 응답할 때 확인합니다. 실제 AVD root/remount와 동적 분석 연결은 별도 실행 단계에서 검증합니다.
