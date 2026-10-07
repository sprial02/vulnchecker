function Get-InstalledAnalysisApps {
    Start-Emulator
    Assert-AcquisitionDeviceConnected 'emulator-5554'
    Assert-ManagedAvd 'emulator-5554' $script:Config.avdName
    $adb=Join-Path (Get-SdkRoot) 'platform-tools\adb.exe'
    $packages=@((Invoke-Native $adb @('-s','emulator-5554','shell','pm','list','packages','-3') -Quiet) -split '\r?\n' | Where-Object {$_ -match '^package:'} | ForEach-Object {$_.Substring(8).Trim()} | Sort-Object)
    @{Serial='emulator-5554';Packages=$packages;Updated=(Get-Date).ToString('o')} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $script:Runtime 'analysis-apps.json') -Encoding UTF8
    Set-ConnectionResult '분석 기기 앱 목록' '확인됨' "루팅 분석 기기 emulator-5554 / 사용자 앱 $($packages.Count)개. 모바일 메뉴에서 대상 앱을 선택하세요."
    return $packages
}

function Set-MobileAnalysisTarget {
    param([string]$Package)
    Assert-AppPackage $Package
    Assert-AcquisitionDeviceConnected 'emulator-5554'
    Assert-ManagedAvd 'emulator-5554' $script:Config.avdName
    $adb=Join-Path (Get-SdkRoot) 'platform-tools\adb.exe'
    $paths=@((Invoke-Native $adb @('-s','emulator-5554','shell','pm','path',$Package) -Quiet) -split '\r?\n' | Where-Object {$_ -match '^package:'} | ForEach-Object {$_.Substring(8).Trim()})
    if (-not $paths.Count) {throw '선택한 앱이 분석 기기에 없습니다. 앱 가져오기에서 추출 및 분석 기기 설치를 먼저 완료하세요.'}
    $target=@{Package=$Package;Serial='emulator-5554';ApkPaths=$paths;Selected=(Get-Date).ToString('o')}
    $script:State['mobile-target']=$target; Save-State
    Set-ConnectionResult '모바일 분석 대상' '선택됨' "$Package / 루팅 분석 기기 emulator-5554 / APK $($paths.Count)개"
    return $target
}

function Prepare-MobilePentestTarget {
    param([string]$Package)
    $target=Set-MobileAnalysisTarget $Package
    $adb=Join-Path (Get-SdkRoot) 'platform-tools\adb.exe'
    $uid=(Invoke-Native $adb @('-s','emulator-5554','shell','id','-u') -Quiet).Trim()
    if ($uid -ne '0') {Wait-AdbRoot; $uid=(Invoke-Native $adb @('-s','emulator-5554','shell','id','-u') -Quiet).Trim()}
    if ($uid -ne '0') {throw '모바일 펜테스트 대상은 루팅 분석 기기여야 합니다. 앱 설치 및 루팅 준비를 먼저 완료하세요.'}
    $tools=Ensure-ApkTools
    $folder=Join-Path $script:Runtime ('mobile-targets\'+$Package+'\'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $files=@()
    for ($i=0; $i -lt $target.ApkPaths.Count; $i++) {
        $file=Join-Path $folder "$i.apk"
        Invoke-Native $adb @('-s','emulator-5554','pull',$target.ApkPaths[$i],$file) -Quiet | Out-Null
        $files+=$file
    }
    $info=Get-ApkSetInfo $files $tools
    if ($info.Package -ne $Package) {throw '분석 기기 APK와 선택한 대상 앱이 다릅니다.'}
    $info | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $folder 'manifest.json') -Encoding UTF8
    $rt=Get-KaliRuntime
    $work="$($rt.Work)/mobile/$Package"
    $apkSource=(Invoke-Kali -Arguments @('wslpath','-a',$folder.Replace('\','/')) -Quiet).Trim()
    $adbLinux=(Invoke-Kali -Arguments @('wslpath','-a',$adb.Replace('\','/')) -Quiet).Trim()
    $route='설치 후 실행 확인 또는 분석 경로 미선택'
    if ($script:State.ContainsKey('analysis-mode')) {$route=[string]$script:State['analysis-mode']}
    $spec=@{package=$Package;serial='emulator-5554';source=$apkSource;work=$work;adb=$adbLinux;route=$route;version=$info.VersionName;config="$($rt.Work)/opencode.json"}
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($spec | ConvertTo-Json -Compress)))
    $helper=[IO.File]::ReadAllText((Join-Path $script:Root 'scripts\prepare-mobile-context.py'),[Text.Encoding]::UTF8)
    $result=Invoke-Kali -Arguments @($rt.HexPython,'-',$encoded) -InputText $helper -Quiet | ConvertFrom-Json
    if (-not $result.connected -or $result.package -ne $Package) {throw 'Kali에서 대상 앱 ADB 연결 검증에 실패했습니다.'}
    $script:State['mobile-target'].Work=$work; Save-State
    Set-ConnectionResult '모바일 펜테스트 대상 연결' '연결됨' "$Package / APK $($files.Count)개 원본 서명·해시 확인 / Kali → Windows ADB → emulator-5554 검증"
    Set-ConnectionResult '모바일 펜테스트 자료' '준비됨' "$work/MOBILE_TARGET.md / 전체 APK: $work/apks / ADB: $work/adb-target. API 자료는 이 작업 폴더에 저장해 지정하세요."
    return $work
}

function Test-MobileMcpTarget {
    param([string]$Package,[string]$Work)
    Assert-AppPackage $Package
    $rt=Get-KaliRuntime
    $helper=[IO.File]::ReadAllText((Join-Path $script:Root 'scripts\check-mobile-mcp.py'),[Text.Encoding]::UTF8)
    $output=Invoke-Kali -Arguments @($rt.HexPython,'-',"$($rt.HexRepo)/hexstrike_mcp.py","http://127.0.0.1:$($script:Config.hexstrikePort)",$Work,$Package) -InputText $helper -Quiet
    $line=@($output -split '\r?\n' | Where-Object {$_ -match '^\{"connected"'}) | Select-Object -Last 1
    if (-not $line) {throw 'HexStrike에서 모바일 대상 앱 연결 결과를 확인할 수 없습니다.'}
    $result=$line | ConvertFrom-Json
    if (-not $result.connected -or $result.package -ne $Package) {throw 'HexStrike 모바일 대상 연결 불일치'}
    Set-ConnectionResult 'HexStrike → 선택 앱 ADB' '연결됨' "$Package / MCP 명령 실행으로 설치 APK 경로 $($result.apk_paths)개 확인. 대상 취약점 점검은 아직 실행하지 않았습니다."
}

function Select-MobSfInstalledTarget {
    param([string]$Package)
    Assert-AppPackage $Package
    $docker=Get-ManagedMobSf
    Invoke-Native $docker @('cp',(Join-Path $script:Root 'scripts\select-mobsf-app.py'),'vulnchecker-mobsf:/tmp/vulnchecker/select-mobsf-app.py') -Quiet | Out-Null
    Set-ConnectionResult 'MobSF 대상 APK' '진행 중' "$Package / 설치된 앱의 base APK 전달 및 정적 분석. 기기의 전체 split 세트는 유지합니다."
    $json=Invoke-Native $docker @('exec','vulnchecker-mobsf','python3','/tmp/vulnchecker/select-mobsf-app.py',$Package) -Quiet
    $result=$json | ConvertFrom-Json
    if ($result.package -ne $Package) {throw 'MobSF 분석 대상이 선택한 앱과 다릅니다.'}
    $script:State['mobile-target'].MobSfHash=$result.hash; Save-State
    $url="http://127.0.0.1:$($script:Config.mobSfPort)$($result.report_path)"
    Set-ConnectionResult 'MobSF 대상 APK' '분석 완료' "$Package / 정적 보고서: $url / 동적 분석에서 같은 앱을 선택하세요."
    Start-Process $url | Out-Null
}

function Prepare-SystemPentestTarget {
    param([string]$Target='')
    if ($Target) {
        $ip=$null; $uri=$null
        $valid=[Net.IPAddress]::TryParse($Target,[ref]$ip)
        if (-not $valid) {$valid=[Uri]::TryCreate($Target,[UriKind]::Absolute,[ref]$uri) -and $uri.Scheme -in @('http','https') -and -not $uri.UserInfo}
        if (-not $valid) {throw '시스템 대상에는 IP 주소 또는 http/https URL을 입력하세요.'}
    }
    $rt=Get-KaliRuntime; $work="$($rt.Work)/system"
    Invoke-Kali -Arguments @('mkdir','-p',$work) -Quiet | Out-Null
    $json=@{kind='system';target=$Target;updated=(Get-Date).ToString('o')} | ConvertTo-Json
    Invoke-Kali -Arguments @('tee',"$work/target.json") -InputText $json -Quiet | Out-Null
    Set-ConnectionResult '시스템 펜테스트 대상' '준비됨' "독립 작업 폴더 $work / IP·URL: $Target. 점검 범위는 OpenCode에서 지정하세요."
    return $work
}
