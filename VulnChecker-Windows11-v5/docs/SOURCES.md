# 공식 출처 (2026-10-03 확인)

- [Microsoft WSL 설치](https://learn.microsoft.com/windows/wsl/install), [명령](https://learn.microsoft.com/windows/wsl/basic-commands), [기업 배포/export/import](https://learn.microsoft.com/windows/wsl/enterprise).
- [Microsoft 공식 WSL 진단 스크립트](https://github.com/microsoft/WSL/blob/master/diagnostics/collect-wsl-logs.ps1): WSL_UTF8 및 콘솔 UTF-8 디코딩을 함께 설정하는 출력 처리 참고.
- [Microsoft WinGet 설치 및 새 계정 등록](https://learn.microsoft.com/en-us/windows/package-manager/winget/): 새 계정의 App Installer 등록 및 Microsoft.WinGet.Client / Repair-WinGetPackageManager로 누락된 설치 도구를 자동 준비.
- [Android 환경변수와 AVD 검색 경로](https://developer.android.com/tools/variables): ANDROID_HOME / ANDROID_AVD_HOME / 기본 사용자 경로 탐지 참고.
- [Kali WSL](https://www.kali.org/docs/wsl/wsl-preparations/).
- [Docker Desktop Windows 설치/약관](https://docs.docker.com/desktop/setup/install/windows-install/). 기업 규모가 250명 초과 또는 연매출 1,000만 달러 초과인 상업적 사용은 유료 구독 필요. 고객사 적용 조건은 고객사 담당자가 확인.
- [Burp 설치](https://portswigger.net/burp/documentation/desktop/getting-started/download-and-install).
- [Android SDK manager](https://developer.android.com/tools/sdkmanager), [AVD manager](https://developer.android.com/tools/avdmanager), [WHPX 가속](https://developer.android.com/studio/run/emulator-acceleration). 기존 cmdline-tools의 avdmanager 경로 사용; 향후 도구 변경 시 업데이트 필요.
- [Google SDK 저장소 메타데이터](https://dl.google.com/android/repository/repository2-1.xml). Windows command-line ZIP의 공식 SHA1을 검증하고 자체 SHA256을 기록. SDK 패키지는 sdkmanager가 관리.
- [MobSF 공식 저장소](https://github.com/MobSF/Mobile-Security-Framework-MobSF), [Docker 실행](https://github.com/MobSF/docs/blob/master/running_mobsf_docker.md), [동적 분석 조건](https://github.com/MobSF/docs/blob/master/dynamic_analyzer_docker.md), [Windows AVD 준비 예](https://github.com/MobSF/Mobile-Security-Framework-MobSF/blob/master/scripts/start_avd.ps1). 루트 가능한 Play Store 없는 Android 11/API 30 이하 AVD 필요. 구현은 전용 AVD에서만 준비 절차를 수행하며 wipe-data는 사용하지 않음.
- [HexStrike 공식 저장소](https://github.com/0x4m4/hexstrike-ai), [고정 커밋](https://github.com/0x4m4/hexstrike-ai/tree/d689933ff579d839c676c82b231f8e98326c5f04). Python 의존성 설치; Flask 서버 loopback 강제 wrapper; 클라이언트 MCP 생성. 자체 설치 대상 목록 외 모든 도구 설치를 보장하지 않음.
- [OpenCode 설치](https://opencode.ai/docs/), [MCP 설정](https://opencode.ai/docs/mcp-servers/). WSL에서 npm 패키지를 설치; 전용 프로젝트에 로컬 MCP 설정을 생성.
- [winget 공식 매니페스트](https://github.com/microsoft/winget-pkgs): `PortSwigger.BurpSuite.Community`, `Microsoft.OpenJDK.21`, `Docker.DockerDesktop`. winget이 다운로드 체크섬을 검증하며 hash 무시 옵션은 사용하지 않음.

고정되는 것은 HexStrike 소스 커밋과 설치 시 기록된 MobSF 이미지 ID입니다. apt/pip transitive dependencies, SDK 최신 command-line tools, 기본 OpenCode latest, winget 미지정 버전은 설치 시점의 저장소에 따라 달라집니다. 완전한 버전 잠금/오프라인 재현 빌드는 아닙니다. 조직에서 승인한 버전은 config의 wingetVersions/opencodeVersion/mobSfImage digest로 지정하고, Kali/SDK는 승인된 이미지/캐시로 별도 관리하세요.

- [Standalone Java Windows 설치](https://learn.microsoft.com/java/openjdk/install), [Burp Android proxy](https://portswigger.net/burp/documentation/desktop/mobile/config-android-device), [Android emulator 실행 옵션](https://developer.android.com/studio/run/emulator-commandline).
- [Burp 명령줄 실행](https://portswigger.net/burp/documentation/desktop/troubleshooting/launch-from-command-line), [프로젝트/config-file 설명](https://portswigger.net/blog/introducing-burp-projects). Community 전체 프로젝트 화면 생략을 보장하지 않으며 --config-file로 설정 선택 단계만 줄입니다.
- [Frida Android 공식 안내](https://frida.re/docs/android/), [공식 서버 릴리스](https://github.com/frida/frida/releases/tag/16.7.19). 실제 Android 11 x86_64 spawn/Java 후크 검사로 16.7.19 호환성을 확인했습니다. MobSF의 FridaServerUpdater/Environment 및 upstream proxy 설정은 실행 이미지의 공식 소스를 확인해 사용했습니다.
