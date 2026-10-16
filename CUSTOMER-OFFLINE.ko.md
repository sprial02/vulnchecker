# 인프라 자체 점검 실행 및 결과 전달 안내

원격 접속 정보를 제공하기 어려운 경우, 서버 담당자가 해당 서버에서 직접 실행하는 점검 도구입니다. 인터넷 연결, Ansible, SSH·WinRM 접속 정보 또는 AI API 키가 필요하지 않습니다. 자동으로 결과를 외부에 전송하지 않습니다.

## 1. 전달받는 파일과 준비 사항

- Unix/Linux 서버: Unix-Infrastructure.sh 한 파일을 서버에 복사합니다. Bash와 Python 3.8 이상이 필요합니다. 시스템의 python3 명령으로 실행하며 필요한 프로그램을 자동 설치하지 않습니다. Python이 없거나 버전이 낮으면 서버 담당자가 승인된 방법으로 준비해야 합니다.
- Windows 서버/PC: Windows-Infrastructure.ps1 한 파일을 복사합니다. Windows PowerShell 5.1 이상과 관리자 권한이 필요합니다. 별도 Python은 필요하지 않습니다. PowerShell 7을 기본 셸로 사용해도 아래 명령의 powershell.exe로 실행하세요.
- README.ko.html을 브라우저로 열어 이 안내를 확인합니다. README.ko.txt도 동일한 내용입니다. 전달 시 라이선스와 Corresponding-Source.zip이 포함된 원래 배포 ZIP을 함께 보관하세요.
- 서버 담당자가 점검 권한, 실행 시각과 대상을 확인합니다. 결과를 저장할 디스크 공간을 확보하세요. 계정·설정·파일 목록 등 민감한 정보가 결과에 포함될 수 있습니다.
- 파일별 SHA256은 SHA256SUMS.txt에서 확인할 수 있습니다. 파일 해시는 변경 확인용이며 배포자 전자서명은 아닙니다.

## 2. Unix/Linux 실행

점검 서버에 파일을 복사하고 해당 폴더에서 승인된 root/sudo 세션으로 실행합니다. chmod 없이 bash로 실행할 수 있습니다.

```bash
sudo bash ./Unix-Infrastructure.sh
```

서버 이름 대신 IP를 결과 식별자로 남기고, 결과를 별도 경로에 저장하려면 다음처럼 실행합니다. 예제 IP는 실제 점검 서버의 IP로 바꾸세요.

```bash
sudo bash ./Unix-Infrastructure.sh --target-id 192.0.2.10 --output /var/tmp/triguard-results
```

기본 실행은 지원 OS를 자동 판별하고 표준 경로에서 확인한 Apache/Nginx/Tomcat 후보를 함께 점검합니다. Debian 계열, RedHat 계열, AIX, HP-UX, Solaris 프로필을 포함합니다. AIX/HP-UX/Solaris도 Bash/Python 3.8 이상 및 해당 항목이 사용하는 명령이 준비되어야 합니다. 실제 OS 버전·명령 호환성을 모두 보장하는 것은 아니며 환경이 맞지 않는 항목은 미완전/수동 확인 대상으로 검토해야 합니다. 미지원 OS를 Debian으로 임의 대체하지 않습니다.

OS만 지정하거나 자동 발견되지 않는 Web/WAS 설치 경로를 지정할 수도 있습니다.

```bash
sudo bash ./Unix-Infrastructure.sh --profile unix-redhat
sudo bash ./Unix-Infrastructure.sh --profile tomcat --instance-root /opt/tomcat
```

Unix OS 프로필: unix-debian, unix-redhat, unix-aix, unix-hpux, unix-solaris. Web/WAS 프로필: apache, nginx, tomcat. 같은 제품의 서비스가 여러 개이면 설치 경로를 달리하여 각각 실행하고 생성된 ZIP을 모두 전달하세요. 설치 경로 지정은 알려진 설정 경로를 연결하는 방식이며 일부 프로세스/패키지 점검은 서버 전체를 확인합니다.

## 3. Windows 실행

관리자 권한으로 Windows PowerShell을 열고 파일이 있는 폴더에서 실행합니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Windows-Infrastructure.ps1
```

IP를 결과 식별자로 지정하고 결과 위치를 바꾸려면 다음처럼 실행합니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Windows-Infrastructure.ps1 -TargetId 192.0.2.20 -Output C:\TriGuard-Results
```

기본 실행은 Windows 서버/PC를 구분하여 서버 64개 또는 PC 18개 항목을 점검하고, IIS 서비스가 등록되어 있으면 IIS 26개 항목을 함께 점검합니다. IIS는 서버 전체 구성을 점검합니다. OS만 또는 IIS만 실행하려면 다음과 같이 지정합니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Windows-Infrastructure.ps1 -Profiles windows
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Windows-Infrastructure.ps1 -Profiles iis
```

ExecutionPolicy Bypass는 이 명령 프로세스에만 적용하며 컴퓨터의 실행 정책을 영구 변경하지 않습니다. 조직의 실행 정책·AppLocker·WDAC·보안 제품이 차단하면 정책을 임의로 해제하지 말고 승인된 실행 절차를 담당자에게 요청하세요.

## 4. DB 점검이 필요한 경우

기본 실행에서는 DB 계정과 암호를 추측하거나 DB를 점검하지 않습니다. DB 담당자와 범위를 확인한 뒤 Unix 실행본에서 mysql, postgresql, oracle, mssql 중 한 프로필을 선택합니다. 해당 서버에 승인된 DB 클라이언트(mysql/psql/sqlplus/sqlcmd)와 접속 권한이 있어야 합니다. 자동 설치는 하지 않습니다.

```bash
sudo bash ./Unix-Infrastructure.sh --profile mysql --db-user audit --db-host localhost --db-port 3306 --db-name appdb
```

DB 암호는 실행 중 화면에 표시하지 않는 입력창에서 요청합니다. 암호를 명령줄이나 메일에 적지 마세요. 임시 실행 설정은 결과 묶음에서 제외하며 제공된 DB 암호는 수집 증적에서 마스킹합니다. 다른 민감정보까지 완전히 제거됐다는 뜻은 아니므로 전달 전 확인이 필요합니다. Oracle 클라이언트 등 제품별 환경 변수와 접속 설정은 서버 담당자가 미리 준비해야 합니다. Windows의 IIS 외 Web/WAS와 DB 점검 원본은 Bash 기반이므로 PowerShell로 변환하여 실행하지 않습니다. 해당 실행 환경을 준비하거나 별도 수동 점검을 협의하세요.

## 5. 점검 시간·실패와 결과 전달

- 각 항목 제한은 기본 90초입니다. 3개 항목이 연속 시간 초과되면 해당 점검 대상의 남은 항목을 건너뜁니다. 정상적으로 수행 시간이 긴 서버는 Unix --item-timeout 300 또는 Windows -ItemTimeout 300으로 늘릴 수 있습니다(10~3600초).
- 완료 시 RETURN THIS RESULT ZIP: 뒤에 생성 파일의 전체 경로를 표시합니다. 종료 코드 0은 실행/증적 검증 완료이며 취약점이 없다는 뜻이 아닙니다. 종료 코드 2는 부분 실패/미완전 결과이며 생성된 ZIP을 함께 전달해야 원인을 확인할 수 있습니다. 필수 실행 환경·출력 경로·압축 생성 문제처럼 실행을 시작하거나 완료할 수 없는 경우 ZIP이 없을 수 있습니다. 이때 화면 오류 문구를 전달하세요.
- 기본 결과 위치는 실행 파일과 같은 폴더의 results입니다. 결과 ZIP 이름은 UTC 실행 시각과 고유 ID입니다. 재실행하면 새 파일을 만들어 이전 결과를 덮어쓰지 않습니다.
- 전달할 것은 화면에 표시된 결과 ZIP입니다. 원본 ZIP을 열어 파일을 수정하거나 일부 파일만 따로 보내지 마세요. 여러 서버는 서버별 ZIP을 모두 모아 전달합니다. 서비스/DB를 별도로 실행했다면 해당 ZIP도 함께 전달하세요.
- ZIP 안에는 summary.json(서버/프로필/판정/미완전 상태), failures.csv(실패 사유), metadata.json(호스트명·주소·실행 정보), 대상별 evidence.zip 또는 evidence.tar.gz(원본 증적·실행 로그), manifest.json(파일 크기·SHA256)이 있습니다.
- 서버 담당자는 점검 대상·IP와 수집 범위가 맞는지, 민감정보 반출 정책에 맞는지 확인하고 협의된 안전한 전달 경로로 전달합니다. 자동 이메일·클라우드 업로드 기능은 없습니다. 전달 후 서버에 남은 results 및 임시 작업 자료는 고객 보관 정책에 따라 처리합니다. 도구는 수집 자료를 자동 삭제하지 않습니다.
- 판단 기준에 대한 설명과 조치 권고는 결과 자료에 포함될 수 있지만 자동 조치를 실행하는 기능은 제공하지 않습니다. 개별 점검 스크립트·명령의 동작 및 부하는 사전 검토 후 승인된 범위에서 실행하세요. 서비스를 재설치하거나 점검 도구를 자동 설치하지 않습니다.

## 6. 결과를 받는 컨설턴트

VulnChecker의 ⑦ 인프라 점검 → 대량 등록 / 실행 설정 → 고객 실행 결과 가져오기에서 전달받은 결과 ZIP을 선택합니다. 여러 파일을 한 번에 가져올 수 있습니다. 파일 경로와 해시·형식을 검사한 뒤 기존 점검 이력에 추가합니다. 같은 실행 ID와 동일 내용은 중복 등록하지 않으며, 같은 실행 ID의 다른 자료는 덮어쓰지 않습니다.

⑦ 점검 결과에서 실패와 증적을 확인한 뒤 ⑧ 레포트 → 결과 동기화를 누릅니다. 기존 보고서와 RAW 통합 보관함에서 사용할 수 있습니다. 가져오기는 결과를 읽는 작업이며 고객 서버로 접속하거나 다시 점검하지 않습니다. 서로 다른 ZIP의 결과를 한 보고서로 자동 합치는 기능은 별도이며, 우선 회차별 조회/추출 및 RAW 분석이 가능합니다.

컨설턴트 PC에는 보고서 전용 실행 환경이 준비되어 있어야 합니다. 처음 가져올 때 환경이 없으면 앱이 해당 환경을 준비하므로 인터넷 연결이 필요할 수 있습니다. 준비된 PC에서 결과 가져오기는 WSL/Ansible 없이 로컬에서 수행합니다. 고객 서버에서 실행하는 두 파일에는 이 설치 과정이 없습니다.

## 7. 소스·라이선스 확인

점검 소스는 KISA-CIIP-2026의 고정 커밋 d081fc1e75a2be207eb2e57632e5e5f398e273b1 기반입니다. 원본 저작권·AGPL-3.0-or-later 라이선스를 동봉하며, 필요한 호환 수정은 source-compatibility.json에 기록합니다. 배포 ZIP의 Corresponding-Source.zip에는 유효 소스와 통합 실행본 생성 소스가 들어 있습니다.

실행하지 않고 내장 소스와 라이선스를 확인하려면 아래 명령을 사용합니다.

```bash
bash ./Unix-Infrastructure.sh --extract-only ./review-source
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Windows-Infrastructure.ps1 -ExtractOnly -Output .\review-source
```
