function Test-PortAvailable {
    param([int]$Port)
    $listener=$null
    try { $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$Port); $listener.Start(); return $true }
    catch { return $false }
    finally { if ($listener) { $listener.Stop() } }
}

function Wait-Http {
    param([string]$Url, [int]$Seconds=180)
    $end=(Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        try { $r=Invoke-WebRequest $Url -UseBasicParsing -TimeoutSec 5; if ($r.StatusCode -eq 200) { return } } catch { }
        Start-Sleep -Seconds 2
    }
    throw "서비스 준비 시간 초과: $Url. 서비스 로그를 확인하세요."
}

function Start-Emulator {
    Set-AndroidEnvironment
    $emulator=Join-Path (Get-SdkRoot) 'emulator\emulator.exe'
    if (-not (Test-Path -LiteralPath $emulator)) { throw 'Android SDK 설치가 필요합니다.' }
    $list=Invoke-Native $emulator @('-list-avds') -Quiet
    if ($script:Config.avdName -notin @($list -split '\r?\n' | ForEach-Object {$_.Trim()})) {
        Write-Log '전용 AVD 없음. 기존 설치 이미지로 생성 (다운로드/기존 AVD 변경 없음)'
        Ensure-AndroidAvd
    }
    $adb=Join-Path (Get-SdkRoot) 'platform-tools\adb.exe'
    $devices=Invoke-Native $adb @('devices') -Quiet
    if ($devices -match '(?m)^emulator-5554\s+device') {
        $name=Invoke-Native $adb @('-s','emulator-5554','emu','avd','name') -Quiet
        if (($name -split '\r?\n')[0].Trim() -ne $script:Config.avdName) { throw '5554 포트에 다른 에뮬레이터가 있습니다. 먼저 종료하세요.' }
        if ($script:State.ContainsKey('emulator-process')) {
            $saved=$script:State['emulator-process']
            $owned=Get-Process -Id $saved.pid -ErrorAction SilentlyContinue
            if (-not $owned -or $owned.StartTime.ToString('o') -ne $saved.start) { $script:State.Remove('emulator-process'); Save-State }
        }
        Write-Log '기존 VulnChecker 에뮬레이터 사용'
    } else {
        Set-ManagedNavigationConfig
        foreach ($p in @(5554,5555)) { if (-not (Test-PortAvailable $p)) { throw "에뮬레이터 포트 $p 사용 중입니다. 다른 에뮬레이터를 종료하세요." } }
        Invoke-Native $emulator @('-accel-check') -Quiet | Out-Null
        $process=Start-Process -FilePath $emulator -WindowStyle Hidden -ArgumentList @('-avd',$script:Config.avdName,'-writable-system','-no-snapshot','-gpu','swiftshader','-memory','2048','-cores','2','-port','5554') -RedirectStandardOutput (Join-Path $script:Runtime 'emulator-stdout.log') -RedirectStandardError (Join-Path $script:Runtime 'emulator-stderr.log') -PassThru
        $script:State['emulator-process']=@{pid=$process.Id; start=$process.StartTime.ToString('o'); avd=$script:Config.avdName}
        Save-State
    }
    Wait-AndroidBoot
    Enable-AndroidNavigation
    Set-ConnectionResult 'Android ADB' '연결됨' 'emulator-5554 부팅 완료'
}

function Set-ManagedNavigationConfig {
    if ($script:Config.avdName -notmatch '^VulnChecker_') { throw '전용 AVD만 변경할 수 있습니다.' }
    $ini=Join-Path (Get-AvdRoot) "$($script:Config.avdName).avd\config.ini"
    $text=Get-Content -LiteralPath $ini -Raw
    if ($text -match '(?m)^hw\.mainKeys\s*=.*$') { $text=[regex]::Replace($text,'(?m)^hw\.mainKeys\s*=.*$','hw.mainKeys=no') }
    else { $text+="`nhw.mainKeys=no`n" }
    [IO.File]::WriteAllText($ini,$text,(New-Object Text.UTF8Encoding($false)))
}

function Enable-AndroidNavigation {
    $adb=Join-Path (Get-SdkRoot) 'platform-tools\adb.exe'
    Invoke-Native $adb @('-s','emulator-5554','shell','cmd','overlay','enable-exclusive','--category','com.android.internal.systemui.navbar.threebutton') -Quiet | Out-Null
    Invoke-Native $adb @('-s','emulator-5554','shell','settings','put','global','policy_control','null') -Quiet | Out-Null
    Set-ConnectionResult 'Android 탐색 버튼' '설정됨' '뒤로 / 홈 / 최근 앱 3버튼. 하드웨어 키 설정 변경은 에뮬레이터 재시작 시 적용됩니다.'
}

function Wait-AndroidBoot {
    $adb=Join-Path (Get-SdkRoot) 'platform-tools\adb.exe'
    $end=(Get-Date).AddSeconds(300)
    Write-Log 'Android 부팅 완료 대기 (최대 5분)'
    while ((Get-Date) -lt $end) {
        if ($script:State.ContainsKey('emulator-process')) {
            $saved=$script:State['emulator-process']
            $proc=Get-Process -Id $saved.pid -ErrorAction SilentlyContinue
            if (-not $proc -or $proc.StartTime.ToString('o') -ne $saved.start) { throw "에뮬레이터가 부팅 전에 종료되었습니다. $(Get-EmulatorFailure)" }
        }
        try {
            $r=Invoke-Native $adb @('-s','emulator-5554','shell','getprop','sys.boot_completed') -Quiet
            if ($r.Trim() -eq '1') { return }
        } catch { }
        Start-Sleep -Seconds 3
    }
    throw "Android 부팅 시간 초과. $(Get-EmulatorFailure) 로그 폴더: $script:Runtime"
}

function Get-EmulatorFailure {
    $parts=@()
    foreach ($file in @('emulator-stderr.log','emulator-stdout.log')) {
        $path=Join-Path $script:Runtime $file
        if (Test-Path $path) { $parts+=@(Get-Content -LiteralPath $path -Tail 18) }
    }
    return ($parts -join "`n")
}

function Set-ConnectionResult {
    param([string]$Name,[string]$Status,[string]$Detail)
    if ($Name -eq '환경 설치' -and $script:State.ContainsKey('install-progress')) {$script:State['install-progress'].Status=$Status}
    if (-not $script:State.ContainsKey('connections')) { $script:State['connections']=@{} }
    if ($script:State['connections'] -isnot [hashtable]) {
        $copy=@{}; foreach ($prop in $script:State['connections'].PSObject.Properties) { $copy[$prop.Name]=$prop.Value }; $script:State['connections']=$copy
    }
    $order=$script:State['connections'].Count
    $previous=$script:State['connections'][$Name]
    if ($previous -and $previous.PSObject.Properties['Order']) { $order=$previous.Order }
    elseif ($previous -is [hashtable] -and $previous.ContainsKey('Order')) { $order=$previous.Order }
    $script:State['connections'][$Name]=@{Name=$Name;Status=$Status;Detail=$Detail;Updated=(Get-Date).ToString('o');Order=$order}
    Save-State
    $rows=@($script:State['connections'].Values | Sort-Object Order,Name)
    $tmp=Join-Path $script:Runtime 'connections.json.tmp'
    ConvertTo-Json -InputObject $rows -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination (Join-Path $script:Runtime 'connections.json') -Force
    Write-Log "$Status $Name : $Detail"
}

function Wait-AdbRoot {
    $adb=Join-Path (Get-SdkRoot) 'platform-tools\adb.exe'
    Invoke-Native $adb @('-s','emulator-5554','root') | Out-Null
    $end=(Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $end) {
        try {
            $uid=Invoke-Native $adb @('-s','emulator-5554','shell','id','-u') -Quiet
            if ($uid.Trim() -eq '0') { return }
        } catch { }
        Start-Sleep -Seconds 2
    }
    throw 'ADB root 실패. Google Play 없는 userdebug 이미지가 필요합니다.'
}

function Prepare-RootedAndroid {
    Start-Emulator
    $adb=Join-Path (Get-SdkRoot) 'platform-tools\adb.exe'
    Wait-AdbRoot
    # These changes apply only to the reserved VulnChecker AVD, never to a physical phone.
    $api=Invoke-Native $adb @('-s','emulator-5554','shell','getprop','ro.build.version.sdk') -Quiet
    if ($api.Trim() -ne [string]$script:Config.androidApi) { throw '에뮬레이터 Android API가 설정과 다릅니다.' }
    $verification=Invoke-Native $adb @('-s','emulator-5554','shell','avbctl','disable-verification')
    $verity=Invoke-Native $adb @('-s','emulator-5554','disable-verity')
    if ($verification -notmatch 'already disabled' -or $verity -notmatch 'already disabled') {
        Invoke-Native $adb @('-s','emulator-5554','reboot') | Out-Null
        Start-Sleep -Seconds 5
        Wait-AndroidBoot
        Wait-AdbRoot
    }
    $remount=Invoke-Native $adb @('-s','emulator-5554','remount')
    if ($remount -match '(?i)reboot.*(required|device)|reboot your device') {
        Invoke-Native $adb @('-s','emulator-5554','reboot') | Out-Null
        Start-Sleep -Seconds 5
        Wait-AndroidBoot
        Wait-AdbRoot
        Invoke-Native $adb @('-s','emulator-5554','remount') | Out-Null
    }
    Invoke-Native $adb @('-s','emulator-5554','shell','touch /system/.vulnchecker-write-test && rm /system/.vulnchecker-write-test') | Out-Null
    Write-Log 'PASS: Android API 일치, uid=0 및 /system 쓰기 검증 완료'
    Set-ConnectionResult 'Android root / system' '연결됨' 'API 일치 / uid=0 / remount 및 /system 쓰기 확인'
}

function Get-MobSfSpec {
    param([switch]$Dynamic)
    $image=$script:Config.mobSfImage
    $compat=Join-Path $script:Runtime 'mobsf-compat-image.json'
    if (Test-Path -LiteralPath $compat) {
        $record=Get-Content -LiteralPath $compat -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($record.ConfigImage -eq $script:Config.mobSfImage) { $image=$record.Image }
    }
    $file=Join-Path $script:Runtime 'mobsf-image.json'
    if ($image -eq $script:Config.mobSfImage -and (Test-Path -LiteralPath $file)) {
        $saved=@(Get-Content -LiteralPath $file -Raw | ConvertFrom-Json)[0]
        # Use the downloaded image ID to prevent an implicit latest update on launch.
        if ($saved.RepoTags -contains $script:Config.mobSfImage -or $saved.RepoDigests -contains $script:Config.mobSfImage) { $image=$saved.Id }
    }
    $mode='static'; if ($Dynamic) { $mode='dynamic' }
    return "$image|$mode|$($script:Config.mobSfPort)|1337|host.docker.internal:5555"
}

function Start-MobSf {
    param([switch]$Dynamic,[switch]$Reconfigure,[switch]$NoBrowser)
    $docker=Wait-Docker
    $spec=Get-MobSfSpec -Dynamic:$Dynamic
    $image=($spec -split '\|')[0]
    Invoke-Native $docker @('image','inspect',$image) -Quiet | Out-Null
    $inspect=$null
    try { $inspect=@((Invoke-Native $docker @('inspect','vulnchecker-mobsf') -Quiet | ConvertFrom-Json))[0] } catch { }
    $managedVolume=$false
    if ($inspect) {
        if ($inspect.Config.Labels.'io.vulnchecker.owner' -ne 'VulnChecker') { throw '동일 이름의 외부 컨테이너가 있습니다. 변경하지 않았습니다.' }
        $managedVolume=$true
        if ($inspect.Config.Labels.'io.vulnchecker.spec' -ne $spec) {
            if ($inspect.State.Running) {
                if (-not $Reconfigure) { throw 'MobSF 모드/설정이 변경되었습니다. 작업을 저장하고 관리 서비스 중지 버튼을 누른 뒤 다시 실행하세요.' }
                Write-Log '선택한 분석 흐름에 맞춰 관리 MobSF 컨테이너를 재구성합니다. 분석 데이터 볼륨은 유지됩니다.'
                Invoke-Native $docker @('stop','vulnchecker-mobsf') -Quiet | Out-Null
            }
            Invoke-Native $docker @('rm','vulnchecker-mobsf') | Out-Null
            $inspect=$null
        }
    }
    if (-not $inspect) {
        foreach ($p in @($script:Config.mobSfPort,1337)) { if (-not (Test-PortAvailable $p)) { throw "MobSF 포트 $p 사용 중입니다." } }
        Initialize-MobSfVolume $docker $image -ManagedContainer:$managedVolume
        $mode='static'; if ($Dynamic) { $mode='dynamic' }
        $args=@('run','--detach','--name','vulnchecker-mobsf','--label','io.vulnchecker.owner=VulnChecker','--label',"io.vulnchecker.spec=$spec",'--publish',"127.0.0.1:$($script:Config.mobSfPort):8000",'--publish','127.0.0.1:1337:1337','--volume','vulnchecker-mobsf-data:/home/mobsf/.MobSF')
        if ($Dynamic) { $args+=@('--env','MOBSF_ANALYZER_IDENTIFIER=host.docker.internal:5555') }
        $args+=$image
        Invoke-Native $docker $args | Out-Null
    } elseif (-not $inspect.State.Running) { Initialize-MobSfVolume $docker $image -ManagedContainer; Invoke-Native $docker @('start','vulnchecker-mobsf') | Out-Null }
    $url="http://127.0.0.1:$($script:Config.mobSfPort)"
    $end=(Get-Date).AddSeconds(180)
    $ready=$false
    while ((Get-Date) -lt $end) {
        $running=Invoke-Native $docker @('inspect','--format','{{.State.Running}}','vulnchecker-mobsf') -Quiet
        if ($running.Trim() -ne 'true') { $tail=Invoke-Native $docker @('logs','--tail','15','vulnchecker-mobsf') -Quiet; throw "MobSF 컨테이너가 종료되었습니다: $tail" }
        try { $response=Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 5; if ($response.StatusCode -eq 200) { $ready=$true; break } } catch { }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) { throw "MobSF 웹 응답 시간 초과: $url" }
    Set-ConnectionResult 'MobSF HTTP' '연결됨' $url
    if ($Dynamic) {
        Invoke-Native $docker @('exec','vulnchecker-mobsf','/usr/bin/adb','connect','host.docker.internal:5555') | Out-Null
        $uid=Invoke-Native $docker @('exec','vulnchecker-mobsf','/usr/bin/adb','-s','host.docker.internal:5555','shell','id','-u') -Quiet
        if ($uid.Trim() -ne '0') { throw 'MobSF 컨테이너에서 ADB root 연결 실패. Docker Desktop host.docker.internal 연결과 고객사 방화벽 정책을 확인하세요.' }
        $write=Invoke-Native $docker @('exec','vulnchecker-mobsf','/usr/bin/adb','-s','host.docker.internal:5555','shell','touch /system/.vulnchecker-container-test && rm /system/.vulnchecker-container-test') -Quiet
        Write-Log 'PASS: MobSF 컨테이너 → Android ADB root 및 /system 쓰기 연결 검증 완료'
        $script:State['dynamic-ready']=@{status='complete'; updated=(Get-Date).ToString('o'); api=$script:Config.androidApi; avd=$script:Config.avdName; specification=$spec}
        Save-State
    }
    if (-not $NoBrowser) { Start-Process $url | Out-Null }
    Write-Log "MobSF: $url (최초 계정 mobsf / mobsf, 로그인 후 비밀번호 변경 권장)"
}

function Initialize-MobSfVolume {
    param([string]$Docker,[string]$Image,[switch]$ManagedContainer)
    $volume=$null
    try { $volume=@((Invoke-Native $Docker @('volume','inspect','vulnchecker-mobsf-data') -Quiet | ConvertFrom-Json))[0] } catch { }
    if (-not $volume) { Invoke-Native $Docker @('volume','create','--label','io.vulnchecker.owner=VulnChecker','vulnchecker-mobsf-data') -Quiet | Out-Null }
    elseif (-not $ManagedContainer -and (-not $volume.Labels -or -not $volume.Labels.PSObject.Properties['io.vulnchecker.owner'] -or $volume.Labels.'io.vulnchecker.owner' -ne 'VulnChecker')) { throw '관리 대상으로 확인되지 않은 MobSF 데이터 볼륨입니다. 기존 데이터를 변경하지 않습니다.' }
    $uid=(Invoke-Native $Docker @('run','--rm','--pull=never','--entrypoint','id',$Image,'-u') -Quiet).Trim()
    $gid=(Invoke-Native $Docker @('run','--rm','--pull=never','--entrypoint','id',$Image,'-g') -Quiet).Trim()
    if ($uid -notmatch '^\d+$' -or $gid -notmatch '^\d+$') { throw 'MobSF 이미지 사용자 UID/GID 확인 실패' }
    Invoke-Native $Docker @('run','--rm','--pull=never','--user','0','--entrypoint','chown','--volume','vulnchecker-mobsf-data:/data',$Image,'-R',"${uid}:${gid}",'/data') -Quiet | Out-Null
    Write-Log "MobSF 관리 데이터 볼륨 권한 확인: UID=$uid GID=$gid (분석 데이터 유지)"
}

function Start-HexStrike {
    $port=$script:Config.hexstrikePort
    $rt=Get-KaliRuntime
    $probe=Invoke-Kali -Arguments @($rt.HexPython,'-c','import flask, mcp') -Quiet
    Ensure-KaliIntegration $rt
    if (-not (Test-PortAvailable $port)) {
        try {
            $health=Invoke-Kali -Arguments @('curl','--fail','--silent','--max-time','15',"http://127.0.0.1:$port/health") -Quiet
            $parsed=$health | ConvertFrom-Json
            if (-not $parsed.PSObject.Properties['status'] -or -not ($parsed.PSObject.Properties['tools_status'] -or $parsed.PSObject.Properties['version'])) { throw 'HexStrike health 형식 불일치' }
            Set-ConnectionResult 'HexStrike HTTP' '연결됨' "기존 서버 재사용 / 127.0.0.1:$port"
            return
        } catch { throw "HexStrike 포트 $port 사용 중이며 서버 검증 실패: $($_.Exception.Message)" }
    }
    $p=Start-Process wsl.exe -WindowStyle Hidden -ArgumentList @('-d',$script:Config.kaliDistro,'-u',$rt.User,'--',$rt.HexPython,$rt.Wrapper,'--repository',$rt.HexRepo,'--port',[string]$port) -RedirectStandardOutput (Join-Path $script:Runtime 'hexstrike-stdout.log') -RedirectStandardError (Join-Path $script:Runtime 'hexstrike-stderr.log') -PassThru
    $script:State['hexstrike-process']=@{pid=$p.Id; start=$p.StartTime.ToString('o')}
    Save-State
    $end=(Get-Date).AddSeconds(60)
    do {
        $p.Refresh()
        if ($p.HasExited) { throw "HexStrike 프로세스 종료: $(Get-Content (Join-Path $script:Runtime 'hexstrike-stderr.log') -Tail 15)" }
        try {
            $health=Invoke-Kali -Arguments @('curl','--fail','--silent','--max-time','15',"http://127.0.0.1:$port/health") -Quiet
            $parsed=$health | ConvertFrom-Json
            if ($parsed) {
                $health | Set-Content -LiteralPath (Join-Path $script:Runtime 'hexstrike-health.json') -Encoding UTF8
                Set-ConnectionResult 'HexStrike HTTP' '연결됨' "127.0.0.1:$port /health 응답"
                return
            }
        } catch { }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $end)
    throw "HexStrike health 응답 시간 초과. 로그: $script:Runtime\hexstrike-stderr.log"
}

function Start-Tool {
    param([string]$Tool,[string]$Package='',[ValidateSet('Auto','Burp','Direct','Preview')][string]$CaptureRoute='Preview',[string]$Target='')
    Set-ConnectionResult "실행: $Tool" '진행 중' '서비스 시작 및 연결 확인'
    try {
    switch ($Tool) {
        'MobileAnalysis' { Start-MobSfAnalysisWorkflow }
        'MobSfAnalysis' {if ($Package) {Set-MobileAnalysisTarget $Package | Out-Null}; Start-MobSfAnalysisWorkflow -Package $Package }
        'MobileApi' {Set-MobileAnalysisTarget $Package | Out-Null; Start-MobileApiWorkflow $Package }
        'PenTest' { Start-AnalysisWorkflow -Mode SystemAnalysis -Target $Target }
        'WebProxyTest' { Start-AnalysisWorkflow -Mode PenTest -Target $Target }
        'SystemAnalysis' { Start-AnalysisWorkflow -Mode SystemAnalysis -Target $Target }
        'MobileAI' { Start-AnalysisWorkflow -Mode MobileAI -Package $Package }
        'RefreshAnalysisApps' {Get-InstalledAnalysisApps | Out-Null}
        'Combined' { Start-CombinedMobile }
        'FridaServer' { Initialize-FridaServer }
        'RootBypass' { Start-RootBypassWorkflow $Package -CaptureRoute $CaptureRoute }
        'RootBypassDirect' { Start-RootBypassWorkflow $Package -DirectCapture }
        'StopRootBypass' { Stop-RootBypass }
        'AppDiagnostics' { Get-AppDiagnostics $Package | Out-Null }
        'Burp' { Start-Burp }
        'AndroidBurp' { Connect-AndroidBurp }
        'WebAI' { Start-Burp; Start-OpenCodeIntegration }
        'Kali' { $rt=Get-KaliRuntime; Start-Process wsl.exe -ArgumentList @('-d',$script:Config.kaliDistro,'-u',$rt.User) | Out-Null }
        'OpenCode' { Start-OpenCodeIntegration }
        'HexStrike' { Start-HexStrike }
        'Emulator' { Start-Emulator; Wait-AdbRoot; Set-ConnectionResult 'Android root' '연결됨' 'adb shell id -u = 0' }
        'MobSF' { Start-MobSf; Set-ConnectionResult 'MobSF HTTP' '연결됨' "http://127.0.0.1:$($script:Config.mobSfPort)" }
        'Dynamic' {
            if ($script:State.ContainsKey('dynamic-ready')) { $script:State.Remove('dynamic-ready'); Save-State }
            Prepare-RootedAndroid
            $adb=Join-Path (Get-SdkRoot) 'platform-tools\adb.exe'
            Invoke-Native $adb @('-s','emulator-5554','shell','settings','put','global','http_proxy',':0') | Out-Null
            Set-ConnectionResult 'Android → Burp' '전환됨' 'MobSF 분석 흐름 선택으로 Burp용 Android proxy 해제'
            Start-MobSf -Dynamic
            Disable-MobSfUpstream
            Initialize-FridaServer
            Set-ConnectionResult 'MobSF → Android' '연결됨' '컨테이너에서 ADB uid=0 /system 쓰기 검증 완료. 앱 업로드 후 Dynamic Analyzer 실행.'
        }
    }
    Set-ConnectionResult "실행: $Tool" '완료' '개별 연결 결과를 확인하세요.'
    Write-Log "LAUNCH $Tool 완료"
    } catch {
        if ($script:State.ContainsKey('analysis-mode') -and $script:State['analysis-mode'] -like 'Preparing*') {$script:State['analysis-mode']='Failed'; Save-State}
        Set-ConnectionResult "실행: $Tool" '실패' $_.Exception.Message; throw
    }
}

function Stop-ManagedProcessTree {
    param([string]$Key,[string[]]$Names)
    if (-not $script:State.ContainsKey($Key)) { return }
    $saved=$script:State[$Key]
    $process=Get-Process -Id $saved.pid -ErrorAction SilentlyContinue
    if (-not $process) { $script:State.Remove($Key); Save-State; return }
    if ($process.ProcessName -notin $Names -or ([DateTimeOffset]$process.StartTime).UtcDateTime.Ticks -ne ([DateTimeOffset]$saved.start).UtcDateTime.Ticks) {
        throw "프로세스 식별 불일치: $Key. 다른 프로세스는 종료하지 않았습니다."
    }
    if ($Key -eq 'burp-process') {
        $expectedPath=Get-AppPath Burp
        if ($saved -is [hashtable] -and $saved.ContainsKey('path')) { $expectedPath=$saved.path }
        elseif ($saved.PSObject.Properties['path']) { $expectedPath=$saved.path }
        if (-not $expectedPath -or $process.Path -ne $expectedPath) { throw 'Burp 실행 경로 불일치' }
        if ($process.CloseMainWindow() -and $process.WaitForExit(5000)) { $script:State.Remove($Key); Save-State; return }
    }
    # Capture descendants before stopping parents. Check creation time again to
    # avoid terminating a recycled PID or an unrelated process.
    $snapshot=@(Get-CimInstance Win32_Process)
    $tree=New-Object Collections.Generic.List[object]
    $rootProcess=$snapshot | Where-Object {$_.ProcessId -eq $process.Id} | Select-Object -First 1
    if (-not $rootProcess) {
        # The remote session may exit between Get-Process and the CIM snapshot.
        if (Get-Process -Id $saved.pid -ErrorAction SilentlyContinue) { throw "프로세스 종료 확인 재시도 필요: $Key" }
        $script:State.Remove($Key); Save-State; return
    }
    $tree.Add($rootProcess)
    for ($index=0; $index -lt $tree.Count; $index++) {
        foreach ($child in @($snapshot | Where-Object {$_.ParentProcessId -eq $tree[$index].ProcessId -and $_.CreationDate -ge $tree[$index].CreationDate})) {
            if ($child.ProcessId -ne $PID -and $child.ProcessId -notin @($tree | ForEach-Object {$_.ProcessId})) { $tree.Add($child) }
        }
    }
    for ($index=$tree.Count-1; $index -ge 0; $index--) {
        $item=$tree[$index]
        $current=Get-CimInstance Win32_Process -Filter "ProcessId=$($item.ProcessId)"
        if ($current -and $current.CreationDate -eq $item.CreationDate -and $current.ExecutablePath -eq $item.ExecutablePath) {
            Stop-Process -Id $item.ProcessId -Force -ErrorAction Stop
        }
    }
    $script:State.Remove($Key); Save-State
    Write-Log "중지: $Key 및 하위 프로세스"
}

function Stop-ManagedRuntime {
    Stop-PlayDownload
    if (@($script:State.Keys | Where-Object {$_ -like 'terminal-OpenCode*'}).Count) {
        $rt=Get-KaliRuntime
        $helper=Get-Content -LiteralPath (Join-Path $script:Root 'scripts\stop-opencode.py') -Raw -Encoding UTF8
        Invoke-Kali -Arguments @($rt.HexPython,'-',"$($rt.Work)/opencode.json") -InputText $helper -Quiet | Out-Null
    }
    foreach ($key in @($script:State.Keys | Where-Object {$_ -like 'terminal-OpenCode*' -or $_ -eq 'terminal-ADB'})) { Stop-ManagedProcessTree $key @('powershell','pwsh','cmd') }
    if ($script:State.ContainsKey('frida-process')) {
        try { $docker=Get-ManagedMobSf; Invoke-Native $docker @('exec','vulnchecker-mobsf','python3','/tmp/vulnchecker/instrument-app.py','--stop') -Quiet -TimeoutSeconds 10 | Out-Null } catch { Write-Log "Frida 세션 중지 확인: $($_.Exception.Message)" }
        Stop-ManagedProcessTree 'frida-process' @('docker')
    }
    try {
        $docker=Get-DockerCli
        $container=@((Invoke-Native $docker @('inspect','vulnchecker-mobsf') -Quiet -TimeoutSeconds 10 | ConvertFrom-Json))[0]
        if ($container.Config.Labels.'io.vulnchecker.owner' -eq 'VulnChecker') { Invoke-Native $docker @('stop','--time','5','vulnchecker-mobsf') -TimeoutSeconds 15 | Out-Null }
    } catch { Write-Log "MobSF 중지 확인: $($_.Exception.Message)" }
    if ($script:State.ContainsKey('emulator-process')) {
        try {
            Set-AndroidEnvironment
            $adb=Join-Path (Get-SdkRoot) 'platform-tools\adb.exe'
            $avd=Invoke-Native $adb @('-s','emulator-5554','emu','avd','name') -Quiet
            if (($avd -split '\r?\n')[0].Trim() -eq $script:State['emulator-process'].avd) { Invoke-Native $adb @('-s','emulator-5554','emu','kill') | Out-Null; Start-Sleep -Seconds 3 }
        } catch { Write-Log '관리 에뮬레이터가 실행 중이지 않거나 ADB에 연결되지 않았습니다.' }
    }
    # A reused PID must never be terminated. Verify both creation timestamp and executable.
    if ($script:State.ContainsKey('hexstrike-process')) {
        try { $rt=Get-KaliRuntime; Invoke-Kali -Arguments @($rt.HexPython,"$($rt.Home)/tools/vulnchecker/stop-hexstrike.py") -Quiet | Out-Null } catch { Write-Log "HexStrike 중지 확인: $($_.Exception.Message)" }
        Stop-ManagedProcessTree 'hexstrike-process' @('wsl')
    }
    Stop-ManagedProcessTree 'emulator-process' @('emulator')
    Stop-ManagedProcessTree 'burp-process' @('BurpSuite','java','javaw')
    # ADB is shared by all Android devices. Only release it when none remain.
    $adb=Join-Path (Get-SdkRoot) 'platform-tools\adb.exe'
    if (Test-Path -LiteralPath $adb) {
        $devices=Invoke-Native $adb @('devices') -Quiet
        if ($devices -match '(?m)^\S+\s+(device|offline|unauthorized|recovery|sideload|bootloader)\b') { Write-Log '다른 Android 연결이 남아 있어 공유 ADB 서버는 유지합니다.' }
        else { Invoke-Native $adb @('kill-server') -Quiet | Out-Null; Write-Log 'ADB 서버 중지 완료' }
    }
    if ($script:State.ContainsKey('dynamic-ready')) { $script:State.Remove('dynamic-ready'); Save-State }
    $script:State['analysis-mode']='Stopped'; Save-State
    if ($script:State.ContainsKey('install-progress') -and $script:State['install-progress'].Status -eq '진행 중') {$script:State['install-progress'].Status='중지됨'; Save-State}
    if ($script:State.ContainsKey('connections')) { $script:State.Remove('connections'); Save-State; '[]' | Set-Content -LiteralPath (Join-Path $script:Runtime 'connections.json') -Encoding UTF8 }
    Write-Log '관리 서비스, 명령 창 및 하위 프로세스 중지 완료. 다른 기기 연결이 없으면 ADB 서버도 중지합니다. 분석 데이터/볼륨/설치 파일은 유지됩니다.'
}

function Test-Environment {
    $inventory=Get-InstallationInventory
    Write-Inventory $inventory
    $inventory.Items | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:Runtime 'verification.json') -Encoding UTF8
    Write-Log '검사는 기존 환경을 읽기만 합니다. 설치/재부팅/에뮬레이터·Docker 자동 시작은 수행하지 않습니다.'
    Write-Log '실제 동적 분석 root/remount 및 컨테이너 연결 검증은 동적 분석 준비 버튼에서 수행합니다.'
    return (@($inventory.Items | Where-Object {$_.NeedsInstall -or $null -eq $_.Installed}).Count -eq 0)
}
