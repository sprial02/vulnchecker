### v7.0.1 Android → Burp CA 경로 수정 (2026-10-05)

- 첨부 로그에서 Burp 실행 이후 wslpath의 Windows D: CA 파일 경로 변환 실패 확인. 프록시 설정/ADB reverse 전에 중단하여 앞서 사용한 MobSF 직접 수집 설정이 남았음.
- Burp DER → PEM 및 Android subject_hash_old 계산을 Windows .NET에서 수행하여 Kali/Windows 드라이브 공유 의존 제거. 실제 Android 시스템 CA 파일의 내용도 비교한 뒤 프록시 준비 완료 표시.
- 실제 Burp CA 해시 9a5ba575 및 테스트 CA 해시 e8103a6b를 OpenSSL -subject_hash_old 결과와 비교해 일치 확인. Windows-only 회귀에서 WSL 호출 차단 및 PEM 재가져오기 지문 일치 검증.
- 실제 모바일 API 경로 성공: Android 127.0.0.1:8080, ADB reverse 8080, Burp CA 파일 내용 일치, 에너지플러스 8.9 Frida 후크 후 재실행. 에뮬레이터 → Burp → 로컬 MobSF 로그인 페이지에 식별 가능한 확인용 HTTP 요청 전달 및 응답 수신: vulnchecker-check=20261005155754. Burp UI history 및 앱의 모든 HTTPS/API 성공은 별도 확인.
- MobSF 단독 분석은 Burp를 거치지 않음. 첨부 로그의 MobSF 정적 scan 300초 timeout은 Burp CA 경로 실패와 별개이며 이번 변경 범위에 포함하지 않음.

### v7.0.0 한글 / Java 결과 저장 / 화면 표시 수정 (2026-10-05)

- Java 재설치 오류가 아닌 결과 파일 교체 실패 확인. 기존 Java 사용 로그 다음에 실패했으며, 읽기 핸들로 열린 JSON에 Move-Item -Force 실행 시 동일한 ‘파일이 이미 있으므로 만들 수 없습니다’ 오류 재현.
- state.json/connections.json 저장에 고유 임시 파일 + File.Replace 원자 교체 및 잠깐의 파일 잠금 재시도 적용. GUI는 삭제 공유가 허용된 Read-SharedText로 읽음. JSON과 PowerShell 배포 파일은 UTF-8 BOM 유지/정규화.
- 이전 UTF-8 BOM 없는 보조 스크립트가 남긴 알려진 깨진 Android SDK 행을 원본 백업 후 정리. 현재 정상 환경 설치 결과를 과거 행으로 덮어쓰지 않음.
- 실제 Java 및 Android SDK 단계 재검증 성공. 기존 JDK/SDK/이미지 재사용, WHPX 사용 가능, 환경 설치 완료로 갱신. 가이드 파일 자동 열기 제거; 사용 가이드 버튼은 명시적 열기에만 사용.
- 화면에 버전 7.0.0과 빌드 날짜 표시, 탭/작업 버튼 번호 ① 형식 적용. Windows PowerShell 5.1 회귀 88개 및 GUI smoke 통과. 생성된 GUI 화면에서 한글/버전/번호/배치 육안 확인.

### Kali 펜테스트 도구 자동 설치 확장 (2026-10-05)

- 공통 JSON 카탈로그로 설치와 명령 탐지 목록 통일: full apt 도구 41종, 프로필별 웹/시스템 및 모바일/리버싱 선택. Frida/Objection, HexStrike/OpenCode 기존 설치 경로와 연동 유지.
- 빠진 명령의 apt 패키지만 요청. 설치된 패키지 건너뛰기, 중복 제거, 다운로드 재시도 3회, 묶음 설치 실패 시 개별 설치를 계속한 뒤 실패 목록/종료 코드 4 반환. 성공 후 명령 재탐지 및 경로/패키지 버전 JSON 저장.
- 실제 Kali 기존 사용자 jhs 환경에서 testssl.sh, dirsearch, enum4linux-ng, adb, apksigner, yara 추가 설치 성공. HexStrike 소스와 Python/OpenCode 기존 설치 재사용, MCP 구성 완료. 13:52:15 kali-tools 완료 확인. 대상 스캔은 실행하지 않음.
- Windows PowerShell 5.1 회귀 86개와 Linux 모의 apt 검사 2개 통과: 프로필별 목록, 기존 설치 재사용, 성공 종료 후 미탐지 도구 실패 처리, 개별 apt 실패 격리, 기존 패키지 제외와 중복 제거. 실제 Kali 명령 44개 모두 탐지, 미탐지 0개. 결과는 최신 selftest 로그와 kali-tools-report.json에 저장.
- 실제 WSL 탐지 중 systemd 사용자 세션 경고가 JSON 파싱을 막는 문제 수정. JSON 응답만 분리해 읽고 경고는 로그에 남김. WSL 작업 시작 폴더를 /로 지정하여 Windows 드라이브 경로 변환 의존 제거.

### SDK 세미콜론 패키지 ID 설치 수정 (2026-10-05 두 번째 로그)

- 첨부 로그에서 MobSF 이미지 pull 및 Docker 엔진 준비 성공 확인. 전체 activity.log에서 SDK 패키지 ID가 분리되어 `Package platforms/android-30/system-images/google_apis not found`에 해당하는 개별 오류 확인.
- Google command-line tools 23.0.0 sdkmanager.bat의 batch 인수 파싱 확인. `--package_file`로 ID 보존, 성공 종료 코드의 패키지 조회 실패 감지, AVD 생성 전 필수 SDK 파일 존재 확인 추가.
- Windows PowerShell 5.1 회귀 84개 통과: 세미콜론 ID 파일 전달, 실패/성공 시 임시 파일 정리, 패키지 조회 실패와 실제 시스템 이미지 누락 시 AVD 차단 포함.
- 실제 누락된 Android 30 플랫폼 및 Google APIs x86_64 시스템 이미지 다운로드·설치 성공. 기존 emulator/platform-tools 재사용. `VulnChecker_API30` 생성 및 `WHPX(10.0.26300) is installed and usable` 확인, Install-Android 종료 코드 0. 에뮬레이터 부팅/앱 동작은 이번 검사 범위에 포함하지 않음.

### SDK 압축 해제 / Docker 준비 수정 (2026-10-05)

- 첨부 설치 로그의 277자 SDK 파일 경로 확인. 짧은 SDK 내부 임시 폴더 사용, ZIP 경로 및 최종 경로 사전 검증, 성공 후 이동과 실패 임시 폴더 정리 추가. 기존 Google 체크섬 및 다운로드 캐시 재사용 유지.
- Docker 특정 레지스트리 키 누락만으로 설치 손상을 단정하던 조기 중단 제거. 실제 Desktop/엔진 준비 확인 유지, 현재 시도의 backend crash 원인 보고 및 날짜 파싱 방어.
- Windows PowerShell 5.1 회귀 검사 81개 통과. 긴 배포 경로 재현, ZIP 경로 탈출 거부, 기존 SDK 보존, 키 누락 시 Desktop 시작/엔진 준비 포함.
- 작업 폴더에 캐시된 실제 Google command-line tools ZIP을 새 추출 함수로 정상 해제. 전체 환경 설치·Docker 시작·MobSF pull은 실행하지 않았으며 재실행 확인 필요.
- 원인 및 이어하기 절차: [INSTALL-FIX-20261005.md](INSTALL-FIX-20261005.md).

### 설치 진행률 표시 (2026-10-05)

- 설치 프로필별 단계 계획을 기록하고 완료한 단계 수로 전체 진행률 계산. 전체/모바일 9단계, 웹 5단계. 사전 확인·가상화·Windows 앱·Kali·Android·MobSF 단계명과 진행률 표시.
- 실패/재부팅 대기/중지는 100% 완료로 표시하지 않음. 설치 상태는 저장되어 화면을 다시 열어도 조회 가능. 새 설치 실행은 이전 실행 상태를 초기화하고 기존 설치 재사용 단계를 다시 확인.
- 설치 진행 막대와 현재 단계 표시, 기타 실행/연동 작업은 진행 애니메이션 표시. 화면 겹침 없이 로그 영역 조정.
- 자동 검사 79개 및 WinForms 화면 검사 통과. 실패 단계 제외, 재부팅 대기, 새 실행 초기화, 전체 완료 100%, 프로필별 분모, 저장된 진행률 및 작업 중 22% → 44% 갱신 확인.

### 새 PC 온라인 자동 설치 상세 (2026-10-05)

- WinGet 미설치를 사전 검사 차단 조건에서 제외. 새 계정의 App Installer 등록 → Microsoft 공식 NuGet/PSGallery/WinGet Client 복구 설치 → 실제 프로그램 설치 순서. 기존 설치 도구·프로그램 재사용.
- 모바일 전용 프로필에서도 앱 API 분석에 필요한 Burp 설치 포함. Docker가 아직 설치되지 않아 MobSF 이미지 상태가 미확인이더라도 실제 설치 단계에서 엔진 준비 및 이미지 다운로드 진행.
- 자동 설치 버튼을 설치 탭의 첫 번째·기본 버튼으로 배치. 설치 시작 시 연동 결과로 이동하고 각 단계의 진행/완료/실패를 표시. 재부팅 대기는 실패 대신 재부팅 필요로 표시. 설치 실패 화면에 단계명과 실제 오류 표시.
- Windows PowerShell 5.1 검사 77개 통과. 새 PC 첫 실행의 가상화 기능 설치/재부팅/이어하기 및 이후 Windows 앱·Kali·Android·MobSF 설치 호출을 모의 검증. WinGet 미설치 사전 검사 통과, 설치 도구가 아예 없는 경우의 자동 bootstrap, 기존 도구 재사용, 누락 앱의 실제 설치 명령 호출 검증 포함.
- WinForms 화면 검사: 자동 설치 버튼 기본 선택/약관 전달/설치 진행 탭 이동/작업 취소 후 버튼 복구 통과. 새 노트북에서 전체 온라인 다운로드·설치를 실제 수행한 결과는 아직 확인되지 않음.

### Docker 시작 실패 및 종료 상태 복구 상세 (2026-10-05)

- 현재 PC의 Docker Desktop 시작 실패: 설치 경로 레지스트리 누락, 엔진 ISO 파일 누락 및 이전 실행의 Secrets Engine 소켓 충돌 확인. 공식 서명된 동일 버전 4.92.0 복구 설치, 경로 등록 복구, 소켓 폴더 백업 후 정상 Linux 엔진 29.8.0 응답 확인. 기존 이미지/컨테이너/볼륨 유지.
- Docker 정보 조회는 최대 10초로 제한하고 전체 준비 제한 시간을 적용. 기존 Desktop 재사용, 시작 충돌 로그 및 프로세스 종료 조기 감지. 종료 작업은 Docker 엔진을 시작하지 않으며 원격 Frida 중지가 실패해도 로컬 세션 정리.
- GUI에서 작업 프로세스 갱신과 종료 코드 확인, 준비 중 전체 종료 버튼 허용, 취소한 작업의 일회성 Docker/ADB/WSL 자식 명령 정리. 완료/실패 후 실행 버튼 복구. 작업 잠금을 존중하여 외부 종료된 Frida 세션의 저장된 분석 상태를 중지됨으로 갱신.
- Windows PowerShell 5.1 자동 검사 71개 통과. 네이티브 명령 응답 제한, Docker 중복 실행 방지, 설치 등록 오류, 종료 상태 복구, 살아 있는 프로세스 식별 및 동시 작업 잠금 검증 포함.
- 기존 관리 MobSF 컨테이너 기동 및 HTTP 응답 확인 후 이전 중지 상태로 복귀. 분석 에뮬레이터가 닫혀 있어 에너지플러스 앱의 전체 Burp/Frida 재실행은 이번 검증에 포함되지 않음.

### 모바일 앱 / 시스템(IP/URL) 및 공유 AI 점검 메뉴 (2026-10-04)

- 실행 탭을 모바일 앱(APK/앱 API)과 시스템(IP/URL)의 두 그룹으로 구성. 모바일: MobSF, 앱 API+Burp, OpenCode+HexStrike APK/API, API 앱 재실행/우회 종료. 시스템: IP/URL OpenCode+HexStrike 직접 연결, Burp 포함 웹 프록시 점검.
- MobileAI와 SystemAnalysis는 같은 HexStrike HTTP/MCP 및 OpenCode 연결 검증을 재사용하고 OpenCode 명령 창을 준비. Android/MobSF/Burp 설정이나 실행 중인 Frida 세션을 변경하지 않음. 기존 PenTest 명령은 Burp 포함 웹 점검으로 유지.
- 모바일 AI에서 선택 패키지와 확보 앱이 일치하면 전체 APK 폴더의 Kali 경로를 결과에 표시. 대상 IP/URL, APK 또는 API 자료와 점검 범위는 OpenCode에서 지정하며 메뉴가 대상 스캔을 자동 실행하지 않음.
- 실제 HexStrike health가 약 5.3초 걸려 5초 curl 제한에 실패하던 문제 확인. 상태 확인 제한을 15초로 조정. 실제 SystemAnalysis에서 기존 서버 재사용, MCP 도구 150개 조회, OpenCode hexstrike connected, 대화형 명령 창 준비 성공.
- 실제 MobileAI에서 동일 MCP 도구 150개 및 OpenCode 연결 성공, 기존 명령 창 재사용, 확보한 에너지플러스 전체 APK 폴더의 /mnt/d 경로 안내 확인. 기존 analysis-mode=MobSf 및 dynamic-ready 유지. 대상 분석/스캔은 실행하지 않음.
- 최종 Windows PowerShell 5.1 회귀 61개 통과. 모바일 AI와 시스템 AI에 대한 실제 준비 검증 및 4개 탭 렌더링 완료. 소스와 실행 폴더 및 배포 ZIP 반영.
- GUI 4개 탭 렌더링과 두 그룹/메뉴 배치 검증. 회귀 검사는 모바일 통신 상태 유지, 시스템의 Burp/Android 비의존성, MCP 실패 시 명령 창 미실행 및 실패 상태, upstream health 대기 시간 포함.

### MobSF Spawn & Inject 초기 루팅 우회 및 세션 유지 (2026-10-04 20:54)

- MobSF 4.5.4의 기존 spawn은 앱을 먼저 resume하고, attach 대기와 JS의 1초 타이머 이후 루팅 후크를 주입함. 관리 MobSF에 검증된 메서드만 수정하는 AST 패처를 추가. 원본 백업, 중복 적용 방지, 알 수 없는 구현/수정된 패치 거부 포함.
- 루팅 우회 선택 또는 에너지플러스 패키지는 spawn → attach → 루팅 JS load → resume 순서 적용. 모니터/사용자 JS의 기존 지연과 RPC 지원 유지. 다른 전면 앱에 잘못 attach하지 않음. 주입 실패 시 해당 작업의 정지된 PID만 종료.
- 실제 API 요청에서 Gunicorn의 stdin EOF 때문에 즉시 unload되어 Java 후크가 적용되지 않던 두 번째 원인 재현. stdin 대신 Frida 세션 detached 이벤트를 기다려 앱 실행 중 주입 유지. 앱 종료/연결 해제 시 unload/detach 정리.
- 실제 MobSF `/api/v1/frida/instrument` (UI Spawn & Inject와 동일 instrument 처리)에서 기본 후크 미선택 상태로 에너지플러스 8.9/234 실행. HTTP 200, 루팅 프로필 설치, y6.a~e 5개 실제 호출과 false 결과, 20초 이후 PID 유지 확인. 루팅 차단 팝업 제거 및 앱 자체 신한 페이백머니 서비스 일시중단 공지 표시 확인. 로그인/결제 기능은 검증하지 않음.
- root_bypass + api_monitor를 함께 선택한 실제 요청도 HTTP 200, 루팅 검사 5개 호출, 20초 이후 PID 유지 확인. MobSF API monitor 로그 213,505바이트 생성 확인. 루팅 우회와 지연된 API 모니터의 동시 동작 검증.
- Windows PowerShell 5.1 기존 회귀 58개 통과. Python 오프라인 회귀 5개: 주입 순서, 일반 앱 체크박스/지연 분리, 실패 PID 정리, 다른 전면 앱 attach 방지, 패치 중복/변조/지원하지 않는 시그니처 검사.

# 검증 상태

2026-10-03 / 사용자 PC Windows 11 Pro x64 / Windows PowerShell 5.1. 깨끗한 고객사 Enterprise 전체 설치 검증은 별도입니다.

## 실제 실행 확인

- Android 11/API 30 Google APIs x86_64 전용 AVD 부팅, UID=0, AVB/verity, remount 및 /system 쓰기. 컨테이너 내부 ADB에서도 root/system 쓰기 확인.
- HexStrike loopback health, OpenCode MCP initialize/list_tools 150개 및 자체 hexstrike connected. 대상 검사와 AI 모델 호출은 수행하지 않음.
- MobSF HTTP 200 및 관리 데이터 볼륨 유지. 원본 이미지와 기존 분석 데이터 삭제 없음.
- Burp 8080 proxy/CA 응답. Android + Burp에서 Windows→WSL 경로 전달 오류 수정 후 시스템 CA 설치·reverse 및 에뮬레이터 실제 HTTP 응답 확인.
- Android→MobSF 1337→Burp 8080 upstream 구성, MobSF CA 내용 일치 확인. 이 경로로 Burp 내부 페이지와 PC의 MobSF 로그인 페이지 HTTP 응답 수신. Burp history에서 식별 가능한 vulnchecker-check 요청 전송. 앱 HTTPS/pinning 성공을 뜻하지 않음.
- Frida 17.18.0 ART helper assertion, 17.7.1 spawn 시 Unsupported Android linker 충돌 확인. 공식 기반 이미지에 Frida 16.7.19만 설치한 깨끗한 로컬 호환 이미지 생성, 동일 서버 배치. 고객 데이터를 이미지에 포함하는 docker commit은 사용하지 않음.
- Frida 16.7.19 x86_64 full access, 앱 목록/프로세스 조회 및 설정 앱 spawn/attach 성공. 실제 RootBypass 실행 경로로 Java JS 초기화 메시지 확인 후 테스트 세션 종료. MobSF 웹/ADB 및 프록시 연결 유지.
- MobSF 실제 Frida.get_script(root_bypass) 합성 결과에 추가 JS 포함 확인. 설정 앱에 이 스크립트를 주입하여 기본 root_bypass와 추가 Java 후크 메시지를 같은 세션에서 수신. 대상 APK의 분석 성공과는 구분.
- 대상 앱 진단: base APK 한 개, native .so 0개, 패키지별 MissingLibraryException/librealm-jni.so 누락. 전체 split 또는 universal APK 필요. 앱 정상 실행/우회 성공으로 기록하지 않음.

## 자동 검사

- PowerShell 32개 회귀 검사 통과: 설정·계정·네이티브 오류·재부팅·의존성·소유권·기존 설치·용량·UTF8·도구 재사용·AVD 조기 종료·MCP 실패·패키지 입력·누락 라이브러리 차단·프록시 응답·Frida 실패 처리.
- WinForms 설치/실행/연동 결과 렌더링 및 개별 행 표시 확인.
- Python/JavaScript 구문 및 ZIP 허용 목록 확인. runtime·고객 APK·로그·인증정보·캐시 제외.

## 남은 현장 검증

- 완전한 대상 APK/split 설치 후 앱 동작, root/native/에뮬레이터 탐지와 pinning 확인.
- 해당 APK의 MobSF 분석·보고서와 수동 JS 동시 동작. 동일 앱 재설치/재시작 시 수동 세션이 끊길 수 있으므로 순서대로 수행.
- Burp 새 프로세스 wizard: --config-file 구성은 적용했지만 기존 인스턴스 재사용으로 새 화면 생략 여부는 직접 재검증하지 않음. Community 전체 생략 지원은 주장하지 않음.
- 고객사 정책·프록시·망분리, 깨끗한 PC 전체 설치 및 재부팅 후 복구.

## v5 실행 흐름 변경 검증 (2026-10-04)

- PowerShell 회귀 37개 통과. 모바일/PenTest 준비 순서, 검사 후 대화형 창 열기, 오류 시 후속 미완료 및 창 열기 중단, 숨겨진 GUI worker, 기존 명령 창 재사용 추가 검증.
- WinForms 실행 탭에 두 가지 분석 메뉴만 있고 순서가 모바일 → Penetration Test인지 검사. 설치/실행/결과 탭 렌더링 확인.
- 신규 흐름 테스트는 모의 서비스로 수행했습니다. 실제 신규 서비스 시작 및 각 콘솔/에뮬레이터 창 표시 상태, 새 Burp 첫 실행 화면, 실제 대상 APK/PenTest 전체 수행은 이번 변경에서 검증하지 않았습니다.

### v5 MobSF 재시작 수정 (2026-10-04)

- 제출 로그: Frida 호환 이미지 전환 중 MobSF 브라우저 중복 열기, 새 컨테이너에서 /tmp/vulnchecker-chain.py 소실로 모바일 준비 실패 확인.
- Frida 복구 이후 upstream 설정/스크립트 복사/프록시 검사를 수행하도록 순서 변경. 내부 재시작에서는 브라우저를 열지 않고 모바일 연동 검사가 끝난 뒤 한 번만 열기.
- 회귀 검사 38개 통과. 컨테이너 교체 후 helper 복사 및 실제 전달 검사 단계 이후 브라우저 한 번 열기 회귀 추가.
- 현재 PC의 MobSF 컨테이너 → host.docker.internal:8080 → Burp 내부 페이지 HTTP 200 및 Burp 응답 확인. 현재 Burp listener는 :: 바인딩 상태였음.
- 별도의 임시 127.0.0.1:18081 listener에 대해 동일 컨테이너 → host.docker.internal:18081 HTTP 응답 확인. 이 PC에서 Docker Desktop이 loopback-only 호스트 서비스에 연결할 수 있음을 확인하고 임시 listener 종료. 실제 Burp 바인딩 설정은 변경하지 않음.
- 수정된 전체 모바일 준비 재실행 및 실제 APK 분석은 별도 검증 필요.
### 단계별 모바일 대상 연결 및 시스템 전용 CMD (2026-10-04)

- 작업 폴더에서 사라졌던 앱 가져오기와 관련 구현을 이전 작업 기록으로 복구. 기존 4. 앱 가져오기 탭 유지 및 모바일 실행 영역 바로가기 추가.
- 모바일 실행: 앱 추출/루팅 기기 설치 → 설치 사용자 앱 목록 갱신 및 선택 → 선택 앱 MobSF 정적/동적 또는 Burp API 분석 → 모바일 펜테스트 연결. 설치 완료 시 대상 목록과 선택 패키지를 함께 갱신. 설치되지 않은 패키지는 연결 준비 전에 거부.
- 실제 에너지플러스 8.9/234 APK 4개, 라이브러리 6개 추출·서명/해시 검사·전체 세트 재설치·Frida 루팅 검사 5개 적용 확인. 이번 추출 검증의 출처는 이미 앱이 설치된 분석 기기이며 새 Google 로그인/다운로드는 수행하지 않음.
- 모바일 펜테스트는 앱 APK 세트를 Kali mobile/<package>/apks에 복사하고 검증. Windows ADB를 연결하는 adb-target, MOBILE_TARGET.md, target.json 생성. HexStrike MCP execute_command로 선택 앱 pm path를 실제 조회하여 APK 경로 4개 반환 확인. 앱 데이터, 인증 토큰, 로그인·결제 작업을 수행하지 않음.
- 선택한 앱 base APK를 MobSF API에 전달해 실제 정적 보고서 b4345a8b17624db019f8e0dc1b30cc29 생성 및 해당 보고서 화면 열기 검증. 기기의 전체 split 세트는 유지. 동적 분석은 해당 앱의 Dynamic Analyzer에서 시작.
- 시스템(IP/URL)은 mobile 작업 폴더와 분리한 system 폴더 및 terminal-OpenCode-System 키 사용. 실제 모바일 powershell PID 9592와 별도 시스템 cmd PID 32116 확인. MCP 도구 150개 조회와 OpenCode 연결 성공. PenTest 호환 명령은 시스템 분석으로 변경; Burp 포함 시스템 점검은 WebProxyTest.
- Windows PowerShell 5.1 회귀 65개, MobSF Python 회귀 5개, GUI 4개 탭 렌더링/바로가기/대상 선택/메뉴 배치 통과. 모바일 대상 검증·준비 실패 시 MCP 미실행·별도 터미널/작업 폴더·IP/URL 검증 포함.
## v7.1.1 Burp 연결 수정 (2026-10-07)

- 기존 Community 2026.3.3과 새 통합 설치 2026.8을 비교하여 2026.8 경로 선택 확인. 사용자 지정 burpPath는 유지하고, 8080 응답 프로세스가 선택한 설치 경로와 같은지도 확인.
- Windows/WSL 릴레이에서 한 방향 EOF 때문에 응답을 취소하던 동작 수정. WSL localhost forwarding의 half-close 처리도 보완. 별도 loopback 포트에서 2 MiB 바이너리 응답 4회(클라이언트 half-close 2회 포함) 바이트 단위 일치 확인.
- 실제 Burp 2026.8 → Windows 8080 → Kali 18880 경로에서 Burp HTTP 응답 및 CA 다운로드·검증 성공. 같은 준비를 연속 2회 수행하여 릴레이 재사용 성공.
- PowerShell 회귀 91개 통과. 설치 버전 정렬 및 에디션 필터 회귀 포함. 외부 대상 스캔은 수행하지 않음.
