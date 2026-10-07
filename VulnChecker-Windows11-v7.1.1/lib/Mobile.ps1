function Get-ManagedMobSf {
    $docker=Get-DockerCli
    $container=@((Invoke-Native $docker @('inspect','vulnchecker-mobsf') -Quiet -TimeoutSeconds 10 | ConvertFrom-Json))[0]
    if ($container.Config.Labels.'io.vulnchecker.owner' -ne 'VulnChecker' -or -not $container.State.Running) { throw '실행 중인 관리 MobSF 컨테이너가 필요합니다.' }
    return $docker
}
function Copy-MobileHelpers {
    param([string]$Docker)
    Invoke-Native $Docker @('exec','vulnchecker-mobsf','mkdir','-p','/tmp/vulnchecker') -Quiet | Out-Null
    foreach ($file in @('ensure-frida.py','instrument-app.py','app-diagnostics.py','root-bypass.js','configure-mobsf-frida.py')) {
        Invoke-Native $Docker @('cp',(Join-Path $script:Root "scripts\$file"),'vulnchecker-mobsf:/tmp/vulnchecker/') -Quiet | Out-Null
    }
}
function Initialize-FridaServer {
    param([switch]$SkipCompatibility)
    $docker=Get-ManagedMobSf
    Copy-MobileHelpers $docker
    $patch=Invoke-Native $docker @('exec','vulnchecker-mobsf','python3','/tmp/vulnchecker/configure-mobsf-frida.py') -Quiet
    if ($patch.Trim() -eq 'changed') {
        Write-Log 'MobSF Spawn & Inject 순서 수정 적용: 루팅 JS load → 앱 resume. 관리 서버를 재시작하며 저장된 분석 데이터는 유지합니다.'
        Invoke-Native $docker @('restart','vulnchecker-mobsf') -Quiet | Out-Null
        Wait-Http "http://127.0.0.1:$($script:Config.mobSfPort)"
    }
    Invoke-Native $docker @('exec','vulnchecker-mobsf','/usr/bin/adb','connect','host.docker.internal:5555') -Quiet | Out-Null
    try { $json=Invoke-Native $docker @('exec','vulnchecker-mobsf','python3','/tmp/vulnchecker/ensure-frida.py','host.docker.internal:5555') -Quiet }
    catch {
        $failure=$_.Exception.Message
        $clientVersion=(Invoke-Native $docker @('exec','vulnchecker-mobsf','python3','-c','import frida; print(frida.__version__)') -Quiet).Trim()
        if ($failure -match 'rt_mod != null|Unsupported Android linker' -and $clientVersion -match '^17\.' -and -not $SkipCompatibility) {
            Repair-FridaCompatibility
            Initialize-FridaServer -SkipCompatibility
            return
        }
        Set-ConnectionResult 'Frida server' '실패' $failure
        throw
    }
    $result=$json | ConvertFrom-Json
    if (-not $result.connected) { throw 'Frida 서버 연결 검사 실패' }
    Set-ConnectionResult 'Frida server' '연결됨' "MobSF와 동일 버전 $($result.version) / $($result.abi) / full access, 앱 spawn·attach 및 프로세스 $($result.processes)개 조회"
    Set-ConnectionResult 'MobSF 루팅 우회 JS' '설정 확인' 'MobSF 기본 root_bypass에 추가 Java/RootBeer 후크 적용. Dynamic Analyzer에서 Bypass Root Detection 선택 후 같은 세션으로 분석.'
}
function Repair-FridaCompatibility {
    $docker=Get-ManagedMobSf
    Write-Log 'Android 런타임/linker 충돌: 공식 MobSF 이미지에 Frida 16.7.19를 고정한 로컬 호환 이미지를 만듭니다. 데이터 볼륨은 유지합니다.'
    $base=(Invoke-Native $docker @('inspect','--format','{{.Image}}','vulnchecker-mobsf') -Quiet).Trim()
    $record=Join-Path $script:Runtime 'mobsf-compat-image.json'
    if (Test-Path $record) { $saved=Get-Content $record -Raw | ConvertFrom-Json; if ($saved.ConfigImage -eq $script:Config.mobSfImage) { $base=$saved.BaseImage } }
    if ($base -notmatch '^sha256:[0-9a-f]{64}$') { throw '관리 MobSF 기반 이미지 ID 식별 실패' }
    $baseTag='vulnchecker-mobsf-base:'+($base.Substring(7,12))
    $tag='vulnchecker-mobsf:frida-16.7.19-'+($base.Substring(7,12))
    Invoke-Native $docker @('tag',$base,$baseTag) -Quiet | Out-Null
    $context=Join-Path $script:Cache 'frida-compat-build'
    New-Item -ItemType Directory -Path $context -Force | Out-Null
    $dockerfile="FROM $baseTag`nUSER root`nRUN python3 -m pip install --no-cache-dir --no-deps frida==16.7.19`nUSER mobsf`n"
    [IO.File]::WriteAllText((Join-Path $context 'Dockerfile'),$dockerfile,(New-Object Text.UTF8Encoding($false)))
    Invoke-Native $docker @('build','--pull=false','--tag',$tag,$context) | Out-Null
    @{ConfigImage=$script:Config.mobSfImage;Image=$tag;Frida='16.7.19';BaseImage=$base} | ConvertTo-Json | Set-Content -LiteralPath $record -Encoding UTF8
    Invoke-Native $docker @('stop','vulnchecker-mobsf') -Quiet | Out-Null
    Start-MobSf -Dynamic -NoBrowser
}
function Assert-AppPackage {
    param([string]$Package)
    if ($Package -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$') { throw '실행 탭에 분석할 앱 패키지명(예: com.company.app)을 입력하세요.' }
}
function Get-AppDiagnostics {
    param([string]$Package)
    Assert-AppPackage $Package
    $docker=Get-ManagedMobSf
    Copy-MobileHelpers $docker
    $json=Invoke-Native $docker @('exec','vulnchecker-mobsf','python3','/tmp/vulnchecker/app-diagnostics.py','host.docker.internal:5555',$Package) -Quiet
    $result=$json | ConvertFrom-Json
    $json | Set-Content -LiteralPath (Join-Path $script:Runtime "app-$Package.json") -Encoding UTF8
    $result.crash_excerpt | Set-Content -LiteralPath (Join-Path $script:Runtime "app-$Package-crash.log") -Encoding UTF8
    $status='확인됨'; $detail="APK $(@($result.apk_paths).Count)개 / native libraries=$($result.native_library_count) / ABI=$($result.abis -join ',')"
    if ($result.missing_realm_crash_seen -and -not @($result.realm_libraries).Count) { $status='앱 수정 필요'; $detail+=' / librealm-jni.so 누락: 전체 split APK 또는 universal APK 필요. 루팅 JS로 해결할 수 없음.' }
    Set-ConnectionResult "앱 진단: $Package" $status $detail
    return $result
}
function Start-RootBypass {
    param([string]$Package)
    Assert-AppPackage $Package
    $diagnostic=Get-AppDiagnostics $Package
    if ($diagnostic.missing_realm_crash_seen -and -not @($diagnostic.realm_libraries).Count) { throw 'librealm-jni.so 누락을 먼저 해결하세요. 종료 예외를 숨기는 대신 정상 APK로 재검증해야 합니다.' }
    Initialize-FridaServer
    $docker=Get-ManagedMobSf
    $out=Join-Path $script:Runtime "frida-$Package-out.log"
    $err=Join-Path $script:Runtime "frida-$Package-error.log"
    if ($script:State.ContainsKey('frida-process')) {
        $saved=$script:State['frida-process']; $old=Get-Process -Id $saved.pid -ErrorAction SilentlyContinue
        if ($old -and $old.StartTime.ToString('o') -eq $saved.start) { throw '관리 Frida 세션이 이미 실행 중입니다. 중지 버튼으로 세션을 종료한 후 다시 실행하세요.' }
    }
    Invoke-Native $docker @('exec','vulnchecker-mobsf','/usr/bin/adb','-s','host.docker.internal:5555','shell','am','force-stop',$Package) -Quiet | Out-Null
    $process=Start-Process $docker -WindowStyle Hidden -ArgumentList @('exec','vulnchecker-mobsf','python3','-u','/tmp/vulnchecker/instrument-app.py','host.docker.internal:5555',$Package,'/tmp/vulnchecker/root-bypass.js') -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
    $script:State['frida-process']=@{pid=$process.Id;start=$process.StartTime.ToString('o');package=$Package}; Save-State
    $end=(Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $end) {
        $process.Refresh()
        if ($process.HasExited) { throw "Frida 세션 종료. $(Get-Content $err -Tail 12) $(Get-Content $out -Tail 8)" }
        $text=Get-Content $out -Raw -ErrorAction SilentlyContinue
        if ($text -match '"type":\s*"error"') { Stop-RootBypass; throw "Frida 후크 오류. $out 확인" }
        if ($text -match 'VulnChecker Java root hooks loaded') {
            $detail='spawn → attach → JS load → resume. Java/RootBeer 후크 활성화. 앱 화면·통신은 추가 확인하세요.'
            if ($text -match '"profile":\s*"energyplus-8.9".*"status":\s*"installed"') { $detail='에너지플러스 8.9 루팅 검사 5개 후크 적용. 원본 서명·TLS·Play 무결성 검사는 유지합니다. 앱 화면·통신은 추가 확인하세요.' }
            Set-ConnectionResult "루팅 우회: $Package" '주입 확인' $detail; return
        }
        Start-Sleep -Seconds 1
    }
    Stop-RootBypass
    throw "Frida JS 초기화 시간 초과. $out / $err 확인"
}
function Stop-RootBypass {
    if ($script:State.ContainsKey('frida-process')) {
        try {
            $docker=Get-ManagedMobSf
            Invoke-Native $docker @('exec','vulnchecker-mobsf','python3','/tmp/vulnchecker/instrument-app.py','--stop') -Quiet -TimeoutSeconds 10 | Out-Null
        } catch {Write-Log "Frida 원격 중지 확인: $($_.Exception.Message)"}
        Stop-ManagedProcessTree 'frida-process' @('docker')
    }
    $script:State['analysis-mode']='Stopped'; $script:State.Remove('dynamic-ready'); Save-State
    Set-ConnectionResult '모바일 API 분석' '중지됨' '우회 세션 종료. 다른 실행 / 연동 작업을 선택할 수 있습니다.'
    Set-ConnectionResult '루팅 우회 세션' '중지됨' '관리 Frida 세션 종료. 다음 앱 실행부터 원래 루팅 검사가 적용됩니다.'
}
function Stop-ActiveRootBypass {
    if ($script:State.ContainsKey('frida-process')) {
        $saved=$script:State['frida-process']; $active=Get-Process -Id $saved.pid -ErrorAction SilentlyContinue
        if ($active -and $active.StartTime.ToString('o') -eq $saved.start) { Stop-RootBypass }
        else {$script:State.Remove('frida-process'); Save-State}
    }
}
function Sync-MobileSessionState {
    # Observe session exit without contacting or starting Docker. Share the
    # worker's lock so an old GUI snapshot cannot overwrite an active launch.
    $lock=$null
    try {
        $lock=[IO.File]::Open((Join-Path $script:Runtime 'operation.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        if (-not (Test-Path -LiteralPath $script:StatePath)) {return $false}
        $fresh=Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $mode=$fresh.PSObject.Properties['analysis-mode']
        if (-not $mode -or $mode.Value -notin @('MobileApi','Preview')) {return $false}
        $session=$fresh.PSObject.Properties['frida-process']
        if ($session) {
            $saved=$session.Value
            $active=Get-Process -Id $saved.pid -ErrorAction SilentlyContinue
            if ($active -and $active.ProcessName -eq 'docker' -and ([DateTimeOffset]$active.StartTime).UtcDateTime.Ticks -eq ([DateTimeOffset]$saved.start).UtcDateTime.Ticks) {return $false}
        }
        $script:State=@{}; foreach ($property in $fresh.PSObject.Properties) {$script:State[$property.Name]=$property.Value}
        $script:State.Remove('frida-process'); $script:State.Remove('dynamic-ready')
        $script:State['analysis-mode']='Stopped'
        $name='분석 앱 실행'; if ($mode.Value -eq 'MobileApi') {$name='모바일 API 분석'}
        Set-ConnectionResult $name '중지됨' '앱 또는 우회 세션이 종료되었습니다. 다른 실행 / 연동 작업을 선택하세요.'
        Set-ConnectionResult '루팅 우회 세션' '중지됨' '관리 Frida 프로세스 종료 확인'
        return $true
    } catch [IO.IOException] {return $false}
    finally {if ($lock) {$lock.Dispose()}}
}
function Start-AppPreviewWorkflow {
    param([string]$Package)
    Assert-AppPackage $Package
    $acquisitionResults=@{}
    if ($script:State.ContainsKey('connections')) {
        foreach ($name in @('APK 확보','APK 호환성','분석 기기 설치','앱 초기 실행','통신 분석','앱 확보: AcquireApp')) {
            if ($script:State['connections'].ContainsKey($name)) {$acquisitionResults[$name]=$script:State['connections'][$name]}
        }
    }
    $script:State['connections']=$acquisitionResults; $script:State['analysis-mode']='PreparingPreview'; Save-State
    Set-ConnectionResult '분석 앱 실행' '준비 중' "$Package / 설치 후 루팅 우회 실행 확인"
    Stop-ActiveRootBypass
    Prepare-RootedAndroid
    Start-MobSf -Dynamic -Reconfigure -NoBrowser
    Initialize-FridaServer
    $adb=Join-Path (Get-SdkRoot) 'platform-tools\adb.exe'
    Invoke-Native $adb @('-s','emulator-5554','shell','settings','put','global','http_proxy',':0') -Quiet | Out-Null
    Start-RootBypass $Package
    $script:State['analysis-mode']='Preview'; $script:State.Remove('dynamic-ready'); Save-State
    Set-ConnectionResult '분석 앱 실행' '주입 후 실행' "$Package / 설치 후 실행 확인 / 프록시 해제. 통신 분석은 MobSF 또는 모바일 API 버튼으로 선택하세요."
}
function Start-MobileApiWorkflow {
    param([string]$Package)
    Assert-AppPackage $Package
    $script:State['connections']=@{}; $script:State['analysis-mode']='PreparingMobileApi'; Save-State
    Set-ConnectionResult '모바일 API 분석' '진행 중' "$Package / Android 고객 앱 → Burp 8080 → API 서버"
    try {
        Stop-ActiveRootBypass
        Connect-AndroidBurp
        # Reuse the compatible Frida runtime without putting MobSF capture in
        # the network path or opening its analysis page.
        Start-MobSf -Dynamic -Reconfigure -NoBrowser
        Initialize-FridaServer
        Start-RootBypass $Package
        $script:State['analysis-mode']='MobileApi'
        $script:State.Remove('dynamic-ready')
        foreach ($name in @('MobSF HTTP','MobSF 루팅 우회 JS','MobSF → Android')) {$script:State['connections'].Remove($name)}
        Save-State
        Set-ConnectionResult '통신 경로' 'Burp 직접 수집' 'Android 고객 앱 → Burp 8080 → API 서버. Burp HTTP history / Target에서 API endpoint를 확인하세요.'
        Set-ConnectionResult '모바일 API 분석' '실행 준비 완료' "$Package / 루팅 우회 후 앱 실행 / Android → Burp → API 서버. Burp HTTP history에서 대상 API를 확인하세요."
    } catch {$script:State['analysis-mode']='Failed'; Set-ConnectionResult '모바일 API 분석' '실패' $_.Exception.Message; throw}
}
function Start-MobSfAnalysisWorkflow {
    param([string]$Package='')
    $script:State['connections']=@{}; $script:State['analysis-mode']='PreparingMobSf'; Save-State
    Set-ConnectionResult '분석 환경 준비' '진행 중' 'MobSF 정적/동적 분석: Android → MobSF 수집 → 서버'
    try {
        Stop-ActiveRootBypass
        Start-CombinedMobile -Reconfigure -DirectCapture -NoBrowser
        if ($Package) {Select-MobSfInstalledTarget $Package}
        else {Start-Process "http://127.0.0.1:$($script:Config.mobSfPort)" | Out-Null}
        $script:State['analysis-mode']='MobSf'; Save-State
        $detail='선택 앱의 정적 보고서를 확인한 뒤 Dynamic Analyzer → Spawn & Inject를 누르세요. 에너지플러스 루팅 후크는 자동 포함. 앱 API/Burp 수집은 별도 버튼으로 실행하세요.'
        if ($script:State.ContainsKey('acquired-app')) {$detail+=" 확보한 앱: $($script:State['acquired-app'].package) / APK 기록: $($script:State['acquired-app'].manifest)"}
        Set-ConnectionResult '분석 환경 준비' '완료' $detail
    } catch {$script:State['analysis-mode']='Failed'; Set-ConnectionResult '분석 환경 준비' '실패' $_.Exception.Message; throw}
}
function Start-RootBypassWorkflow {
    param([string]$Package,[switch]$DirectCapture,[ValidateSet('Auto','Burp','Direct','Preview')][string]$CaptureRoute='Auto')
    Assert-AppPackage $Package
    if ($CaptureRoute -eq 'Preview') {Start-AppPreviewWorkflow $Package; return}
    if ($DirectCapture) {$CaptureRoute='Direct'}
    $direct=$CaptureRoute -eq 'Direct' -or ($CaptureRoute -eq 'Auto' -and $Package -eq 'com.gscaltex.energyplus')
    $script:State['root-capture-route']=$CaptureRoute; Save-State
    $route='Android → MobSF → Burp'; if ($direct) {$route='Android → MobSF 직접 수집'}
    Set-ConnectionResult '분석 앱 실행' '준비 중' "$Package / $route / Frida 주입 후 실행"
    Stop-ActiveRootBypass
    Start-CombinedMobile -Reconfigure -DirectCapture:$direct
    Start-RootBypass $Package
    Set-ConnectionResult '분석 앱 실행' '주입 후 실행' "$Package / $route / Frida Java 후크 초기화 확인. 실제 화면·API 응답은 별도로 확인하세요."
}
function Test-AndroidProxyTraffic {
    param([ValidateRange(1,65535)][int]$Port=8080,[switch]$HistoryTarget)
    $adb=Join-Path (Get-SdkRoot) 'platform-tools\adb.exe'
    $target='http://burp/'; $hostName='burp'; $expected='Burp Suite'
    if ($HistoryTarget) { $hostName="127.0.0.1:$($script:Config.mobSfPort)"; $target="http://$hostName/login/?vulnchecker-check="+(Get-Date -Format 'yyyyMMddHHmmss'); $expected='Mobile Security Framework - MobSF' }
    $request="(printf 'GET $target HTTP/1.1\r\nHost: $hostName\r\nConnection: close\r\n\r\n'; sleep 2) | toybox nc -w 5 -W 5 -q 5 127.0.0.1 $Port"
    $response=Invoke-Native $adb @('-s','emulator-5554','shell',$request) -Quiet
    if ($response -notmatch $expected) { throw "Android → proxy $Port 응답 없음. Intercept/reverse/프록시 경로를 확인하세요." }
    Set-ConnectionResult 'Android → 프록시 전달 검사' '연결됨' "에뮬레이터 TCP ${Port} HTTP 응답 확인: $target"
}
function Start-CombinedMobile {
    param([switch]$Reconfigure,[switch]$DirectCapture,[switch]$NoBrowser)
    Prepare-RootedAndroid
    if (-not $DirectCapture) { Start-Burp; Wait-BurpProxy }
    Start-MobSf -Dynamic -Reconfigure:$Reconfigure -NoBrowser
    # Frida repair can replace the container. Configure/copy proxy helpers only
    # after that repair, so they survive through the remaining connection checks.
    Initialize-FridaServer
    $docker=Get-ManagedMobSf
    # Preserve the data volume and other settings. Django reads this on restart.
    $scriptPath=Join-Path $script:Root 'scripts\configure-chain.py'
    Invoke-Native $docker @('cp',$scriptPath,'vulnchecker-mobsf:/tmp/vulnchecker-chain.py') -Quiet | Out-Null
    $configureArgs=@('exec','vulnchecker-mobsf','python3','/tmp/vulnchecker-chain.py')
    if ($DirectCapture) {$configureArgs+='--disable'}
    $change=Invoke-Native $docker $configureArgs -Quiet
    if ($change.Trim() -eq 'changed') {
        Write-Log 'MobSF upstream 변경 적용을 위해 관리 컨테이너를 재시작합니다. 저장된 분석 데이터는 유지됩니다.'
        Invoke-Native $docker @('restart','vulnchecker-mobsf') -Quiet | Out-Null
    }
    Wait-Http "http://127.0.0.1:$($script:Config.mobSfPort)"
    Invoke-Native $docker @('exec','vulnchecker-mobsf','/usr/bin/adb','connect','host.docker.internal:5555') -Quiet | Out-Null
    # Start only an isolated diagnostic capture if no proxy is currently alive.
    $probeArgs=@('exec','vulnchecker-mobsf','python3','/tmp/vulnchecker-chain.py','--probe-proxy')
    if ($DirectCapture) {$probeArgs+='--direct'}
    Invoke-Native $docker $probeArgs -Quiet | Out-Null
    Invoke-Native $docker @('exec','vulnchecker-mobsf','python3','/tmp/vulnchecker-chain.py','--install-ca') -Quiet | Out-Null
    Set-ConnectionResult 'MobSF CA → Android' '설정 확인' '전용 AVD 시스템 CA 설치 및 인증서 내용 일치 확인. 앱별 TLS/pinning은 별도 검사.'
    $adb=Join-Path (Get-SdkRoot) 'platform-tools\adb.exe'
    Invoke-Native $adb @('-s','emulator-5554','reverse','tcp:1337','tcp:1337') -Quiet | Out-Null
    Invoke-Native $adb @('-s','emulator-5554','shell','settings','put','global','http_proxy','127.0.0.1:1337') -Quiet | Out-Null
    if (-not $DirectCapture) {Test-AndroidProxyTraffic 1337}
    Test-AndroidProxyTraffic 1337 -HistoryTarget
    if ($DirectCapture) {
        Set-ConnectionResult 'MobSF → Android' '연결됨' 'ADB/Frida 유지. Android 1337 → MobSF 직접 수집. Burp로 전달하지 않습니다.'
        Set-ConnectionResult 'MobSF 통신 수집' '연결됨' 'Android → MobSF 자체 수집 → 서버. 정적/동적 분석은 MobSF에서 확인하세요.'
    } else {
        Set-ConnectionResult 'MobSF → Android' '연결됨' 'ADB/Frida 유지. Android proxy 1337은 MobSF를 통과해 Burp로 전달.'
        Set-ConnectionResult 'MobSF + Burp' '연결됨' 'Android 1337 → MobSF capture → host.docker.internal:8080 Burp. Dynamic Analyzer 시작 시 MobSF가 앱별 capture로 전환.'
    }
    $script:State['mobile-capture-direct']=[bool]$DirectCapture; Save-State
    if (-not $NoBrowser) {Start-Process "http://127.0.0.1:$($script:Config.mobSfPort)" | Out-Null}
}
function Disable-MobSfUpstream {
    $docker=Get-ManagedMobSf
    Invoke-Native $docker @('cp',(Join-Path $script:Root 'scripts\configure-chain.py'),'vulnchecker-mobsf:/tmp/vulnchecker-chain.py') -Quiet | Out-Null
    $change=Invoke-Native $docker @('exec','vulnchecker-mobsf','python3','/tmp/vulnchecker-chain.py','--disable') -Quiet
    if ($change.Trim() -eq 'changed') {
        Write-Log 'MobSF 단독 분석으로 전환: upstream 해제 및 관리 컨테이너 재시작 (데이터 유지)'
        Invoke-Native $docker @('restart','vulnchecker-mobsf') -Quiet | Out-Null
        Wait-Http "http://127.0.0.1:$($script:Config.mobSfPort)"
    }
    Set-ConnectionResult 'MobSF + Burp' '전환됨' 'MobSF 단독 분석 선택: Burp upstream 해제'
}
