# VulnChecker

### IBM ICA / DeepSeek AI 설정

처음 실행하면 **⑥ AI 설정** 탭이 열립니다. **IBM ICA API KEY**와 선택 사항인 **DEEPSEEK API KEY**를 입력하고 **API 키 / 모델 저장**을 누른 뒤 펜테스트 실행 버튼을 사용하세요. 설치 전에도 키를 저장할 수 있습니다.

IBM ICA 주소는 `https://api.nextgen-beta.ica.ibm.com/ica/v1`이며 기본 모델은 `gemini-3.1-pro-preview`입니다. 같은 제공자의 `claude-sonnet-4-6`, `claude-sonnet-5`도 선택할 수 있습니다. 모델 ID는 회사에서 제공한 값을 그대로 사용합니다. OpenAI 호환 Chat Completions와 Bearer API 키 인증을 전제로 구성했으며, 회사 게이트웨이가 다른 인증/요청 형식을 요구하면 추가 조정이 필요합니다.

DeepSeek는 예비 제공자로 등록됩니다. IBM ICA 토큰 소진 시 열린 OpenCode에서 `/models` → **DeepSeek (backup)** → `deepseek-flash` 또는 `deepseek-v4-pro`를 선택해 이어서 진행하세요. 자동 전환은 하지 않습니다. 다음 실행에도 DeepSeek를 사용하려면 AI 설정의 시작 모델을 변경해 저장하세요. 모델 구성은 [OpenCode 제공자 문서](https://opencode.ai/docs/providers/)와 [DeepSeek 공식 문서](https://api-docs.deepseek.com/)를 기준으로 합니다.

키 입력란은 마스킹되며 Windows 저장본은 현재 계정의 DPAPI로 암호화됩니다. 빈 입력란은 저장한 키를 유지하고, 삭제 체크박스를 선택하면 다음 실행에 해당 키가 제거됩니다. 실행할 때 Kali 사용자 전용 폴더에 읽기 제한된 키 파일(폴더 700 / 파일 600)을 만들고 OpenCode에는 파일 참조만 저장합니다. 기존 MCP와 다른 제공자 설정은 유지합니다. 키와 실행 자료는 배포 ZIP에 포함되지 않습니다. 설정 변경 후 열린 OpenCode는 종료하고 VulnChecker 실행 버튼으로 다시 여세요. 실제 API 인증·스트리밍·도구 호출은 유효한 키를 넣고 첫 점검 요청에서 확인해야 합니다.

고객사 Windows 11 x64 PC에서 웹·Android 진단 환경을 준비하는 PowerShell 5.1 기반 데스크톱 설치/실행 관리자입니다. 별도 Python/Node 설치 없이 `Start.cmd`로 엽니다. 현재 버전 **7.1.1** (2026-10-07), 화면 제목과 `version.json`에서 확인합니다.

**현재 기본값: Burp Community, Android 11(API 30) Google APIs x86_64 (Google Play 없음), WSL2 Kali, HexStrike, OpenCode, Docker Desktop, MobSF.**

1. 고객사 PC로 이 폴더 전체를 복사하고 압축을 풀어 `Start.cmd` 실행.
2. 새 PC에서는 약관을 검토하고 동의란 선택 → **자동 설치 / 이어하기**를 누릅니다. 기존 설치 확인부터 누락된 프로그램의 인터넷 다운로드·설치까지 진행하며, 설치 작업만 같은 계정의 관리자 권한으로 승격됩니다.
3. Windows 앱 설치 도구(WinGet)도 없으면 자동 등록·다운로드·설치합니다. **기존 설치 / 사전 확인**, **설치 상태 확인**은 조회만 수행합니다. 미탐지·미확인 목록이 나왔다고 설치 단계가 끝난 것은 아닙니다. 설치 중에는 연동 결과에서 각 단계의 진행·실패 이유를 확인합니다.
4. 화면 아래 진행 막대에 **설치 44% · 4/9 단계 완료 · Docker Desktop 설치 중**처럼 현재 단계와 완료 비율이 표시됩니다. 비율은 전체 설치 단계 기준이며 파일 다운로드 바이트나 남은 시간을 뜻하지 않습니다. 실패한 단계는 완료로 계산하지 않습니다. **재부팅 필요**가 표시되면 Windows 재부팅 후 같은 계정으로 다시 `Start.cmd` → **자동 설치 / 이어하기**. 가상화 기능을 처음 설치한 PC에서는 재부팅 후 프로그램 다운로드 단계로 넘어갑니다.
5. **실행 / 연동** 탭에서 모바일 앱의 단계별 메뉴 또는 **시스템(IP/URL) 펜테스트 실행** 선택. 필요한 서비스가 순서대로 자동 시작되며 **연동 결과** 탭으로 자동 이동합니다.
6. 설치 후 가이드는 자동으로 열리지 않습니다. 필요할 때 **사용 가이드** 버튼이나 [사용 가이드](docs/GUIDE.ko.html)를 직접 엽니다.

창은 시작할 때 다른 프로그램 앞으로 표시됩니다. 오른쪽 위 **화면 테마**에서 **다크 / 밝게**를 선택하면 다음 실행에도 유지됩니다.

추출하거나 가져온 APK는 `apk-library/<사용자 SID>/<추출 시각-ID>/`에 전체 split 세트와 `manifest.json`으로 자동 보관합니다. 분석 기기 설치나 실행이 실패해도 확보된 APK는 유지됩니다. **⑤ APK 보관함 → 앱 선택 → 선택한 APK 세트 재사용 → ③ 가져오기 / 분석 기기 설치**로 다시 설치할 수 있습니다. **보관 폴더 열기**로 파일을 확인하거나 복사할 수 있으며, 기존 `runtime/<PC-SID>/acquired-apps`의 APK도 목록에 표시합니다. APK 보관함은 배포 ZIP에 포함되지 않습니다.

OpenCode에서 `/exit`로 나온 뒤에는 전용 PowerShell 창에 복귀 안내가 표시됩니다. `oc`는 이전 대화 이어서 열기, `oc-new`는 새 대화, `oc --session ID`는 지정한 대화를 엽니다. 수정 후 새로 연 전용 창부터 적용됩니다. 배포 ZIP 전달과 GitHub Releases 업로드, 새 PC 설치 절차는 [배포 안내](docs/DEPLOY.ko.md)를 참고하세요.

CLI 사용 예 (설치는 관리자 PowerShell):

```powershell
.\VulnChecker.ps1 -Action Plan
.\VulnChecker.ps1 -Action Preflight
.\VulnChecker.ps1 -Action Install -AcceptLicenses
.\VulnChecker.ps1 -Action Verify
.\VulnChecker.ps1 -Action Launch -Tool MobileAnalysis
.\VulnChecker.ps1 -Action Launch -Tool PenTest
.\VulnChecker.ps1 -Action Launch -Tool AppDiagnostics -Package com.company.app
.\VulnChecker.ps1 -Action Launch -Tool RootBypass -Package com.company.app
.\VulnChecker.ps1 -Action Stop
.\VulnChecker.ps1 -Action Guide
```

이 프로그램은 환경 설치와 실행을 자동화합니다. 진단 대상 스캔·APK 분석은 사용자가 도구에서 수행합니다. `Launch MobileAnalysis`는 준비 검증이며 APK 대상 동적 분석 성공을 뜻하지 않습니다.

## MCP 무응답과 웹 트래픽 기록

- `connected`는 초기 연결 상태입니다. 시작 시 도구 목록뿐 아니라 MCP → HexStrike → 로컬 확인 명령 → 결과 반환까지 검사합니다. 긴 동기 작업은 별도 스레드에서 실행하고 진행 알림을 보내며, 호출 대기 시간은 6분으로 설정합니다. HexStrike HTTP 요청 제한은 5분입니다. 더 긴 점검은 작업을 나누어 실행하세요.
- **MCP 실제 응답 확인 / 복구 판단**이 정상이라면 기존 OpenCode의 `/mcp`에서 hexstrike를 껐다 켭니다. 실행 중 창에 새 설정이 반영되지 않으면 OpenCode를 종료하고 다시 열어 이전 대화를 이어갑니다. 서버 자체 HTTP가 실패할 때만 실행 중 작업과 결과를 확인하고 관리 서버 재시작을 고려합니다. 시간 초과된 점검을 자동 재실행하지 않습니다.
- 시스템 작업 폴더에는 MCP 실패 시 로컬 정찰로 대체하지 않는 지침과 `bash`/`webfetch` 차단 설정을 추가합니다. 새 설정은 OpenCode를 다시 열어 적용하세요. 기존 모델·별도 지침은 보존하며 프로젝트 설정 변경 전 백업합니다.
- 수동·자동 웹 점검을 함께 기록하려면 **웹 프록시 + 시스템 펜테스트**를 선택하세요. Burp 초기 프로젝트 화면을 완료하고 **Intercept Off**로 둡니다. **수동:** Burp의 **Proxy → Intercept → Open browser**로 접속합니다. 일반 Edge/Chrome은 Burp 프록시와 HTTPS CA를 별도로 설정해야 합니다.
- **자동:** OpenCode가 HexStrike의 명령 실행 기능으로 관리 `web-tools.py`를 사용합니다. curl, ffuf, gobuster, nikto, sqlmap, nuclei, httpx, katana, whatweb에 명시적으로 Burp 프록시를 전달합니다. 설치된 지원 도구만 사용하며 미지원 도구나 연결 실패는 직접 연결로 대체하지 않습니다. 일반 HexStrike 웹 도구를 프록시 설정 없이 실행하면 Burp 기록을 보장할 수 없습니다.
- WSL NAT에서는 Windows → WSL의 loopback 역방향 릴레이로 Kali에서 Windows Burp에 연결합니다. 방화벽·시스템 프록시를 변경하지 않으며 CA는 관리 웹 도구 전용 번들에 저장합니다. **관리 환경 전체 종료** 시 릴레이도 종료합니다. Burp **Proxy → HTTP history**에서 양쪽 요청·응답을 확인하세요. Nmap의 TCP/UDP 포트 점검은 HTTP가 아니므로 이 기록에 나타나지 않습니다.

## 포함된 기능

- 관리자/계정 불일치 차단, 기존 설치 탐지 → 추가 설치 계획 → Windows 11 x64·가상화·용량 검사.
- winget 공식 패키지 식별자와 검증된 설치 경로 사용. 기존 설치는 자동 업그레이드하지 않음.
- WSL·VirtualMachinePlatform·WHPX 활성화, 자동 재부팅 없이 재실행으로 이어하기.
- 기존 Kali 비관리자 사용자와 HexStrike/OpenCode 경로·가상환경 재사용. 기본 사용자가 root인 신규 환경만 비관리자 `vulnchecker` 사용. 새 HexStrike 복제는 커밋 고정, 기존 소스는 checkout/업그레이드하지 않음.
- Kali 프로필별 자동 설치: 기본 apt 도구 41종(full), Frida/Objection, HexStrike/OpenCode. 설치·탐지 공통 목록은 `scripts/kali-tools.json`에서 관리하며, 기존 명령은 재사용하고 누락된 도구만 추가 설치합니다.
- 네트워크/패킷: Nmap, Masscan, tcpdump, tshark, netcat, socat, DNS/WHOIS. 웹/TLS: ffuf, sqlmap, nikto, nuclei, gobuster, feroxbuster, WhatWeb, wafw00f, testssl, sslscan, dirsearch, wfuzz.
- SMB/AD/암호 감사: enum4linux-ng, smbclient, smbmap, Impacket, NetExec, Hydra, John, Hashcat. 취약점 자료/프레임워크: SearchSploit, Metasploit. 모바일/리버싱: jadx, apktool, adb, apksigner, binwalk, radare2, gdb, YARA, strings, Frida/Objection.
- `extraKaliPackages`에 `seclists`, `wordlists`, `ghidra` 등 추가 apt 패키지를 지정할 수 있습니다. 일부 패키지 실패 시 나머지 설치를 계속하고 실패 목록을 표시합니다. 성공 후 `runtime/<PC-SID>/kali-tools-report.json`에 명령 경로와 apt 패키지 버전을 저장합니다. 자동 설치는 대상 스캔을 실행하지 않습니다.
- 기존 Google SDK/AVD 경로 탐지, 신규 SDK 다운로드 체크섬 검증. 기존 AVD 목록은 읽기만 하며 동적 검증용 전용 AVD를 별도로 준비. 기존 에뮬레이터 데이터 초기화 없음.
- Android 부팅·root·AVB/verity·remount·`/system` 쓰기 검증. 컨테이너 내부 ADB root 및 쓰기까지 확인.
- MobSF 이미지 ID 기록/재사용, loopback 서비스 공개, 분석 볼륨 유지, 관리 런타임 중지.
- PC·SID별 inventory.json/상태/로그, 동시 변경 작업 파일 잠금. 설치됨·미탐지·미확인을 구분하고 Docker 설치와 엔진/이미지 상태를 별도 표시.
- WSL_UTF8와 PowerShell 출력 디코더를 함께 설정하여 WSL 한글 오류 출력 보존. 작업 후 인코딩/환경 설정 복원.

## 지원 범위와 검증

인터넷 연결이 있는 Windows 11 x64가 기본 지원 범위입니다. Windows Enterprise의 AppLocker/WDAC/EDR, WSL 금지, 프록시, BIOS 잠금은 고객사 IT 정책에 따라 달라집니다. 정책·보안 제품을 해제하지 않습니다.

완전 망분리 설치 번들은 포함하지 않습니다. 승인된 Kali export TAR / Docker save TAR 입력은 지원하지만 Windows 설치 파일, SDK, apt/npm/pip 저장소 또는 사전 준비 이미지가 별도로 필요합니다. GUI의 실행정책 옵션은 해당 프로세스에만 적용되며 Group Policy를 우회하지 않습니다.

HexStrike가 광고하는 모든 도구를 설치하지는 않습니다. 선택 프로필의 명시된 도구를 설치하며 `/health` 응답에 전체 도구 누락이 남을 수 있습니다. MCP 활성화와 연결 검사는 자동화되며, AI 계정 인증과 실제 APK의 Frida·ABI·인증서 호환성은 사용자가 확인합니다.

테스트: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\SelfTest.ps1`. 설치·재부팅·대상 스캔 없이 설정 검증, 오류 전파, 상태 기록, 재부팅 분기, 의존성 실패, 동적 분석 실패 처리 및 기존 설치/용량/인코딩/재사용 회귀를 회귀 테스트로 검증합니다. 깨끗한 고객사 Windows 11 Enterprise에서 전체 설치/동적 분석 검증은 별도 파일럿이 필요합니다.

배포 ZIP: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Build-Package.ps1`. 명시된 소스/가이드 파일만 묶고 runtime·분석 데이터·캐시는 제외합니다. `dist\VulnChecker-Windows11-v5.zip` 및 SHA256 파일이 생성됩니다.

[상세 사용 가이드](docs/GUIDE.ko.html) · [공식 출처와 조건](docs/SOURCES.md)

## 모바일 앱 / 시스템(IP/URL) 실행

모바일 앱은 실행 탭 왼쪽의 순서대로 진행합니다. 기존 **4. 앱 가져오기** 탭도 그대로 유지합니다.

1. **앱 추출 / 루팅 기기 설치**: 4번 탭을 엽니다. Google Play 다운로드 기기, 실제 단말 또는 고객 APK를 선택합니다. 전체 base/split APK를 추출하고 원본 서명·해시·ABI·minSdk를 확인한 뒤 분석 기기에 함께 설치합니다. 기본 **설치 후 앱 실행 확인**을 선택하면 Frida 우회 JS를 주입하고 실행합니다.
2. **설치 앱 찾기 / 새로고침**: 루팅 분석 기기의 사용자 앱 목록에서 대상 앱을 선택합니다. 출처 기기 목록과 분석 기기의 대상 목록은 별개입니다. APK 세트 설치가 완료되면 대상 앱과 분석 기기 목록도 갱신합니다.
3. **MobSF 정적 / 동적 분석** 또는 **앱 API 분석(Burp)**: MobSF는 선택한 앱의 base APK를 전달해 정적 보고서를 열고, Dynamic Analyzer에서 같은 앱을 분석합니다. 앱 API는 선택한 앱을 Frida로 실행하고 Android → Burp → API 서버로 직접 수집합니다. 두 수집 모드는 같은 AVD에서 한 번에 하나만 사용합니다.
4. **모바일 앱 펜테스트 연결**: 선택한 앱의 현재 설치 APK 전체를 다시 확보하고 서명·해시를 검사해 Kali의 `~/work/vulnchecker/mobile/<package>/apks`에 준비합니다. MCP 명령 실행으로 선택 기기의 앱 APK 경로를 확인한 뒤 모바일 전용 OpenCode 창을 엽니다. `MOBILE_TARGET.md`와 `target.json`에 대상·APK·ADB·현재 통신 경로를 기록합니다.

HexStrike는 앱 UI에 자동으로 붙는 도구가 아닙니다. APK 파일은 jadx/apktool 등으로 점검하고, 모바일 작업 폴더의 `./adb-target`은 Windows SDK ADB를 통해 `emulator-5554`에 연결합니다. 실제 API 펜테스트에는 Burp에서 내보낸 대상 요청/응답 또는 MobSF 결과, endpoint와 인증 조건을 제공해야 합니다. 모바일 연결 검사는 읽기 전용 `pm path`만 수행하며 취약점 점검은 OpenCode에서 범위를 정해 시작합니다. 루팅 우회 주입은 모바일 메뉴의 **루팅 우회 후 앱 실행**에서 수행합니다.

**시스템(IP/URL) 펜테스트 실행**은 Android/Burp/MobSF를 요구하지 않습니다. IP 또는 HTTP/HTTPS URL을 입력하거나 열린 OpenCode에서 지정합니다. 모바일 창과 별도로 CMD를 열고 `~/work/vulnchecker/system`을 사용합니다. **웹 프록시 + 시스템 펜테스트**는 Burp도 준비합니다. 모바일 APK/ADB 자료는 시스템 작업 폴더에 전달하지 않습니다. AI 계정은 OpenCode `/connect`에서 연결합니다.

준비 작업 중에도 **3. 연동 결과 → 관리 환경 전체 종료**로 취소할 수 있습니다. 작업 완료·실패·종료 후 실행 버튼이 다시 활성화됩니다. 앱 또는 Frida 우회 세션 종료는 자동으로 감지하여 분석 상태를 **중지됨**으로 갱신합니다. 도커 응답 검사에는 개별 시간 제한이 있으며, 이미 실행 중인 Docker Desktop을 중복으로 시작하지 않습니다. 설치 등록 손상이나 시작 충돌은 실제 원인과 로그 위치를 표시합니다.

CLI 예시:

```powershell
.\VulnChecker.ps1 -Action Launch -Tool RefreshAnalysisApps
.\VulnChecker.ps1 -Action Launch -Tool MobileApi -Package com.company.app
.\VulnChecker.ps1 -Action Launch -Tool MobSfAnalysis -Package com.company.app
.\VulnChecker.ps1 -Action Launch -Tool MobileAI -Package com.company.app
.\VulnChecker.ps1 -Action Launch -Tool SystemAnalysis -Target https://example.com
```

`PenTest`는 시스템 펜테스트의 호환 별칭입니다. Burp 포함 실행은 `WebProxyTest`입니다. `RootBypass -Package ... -CaptureRoute Preview`는 통신 경로 없이 설치 앱 실행을 확인합니다. MobSF의 Spawn & Inject는 루팅 JS load 후 resume하며 앱이 종료될 때까지 후크를 유지합니다. 에너지플러스 8.9/versionCode 234의 루팅 검사 5개는 확인된 전용 프로필을 사용합니다. 다른 앱은 앱별 후크가 필요할 수 있습니다.

## Google Play 다운로드 및 앱 가져오기

Google Play는 다운로드 전용 비루팅 AVD `VulnChecker_Play_API30` (`emulator-5560`)에서 사용합니다. 분석용 AVD `VulnChecker_API30` (`emulator-5554`)와 계정을 분리합니다. 분석용 Google 계정 로그인과 앱 설치는 다운로드 기기에서 직접 진행합니다. 앱 가져오기는 APK만 복사하며 Google 계정, 비밀번호, 앱 사용자 데이터를 분석 기기에 복사하지 않습니다. **다운로드 계정·앱 초기화**는 확인 후 다운로드 기기의 데이터만 초기화합니다.

배포 ZIP은 Build-Package.ps1의 명시된 소스/가이드 목록만 포함합니다. APK, 고객 자료, runtime, 캐시, 인증 정보는 포함하지 않습니다. 현재 작업 폴더에서 Start.cmd를 실행하세요. 예전 ZIP을 같은 폴더에 덮어 풀면 메뉴/구현 코드가 이전 버전으로 돌아갈 수 있습니다.
