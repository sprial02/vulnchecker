# IBM TriGuard AI UI 및 명령어 사용 가이드

이 문서는 **v7.2.0**의 화면과 `VulnChecker.ps1`을 기준으로 작성했습니다. Windows 11 x64에서 프로그램 폴더의 `Start.cmd`를 실행하면 UI가 열립니다. 예제의 패키지명, 주소, 파일 경로는 실제 대상에 맞게 바꾸세요.

## 1. 처음 사용할 때

1. 프로그램 폴더 전체를 압축 해제하고 `Start.cmd`를 실행합니다.
2. **⑥ AI 설정**에서 사용할 API 키와 시작 모델을 저장합니다. AI 분석을 사용하지 않는 인프라 점검에는 AI API 키가 필요하지 않습니다.
3. **① 설치**에서 약관 확인란을 선택하고 **자동 설치 / 이어하기**를 누릅니다. 필요한 실행 버튼을 먼저 눌러 해당 기능의 누락 도구만 준비할 수도 있습니다.
4. 관리자 권한 요청이 나오면 같은 Windows 계정으로 진행합니다. 재부팅 필요 안내가 나오면 재부팅한 뒤 같은 버튼으로 이어갑니다.
5. 모바일·웹/시스템은 **② 실행 / 연동**, 서버 점검은 **⑦ 인프라 점검**에서 진행합니다.
6. **③ 연동 결과**와 아래 로그에서 작업 상태를 확인하고, 점검 후 **⑧ 레포트**에서 결과를 정리합니다.

### 탭 한눈에 보기

| 탭 | 용도 |
| --- | --- |
| ① 설치 | 기존 환경 확인, 도구 설치 및 설치 검증 |
| ② 실행 / 연동 | 모바일 분석, 웹·시스템 펜테스트 도구 실행 |
| ③ 연동 결과 | 서비스별 연결 결과와 오류 확인, 관리 환경 종료 |
| ④ 앱 가져오기 | Google Play·실제 단말·고객 APK에서 분석용 앱 확보 |
| ⑤ APK 보관함 | 확보한 base/split APK 세트 보관 및 재사용 |
| ⑥ AI 설정 | API 키와 시작 모델 저장 |
| ⑦ 인프라 점검 | 서버 등록, 접속 확인, 점검 및 재실행 |
| ⑧ 레포트 | 결과 동기화, 보고서와 원본 증적 ZIP 추출 |

화면 오른쪽 위 **화면 테마**에서 다크/밝게를 선택할 수 있습니다. 위쪽 연결 표시는 녹색=연결, 빨강=실패, 노랑=확인 중, 회색=미확인·종료입니다. 연결 성공은 취약점 점검 완료를 의미하지 않습니다. 설치 진행률은 완료한 단계 수 기준이며 다운로드 비율이나 남은 시간이 아닙니다.

## 2. 탭별 메뉴 설명

### ① 설치

| 메뉴 | 사용 방법 |
| --- | --- |
| 기존 설치 / 사전 확인 | 기존 도구, 가상화, 용량 등 설치 조건을 조회합니다. 설치는 수행하지 않습니다. |
| 자동 설치 / 이어하기 | 약관 확인 후 누락된 구성 요소를 설치합니다. 재부팅·실패 후 같은 버튼으로 이어갑니다. |
| 설치 상태 확인 | 구성 요소의 설치·준비 상태를 검증합니다. |
| 설정 파일 | 설치 경로와 프로필 등을 담은 설정 파일을 엽니다. |
| 사용 가이드 | 기존 HTML 상세 가이드를 엽니다. |

기존 설치와 분석 데이터를 재사용합니다. `미탐지` 또는 `미확인`이 표시되면 아래 로그에서 원인을 확인하세요.

### ② 실행 / 연동

**모바일 앱 · APK / 앱 API** 영역은 앱 확보 → 대상 앱 선택 → 통신 분석 → AI 연결 순서입니다.

| 메뉴 | 사용 방법 |
| --- | --- |
| ① 앱 추출 / 루팅 기기 설치 | ④ 앱 가져오기 탭으로 이동합니다. |
| ② 설치 앱 찾기 / 새로고침 | 분석 기기에 설치된 사용자 앱을 조회합니다. 이후 `대상 앱`을 선택합니다. |
| ③ MobSF 정적 / 동적 분석 | 선택 앱의 base APK로 정적 보고서를 열고 동적 분석을 준비합니다. MobSF 화면에서 분석을 진행합니다. |
| ③ 앱 API 분석 (Burp) | 선택 앱을 Frida로 실행하고 Android → Burp → API 서버 경로로 통신을 수집합니다. |
| ④ 모바일 앱 펜테스트 연결 · OpenCode + HexStrike | 앱 APK와 기기 정보를 준비하고 모바일 전용 OpenCode 창을 엽니다. |
| 루팅 우회 후 앱 실행 | 통신 분석 없이 선택 앱의 실행을 확인합니다. 앱별로 추가 우회가 필요할 수 있습니다. |
| 우회 세션 종료 | 실행 중인 루팅 우회 세션을 종료합니다. |

MobSF와 Burp 수집은 같은 분석 기기에서 한 번에 하나씩 사용합니다. 모바일 AI 연결 후에는 실제 분석 범위를 지정하고 필요한 API 요청·응답, 인증 조건을 제공합니다.

**시스템 · IP / URL** 영역에서는 대상 주소를 입력하거나 열린 OpenCode에서 대상을 지정합니다.

| 메뉴 | 사용 방법 |
| --- | --- |
| 시스템(IP/URL) 펜테스트 실행 | Kali·HexStrike·OpenCode를 준비하고 시스템 분석 창을 엽니다. |
| 웹 프록시 + 시스템 펜테스트 | Burp를 함께 실행해 웹 요청·응답을 기록할 수 있도록 준비합니다. |
| MCP 실제 응답 확인 / 복구 판단 | MCP에서 HexStrike를 거쳐 명령 결과가 돌아오는지 검사합니다. |
| 바이너리 분석 도구 추가 설치 | 선택 환경에 angr/pwntools 등 바이너리 분석 도구를 추가합니다. |

웹 기록을 확인하려면 Burp 초기 프로젝트 설정을 완료하고 **Intercept Off**로 둡니다. 수동 접속은 **Proxy → Intercept → Open browser**, 기록 조회는 **Proxy → HTTP history**를 사용합니다. 자동 점검은 관리 `web-tools.py`를 사용하는 흐름에서 프록시를 전달합니다. 프록시 설정 없는 도구의 요청이나 TCP/UDP 점검은 Burp HTTP 기록에 나타나지 않을 수 있습니다.

### ③ 연동 결과

표의 **서비스 / 연결**, **결과**, **확인 내용**, **검사 시간**에서 구성 요소별 상태를 확인합니다. 실패 시 확인 내용과 아래 로그를 함께 읽으세요.

**관리 환경 전체 종료**는 준비 작업을 취소하거나 이 프로그램이 관리하는 실행 환경을 종료할 때 사용합니다. MCP 연결만 정상이고 OpenCode가 응답하지 않으면 OpenCode의 `/mcp`에서 hexstrike 연결을 다시 켜고, 설정 변경 후에는 OpenCode를 다시 실행합니다.

### ④ 앱 가져오기

먼저 **앱 출처**, **기기 식별자**, **앱 패키지**를 확인합니다. 고객 APK 파일은 base와 split을 함께 선택합니다.

| 메뉴 | 사용 방법 |
| --- | --- |
| ① Google Play 기기 실행 | 다운로드 전용 기기를 엽니다. 기기에서 직접 Google 로그인 후 앱을 설치합니다. |
| ② 설치 앱 목록 새로고침 | 출처 기기의 설치 앱 목록을 읽고 가져올 패키지를 선택합니다. |
| ③ 가져오기 / 분석 기기 설치 | APK 전체 세트를 확보·보관하고 루팅 분석 기기에 설치합니다. |
| 고객 APK 파일 선택 | Windows에 있는 APK 파일을 선택합니다. split APK는 함께 선택합니다. |
| 다운로드 계정·앱 초기화 | 확인 후 다운로드 기기의 계정·앱 데이터를 초기화합니다. |
| 연결된 실제 단말 확인 | ADB로 연결된 실제 Android 단말의 식별자를 확인합니다. |

**설치 후 앱 실행 확인**을 선택하면 설치 후 루팅 우회 주입과 실행 확인을 수행합니다. 통신 분석은 이후 ② 탭에서 선택합니다.

- 다운로드 기기: `VulnChecker_Play_API30`, `emulator-5560` — Google Play용 비루팅 기기.
- 분석 기기: `VulnChecker_API30`, `emulator-5554` — 루팅 가능한 분석 기기.

APK 가져오기는 Google 계정이나 앱 사용자 데이터를 복사하지 않습니다. 실제 단말은 USB 디버깅을 허용하고 PC 연결 승인을 완료해야 합니다.

### ⑤ APK 보관함

| 메뉴 | 사용 방법 |
| --- | --- |
| 선택한 APK 세트 재사용 | 목록의 앱을 선택하면 ④ 탭에 전체 APK 세트를 채웁니다. 이후 `③ 가져오기 / 분석 기기 설치`를 누릅니다. |
| 보관 폴더 열기 | 선택 앱의 APK 파일과 메타데이터를 확인하거나 복사합니다. |
| 보관함 새로고침 | 저장된 APK 목록을 다시 읽습니다. |

APK는 `apk-library/<사용자 SID>/<추출 시각-ID>/`에 보관합니다. 분석 기기 설치나 실행이 실패해도 확보된 APK는 남습니다.

### ⑥ AI 설정

| 항목 / 메뉴 | 설명 |
| --- | --- |
| IBM ICA API KEY | 기본 AI 제공자 인증 키를 입력합니다. |
| DEEPSEEK API KEY | 예비 제공자를 사용할 경우 입력합니다. |
| 저장 키 삭제 | 해당 제공자의 기존 키를 삭제하려면 선택한 뒤 저장합니다. |
| 시작 모델 | 다음 OpenCode 실행에 사용할 모델을 선택합니다. |
| API 키 / 모델 저장 | 현재 Windows 계정으로 키를 암호화해 저장합니다. 빈 키 입력란은 기존 값을 유지합니다. |

설치 전에도 저장할 수 있습니다. 변경 후 열린 OpenCode와 전용 명령 창을 닫고 실행 버튼으로 다시 여세요. 토큰 소진 시 `/models`에서 DeepSeek를 수동 선택하며 자동 전환하지 않습니다.

### ⑦ 인프라 점검

#### 서버 등록 / 실행

서버 이름, 주소, 계정, OS/접속 종류, 포트와 인증 정보를 입력하고 **서버 저장**을 누릅니다. Linux/Unix는 SSH, Windows는 WinRM/PSRP를 사용합니다. 기본 접속 예는 SSH 22, WinRM/PSRP HTTPS 5986입니다.

| 메뉴 | 설명 |
| --- | --- |
| 새 서버 / 서버 저장 / 서버 삭제 | 새 입력 시작, 등록 정보 저장, 선택 등록 삭제. 서버 삭제는 등록 목록에서 제거하는 기능입니다. |
| 기존 서버 | 기존 Kali 인프라 환경의 서버 설정을 UI로 가져옵니다. |
| OS / Web·WAS / DB 구성 | 저장한 서버의 점검 프로필과 서비스 인스턴스 정보를 설정합니다. |
| OS / 서비스 자동 감지 | 선택 서버의 OS·서비스를 확인해 구성 설정에 활용합니다. |
| Ansible 설치 / 확인 | 인프라 점검 실행 환경을 준비합니다. |
| 접속 / 권한 확인 | 선택 서버의 인증과 점검 권한을 먼저 확인합니다. |
| 선택 서버 점검 / 전체 서버 점검 | 선택 대상 또는 전체 점검 포함 대상으로 점검합니다. |
| 가이드 | 인프라 상세 HTML 가이드를 엽니다. |

암호 입력란을 비워 저장하면 기존 암호를 유지합니다. sudo 암호 미등록 시 접속 암호를 사용합니다. **전체 점검에 포함**으로 일괄 점검 포함 여부를 정합니다. DB 점검은 해당 프로필과 승인된 DB 인증 정보를 구성하세요.

#### 점검 결과 / 재실행

| 메뉴 | 설명 |
| --- | --- |
| 결과 폴더 열기 | 선택한 점검 회차의 원본 결과와 증적을 엽니다. |
| 실패 서버 전체 재실행 | 선택 회차에서 수행에 실패한 서버를 다시 실행합니다. |
| 선택 실패 서버 재실행 | 실패 서버 행의 선택 칸을 체크한 후 실행합니다. |
| 결과 새로고침 | 점검 이력과 결과 표시를 갱신합니다. |
| 담당자 확인용 실패 CSV | 실패 원인 확인용 `failures.csv`를 엽니다. |

**취약 판정**과 **수행 실패**는 다릅니다. 취약 항목은 결과 검토·조치 대상이며, 재실행 메뉴는 접속 오류 등으로 수행에 실패한 서버를 대상으로 합니다.

#### 대량 등록 / 실행 설정

| 메뉴 / 항목 | 설명 |
| --- | --- |
| CSV 양식 저장 | 빈 양식과 작성 안내 파일을 저장합니다. |
| CSV 일괄 등록 | 작성한 UTF-8 CSV로 여러 서버를 등록합니다. |
| 동시 작업 수 / 배치 서버 수 | 동시에 실행할 작업 수와 한 배치의 서버 수를 지정합니다. 시작값은 동시 20 / 배치 100입니다. |
| 고객 실행본 저장 | 고객 서버에서 직접 실행할 점검 도구와 설명서 ZIP을 저장합니다. |
| 고객 실행 결과 가져오기 | 고객에게 받은 결과 ZIP을 점검 이력과 보고서 데이터에 연결합니다. |

CSV 필수 항목은 `Host`, `User`, `Connection`, `Platform`, `Port`와 인증 정보입니다. 작은 규모로 접속을 먼저 검증한 뒤 확대하세요. 고객 실행본 사용법은 [고객 자체 점검 안내](CUSTOMER-OFFLINE.ko.md)를 참고하세요.

### ⑧ 레포트

고객사명·작성 담당·점검 기간·대상 범위를 입력하고 **종류**와 **결과**를 선택합니다. 본문 상세 건수와 증적 이미지 포함 여부도 지정할 수 있습니다.

| 메뉴 | 설명 |
| --- | --- |
| 결과 동기화 | 기존 인프라·MobSF·분석 결과를 색인하고 RAW 보관함에 모읍니다. 최초 사용 시 보고서 전용 환경을 준비합니다. |
| JSON 가져오기 | 외부 점검 결과를 지원 JSON 형식으로 가져옵니다. |
| 항목 조회 / 다음 100건 | 선택 결과의 판정 항목을 100건씩 확인합니다. |
| DOCX 추출 | 선택 결과로 고객 보고서와 부록을 생성합니다. |
| 3종 서식 추출 | 모바일·웹·인프라 보고서 서식을 만듭니다. 점검 완료 결과를 의미하지 않습니다. |
| 보고서 폴더 / 목록 갱신 | 생성 파일을 열거나 선택 가능한 결과 목록을 갱신합니다. |
| 선택 RAW ZIP 저장 / RAW 보관함 | 선택 회차의 원본 증적을 ZIP으로 저장하거나 보관 위치를 엽니다. |

모바일·웹 상세 본문은 기본 30건, 최대 200건입니다. 인프라는 전체 서버 집계를 DOCX에, 서버별 항목 결과를 Excel에 담습니다. 전체 결과 CSV는 본문 제한과 별도로 생성됩니다. 실제 점검 결과 파일이 있어야 보고서에 반영되며 도구 연결이나 터미널 로그만으로 취약점 결과를 만들지 않습니다. JSON 형식과 출력물 설명은 [고객 보고서 안내](REPORTS.ko.md)를 참고하세요.

## 3. 명령어 셸에서 사용하기

### 실행 준비 및 기본 명령

아래 예제는 **Windows PowerShell 5.1**에서 프로그램 폴더를 기준으로 실행합니다. `D:\Code\...`는 현재 개발 폴더의 예시이므로 배포본에서는 압축을 푼 경로로 바꾸세요. GUI와 셸에서 변경 작업을 동시에 실행하지 말고 작업 완료를 기다립니다.

```powershell
Set-Location 'D:\Code\vulnchecker\VulnChecker-Windows11-v7.2.0'

# GUI 실행
.\Start.cmd

# 설치 계획 / 사전 확인 / 설치 검증 (조회)
.\VulnChecker.ps1 -Action Plan
.\VulnChecker.ps1 -Action Preflight
.\VulnChecker.ps1 -Action Verify

# 관리자 PowerShell: 약관을 확인한 후 전체 환경 설치 / 이어하기
.\VulnChecker.ps1 -Action Install -AcceptLicenses

# 기존 HTML 가이드 / 관리 환경 종료
.\VulnChecker.ps1 -Action Guide
.\VulnChecker.ps1 -Action Stop
```

스크립트 실행이 허용되지 않는 일반 환경에서는 프로세스 단위로 아래처럼 실행할 수 있습니다. 조직 정책이 차단하는 경우 담당자의 승인된 절차를 따르세요.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\VulnChecker.ps1 -Action Preflight
```

### 모바일 앱 확보와 분석

아래 명령은 필요한 작업을 순서대로 골라 실행합니다. Google Play 다운로드와 고객 APK 가져오기는 각각의 출처에 맞는 방법을 선택하세요.

```powershell
# Google Play 기기 실행 → 기기에서 로그인 및 앱 설치 → 목록 조회
.\VulnChecker.ps1 -Action Launch -Tool PlayDownload
.\VulnChecker.ps1 -Action Launch -Tool RefreshApps -SourceSerial emulator-5560

# Play 기기에서 앱 확보·설치·실행 확인
.\VulnChecker.ps1 -Action Launch -Tool AcquireApp -Package com.company.app -SourceSerial emulator-5560 -LaunchWithBypass

# 실제 단말 확인 (확인한 식별자를 AcquireApp의 SourceSerial에 지정)
.\VulnChecker.ps1 -Action Launch -Tool RefreshDevices

# 고객 APK 세트로 설치하는 경우
.\VulnChecker.ps1 -Action Launch -Tool AcquireApp -ApkPaths @('C:\Input\base.apk', 'C:\Input\split_config.arm64_v8a.apk') -LaunchWithBypass

# 분석 기기의 대상 앱 조회
.\VulnChecker.ps1 -Action Launch -Tool RefreshAnalysisApps

# 분석 목적에 맞게 하나씩 실행
.\VulnChecker.ps1 -Action Launch -Tool MobSfAnalysis -Package com.company.app
.\VulnChecker.ps1 -Action Launch -Tool MobileApi -Package com.company.app
.\VulnChecker.ps1 -Action Launch -Tool MobileAI -Package com.company.app

# 통신 분석 없이 앱 실행 확인 / 우회 세션 종료
.\VulnChecker.ps1 -Action Launch -Tool RootBypass -Package com.company.app -CaptureRoute Preview
.\VulnChecker.ps1 -Action Launch -Tool StopRootBypass
```

`-Package`는 앱 표시명이 아닌 Android 패키지 ID입니다. 실제 단말에서 가져오려면 `AcquireApp -Package ... -SourceSerial <단말 식별자>`를 사용합니다.

### 웹·시스템 분석

```powershell
# 시스템 분석 또는 Burp 포함 웹 분석 중 목적에 맞게 선택
.\VulnChecker.ps1 -Action Launch -Tool SystemAnalysis -Target https://example.com
.\VulnChecker.ps1 -Action Launch -Tool WebProxyTest -Target https://example.com

# 연결 응답 검사 / 선택적 바이너리 도구 설치
.\VulnChecker.ps1 -Action Launch -Tool CheckMcp
.\VulnChecker.ps1 -Action Launch -Tool BinaryAnalysisTools
```

`PenTest`는 `SystemAnalysis`의 호환 별칭입니다. 열린 OpenCode에서 점검 대상과 범위를 입력해 실제 분석을 시작합니다. `/exit`로 나온 전용 PowerShell 창에서는 `oc`로 이전 대화, `oc-new`로 새 대화, `oc --session ID`로 지정 대화를 엽니다. `/models`는 모델 선택, `/mcp`는 MCP 상태 확인에 사용합니다.

### 인프라 접속 확인·점검·재실행

먼저 ⑦ 탭에서 서버를 저장하세요. `Hosts`에는 등록한 서버의 이름(Alias)을 넣습니다. `-Target`은 이 작업에서 주소가 아닌 **JSON 요청 문자열**입니다.

```powershell
.\VulnChecker.ps1 -Action Infrastructure -Tool InfraInstall

$request = @{ Hosts = @('server-01'); RunId = '' } | ConvertTo-Json -Compress
.\VulnChecker.ps1 -Action Infrastructure -Tool InfraPreflight -Target $request
.\VulnChecker.ps1 -Action Infrastructure -Tool InfraRun -Target $request

# 전체 점검 포함 대상 실행: 빈 Hosts / 동시 20 / 배치 100
$request = @{ Hosts = @(); RunId = ''; Forks = 20; BatchSize = 100 } | ConvertTo-Json -Compress
.\VulnChecker.ps1 -Action Infrastructure -Tool InfraRun -Target $request

# 선택 회차의 실패 서버 재실행: RunId는 실제 점검 회차 ID로 교체
$request = @{ Hosts = @('server-01'); RunId = '실제-점검-회차-ID' } | ConvertTo-Json -Compress
.\VulnChecker.ps1 -Action Infrastructure -Tool InfraRetry -Target $request

# 고객 자체 점검 결과 ZIP 가져오기
$request = @{ Files = @('C:\Input\customer-result.zip') } | ConvertTo-Json -Compress
.\VulnChecker.ps1 -Action Infrastructure -Tool InfraOfflineImport -Target $request
```

재실행 시 `Hosts = @()`는 해당 회차의 실패 서버 전체를 대상으로 합니다. 회차 ID는 `runtime/<PC명>-<SID>/infra-runs/`의 결과 폴더에서 확인합니다. UI의 자동 감지 기능은 현재 최상위 CLI `-Tool` 허용 목록에 없으므로 UI에서 사용하세요.

고객 실행본은 압축을 푼 뒤 해당 서버에서 아래처럼 실행합니다. Unix는 Bash·Python 3.8 이상과 승인된 root/sudo 세션, Windows는 관리자 Windows PowerShell 5.1 이상이 필요합니다.

```bash
sudo bash ./Unix-Infrastructure.sh
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Windows-Infrastructure.ps1
```

### 보고서 생성

보고서 명령도 `-Target`에 JSON 요청을 전달합니다. 먼저 동기화하고, UI에서 결과를 선택하거나 아래 카탈로그에서 실제 `id`와 `kind`를 확인합니다.

```powershell
.\VulnChecker.ps1 -Action Report -Tool ReportSync

# 현재 PC / Windows 계정의 결과 목록 확인
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$runtimePath = Join-Path $PWD.Path ("runtime\{0}-{1}" -f $env:COMPUTERNAME, $sid)
Get-Content (Join-Path $runtimePath 'report-catalog.json') -Raw -Encoding UTF8

# SourceId와 Kind는 위 목록의 실제 결과에 맞게 교체
$request = @{
    Customer = '고객사명'; Author = '작성 담당자'
    Period = '2026-10-16'; Scope = '승인된 점검 범위'
    Kind = 'infra'; SourceId = '실제-결과-ID'
    DetailLimit = 30; IncludeImages = $false
} | ConvertTo-Json -Compress
.\VulnChecker.ps1 -Action Report -Tool ReportExport -Target $request

# 같은 결과 ID의 원본 증적 ZIP 저장
$request = @{ SourceId = '실제-결과-ID' } | ConvertTo-Json -Compress
.\VulnChecker.ps1 -Action Report -Tool ReportRawExport -Target $request

# 외부 JSON 결과 가져오기 (Kind: mobile / web / infra)
$request = @{ Kind = 'web'; File = 'C:\Input\findings.json' } | ConvertTo-Json -Compress
.\VulnChecker.ps1 -Action Report -Tool ReportImport -Target $request
```

API 키 저장, 서버 등록/CSV 가져오기, APK 보관함 선택은 UI를 사용하면 됩니다. 모든 화면 버튼에 동일한 CLI 명령이 있는 것은 아닙니다.

## 4. 결과 위치와 자주 겪는 상황

`runtime/<PC명>-<SID>/`는 현재 PC와 Windows 사용자별 작업 폴더입니다.

| 위치 / 상황 | 확인 방법 |
| --- | --- |
| `runtime/<PC명>-<SID>/infra-runs/` | 인프라 회차별 결과와 원본 증적 |
| `runtime/<PC명>-<SID>/reports/` | DOCX와 CSV·Excel 등 생성 부록 |
| `runtime/<PC명>-<SID>/raw-data/`, `raw-exports/` | 버전별 원본 보관함과 선택 회차 ZIP |
| `runtime/<PC명>-<SID>/report-results.sqlite3` | 로컬 보고서 결과 DB |
| 설치 후 재부팅 필요 | 재부팅 후 같은 계정으로 같은 설치/실행 버튼을 다시 선택 |
| 도구 실행은 됐지만 분석 결과 없음 | 열린 MobSF/OpenCode 등에서 실제 점검을 수행하고 결과 파일 생성 여부 확인 |
| 앱 설치 실패 | 패키지·ABI·split 세트와 로그 확인 후 ⑤ 보관함에서 재사용 |
| 인프라 수행 실패 | 접속·권한·프로필·실패 CSV 확인 후 실패 서버만 재실행 |
| 보고서 결과 목록이 비어 있음 | 결과 동기화 또는 지원 JSON 가져오기 후 목록 갱신 |

고객 전달 전에는 선택한 회차의 대상과 원본 증적의 민감정보를 확인하세요. 고객사명 입력은 결과 필터가 아닙니다. 프로그램 배포 ZIP은 고객 결과·APK·키·런타임을 포함하지 않으므로 결과 백업은 별도로 보관해야 합니다.

## 5. 상세 문서

- [기존 HTML 사용 가이드](GUIDE.ko.html)
- [인프라 UI 상세 가이드](INFRASTRUCTURE.ko.html)
- [고객 자체 점검 안내](CUSTOMER-OFFLINE.ko.md)
- [고객 보고서·JSON 형식·RAW 보관 안내](REPORTS.ko.md)
- [배포 안내](DEPLOY.ko.md)
