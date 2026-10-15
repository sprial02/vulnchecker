$ErrorActionPreference='Stop'
$os=Get-CimInstance Win32_OperatingSystem
$profile='windows';if($os.ProductType -eq 1){$profile='pc'}
$rows=@([ordered]@{Id='os';Profile=$profile;Root='';Evidence=$os.Caption;Ready=$true;RunAs='';Bash='';Python='';DbHost='localhost';DbPort=1433;DbUser='';DbPassword='';DbName=''})
$services=@(Get-Service)
if(@($services | Where-Object Name -eq 'W3SVC').Count){$rows+=,[ordered]@{Id='iis-1';Profile='iis';Root='';Evidence='IIS W3SVC 서비스 등록';Ready=$true;RunAs='';Bash='';Python='';DbHost='localhost';DbPort=1433;DbUser='';DbPassword='';DbName=''}}
$notes=@('서비스 등록 기반 후보 탐지입니다. 설치 경로·컨테이너·원격 DB는 수동 등록이 필요할 수 있습니다.')
foreach($service in $services){
  if($service.Name -match 'MSSQL|MySQL|MariaDB|postgres|Oracle|Tomcat|Apache|nginx'){
    $notes+=($service.Name+': 발견됨. IIS 외 Web/WAS 및 DBMS 원본은 Bash 스크립트이므로 SSH 실행 서버에 별도 구성을 등록하세요.')
  }
}
[ordered]@{System='Windows';Platform='';Candidates=$rows;Notes=$notes} | ConvertTo-Json -Depth 6 -Compress
