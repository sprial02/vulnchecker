# 2026-10-05 설치 실패 원인과 수정

## 두 번째 실행에서 확인한 SDK 패키지 누락

12:45:32 로그에서 Docker와 MobSF 이미지 다운로드는 정상 완료했습니다. Android SDK 압축 해제도 통과했지만 플랫폼과 시스템 이미지가 설치되지 않았습니다. 전체 activity.log에는 `Package platforms not found.`, `Package android-30 not found.`, `Package system-images not found.`, `Package google_apis not found.`가 남아 있습니다.

새 Google command-line tools 23.0.0의 sdkmanager.bat은 Android CLI로 전달하기 전에 batch SHIFT로 인수를 읽습니다. Windows PowerShell 5.1이 전달한 따옴표 없는 세미콜론 패키지 ID가 batch 인수 분리로 훼손됐습니다. 플랫폼 도구/에뮬레이터는 세미콜론이 없어 설치됐고, Android CLI는 일부 패키지 조회 실패에도 성공 종료 코드를 반환했습니다.

수정본은 요청 패키지 ID를 UTF-8 파일에 한 줄씩 기록하고 sdkmanager의 `--package_file`로 전달합니다. SDK 출력에 패키지 조회 실패가 있으면 성공 종료 코드라도 실패로 처리합니다. AVD 생성 전 adb/emulator/android.jar/system.img가 실제로 설치되었는지도 확인하며, 누락 시 패키지 ID와 파일 경로를 표시합니다. 이미 설치된 에뮬레이터와 플랫폼 도구는 재다운로드하지 않습니다.

현재 Android CLI 공식 안내: https://developer.android.com/tools/agents/android-cli

수정본으로 이 PC에서 누락된 Android 30 플랫폼과 Google APIs x86_64 시스템 이미지를 설치하고 `VulnChecker_API30` AVD를 생성했습니다. 12:54:33에 WHPX 가속 사용 가능 및 Install-Android 성공 종료(0)를 확인했습니다. Windows PowerShell 5.1 회귀 검사 84개 통과. 에뮬레이터 부팅과 앱 동작 검증은 별도입니다.

첨부 로그에서 Kali/Python/OpenCode 설치는 완료되었습니다. 실패는 Android SDK 압축 해제와 Docker 엔진 준비 단계입니다.

## Android SDK

실패한 JAR 전체 경로는 277자입니다. 배포 폴더 이름 + 컴퓨터/SID별 runtime/cache + 임시 폴더 + SDK 내부 경로가 Windows PowerShell 5.1의 기본 경로 한계를 넘었습니다. 다운로드 자체의 실패가 아닙니다.

- SDK 폴더 바로 아래의 짧은 임시 폴더에서 ZIP을 풉니다. 배포 폴더 이름과 SID 길이가 압축 해제 경로에 영향을 주지 않습니다.
- ZIP 안의 경로와 최종 설치 경로 길이를 먼저 확인하고, 너무 길면 `config.json`의 `existing.sdkRoot`에 `D:\Android\Sdk` 같은 짧은 위치를 지정하라는 오류를 표시합니다.
- 압축 해제 완료 후 sdkmanager/avdmanager/source.properties를 확인하고 최종 폴더로 옮깁니다. 실패 시 해당 작업의 임시 폴더만 정리합니다. 기존 SDK 폴더는 덮어쓰거나 삭제하지 않습니다.
- Google 공식 SHA1 확인과 ZIP 캐시 재사용은 유지합니다.

Windows 경로 제한과 긴 경로 지원 조건: https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation

## Docker / MobSF

기존 코드는 `docker info` 실패 후 특정 Docker 레지스트리 키가 없으면 즉시 설치 손상으로 판정했습니다. 첨부 로그만으로 실제 Docker 설치 손상을 확정할 수 없습니다. 사용자별 설치와 설치 방식에 따라 등록 위치가 달라질 수 있습니다.

- 키 누락을 진단 로그로 남기고, 실행 파일과 실제 Linux 엔진 응답을 확인합니다.
- Desktop이 이미 실행 중이면 재사용하고, 없으면 한 번 시작하여 제한 시간 내 준비를 기다립니다.
- 현재 시작 시도의 backend crash가 발견되면 실제 이유와 로그 위치를 표시합니다. 과거 충돌 로그와 잘못된 날짜 문자열은 현재 실패로 판정하지 않습니다.
- 실제 설치 손상은 앱 코드 수정으로 복구되지 않습니다. 같은 오류가 다시 발생하면 표시된 Docker backend 로그를 확인하고 공식 설치 프로그램으로 복구해야 합니다. WSL 배포판, Docker 볼륨 및 분석 데이터는 삭제하지 마세요.

Docker 공식 설치 안내: https://docs.docker.com/desktop/setup/install/windows-install/

## 다시 실행

기존 배포 폴더의 `lib\Install.ps1`을 수정본으로 교체한 뒤 `Start.cmd` → **자동 설치 / 이어하기**를 실행하세요. 같은 Windows 계정과 기존 `runtime` 폴더를 유지해야 다운로드 캐시와 설치 상태를 재사용합니다. 새 ZIP을 별도 폴더에 풀 경우 Windows/WSL 기존 프로그램은 재사용하지만 이전 폴더의 ZIP 캐시는 자동 이동되지 않습니다.

SDK ZIP이 정상이며 최종 SDK 경로가 짧다면 재다운로드 없이 압축 해제를 다시 진행합니다. Kali 완료 항목은 기존 설치를 확인해 재사용합니다. 부분 생성된 `cmdline-tools\latest`가 있다면 로그에 표시된 해당 폴더만 다른 이름으로 옮기고 재시도하세요.

전체 설치·Docker 이미지 다운로드 성공 여부는 실제 설치 재실행으로 확인해야 합니다. 오프라인 회귀 검사는 Windows 설정이나 설치된 프로그램을 변경하지 않습니다.
