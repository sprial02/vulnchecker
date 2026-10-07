function Invoke-ConnectionStep {
    param([string]$Name,[scriptblock]$Work)
    Set-ConnectionResult $Name '진행 중' '서비스 시작 및 연결 검사'
    try { & $Work; Set-ConnectionResult $Name '연결됨' '응답 확인 완료' }
    catch { Set-ConnectionResult $Name '실패' $_.Exception.Message; throw }
}

function Start-OpenCodeIntegration {
    param([switch]$CheckOnly)
    Start-HexStrike
    $rt=Get-KaliRuntime
    Ensure-KaliIntegration $rt
    Invoke-ConnectionStep 'OpenCode → HexStrike MCP' {
        $output=Invoke-Kali -Arguments @($rt.HexPython,"$($rt.Home)/tools/vulnchecker/check-mcp.py","$($rt.HexRepo)/hexstrike_mcp.py","http://127.0.0.1:$($script:Config.hexstrikePort)") -Quiet
        $line=@($output -split '\r?\n' | Where-Object {$_ -match '^\{"connected"'}) | Select-Object -Last 1
        if (-not $line) { throw "MCP 초기화 결과 없음: $output" }
        $result=$line | ConvertFrom-Json
        if (-not $result.connected -or $result.tools -lt 1) { throw 'MCP 도구 목록 조회 실패' }
        Write-Log "MCP 초기화 및 도구 $($result.tools)개 조회 성공 (대상 검사 실행 없음)"
        $list=Invoke-Kali -Arguments @('timeout','90','env',"OPENCODE_CONFIG=$($rt.Work)/opencode.json",$rt.OpenCode,'mcp','list') -Quiet
        if ($list -notmatch 'hexstrike' -or $list -notmatch 'connected') { throw "OpenCode 자체 MCP 연결 검증 실패: $list" }
        Write-Log $list
    }
    if (-not $CheckOnly) { Open-AnalysisTerminal -Kind OpenCode }
    Set-ConnectionResult 'OpenCode AI 계정' '사용자 확인' 'OpenCode /connect에서 허용된 AI 계정을 연결하세요. MCP 검증은 모델 호출 없이 완료.'
}

function Wait-BurpProxy {
    Set-ConnectionResult 'Burp Proxy' '진행 중' 'Burp 시작 대기. 초기 화면이 보이면 Temporary project → Next → Start Burp, Intercept Off.'
    $end=(Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $end) {
        try {
            $response=Invoke-WebRequest 'http://burp/' -Proxy 'http://127.0.0.1:8080' -UseBasicParsing -TimeoutSec 3
            if ($response.Content -match 'Burp Suite') {
                Set-ConnectionResult 'Burp Proxy' '연결됨' '127.0.0.1:8080 실제 Burp HTTP 응답 확인'
                return
            }
        } catch { }
        Start-Sleep -Seconds 2
    }
    throw 'Burp 응답 시간 초과. 초기 프로젝트 화면을 완료하고 Intercept Off 및 8080 listener를 확인하세요.'
}

function Open-AnalysisTerminal {
    param([ValidateSet('OpenCode','ADB')][string]$Kind,[ValidateSet('Shared','Mobile','System')][string]$Scope='Shared',[string]$Work='',[string]$Package='')
    $key="terminal-$Kind"
    $expectedProcess='powershell'
    if ($Kind -eq 'OpenCode' -and $Scope -eq 'Mobile') {Assert-AppPackage $Package; $key+="-Mobile-$Package"}
    if ($Kind -eq 'OpenCode' -and $Scope -eq 'System') {$key+='-System'; $expectedProcess='cmd'}
    if ($script:State.ContainsKey($key)) {
        $saved=$script:State[$key]
        $existing=Get-Process -Id $saved.pid -ErrorAction SilentlyContinue
        if ($existing -and $existing.ProcessName -eq $expectedProcess -and $existing.StartTime.ToString('o') -eq $saved.start) {
            if ($existing.MainWindowHandle -ne [IntPtr]::Zero) {
                if (-not ('VulnChecker.TerminalWindow' -as [type])) {
                    Add-Type -Namespace VulnChecker -Name TerminalWindow -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindowAsync(System.IntPtr hWnd, int nCmdShow); [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr hWnd);'
                }
                [void][VulnChecker.TerminalWindow]::ShowWindowAsync($existing.MainWindowHandle,9)
                [void][VulnChecker.TerminalWindow]::SetForegroundWindow($existing.MainWindowHandle)
            }
            Set-ConnectionResult "$Kind 명령 창" '열림' '기존 명령 창 재사용'
            return
        }
    }
    $title="VulnChecker | $Kind"; if ($Scope -eq 'Mobile') {$title="VulnChecker | 모바일 앱 | $Package"}; if ($Scope -eq 'System') {$title='VulnChecker | 시스템 IP/URL 펜테스트'}
    $code='$Host.UI.RawUI.WindowTitle = '+(Quote-PsLiteral $title)+'; '
    if ($Kind -eq 'ADB') {
        Set-AndroidEnvironment
        $code+='$env:ANDROID_SERIAL = '+(Quote-PsLiteral 'emulator-5554')+'; '
        $code+='$env:Path = '+(Quote-PsLiteral ((Join-Path (Get-SdkRoot) 'platform-tools')+';'))+' + $env:Path; '
        $code+='Write-Host '+(Quote-PsLiteral 'ADB 준비 완료 · 대상 emulator-5554 · 예: adb devices / adb shell')
    } else {
        $rt=Get-KaliRuntime
        if (-not $Work) {$Work=$rt.Work}
        if ($Scope -eq 'Mobile') {$code+='Write-Host '+(Quote-PsLiteral '모바일 대상 연결 완료. OpenCode에서 MOBILE_TARGET.md를 읽고 점검 범위를 지정하세요.')+'; '}
        $args=@('-d',$script:Config.kaliDistro,'-u',$rt.User,'--cd',$Work,'--','env',"OPENCODE_CONFIG=$($rt.Work)/opencode.json",$rt.OpenCode)
        $code+='& wsl.exe '+(($args | ForEach-Object {Quote-PsLiteral $_}) -join ' ')
    }
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    if ($Scope -eq 'System' -and $Kind -eq 'OpenCode') {
        $process=Start-Process "$env:SystemRoot\System32\cmd.exe" -WindowStyle Normal -ArgumentList @('/k',("powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded")) -PassThru
    } else {
        $process=Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -WindowStyle Normal -ArgumentList @('-NoProfile','-NoExit','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -PassThru
    }
    $script:State[$key]=@{pid=$process.Id;start=$process.StartTime.ToString('o');work=$Work;scope=$Scope}
    Save-State
    $detail='대화형 입력 준비'; if ($Scope -ne 'Shared') {$detail="$Scope 전용 창 / $Work"}
    Set-ConnectionResult "$Kind 명령 창" '열림' $detail
}

function Start-AnalysisWorkflow {
    param([ValidateSet('MobileAnalysis','PenTest','SystemAnalysis','MobileAI')][string]$Mode,[string]$Package='',[string]$Target='')
    if ($Mode -eq 'MobileAnalysis') {Start-MobSfAnalysisWorkflow; return}
    if ($Mode -eq 'MobileAI') {Assert-AppPackage $Package}
    # Publish only results from this run; failures leave the remaining steps pending.
    $script:State['connections']=@{}
    Save-State
    $steps=@('HexStrike HTTP','OpenCode → HexStrike MCP','OpenCode 명령 창')
    if ($Mode -eq 'PenTest') { $steps=@('Burp Proxy')+$steps }
    foreach ($name in $steps) { Set-ConnectionResult $name '대기' '앞 단계 완료 후 자동 진행' }
    Set-ConnectionResult '분석 환경 준비' '진행 중' $Mode
    try {
        $scope='System'; $work=''
        if ($Mode -eq 'MobileAI') {$scope='Mobile'; $work=Prepare-MobilePentestTarget $Package}
        else {$work=Prepare-SystemPentestTarget $Target}
        if ($Mode -eq 'PenTest') {
            Invoke-ConnectionStep '침투 테스트 준비' { Start-Burp; Wait-BurpProxy }
        }
        Start-OpenCodeIntegration -CheckOnly
        if ($Mode -eq 'MobileAI') {Test-MobileMcpTarget -Package $Package -Work $work}
        Open-AnalysisTerminal -Kind OpenCode -Scope $scope -Work $work -Package $Package
        $detail='서비스 및 연동 검사 완료. 대상 테스트는 OpenCode에서 시작하세요. AI 인증 상태는 별도 확인.'
        if ($Mode -eq 'SystemAnalysis') { $detail='시스템(IP/URL) 분석 준비 완료: OpenCode + HexStrike MCP. OpenCode에 대상 IP/URL과 점검 범위를 입력하세요.' }
        if ($Mode -eq 'MobileAI') {
            $detail='모바일 펜테스트 연결 완료: 선택 앱의 전체 APK 및 분석 기기 ADB 연결을 OpenCode + HexStrike 작업 폴더에 준비했습니다. MOBILE_TARGET.md를 읽고 범위를 지정하세요.'
            if ($Package) {$detail+=" 분석 앱: $Package"}
            Set-ConnectionResult '모바일 분석 연동' '준비됨' '기존 앱 실행과 MobSF/Burp 통신 설정 유지. APK/API 분석은 열린 OpenCode에서 진행하세요.'
            if ($script:State.ContainsKey('acquired-app')) {
                $app=$script:State['acquired-app']
                if ((-not $Package -or $Package -eq $app.package) -and (Test-Path -LiteralPath $app.manifest)) {
                    $folder=Split-Path $app.manifest
                    try {
                        $linuxFolder=(Invoke-Kali -Arguments @('wslpath','-a',$folder.Replace('\','/')) -Quiet).Trim()
                        Set-ConnectionResult 'APK 분석 자료' '준비됨' "확보한 전체 APK 폴더: $linuxFolder / Windows: $folder. OpenCode에 이 경로를 지정하세요."
                    } catch {Set-ConnectionResult 'APK 분석 자료' '사용자 확인' "APK 폴더: $folder. Kali에서 읽을 수 있는 경로를 OpenCode에 지정하세요."}
                }
            }
        }
        Set-ConnectionResult '분석 환경 준비' '완료' $detail
    } catch {
        $failure=$_.Exception.Message
        foreach ($name in $steps) {
            if ($script:State['connections'][$name].Status -in @('대기','진행 중')) { Set-ConnectionResult $name '미완료' '준비 중 오류 발생. 실패 항목을 해결한 뒤 같은 메뉴로 재실행하세요.' }
        }
        Set-ConnectionResult '분석 환경 준비' '실패' $failure
        throw
    }
}

function Start-Burp {
    $app=Get-AppPath Burp
    if (-not $app) { throw 'Burp 설치가 필요합니다.' }
    try {
        $response=Invoke-WebRequest 'http://burp/' -Proxy 'http://127.0.0.1:8080' -UseBasicParsing -TimeoutSec 3
        if ($response.Content -match 'Burp') { Set-ConnectionResult 'Burp Proxy' '연결됨' '127.0.0.1:8080 Burp 응답'; return }
    } catch { }
    if (-not (Test-PortAvailable 8080)) { throw '8080 포트가 사용 중이며 Burp 응답이 아닙니다.' }
    $launchConfig=Join-Path $script:Runtime 'burp-launch.json'
    '{}' | Set-Content -LiteralPath $launchConfig -Encoding ASCII
    $process=Start-Process -FilePath $app -ArgumentList ('--config-file="'+$launchConfig+'"') -PassThru
    $script:State['burp-process']=@{pid=$process.Id;start=$process.StartTime.ToString('o');path=$app}; Save-State
    Set-ConnectionResult 'Burp Proxy' '사용자 확인' 'Community: Temporary project → Next → Start Burp. --config-file로 설정 선택 단계를 생략합니다. --use-defaults는 저장 설정을 지우므로 사용하지 않습니다.'
}

function Connect-AndroidBurp {
    Prepare-RootedAndroid
    Start-Burp
    $end=(Get-Date).AddSeconds(120)
    $cert=Join-Path $script:Runtime 'burp-ca.der'
    $ready=$false
    while ((Get-Date) -lt $end) {
        try {
            Invoke-WebRequest 'http://burp/cert' -Proxy 'http://127.0.0.1:8080' -OutFile $cert -UseBasicParsing -TimeoutSec 3
            $x509=New-Object Security.Cryptography.X509Certificates.X509Certificate2($cert)
            if ($x509.Subject -notmatch 'PortSwigger|Burp') { throw 'Burp CA가 아닌 응답' }
            $ready=$true; break
        } catch { Start-Sleep -Seconds 2 }
    }
    if (-not $ready) { throw 'Burp proxy/CA 응답 없음. Burp 초기 화면을 완료하고 8080 listener를 활성화한 뒤 다시 실행하세요.' }
    $linuxPath=(Invoke-Kali -Arguments @('wslpath','-a',$cert.Replace('\','/')) -Quiet).Trim()
    Invoke-Kali -Arguments @('openssl','x509','-inform','DER','-in',$linuxPath,'-out',"$linuxPath.pem") -Quiet | Out-Null
    $hash=(Invoke-Kali -Arguments @('openssl','x509','-inform','DER','-in',$linuxPath,'-subject_hash_old','-noout') -Quiet).Trim()
    if ($hash -notmatch '^[0-9a-f]{8}$') { throw 'Burp CA hash 계산 실패' }
    $adb=Join-Path (Get-SdkRoot) 'platform-tools\adb.exe'
    Invoke-Native $adb @('-s','emulator-5554','push',"$cert.pem","/system/etc/security/cacerts/$hash.0") | Out-Null
    Invoke-Native $adb @('-s','emulator-5554','shell',"chmod 644 /system/etc/security/cacerts/$hash.0") | Out-Null
    Invoke-Native $adb @('-s','emulator-5554','reverse','tcp:8080','tcp:8080') | Out-Null
    Invoke-Native $adb @('-s','emulator-5554','shell','settings','put','global','http_proxy','127.0.0.1:8080') | Out-Null
    $proxy=Invoke-Native $adb @('-s','emulator-5554','shell','settings','get','global','http_proxy') -Quiet
    $reverse=Invoke-Native $adb @('-s','emulator-5554','reverse','--list') -Quiet
    if ($proxy.Trim() -ne '127.0.0.1:8080' -or $reverse -notmatch 'tcp:8080 tcp:8080') { throw 'Android Burp proxy 설정 확인 실패' }
    Set-ConnectionResult 'Burp Proxy' '연결됨' 'Burp CA 및 프록시 응답 확인'
    Test-AndroidProxyTraffic 8080
    Set-ConnectionResult 'Android → Burp' '설정 확인' 'ADB reverse 8080 + Android proxy + 전용 AVD 시스템 CA. 실제 HTTPS 트래픽은 Burp에서 확인; 인증서 고정 앱은 별도 처리.'
    if ($script:State.ContainsKey('dynamic-ready')) { $script:State.Remove('dynamic-ready'); Save-State; Set-ConnectionResult 'MobSF → Android' '전환됨' '현재 Android proxy는 Burp입니다. MobSF 동적 연동 버튼으로 다시 준비하세요.' }
}
