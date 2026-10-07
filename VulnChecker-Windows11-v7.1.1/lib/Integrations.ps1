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
        if (-not $result.PSObject.Properties['execution'] -or -not $result.execution) {throw 'MCP 실제 명령 왕복 확인 실패'}
        Write-Log "MCP 초기화 · 도구 $($result.tools)개 · 로컬 확인 명령 왕복 성공 (대상 검사 실행 없음)"
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

function Enable-SystemWebCapture {
    $rt=Get-KaliRuntime
    Ensure-KaliIntegration $rt
    $proxy='http://127.0.0.1:8080'
    $direct=$false
    try {
        $probe=Invoke-Kali -Arguments @('curl','--fail','--silent','--max-time','3','--proxy',$proxy,'http://burp/') -Quiet
        $direct=$probe -match 'Burp'
    } catch {}
    if (-not $direct) {
        $proxy='http://127.0.0.1:18880'
        $alive=$false
        if ($script:State.ContainsKey('burp-relay-process')) {
            $saved=$script:State['burp-relay-process']; $p=Get-Process -Id $saved.pid -ErrorAction SilentlyContinue
            $protocol=if ($saved -is [Collections.IDictionary]) {$saved['protocol']} elseif ($saved.PSObject.Properties['protocol']) {$saved.protocol} else {''}
            $alive=$p -and $p.ProcessName -eq 'powershell' -and $p.StartTime.ToString('o') -eq $saved.start -and $protocol -eq 'reverse-v2'
            if (-not $alive) {Stop-ManagedProcessTree 'burp-relay-process' @('powershell')}
        }
        if (-not $alive) {
            $content=Get-Content -LiteralPath (Join-Path $script:Root 'scripts\web-relay.py') -Raw -Encoding UTF8
            Invoke-Kali -Arguments @('tee',"$($rt.Home)/tools/vulnchecker/web-relay.py") -InputText $content -Quiet | Out-Null
            Invoke-Kali -Arguments @($rt.HexPython,"$($rt.Home)/tools/vulnchecker/web-relay.py",'--stop') -Quiet | Out-Null
            $token=[guid]::NewGuid().ToString('N')
            $linux=Start-Process wsl.exe -WindowStyle Hidden -ArgumentList @('-d',$script:Config.kaliDistro,'-u',$rt.User,'--',$rt.HexPython,"$($rt.Home)/tools/vulnchecker/web-relay.py",'--token',$token) -RedirectStandardError (Join-Path $script:Runtime 'web-relay-error.log') -PassThru
            $script:State['web-relay-process']=@{pid=$linux.Id;start=$linux.StartTime.ToString('o')}; Save-State
            $code='& '+(Quote-PsLiteral (Join-Path $script:Root 'scripts\burp-relay.ps1'))+' -Token '+(Quote-PsLiteral $token)
            $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
            $p=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -RedirectStandardError (Join-Path $script:Runtime 'burp-relay-error.log') -PassThru
            $script:State['burp-relay-process']=@{pid=$p.Id;start=$p.StartTime.ToString('o');protocol='reverse-v2'}; Save-State
            Start-Sleep -Seconds 2
        }
    }
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{proxy=$proxy} | ConvertTo-Json -Compress)))
    try {$result=Invoke-Kali -Arguments @($rt.HexPython,"$($rt.Home)/tools/vulnchecker/web-tools.py",'--configure',$encoded) -Quiet | ConvertFrom-Json}
    catch {throw "Kali → Burp 연결 실패. Burp 8080 수신기·Intercept Off·WSL 릴레이 로그를 확인하세요. 직접 연결로 전환하지 않았습니다. $($_.Exception.Message)"}
    if (-not $result.connected) {throw 'Kali → Burp 프록시 확인 실패'}
    Set-ConnectionResult '자동 웹 점검 → Burp' '연결됨' "$proxy / Kali에서 Burp 응답 및 CA 확인 / 지원 도구: $($result.tools -join ', '). 관리 web-tools 경로로 수행합니다."
    Set-ConnectionResult '수동 브라우저 → Burp' '사용자 확인' 'Burp → Proxy → Intercept → Open browser. 일반 Edge/Chrome은 프록시·HTTPS CA 설정이 필요합니다. Intercept Off에서도 HTTP history에 기록됩니다.'
}

function Prepare-SystemWorkflowContext {
    param([string]$Work,[bool]$Web)
    $rt=Get-KaliRuntime
    $spec=@{work=$Work;web=$Web;helper="$($rt.Home)/tools/vulnchecker/web-tools.py"}
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($spec | ConvertTo-Json -Compress)))
    $helper=Get-Content -LiteralPath (Join-Path $script:Root 'scripts\prepare-system-context.py') -Raw -Encoding UTF8
    Invoke-Kali -Arguments @($rt.HexPython,'-',$encoded) -InputText $helper -Quiet | Out-Null
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
        $terminalScript=Join-Path $script:Root 'scripts\opencode-terminal.ps1'
        $code+='& '+(Quote-PsLiteral $terminalScript)+' -Distro '+(Quote-PsLiteral $script:Config.kaliDistro)+' -User '+(Quote-PsLiteral $rt.User)+' -Work '+(Quote-PsLiteral $Work)+' -Config '+(Quote-PsLiteral "$($rt.Work)/opencode.json")+' -Executable '+(Quote-PsLiteral $rt.OpenCode)
    }
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    if ($Scope -eq 'System' -and $Kind -eq 'OpenCode') {
        $process=Start-Process "$env:SystemRoot\System32\cmd.exe" -WindowStyle Normal -ArgumentList @('/k',("powershell.exe -NoProfile -NoExit -ExecutionPolicy Bypass -EncodedCommand $encoded")) -PassThru
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
        if ($Mode -eq 'PenTest') {Enable-SystemWebCapture}
        if ($Mode -ne 'MobileAI') {Prepare-SystemWorkflowContext -Work $work -Web ($Mode -eq 'PenTest')}
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

function Get-BurpProxyOwner {
    $listeners=@(Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue)
    foreach ($listener in $listeners) {
        $process=Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)" -ErrorAction SilentlyContinue
        if (-not $process -or -not $process.ExecutablePath) {continue}
        if ([IO.Path]::GetFileName($process.ExecutablePath) -in @('BurpSuite.exe','BurpSuiteCommunity.exe','BurpSuitePro.exe')) {return Get-BurpInstallationInfo $process.ExecutablePath}
        if ($process.Name -in @('java.exe','javaw.exe') -and $process.CommandLine -match 'burpsuite.*\.jar') {
            foreach ($installation in @(Get-BurpInstallations)) {
                if ($process.ExecutablePath.StartsWith((Split-Path $installation.Path)+'\',[StringComparison]::OrdinalIgnoreCase)) {return $installation}
            }
        }
    }
    return $null
}

function Start-Burp {
    $app=Get-AppPath Burp
    if (-not $app) { throw 'Burp 설치가 필요합니다.' }
    $selected=Get-BurpInstallationInfo $app
    Set-ConnectionResult 'Burp 실행 버전' '선택됨' "$($selected.Name) $($selected.DisplayVersion) / $app"
    $ready=$false
    try {
        $response=Invoke-WebRequest 'http://burp/' -Proxy 'http://127.0.0.1:8080' -UseBasicParsing -TimeoutSec 3
        $ready=$response.Content -match 'Burp'
    } catch { }
    if ($ready) {
        $owner=Get-BurpProxyOwner
        if (-not $owner) {throw 'Burp 8080 응답은 있지만 실행 파일 확인이 되지 않습니다. 수신 프로세스의 경로를 확인하세요.'}
        if ($owner.Path -ne $app) {throw "다른 Burp가 8080을 사용 중입니다: $($owner.DisplayVersion) / $($owner.Path). 프로젝트를 저장하고 해당 Burp를 닫은 뒤 재실행하세요. 선택한 버전: $($selected.DisplayVersion) / $app"}
        Set-ConnectionResult 'Burp Proxy' '연결됨' "$($selected.DisplayVersion) / $app / 127.0.0.1:8080 응답 및 프로세스 경로 확인"
        return
    }
    if (-not (Test-PortAvailable 8080)) { throw '8080 포트가 사용 중이며 Burp 응답이 아닙니다.' }
    $launchConfig=Join-Path $script:Runtime 'burp-launch.json'
    '{}' | Set-Content -LiteralPath $launchConfig -Encoding ASCII
    $process=Start-Process -FilePath $app -ArgumentList ('--config-file="'+$launchConfig+'"') -PassThru
    $script:State['burp-process']=@{pid=$process.Id;start=$process.StartTime.ToString('o');path=$app}; Save-State
    Set-ConnectionResult 'Burp Proxy' '사용자 확인' 'Community: Temporary project → Next → Start Burp. --config-file로 설정 선택 단계를 생략합니다. --use-defaults는 저장 설정을 지우므로 사용하지 않습니다.'
}

function Export-AndroidBurpCa {
    param([string]$CertificatePath)
    $certificate=New-Object Security.Cryptography.X509Certificates.X509Certificate2($CertificatePath)
    $md5=[Security.Cryptography.MD5]::Create()
    try {
        if ($certificate.Subject -notmatch 'PortSwigger|Burp') {throw 'Burp CA가 아닌 인증서'}
        # Android API30 uses OpenSSL's legacy subject hash: first four MD5
        # bytes of the DER subject, interpreted little-endian and padded to 8.
        $digest=$md5.ComputeHash($certificate.SubjectName.RawData)
        $hash=([uint32]($digest[0]+([uint32]$digest[1]*256)+([uint32]$digest[2]*65536)+([uint32]$digest[3]*16777216))).ToString('x8')
        $base64=[Convert]::ToBase64String($certificate.RawData)
        $lines=for ($i=0; $i -lt $base64.Length; $i+=64) {$base64.Substring($i,[Math]::Min(64,$base64.Length-$i))}
        $pem="-----BEGIN CERTIFICATE-----`n"+($lines -join "`n")+"`n-----END CERTIFICATE-----`n"
        $path=$CertificatePath+'.pem'
        [IO.File]::WriteAllText($path,$pem,[Text.Encoding]::ASCII)
        return [pscustomobject]@{Hash=$hash;Path=$path;Pem=$pem}
    } finally {$md5.Dispose(); $certificate.Dispose()}
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
    $ca=Export-AndroidBurpCa -CertificatePath $cert
    $hash=$ca.Hash
    $adb=Join-Path (Get-SdkRoot) 'platform-tools\adb.exe'
    Invoke-Native $adb @('-s','emulator-5554','push',$ca.Path,"/system/etc/security/cacerts/$hash.0") | Out-Null
    Invoke-Native $adb @('-s','emulator-5554','shell',"chmod 644 /system/etc/security/cacerts/$hash.0") | Out-Null
    $installed=Invoke-Native $adb @('-s','emulator-5554','shell','cat',"/system/etc/security/cacerts/$hash.0") -Quiet
    if ($installed.Trim() -ne $ca.Pem.Trim()) {throw 'Android Burp CA 설치 내용 불일치. 프록시 연결을 완료하지 않았습니다.'}
    Invoke-Native $adb @('-s','emulator-5554','reverse','tcp:8080','tcp:8080') | Out-Null
    Invoke-Native $adb @('-s','emulator-5554','shell','settings','put','global','http_proxy','127.0.0.1:8080') | Out-Null
    $proxy=Invoke-Native $adb @('-s','emulator-5554','shell','settings','get','global','http_proxy') -Quiet
    $reverse=Invoke-Native $adb @('-s','emulator-5554','reverse','--list') -Quiet
    if ($proxy.Trim() -ne '127.0.0.1:8080' -or $reverse -notmatch 'tcp:8080 tcp:8080') { throw 'Android Burp proxy 설정 확인 실패' }
    Set-ConnectionResult 'Burp Proxy' '연결됨' 'Burp CA 및 프록시 응답 확인'
    Test-AndroidProxyTraffic 8080
    Set-ConnectionResult 'Android → Burp' '연결됨' 'ADB reverse 8080 + Android proxy + Burp 시스템 CA 내용 검증 완료. Proxy → HTTP history에서 요청을 확인하세요(Intercept off에서도 기록).'
    if ($script:State.ContainsKey('dynamic-ready')) { $script:State.Remove('dynamic-ready'); Save-State; Set-ConnectionResult 'MobSF → Android' '전환됨' '현재 Android proxy는 Burp입니다. MobSF 동적 연동 버튼으로 다시 준비하세요.' }
}
