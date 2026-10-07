#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$testRoot=Join-Path $root ('runtime\selftest-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$script:Passed=0
$script:Failed=0

function Assert-True {
    param([bool]$Value,[string]$Name)
    if (-not $Value) { throw "Assertion failed: $Name" }
}
function Assert-Throws {
    param([scriptblock]$Work,[string]$Name)
    $threw=$false
    try { & $Work | Out-Null } catch { $threw=$true }
    Assert-True $threw $Name
}
function Run-Test {
    param([string]$Name,[scriptblock]$Work)
    try { & $Work; $script:Passed++; Write-Host "PASS $Name" -ForegroundColor Green }
    catch { $script:Failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" -ForegroundColor Red }
}
function Fresh-Module {
    Import-Module (Join-Path $root 'lib\Core.psm1') -Force -DisableNameChecking
    $context=Initialize-Context -Root $testRoot -ConfigPath (Join-Path $root 'config.json')
    return (Get-Module Core)
}

Run-Test 'All PowerShell files parse' {
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {$_.Extension -in @('.ps1','.psm1') -and $_.FullName -notlike '*\runtime\*'}) {
        $tok=$null; $errors=$null
        [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tok,[ref]$errors) | Out-Null
        Assert-True ($errors.Count -eq 0) $file.Name
    }
}
Run-Test 'Default configuration accepts Android 11/API30 and Community' {
    $m=Fresh-Module
    $c=Get-Content (Join-Path $root 'config.json') -Raw | ConvertFrom-Json
    Assert-Config $c
    Assert-True ($c.androidApi -eq 30 -and $c.burpEdition -eq 'Community' -and $c.androidImage -eq 'google_apis') 'User requirements'
}
Run-Test 'Reject obsolete API, Play image, command injection, duplicate/reserved ports' {
    $m=Fresh-Module
    foreach ($change in @(@{androidApi=11},@{androidImage='google_apis_playstore'},@{kaliDistro='kali;calc'},@{hexstrikeCommit='master'},@{opencodeVersion='latest;id'},@{avdName='other_avd'},@{mobSfImage='evil/image:latest'},@{hexstrikePort=8000},@{mobSfPort=5555},@{extraKaliPackages=@('nmap;id')})) {
        $c=Get-Content (Join-Path $root 'config.json') -Raw | ConvertFrom-Json
        foreach ($k in $change.Keys) { $c.$k=$change[$k] }
        Assert-Throws {Assert-Config $c} 'Unsafe config'
    }
}
Run-Test 'Cross-user elevation fails before initialization' {
    $m=Fresh-Module
    Assert-Throws {Initialize-Context -Root $testRoot -ConfigPath (Join-Path $root 'config.json') -ExpectedUserSid 'S-1-0-0'} 'Cross-user guard'
}
Run-Test 'Native failure exit code propagates; stdout retained' {
    $m=Fresh-Module
    $out=Invoke-Native "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @('-NoProfile','-Command','Write-Output native-ok; exit 0') -Quiet
    Assert-True ($out.Trim() -eq 'native-ok') 'stdout'
    Assert-Throws {Invoke-Native "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @('-NoProfile','-Command','Write-Error native-fail; exit 7') -Quiet} 'Native error'
    $out=Invoke-Native "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @('-NoProfile','-Command','exit 3010') -SuccessCodes @(0,3010) -Quiet
}
Run-Test 'Bounded native calls retain output, arguments and failures' {
    $m=Fresh-Module
    $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $out=Invoke-Native $ps @('-NoProfile','-Command','Write-Output "space and quote"; exit 0') -Quiet -TimeoutSeconds 10
    Assert-True ($out -eq 'space and quote') 'Windows argument quoting'
    Assert-Throws {Invoke-Native $ps @('-NoProfile','-Command','Write-Error bounded-fail; exit 7') -Quiet -TimeoutSeconds 10} 'Bounded native failure'
    $watch=[Diagnostics.Stopwatch]::StartNew()
    Assert-Throws {Invoke-Native $ps @('-NoProfile','-Command','Start-Sleep -Seconds 60') -Quiet -TimeoutSeconds 1} 'Hung native timeout'
    Assert-True ($watch.Elapsed.TotalSeconds -lt 8) 'Timeout actually bounds execution'
}
Run-Test 'Docker readiness reuses Desktop and probes with a time limit' {
    $m=Fresh-Module
    & $m {
        $script:ProbeCount=0; $script:DesktopLaunches=0
        function script:Get-DockerCli {return 'docker.exe'}
        function script:Get-AppPath {return 'Docker Desktop.exe'}
        function script:Get-Process {return [pscustomobject]@{Id=123}}
        function script:Test-Path {param($Path,$LiteralPath) return $Path -like 'HKLM:*'}
        function script:Start-Process {$script:DesktopLaunches++}
        function script:Start-Sleep {}
        function script:Invoke-Native {param($File,$Arguments,[switch]$Quiet,$TimeoutSeconds)
            if (-not $TimeoutSeconds -or $TimeoutSeconds -gt 10) {throw 'Probe must be bounded'}
            $script:ProbeCount++; if ($script:ProbeCount -lt 3) {throw 'not ready'}; return 'linux'
        }
        if ((Wait-Docker) -ne 'docker.exe' -or $script:DesktopLaunches -ne 0 -or $script:ProbeCount -ne 3) {throw 'Desktop duplicate launch or readiness failure'}
    }
}
Run-Test 'Docker damaged registration fails before Desktop restart' {
    $m=Fresh-Module
    & $m {
        function script:Get-DockerCli {return 'docker.exe'}
        function script:Get-AppPath {return 'Docker Desktop.exe'}
        function script:Test-Path {return $false}
        function script:Invoke-Native {throw 'not ready'}
        function script:Start-Process {throw 'Must not start damaged Desktop'}
        try {Wait-Docker; throw 'Expected failure'} catch {if ($_.Exception.Message -notmatch '설치 등록이 손상') {throw}}
    }
}
Run-Test 'Stopping root session releases analysis mode even with Docker unavailable' {
    $m=Fresh-Module
    & $m {
        $script:State['analysis-mode']='MobileApi'; $script:State['dynamic-ready']=$true
        $script:State['frida-process']=@{pid=123;start='test'}
        function script:Get-ManagedMobSf {throw 'Docker offline'}
        function script:Stop-ManagedProcessTree {param($Key,$Names) $script:State.Remove($Key)}
        Stop-RootBypass
        if ($script:State['analysis-mode'] -ne 'Stopped' -or $script:State.ContainsKey('frida-process') -or $script:State.ContainsKey('dynamic-ready')) {throw 'Analysis state remains active'}
    }
}
Run-Test 'External mobile session exit clears saved status without Docker restart' {
    $m=Fresh-Module
    & $m {
        $script:State['analysis-mode']='MobileApi'
        $script:State['frida-process']=@{pid=123;start=(Get-Date).ToString('o')}
        $script:State['customer-data']='preserved'; Save-State
        function script:Get-Process {return $null}
        function script:Get-DockerCli {throw 'Must not contact Docker'}
        if (-not (Sync-MobileSessionState)) {throw 'Session exit not detected'}
        if ($script:State['analysis-mode'] -ne 'Stopped' -or $script:State['customer-data'] -ne 'preserved' -or $script:State.ContainsKey('frida-process')) {throw 'Stale state or lost unrelated state'}
        if (Sync-MobileSessionState) {throw 'Repeated session reset'}
    }
}
Run-Test 'Session monitor respects operation lock and a live process identity' {
    $m=Fresh-Module
    & $m {
        $script:State['analysis-mode']='MobileApi'
        $start=Get-Date; $script:State['frida-process']=@{pid=123;start=$start.ToString('o')}; Save-State
        $script:SessionStart=$start
        function script:Get-Process {return [pscustomobject]@{ProcessName='docker';StartTime=$script:SessionStart}}
        if (Sync-MobileSessionState) {throw 'Live session reset'}
        $held=[IO.File]::Open((Join-Path $script:Runtime 'operation.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try {if (Sync-MobileSessionState) {throw 'Active operation overwritten'}} finally {$held.Dispose()}
    }
}
Run-Test 'Step failure saved and retry replaces failure' {
    $m=Fresh-Module
    Assert-True (-not (Invoke-Step 'test-retry' {throw 'interrupted'})) 'Failure return'
    $statePath=& $m { $script:StatePath }
    $state=Get-Content $statePath -Raw | ConvertFrom-Json
    Assert-True ($state.'test-retry'.status -eq 'failed') 'Failure persisted'
    Assert-True (Invoke-Step 'test-retry' {}) 'Retry success'
    $state=Get-Content $statePath -Raw | ConvertFrom-Json
    Assert-True ($state.'test-retry'.status -eq 'complete') 'Retry saved'
}
Run-Test 'Operation file lock rejects concurrent writers and releases cleanly' {
    $lockPath=Join-Path $testRoot 'lock-test'
    $handle=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')
    try { Assert-Throws { $other=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None'); $other.Dispose() } 'Parallel guard' }
    finally { $handle.Dispose() }
    $handle=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None'); $handle.Dispose()
}
Run-Test 'Port collision detected without altering listener' {
    $m=Fresh-Module
    $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
    $listener.Start()
    try { Assert-True (-not (Test-PortAvailable $listener.LocalEndpoint.Port)) 'Busy port' }
    finally { $listener.Stop() }
}
Run-Test 'License and administrator checks prevent installation' {
    $m=Fresh-Module
    & $m { function script:Test-Admin {return $true} }
    Assert-Throws { & $m {Install-Environment} } 'License gate'
    & $m { function script:Test-Admin {return $false} }
    Assert-Throws { & $m {Install-Environment -AcceptLicenses} } 'Admin gate'
}
Run-Test 'Reboot boundary prevents dependent installers' {
    $m=Fresh-Module
    $code=& $m {
        function script:Test-Admin {return $true}
        function script:Get-Preflight {return [pscustomobject]@{BlockingIssues=@();RAM_GB=32;RebootPending=$false}}
        function script:Get-Plan {}
        function script:Enable-VirtualizationFeatures {return $true}
        function script:Install-WingetPackage {throw 'Must not install across reboot boundary'}
        Install-Environment -AcceptLicenses
    }
    Assert-True ($code -eq 3010) 'Reboot code'
}
Run-Test 'Kali failure skips dependent tools but continues independent Android/MobSF' {
    $m=Fresh-Module
    $result=& $m {
        $script:Trace=New-Object 'System.Collections.Generic.List[string]'
        function script:Test-Admin {return $true}
        function script:Get-Preflight {return [pscustomobject]@{BlockingIssues=@();RAM_GB=32;RebootPending=$false}}
        function script:Get-Plan {}
        function script:Enable-VirtualizationFeatures {return $false}
        function script:Test-RebootPending {return $false}
        function script:Install-WingetPackage {param($Id,$App); $script:Trace.Add($App)}
        function script:Install-Kali {throw 'Kali unavailable'}
        function script:Install-KaliTools {$script:Trace.Add('kali-tools')}
        function script:Install-Android {$script:Trace.Add('android')}
        function script:Install-MobSfImage {$script:Trace.Add('mobsf')}
        $code=Install-Environment -AcceptLicenses
        @{code=$code;trace=$script:Trace.ToArray()}
    }
    Assert-True ($result.code -eq 1) 'Partial failure code'
    Assert-True ('kali-tools' -notin $result.trace -and 'android' -in $result.trace -and 'mobsf' -in $result.trace) 'Dependency ordering'
}
Run-Test 'Android root failure prevents MobSF dynamic launch' {
    $m=Fresh-Module
    & $m {
        $script:MobSfCalled=$false
        $script:State['dynamic-ready']=@{status='complete';updated='previous-run'}
        function script:Start-Emulator {}
        function script:Wait-AdbRoot {throw 'Root denied'}
        function script:Start-MobSf {$script:MobSfCalled=$true}
    }
    Assert-Throws { & $m {Start-Tool Dynamic} } 'Root rejection'
    Assert-True (-not (& $m {$script:MobSfCalled})) 'No false dynamic launch'
    Assert-True (-not (& $m {$script:State.ContainsKey('dynamic-ready')})) 'Previous success cleared'
}
Run-Test 'CLI uses correct default config under Windows PowerShell 5.1' {
    $m=Fresh-Module
    $out=Invoke-Native "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'VulnChecker.ps1'),'-Action','Plan') -Quiet
    Assert-True ($out -match 'Burp Suite Community' -and $out -match 'OpenCode') 'Default CLI entrypoint'
}
Run-Test 'Container ADB non-root result cannot report dynamic ready' {
    $m=Fresh-Module
    & $m {
        $script:State.Remove('dynamic-ready')
        $script:DockerArgs=New-Object 'System.Collections.Generic.List[string]'
        function script:Wait-Docker {return 'mock-docker'}
        function script:Wait-Http {}
        function script:Initialize-MobSfVolume {}
        function script:Invoke-WebRequest {return [pscustomobject]@{StatusCode=200}}
        function script:Test-PortAvailable {return $true}
        function script:Invoke-Native {
            param($File,[string[]]$Arguments,[switch]$Quiet)
            $script:DockerArgs.Add(($Arguments -join ' '))
            if ($Arguments[0] -eq 'inspect' -and $Arguments -contains '--format') {return 'true'}
            if ($Arguments[0] -eq 'inspect') {throw 'Container absent'}
            if (($Arguments -join ' ') -match 'shell id -u') {return '2000'}
            return 'mock'
        }
    }
    Assert-Throws { & $m {Start-MobSf -Dynamic} } 'Container root check'
    Assert-True (-not (& $m {$script:State.ContainsKey('dynamic-ready')})) 'No stale success'
    $args=& $m {$script:DockerArgs.ToArray()}
    Assert-True (($args -join "`n") -match '127.0.0.1:8000:8000' -and ($args -join "`n") -match 'MOBSF_ANALYZER_IDENTIFIER=host.docker.internal:5555') 'Local binding and ADB endpoint'
}
Run-Test 'Existing unowned MobSF container is never stopped or replaced' {
    $m=Fresh-Module
    & $m {
        $script:Mutated=$false
        function script:Wait-Docker {return 'mock-docker'}
        function script:Invoke-Native {
            param($File,[string[]]$Arguments,[switch]$Quiet)
            if ($Arguments[0] -eq 'image') {return '{}'}
            if ($Arguments[0] -eq 'inspect') {return '[{"Config":{"Labels":{"io.vulnchecker.owner":"someone-else"}},"State":{"Running":true}}]'}
            $script:Mutated=$true
            throw 'Unexpected mutation'
        }
    }
    Assert-Throws { & $m {Start-MobSf} } 'Unowned guard'
    Assert-True (-not (& $m {$script:Mutated})) 'No external mutation'
}
Run-Test 'Guide and all packaged entrypoints exist' {
    foreach ($p in @('Start.cmd','VulnChecker.ps1','docs\GUIDE.ko.html','scripts\kali-bootstrap.sh','scripts\hexstrike-local.py')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $root $p)) $p
    }
    $html=Get-Content (Join-Path $root 'docs\GUIDE.ko.html') -Raw -Encoding UTF8
    Assert-True ($html -match 'API 30' -and $html -match 'host.docker.internal:5555' -and $html -match '재부팅') 'Guide content'
}

Run-Test 'Capacity counts missing components only; unknown engine adds no reinstall cost' {
    $m=Fresh-Module
    $all=@((New-InventoryItem 'burp' 'Burp' $true $true 'existing.exe' ''),(New-InventoryItem 'docker-engine' 'Docker engine' $null $false '' 'stopped'))
    $plan=Get-CapacityPlan ([pscustomobject]@{Items=$all})
    Assert-True ($plan.RequiredGB -eq 0 -and $plan.AdditionalGB -eq 0 -and $plan.Unknown.Count -eq 1) 'No arbitrary 60GB gate'
    $all+=(New-InventoryItem 'sdk' 'SDK' $false $false '' '' $true 2)
    $plan=Get-CapacityPlan ([pscustomobject]@{Items=$all})
    Assert-True ($plan.RequiredGB -eq 7 -and $plan.Items.Count -eq 1) 'Only missing SDK plus reserve'
}
Run-Test 'Preflight discovers installations before reading capacity and allows installed low-space PC' {
    $m=Fresh-Module
    $result=& $m {
        $script:Order=New-Object 'System.Collections.Generic.List[string]'
        function script:Get-InstallationInventory {
            $script:Order.Add('inventory')
            [pscustomobject]@{Items=@((New-InventoryItem 'burp' 'Burp' $true $true 'existing.exe' ''))}
        }
        function script:Get-CimInstance {
            param($ClassName,$Filter)
            $script:Order.Add($ClassName)
            switch ($ClassName) {
                'Win32_OperatingSystem' {[pscustomobject]@{Caption='Windows 11';BuildNumber=26300;ProductType=1}}
                'Win32_ComputerSystem' {[pscustomobject]@{HypervisorPresent=$true;TotalPhysicalMemory=32GB}}
                'Win32_Processor' {[pscustomobject]@{VirtualizationFirmwareEnabled=$true}}
                'Win32_LogicalDisk' {[pscustomobject]@{FreeSpace=2GB}}
            }
        }
        function script:Test-RebootPending {return $false}
        $pre=Get-Preflight
        @{Pre=$pre;Order=$script:Order.ToArray()}
    }
    Assert-True ($result.Order[0] -eq 'inventory') 'Inventory precedes disk'
    Assert-True ($result.Pre.RequiredFreeGB -eq 0 -and $result.Pre.BlockingIssues.Count -eq 0) 'No disk block for installed software'
}
Run-Test 'Inventory uses default existing Kali user; never requires managed account' {
    $m=Fresh-Module
    & $m {
        function script:Get-LinuxInventory {
            [pscustomobject]@{user='existinguser';home='/home/existinguser';hexstrike=[pscustomobject]@{path='/home/existinguser/hexstrike-ai';python='/home/existinguser/hexstrike-ai/venv/bin/python';dependencies=$true};commands=[pscustomobject]@{opencode='/home/existinguser/.opencode/bin/opencode'}}
        }
    }
    $rt=Get-KaliRuntime
    Assert-True ($rt.User -eq 'existinguser' -and $rt.HexPython -match '/venv/bin/python' -and $rt.OpenCode -match '/.opencode/bin') 'Reuse actual paths'
}
Run-Test 'Empty Android install is classified without null-property errors' {
    $m=Fresh-Module
    & $m {
        function script:Get-AppPath {return $null}
        function script:Get-WslDistributions {return @()}
        function script:Get-AndroidInventory {return [pscustomobject]@{Sdks=@();Avds=@()}}
        function script:Get-DockerCli {throw 'Not installed'}
    }
    $inventory=Get-InstallationInventory
    $sdk=@($inventory.Items | Where-Object {$_.Id -eq 'sdk'})[0]
    $avd=@($inventory.Items | Where-Object {$_.Id -eq 'avd'})[0]
    Assert-True ($sdk.Installed -eq $false -and $avd.Installed -eq $false) 'Correct empty inventory'
}
Run-Test 'Closed Docker engine is unknown, not missing image' {
    $m=Fresh-Module
    & $m {
        function script:Get-AppPath {return 'existing.exe'}
        function script:Get-JavaHome {return 'existing-java'}
        function script:Get-WslDistributions {return @()}
        function script:Get-AndroidInventory {return [pscustomobject]@{Sdks=@();Avds=@()}}
        function script:Get-DockerCli {throw 'Engine not running'}
    }
    $inventory=Get-InstallationInventory
    $row=@($inventory.Items | Where-Object {$_.Id -eq 'mobsf'})[0]
    Assert-True ($null -eq $row.Installed -and -not $row.NeedsInstall -and $row.Status -eq '미확인') 'Stopped is not uninstalled'
}
Run-Test 'WSL UTF8 encoding and environment restored after native success/failure' {
    $m=Fresh-Module
    $old=$env:WSL_UTF8; $encoding=[Console]::OutputEncoding.CodePage
    if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
        try { Invoke-Native wsl.exe @('--version') -Quiet | Out-Null } catch {}
        try { Invoke-Native wsl.exe @('--vulnchecker-invalid-argument') -Quiet | Out-Null } catch {}
    }
    Assert-True ($env:WSL_UTF8 -eq $old -and [Console]::OutputEncoding.CodePage -eq $encoding) 'Encoding restore'
}
Run-Test 'Fully installed existing Kali environment skips package and source changes' {
    $m=Fresh-Module
    $result=& $m {
        $script:NativeCalled=$false; $script:Integrated=$false
        function script:Get-KaliRuntime {
            param([switch]$Refresh)
            $commands=[pscustomobject]@{nmap='/usr/bin/nmap';ffuf='/usr/bin/ffuf';sqlmap='/usr/bin/sqlmap';nikto='/usr/bin/nikto';nuclei='/usr/bin/nuclei';gobuster='/usr/bin/gobuster';feroxbuster='/usr/bin/feroxbuster';jadx='/usr/bin/jadx';apktool='/usr/bin/apktool';frida='/existing/venv/bin/frida';objection='/existing/venv/bin/objection';opencode='/existing/opencode'}
            [pscustomobject]@{User='existinguser';HexRepo='/existing/hexstrike-ai';HexPython='/existing/venv/bin/python';OpenCode='/existing/opencode';Probe=[pscustomobject]@{user='existinguser';commands=$commands;hexstrike=[pscustomobject]@{dependencies=$true;path='/existing/hexstrike-ai'}}}
        }
        function script:Ensure-KaliIntegration {param($Runtime); $script:Integrated=$true}
        function script:Invoke-Kali {$script:NativeCalled=$true;throw 'Unexpected install'}
        Install-KaliTools
        @{Integrated=$script:Integrated;NativeCalled=$script:NativeCalled}
    }
    Assert-True ($result.Integrated -and -not $result.NativeCalled) 'No download or repository mutation'
}
Run-Test 'Missing mobile tools preserves detected HexStrike Python and OpenCode paths' {
    $m=Fresh-Module
    & $m { param($actualRoot); $script:Root=$actualRoot } $root
    $result=& $m {
        $script:BootstrapArgs=$null
        function script:Get-KaliRuntime {
            param([switch]$Refresh)
            $commands=[pscustomobject]@{nmap='/usr/bin/nmap';ffuf='/usr/bin/ffuf';sqlmap='/usr/bin/sqlmap';nikto='/usr/bin/nikto';nuclei='/usr/bin/nuclei';gobuster='/usr/bin/gobuster';feroxbuster='/usr/bin/feroxbuster';jadx='/usr/bin/jadx';apktool='/usr/bin/apktool';frida=$null;objection=$null;opencode='/existing/opencode'}
            [pscustomobject]@{User='existinguser';HexRepo='/existing/hexstrike-ai';HexPython='/existing/venv/bin/python';OpenCode='/existing/opencode';Probe=[pscustomobject]@{user='existinguser';commands=$commands;hexstrike=[pscustomobject]@{dependencies=$true;path='/existing/hexstrike-ai'}}}
        }
        function script:Ensure-KaliIntegration {param($Runtime)}
        function script:Invoke-Kali {
            param([string[]]$Arguments,[switch]$Root,[switch]$Quiet,[string]$InputText)
            if ($Arguments[0] -eq 'bash') { $script:BootstrapArgs=$Arguments }
            return ''
        }
        Install-KaliTools
        $script:BootstrapArgs
    }
    Assert-True ('existinguser' -in $result -and '/existing/venv/bin/python' -in $result -and '/existing/opencode' -in $result) 'Retain reuse selections even during repair'
}

Run-Test 'Early emulator exit reports log before boot timeout' {
    $m=Fresh-Module
    & $m {
        $script:State['emulator-process']=@{pid=2147483647;start='invalid'}
        function script:Get-SdkRoot {return 'C:\mock-sdk'}
        function script:Invoke-Native {throw 'ADB should not run after process exit'}
        function script:Get-EmulatorFailure {return 'AVD startup diagnostic'}
    }
    $message=''
    try { & $m {Wait-AndroidBoot} } catch {$message=$_.Exception.Message}
    Assert-True ($message -match 'AVD startup diagnostic') 'Immediate original failure evidence'
}
Run-Test 'MCP failure prevents launching OpenCode UI and records failure' {
    $m=Fresh-Module
    & $m {
        $script:UiStarted=$false
        function script:Start-HexStrike {}
        function script:Get-KaliRuntime {return [pscustomobject]@{HexPython='python';Home='/home/user';HexRepo='/repo';Work='/work';OpenCode='opencode'}}
        function script:Ensure-KaliIntegration {}
        function script:Invoke-Kali {return 'MCP handshake failed'}
        function script:Start-Process {$script:UiStarted=$true}
    }
    Assert-Throws { & $m {Start-OpenCodeIntegration} } 'Handshake failure'
    Assert-True (-not (& $m {$script:UiStarted})) 'No falsely ready UI'
    Assert-True ((& $m {$script:State.connections['OpenCode → HexStrike MCP'].Status}) -eq '실패') 'Visible edge failure'
}
Run-Test 'Unmanaged MobSF volume remains untouched' {
    $m=Fresh-Module
    & $m {
        $script:Mutated=$false
        function script:Invoke-Native {
            param($File,[string[]]$Arguments,[switch]$Quiet)
            if ($Arguments[0] -eq 'volume' -and $Arguments[1] -eq 'inspect') {return '[{"Labels":null}]'}
            $script:Mutated=$true; throw 'Unexpected mutation'
        }
    }
    Assert-Throws { & $m {Initialize-MobSfVolume 'docker' 'image'} } 'Unknown ownership'
    Assert-True (-not (& $m {$script:Mutated})) 'Unrelated volume not changed'
}
Run-Test 'MobSF early exit reports container error without full HTTP timeout' {
    $m=Fresh-Module
    & $m {
        function script:Wait-Docker {return 'mock-docker'}
        function script:Initialize-MobSfVolume {}
        function script:Test-PortAvailable {return $true}
        function script:Invoke-Native {
            param($File,[string[]]$Arguments,[switch]$Quiet)
            if ($Arguments[0] -eq 'inspect' -and $Arguments -contains '--format') {return 'false'}
            if ($Arguments[0] -eq 'inspect') {throw 'Absent'}
            if ($Arguments[0] -eq 'logs') {return 'Volume PermissionError'}
            return '{}'
        }
    }
    $message=''
    try { & $m {Start-MobSf} } catch {$message=$_.Exception.Message}
    Assert-True ($message -match 'Volume PermissionError') 'Original container diagnostic'
}
Run-Test 'App package rejects shell syntax before invoking tools' {
    $m=Fresh-Module
    foreach ($value in @('', 'com.app;id', 'com.app test', '../app', 'com.app`n')) {
        Assert-Throws { & $m {param($p) Assert-AppPackage $p} $value } 'Invalid package'
    }
    & $m {Assert-AppPackage 'com.company.app'}
}
Run-Test 'Missing Realm library prevents misleading root-bypass launch' {
    $m=Fresh-Module
    & $m {
        $script:FridaAttempted=$false
        function script:Get-AppDiagnostics {return [pscustomobject]@{missing_realm_crash_seen=$true;realm_libraries=@()}}
        function script:Initialize-FridaServer {$script:FridaAttempted=$true}
    }
    Assert-Throws { & $m {Start-RootBypass 'com.company.app'} } 'Missing library failure'
    Assert-True (-not (& $m {$script:FridaAttempted})) 'No hooks claiming to fix native library'
}
Run-Test 'Proxy connectivity requires actual response and keeps TCP input open' {
    $m=Fresh-Module
    & $m {
        function script:Get-SdkRoot {return 'C:\mock-sdk'}
        function script:Invoke-Native {param($File,[string[]]$Arguments,[switch]$Quiet) $script:ProxyArgs=$Arguments; return 'HTTP/1.1 200 OK Burp Suite'}
        Test-AndroidProxyTraffic 1337
    }
    Assert-True ((& $m {$script:ProxyArgs[-1]}) -match 'sleep 2.*1337') 'TCP input and selected port'
    & $m {function script:Invoke-Native {return ''}}
    Assert-Throws { & $m {Test-AndroidProxyTraffic 1337} } 'Empty response is failure'
}
Run-Test 'Frida initialization reports server error instead of ready' {
    $m=Fresh-Module
    & $m {
        function script:Get-ManagedMobSf {return 'docker'}
        function script:Copy-MobileHelpers {}
        function script:Invoke-Native {
            param($File,[string[]]$Arguments,[switch]$Quiet)
            if ($Arguments -contains '/tmp/vulnchecker/ensure-frida.py') {throw 'ServerNotRunningError'}
            if ($Arguments -contains '-c') {return '16.7.19'}
            return ''
        }
    }
    Assert-Throws { & $m {Initialize-FridaServer} } 'No false ready'
    Assert-True ((& $m {$script:State.connections['Frida server'].Status}) -eq '실패') 'Visible failure'
}
Run-Test 'MobSF mode uses its own capture without Burp or API app injection' {
    $m=Fresh-Module
    $order=& $m {
        $script:Calls=New-Object 'System.Collections.Generic.List[string]'
        Set-ConnectionResult 'stale result' '완료' 'old'
        function script:Stop-ActiveRootBypass {$script:Calls.Add('stop-session')}
        function script:Start-CombinedMobile {param([switch]$Reconfigure,[switch]$DirectCapture) if (-not $Reconfigure -or -not $DirectCapture) {throw 'Independent MobSF capture required'}; $script:Calls.Add('mobsf')}
        function script:Start-Burp {throw 'MobSF mode must not start Burp'}
        function script:Start-RootBypass {throw 'MobSF must use its own Dynamic Analyzer instrumentation'}
        function script:Open-AnalysisTerminal {throw 'No terminal requested for MobSF'}
        function script:Start-Process {}
        Start-Tool MobileAnalysis
        $script:Calls.ToArray()
    }
    Assert-True (($order -join ',') -eq 'stop-session,mobsf') 'Ordered independent MobSF preparation'
    Assert-True ((& $m {$script:State.connections['분석 환경 준비'].Status}) -eq '완료') 'Final workflow result'
    Assert-True (-not (& $m {$script:State.connections.ContainsKey('stale result')})) 'No stale results'
}
Run-Test 'Web proxy test waits for Burp and opens only a system OpenCode after MCP checks' {
    $m=Fresh-Module
    $order=& $m {
        $script:Calls=New-Object 'System.Collections.Generic.List[string]'
        function script:Start-Burp {$script:Calls.Add('burp')}
        function script:Prepare-SystemPentestTarget {return '/system'}
        function script:Wait-BurpProxy {$script:Calls.Add('burp-ready')}
        function script:Start-OpenCodeIntegration {param([switch]$CheckOnly) if (-not $CheckOnly) {throw 'Checks required'}; $script:Calls.Add('mcp')}
        function script:Open-AnalysisTerminal {param($Kind) $script:Calls.Add($Kind)}
        Start-Tool WebProxyTest
        $script:Calls.ToArray()
    }
    Assert-True (($order -join ',') -eq 'burp,burp-ready,mcp,OpenCode') 'Ordered PenTest preparation'
}
Run-Test 'System and mobile AI use MCP without Burp or changing Android state' {
    foreach ($mode in @('SystemAnalysis','MobileAI')) {
        $m=Fresh-Module
        $order=& $m {
            param($Mode)
            $script:Calls=New-Object 'System.Collections.Generic.List[string]'
            $script:State['analysis-mode']='MobSf'; $script:State['dynamic-ready']=$true
            function script:Start-Burp {throw 'Unexpected Burp'}
            function script:Prepare-RootedAndroid {throw 'Unexpected Android change'}
            function script:Stop-ActiveRootBypass {throw 'Unexpected session stop'}
            function script:Start-MobSf {throw 'Unexpected MobSF'}
            function script:Prepare-MobilePentestTarget {param($Package) if ($Package -ne 'com.company.selected') {throw 'Wrong target'}; $script:Calls.Add('target'); return '/mobile'}
            function script:Prepare-SystemPentestTarget {$script:Calls.Add('target'); return '/system'}
            function script:Test-MobileMcpTarget {param($Package,$Work) if ($Package -ne 'com.company.selected' -or $Work -ne '/mobile') {throw 'Wrong mobile MCP target'}}
            function script:Start-OpenCodeIntegration {param([switch]$CheckOnly) if (-not $CheckOnly) {throw 'Checks required'}; $script:Calls.Add('mcp')}
            function script:Open-AnalysisTerminal {param($Kind,$Scope,$Work,$Package) $script:Calls.Add("$Kind-$Scope")}
            Start-Tool $Mode -Package 'com.company.selected'
            if ($script:State['analysis-mode'] -ne 'MobSf' -or -not $script:State['dynamic-ready']) {throw 'Mobile state changed'}
            $script:Calls.ToArray()
        } $mode
        $scope='System'; if ($mode -eq 'MobileAI') {$scope='Mobile'}
        Assert-True (($order -join ',') -eq "target,mcp,OpenCode-$scope") "Independent $mode preparation"
        Assert-True ((& $m {$script:State.connections['분석 환경 준비'].Status}) -eq '완료') 'Preparation complete'
        Assert-True (-not (& $m {$script:State.connections.ContainsKey('Burp Proxy')})) 'No Burp prerequisite'
    }
}
Run-Test 'HexStrike health allows the upstream telemetry response time' {
    $m=Fresh-Module
    & $m {
        function script:Get-KaliRuntime {return @{HexPython='python';Work='/work'}}
        function script:Ensure-KaliIntegration {}
        function script:Test-PortAvailable {return $false}
        function script:Invoke-Kali {
            param([string[]]$Arguments,[switch]$Quiet)
            if ($Arguments[0] -eq 'curl') {
                $index=[array]::IndexOf($Arguments,'--max-time')
                if ([int]$Arguments[$index+1] -lt 15) {throw 'Health timeout too short for telemetry'}
                return '{"status":"healthy","tools_status":{}}'
            }
        }
        Start-HexStrike
        if ($script:State.connections['HexStrike HTTP'].Status -ne '연결됨') {throw 'Health not ready'}
    }
}
Run-Test 'System and mobile AI MCP failure prevents interactive launch' {
    foreach ($mode in @('SystemAnalysis','MobileAI')) {
        $m=Fresh-Module
        & $m {
            $script:Opened=$false
            function script:Prepare-MobilePentestTarget {return '/mobile'}
            function script:Prepare-SystemPentestTarget {return '/system'}
            function script:Start-OpenCodeIntegration {throw 'MCP connection failed'}
            function script:Open-AnalysisTerminal {$script:Opened=$true}
        }
        Assert-Throws {& $m {param($Mode) Start-Tool $Mode -Package 'com.company.app'} $mode} 'MCP failure propagated'
        Assert-True (-not (& $m {$script:Opened})) 'No terminal after MCP failure'
        Assert-True ((& $m {$script:State.connections['분석 환경 준비'].Status}) -eq '실패') 'Visible failure'
        Assert-True ((& $m {$script:State.connections['OpenCode 명령 창'].Status}) -eq '미완료') 'No false ready state'
    }
}
Run-Test 'Workflow failure marks unfinished steps and does not open terminals' {
    $m=Fresh-Module
    & $m {
        $script:Opened=$false
        function script:Start-CombinedMobile {throw 'Android connection denied'}
        function script:Start-OpenCodeIntegration {throw 'Must not reach MCP'}
        function script:Open-AnalysisTerminal {$script:Opened=$true}
    }
    Assert-Throws { & $m {Start-Tool MobileAnalysis} } 'Preparation failure propagated'
    Assert-True (-not (& $m {$script:Opened})) 'No interactive windows after failure'
    Assert-True ((& $m {$script:State.connections['분석 환경 준비'].Status}) -eq '실패') 'Final failure'
    Assert-True ((& $m {$script:State['analysis-mode']}) -eq 'Failed') 'Failed mode is not marked ready'
}
Run-Test 'GUI worker starts hidden without launching a real process' {
    $m=Fresh-Module
    $style=& $m {
        function script:Start-Process {param($FilePath,$WindowStyle,$ArgumentList,[switch]$PassThru) return $WindowStyle}
        Start-Worker -Action Launch -Tool PenTest
    }
    Assert-True ($style -eq 'Hidden') 'Background worker'
}
Run-Test 'Repeated launch reuses an owned live terminal' {
    $m=Fresh-Module
    & $m {
        $script:Started=$false
        $proc=Get-Process -Id $PID
        $script:State['terminal-ADB']=@{pid=$proc.Id;start=$proc.StartTime.ToString('o')}
        function script:Start-Process {$script:Started=$true;throw 'Duplicate terminal'}
        Open-AnalysisTerminal ADB
    }
    Assert-True (-not (& $m {$script:Started})) 'No duplicate window'
}
Run-Test 'Frida container replacement precedes proxy helper copy and opens MobSF once' {
    $m=Fresh-Module
    $result=& $m {
        $script:Generation='old'; $script:Copied=''; $script:Browsers=0; $script:TrafficChecks=0
        function script:Prepare-RootedAndroid {}
        function script:Start-Burp {}
        function script:Wait-BurpProxy {}
        function script:Start-MobSf {param([switch]$Dynamic,[switch]$Reconfigure,[switch]$NoBrowser) if (-not $NoBrowser) {throw 'Premature browser'} }
        function script:Initialize-FridaServer {$script:Generation='replacement'}
        function script:Get-ManagedMobSf {return 'docker'}
        function script:Get-SdkRoot {return 'C:\mock-sdk'}
        function script:Wait-Http {}
        function script:Invoke-Native {
            param($File,[string[]]$Arguments,[switch]$Quiet)
            if ($Arguments[0] -eq 'cp') { $script:Copied=$script:Generation }
            if ($Arguments -contains '/tmp/vulnchecker-chain.py') {
                if ($script:Copied -ne 'replacement') {throw 'Helper lost during replacement'}
                return 'unchanged'
            }
            return ''
        }
        function script:Test-AndroidProxyTraffic {$script:TrafficChecks++}
        function script:Start-Process {param($FilePath) if ($FilePath -notlike 'http://127.0.0.1:*') {throw 'Unexpected browser URL'}; $script:Browsers++}
        Start-CombinedMobile -Reconfigure
        @{Copied=$script:Copied;Browsers=$script:Browsers;TrafficChecks=$script:TrafficChecks}
    }
    Assert-True ($result.Copied -eq 'replacement' -and $result.Browsers -eq 1 -and $result.TrafficChecks -eq 2) 'Fresh helper, verified traffic, single browser'
}
Run-Test 'Navigation config replaces spaced hardware-key setting' {
    $m=Fresh-Module
    $avd=Join-Path $testRoot 'avds\VulnChecker_API30.avd'
    New-Item -ItemType Directory -Path $avd -Force | Out-Null
    'hw.mainKeys = yes' | Set-Content (Join-Path $avd 'config.ini')
    & $m {param($path) $script:TestAvdRoot=$path; function script:Get-AvdRoot {return $script:TestAvdRoot}; Set-ManagedNavigationConfig} (Split-Path $avd)
    $text=Get-Content (Join-Path $avd 'config.ini') -Raw
    Assert-True ($text -match 'hw.mainKeys=no' -and $text -notmatch '= yes') 'Software navigation enabled'
}
Run-Test 'Shutdown refuses a reused process identity and retains state' {
    $m=Fresh-Module
    $p=Get-Process -Id $PID
    & $m {param($id) $script:State['terminal-ADB']=@{pid=$id;start='2000-01-01T00:00:00.0000000Z'}} $PID
    Assert-Throws {& $m {Stop-ManagedProcessTree 'terminal-ADB' @('powershell','pwsh')}} 'Reused PID protected'
    Assert-True (-not $p.HasExited -and (& $m {$script:State.ContainsKey('terminal-ADB')})) 'No unrelated process stopped'
}
Run-Test 'Shutdown ends an owned background PowerShell and clears its record' {
    $m=Fresh-Module
    $p=Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -WindowStyle Hidden -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 90') -PassThru
    try {
        & $m {param($id,$start) $script:State['terminal-ADB']=@{pid=$id;start=$start}; Stop-ManagedProcessTree 'terminal-ADB' @('powershell')} $p.Id $p.StartTime.ToString('o')
        Assert-True ($p.WaitForExit(5000) -and -not (& $m {$script:State.ContainsKey('terminal-ADB')})) 'Owned process ended'
    } finally { if (-not $p.HasExited) {Stop-Process -Id $p.Id -Force} }
}
Run-Test 'Play defaults remain separate for an older config' {
    $m=Fresh-Module
    $result=& $m {
        $script:Config.PSObject.Properties.Remove('playApi'); $script:Config.PSObject.Properties.Remove('playAvdName')
        Get-PlaySpec
    }
    Assert-True ($result.Name -eq 'VulnChecker_Play_API30' -and $result.Serial -eq 'emulator-5560' -and $result.Image -match 'google_apis_playstore') 'Dedicated Play AVD'
}
Run-Test 'Play config rejects shared AVD names and reserved transfer ports' {
    $m=Fresh-Module
    foreach ($change in @(@{playApi=37},@{playAvdName='VulnChecker_API30'},@{mobSfPort=5560},@{hexstrikePort=5561})) {
        $c=Get-Content (Join-Path $root 'config.json') -Raw | ConvertFrom-Json
        foreach ($k in $change.Keys) {$c.$k=$change[$k]}
        Assert-Throws {Assert-Config $c} 'Play environment guard'
    }
}
Run-Test 'Play launch rejects a foreign AVD before proxy settings change' {
    $m=Fresh-Module
    & $m {
        $script:Modified=$false
        function script:Initialize-PlayAvd {return @{Name='VulnChecker_Play_API30';Serial='emulator-5560'}}
        function script:Get-SdkRoot {return 'C:\mock-sdk'}
        function script:Invoke-Native {
            param($File,[string[]]$Arguments,[switch]$Quiet)
            if ($Arguments[0] -eq 'devices') {return "List of devices attached`nemulator-5560 device"}
            if ($Arguments -contains 'name') {return 'Customer_AVD'}
            $script:Modified=$true
        }
    }
    Assert-Throws {& $m {Start-PlayDownload}} 'Foreign AVD protected'
    Assert-True (-not (& $m {$script:Modified})) 'No proxy/account/device changes'
}
Run-Test 'Account reset stops Play before requesting a data wipe' {
    $m=Fresh-Module
    $result=& $m {
        $script:Stopped=$false; $script:Wiped=$false
        function script:Stop-PlayDownload {$script:Stopped=$true}
        function script:Start-PlayDownload {param([switch]$WipeData,[switch]$AcceptLicenses) if (-not $script:Stopped) {throw 'Wipe before stop'}; $script:Wiped=[bool]$WipeData}
        Invoke-AppAcquisition -Tool ResetPlay
        $script:Wiped
    }
    Assert-True $result 'Only explicit reset requests wipe'
}
Run-Test 'Source device discovery reports unauthorized devices without selecting them' {
    $m=Fresh-Module
    $path=& $m {
        function script:Get-SdkRoot {return 'C:\mock-sdk'}
        function script:Invoke-Native {return "List of devices attached`nemulator-5554 device`nusb-one device`nusb-two unauthorized"}
        Get-AcquisitionDevices
        Join-Path $script:Runtime 'acquisition-devices.json'
    }
    $devices=(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).Devices
    Assert-True ($devices.Count -eq 2 -and $devices[1].Status -eq 'unauthorized') 'Physical devices only, authorization preserved'
}
Run-Test 'Direct capture disables Burp preparation and upstream forwarding' {
    $m=Fresh-Module
    $result=& $m {
        $script:Disabled=$false; $script:DirectProbe=$false; $script:TrafficChecks=0
        function script:Prepare-RootedAndroid {}
        function script:Start-Burp {throw 'Direct mode must not start Burp'}
        function script:Wait-BurpProxy {throw 'Direct mode must not wait for Burp'}
        function script:Start-MobSf {}
        function script:Initialize-FridaServer {}
        function script:Get-ManagedMobSf {return 'mock-docker'}
        function script:Get-SdkRoot {return 'C:\mock-sdk'}
        function script:Wait-Http {}
        function script:Invoke-Native {
            param($File,[string[]]$Arguments,[switch]$Quiet)
            if ($Arguments -contains '--disable') {$script:Disabled=$true; return 'unchanged'}
            if ($Arguments -contains '--direct') {$script:DirectProbe=$true}
            return ''
        }
        function script:Test-AndroidProxyTraffic {param($Port,[switch]$HistoryTarget) if (-not $HistoryTarget) {throw 'Burp internal page requested in direct mode'}; $script:TrafficChecks++}
        function script:Start-Process {}
        Start-CombinedMobile -DirectCapture
        @{Disabled=$script:Disabled;DirectProbe=$script:DirectProbe;TrafficChecks=$script:TrafficChecks;Saved=$script:State['mobile-capture-direct']}
    }
    Assert-True ($result.Disabled -and $result.DirectProbe -and $result.Saved -and $result.TrafficChecks -eq 1) 'Direct route and response check'
}
Run-Test 'Session exit between process lookup and snapshot clears its record' {
    $m=Fresh-Module
    & $m {
        $script:LookupCount=0; $stamp=Get-Date
        $script:State['frida-process']=@{pid=12345;start=$stamp.ToString('o')}
        $script:FakeProcess=[pscustomobject]@{Id=12345;ProcessName='docker';StartTime=$stamp}
        function script:Get-Process {$script:LookupCount++; if ($script:LookupCount -eq 1) {$script:FakeProcess}}
        function script:Get-CimInstance {return @()}
        function script:Stop-Process {throw 'Must not stop an exited process'}
        Stop-ManagedProcessTree 'frida-process' @('docker')
        if ($script:State.ContainsKey('frida-process')) {throw 'Exited session retained'}
    }
}
Run-Test 'Root launch reconfigures managed MobSF and resolves explicit and automatic routes' {
    foreach ($case in @(@('com.gscaltex.energyplus','Auto',$true),@('com.gscaltex.energyplus','Burp',$false),@('com.company.app','Direct',$true),@('com.company.app','Auto',$false))) {
        $m=Fresh-Module
        $result=& $m {
            param($Package,$Route)
            $script:Prepared=$false; $script:Direct=$false; $script:Launched=''
            function script:Start-CombinedMobile {param([switch]$Reconfigure,[switch]$DirectCapture) if (-not $Reconfigure) {throw 'Reconfiguration omitted'}; $script:Prepared=$true; $script:Direct=[bool]$DirectCapture}
            function script:Start-RootBypass {param($Package) if (-not $script:Prepared) {throw 'Injected before capture prepared'}; $script:Launched=$Package}
            Start-RootBypassWorkflow $Package -CaptureRoute $Route
            @{Direct=$script:Direct;Package=$script:Launched;Route=$script:State['root-capture-route']}
        } $case[0] $case[1]
        Assert-True ($result.Direct -eq $case[2] -and $result.Package -eq $case[0] -and $result.Route -eq $case[1]) 'Selected app and route retained'
    }
}
Run-Test 'Root launch replaces only its tracked live Frida session before reconfiguration' {
    $m=Fresh-Module
    & $m {
        $stamp=Get-Date; $script:State['frida-process']=@{pid=12345;start=$stamp.ToString('o')}
        $script:FakeProcess=[pscustomobject]@{StartTime=$stamp}; $script:Stopped=$false
        function script:Get-Process {return $script:FakeProcess}
        function script:Stop-RootBypass {$script:Stopped=$true}
        function script:Start-CombinedMobile {if (-not $script:Stopped) {throw 'Session not stopped before configuration change'}}
        function script:Start-RootBypass {}
        Start-RootBypassWorkflow 'com.company.app'
    }
}
Run-Test 'Acquisition forwards instrumentation choice and route to installation' {
    $m=Fresh-Module
    & $m {
        function script:Import-AcquisitionApp {param($Serial,$Package,$ApkPaths,[switch]$AcceptLicenses,[switch]$LaunchWithBypass,$CaptureRoute) if (-not $LaunchWithBypass -or $CaptureRoute -ne 'Direct' -or $Package -ne 'com.company.app') {throw 'Acquisition launch settings lost'}}
        Invoke-AppAcquisition -Tool AcquireApp -Package 'com.company.app' -LaunchWithBypass -CaptureRoute Direct
    }
}
Run-Test 'GUI log reader permits concurrent worker logging' {
    $m=Fresh-Module
    & $m {
        [IO.File]::WriteAllText($script:Log,'initial')
        $stream=[IO.File]::Open($script:Log,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        try {Write-Log 'concurrent writer'; if ((Read-SharedText $script:Log) -notmatch 'concurrent writer') {throw 'Worker log missing'}} finally {$stream.Dispose()}
    }
}
Run-Test 'Mobile API prepares direct Burp and Frida without MobSF capture or browser' {
    $m=Fresh-Module
    $order=& $m {
        $script:Calls=New-Object 'System.Collections.Generic.List[string]'
        function script:Stop-ActiveRootBypass {$script:Calls.Add('stop')}
        function script:Connect-AndroidBurp {$script:Calls.Add('direct-burp')}
        function script:Start-MobSf {param([switch]$Dynamic,[switch]$Reconfigure,[switch]$NoBrowser) if (-not $Dynamic -or -not $Reconfigure -or -not $NoBrowser) {throw 'Hidden compatible runtime required'}; $script:Calls.Add('frida-runtime')}
        function script:Initialize-FridaServer {$script:Calls.Add('frida-server')}
        function script:Start-RootBypass {param($Package) if ($Package -ne 'com.company.selected') {throw 'Wrong target app'}; $script:Calls.Add('app')}
        function script:Start-CombinedMobile {throw 'MobSF capture must not be in API route'}
        function script:Set-MobileAnalysisTarget {param($Package) if ($Package -ne 'com.company.selected') {throw 'Wrong selected target'}}
        Start-Tool MobileApi -Package 'com.company.selected'
        if ($script:State['analysis-mode'] -ne 'MobileApi') {throw 'API mode not saved'}
        $script:Calls.ToArray()
    }
    Assert-True (($order -join ',') -eq 'stop,direct-burp,frida-runtime,frida-server,app') 'Direct API pipeline'
}
Run-Test 'Mobile API does not launch app when Burp connection fails' {
    $m=Fresh-Module
    & $m {
        function script:Stop-ActiveRootBypass {}
        function script:Connect-AndroidBurp {throw 'Burp unavailable'}
        function script:Start-RootBypass {throw 'Must not launch before Burp'}
    }
    Assert-Throws {& $m {Start-MobileApiWorkflow 'com.company.app'}} 'Burp failure propagated'
    Assert-True ((& $m {$script:State.connections['모바일 API 분석'].Status}) -eq '실패') 'API failure visible'
}
Run-Test 'Acquisition preview runs rooted app without starting a capture route' {
    $m=Fresh-Module
    & $m {
        $script:ProxyCleared=$false
        function script:Stop-ActiveRootBypass {}
        function script:Prepare-RootedAndroid {}
        function script:Start-MobSf {}
        function script:Initialize-FridaServer {}
        function script:Get-SdkRoot {return 'C:\mock-sdk'}
        function script:Invoke-Native {param($File,[string[]]$Arguments,[switch]$Quiet) if ($Arguments -contains ':0') {$script:ProxyCleared=$true}}
        function script:Start-RootBypass {if (-not $script:ProxyCleared) {throw 'Preview must clear stale proxy'}}
        function script:Start-CombinedMobile {throw 'Preview must not start capture'}
        function script:Start-Burp {throw 'Preview must not start Burp'}
        Set-ConnectionResult '분석 기기 설치' '완료' 'APK set installed'
        Start-RootBypassWorkflow 'com.company.app' -CaptureRoute Preview
        if ($script:State['analysis-mode'] -ne 'Preview') {throw 'Preview mode missing'}
        if ($script:State.connections['분석 기기 설치'].Status -ne '완료') {throw 'Installation result lost during preview'}
    }
}
Run-Test 'Native UTF8 Korean stdout and stderr survive success and failure with encoding restored' {
    $fixture=Join-Path $testRoot 'native-utf8.ps1'
    $code=@'
param([int]$Result=0)
$utf8=New-Object Text.UTF8Encoding($false)
$stdout=[Console]::OpenStandardOutput(); $stderr=[Console]::OpenStandardError()
$bytes=$utf8.GetBytes("정상 한국어 출력`n"); $stdout.Write($bytes,0,$bytes.Length); $stdout.Flush()
$bytes=$utf8.GetBytes("오류 한국어 연결 거부`n"); $stderr.Write($bytes,0,$bytes.Length); $stderr.Flush()
exit $Result
'@
    [IO.File]::WriteAllText($fixture,$code,(New-Object Text.UTF8Encoding($true)))
    $original=[Console]::OutputEncoding.CodePage
    $output=Invoke-Native "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @('-NoProfile','-ExecutionPolicy','Bypass','-File',$fixture) -NativeEncoding ([Text.Encoding]::UTF8) -Quiet
    Assert-True ($output -match '정상 한국어 출력' -and $output -match '오류 한국어 연결 거부') 'Korean stdout and stderr'
    $failure=''
    try {Invoke-Native "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @('-NoProfile','-ExecutionPolicy','Bypass','-File',$fixture,'-Result','7') -NativeEncoding ([Text.Encoding]::UTF8) -Quiet | Out-Null} catch {$failure=$_.Exception.Message}
    Assert-True ($failure -match '종료 코드 7' -and $failure -match '오류 한국어 연결 거부') 'Decoded error retained'
    Assert-True ([Console]::OutputEncoding.CodePage -eq $original) 'Console encoding restored after failure'
}
Run-Test 'Missing Play download device reports Korean instructions before AVD query' {
    $m=Fresh-Module
    $message=& $m {
        function script:Get-SdkRoot {return 'C:\mock-sdk'}
        function script:Invoke-Native {param($File,[string[]]$Arguments,[switch]$Quiet) if ($Arguments[0] -ne 'devices') {throw 'Must not query disconnected emulator'}; return "List of devices attached`nemulator-5554 device"}
        try {Get-AcquisitionApps 'emulator-5560'} catch {$_.Exception.Message}
    }
    Assert-True ($message -match 'Google Play 다운로드 기기' -and $message -match '부팅 완료' -and $message -notmatch 'Must not query') 'Friendly offline message'
}
Run-Test 'Source devices must be online and authorized before listing apps' {
    foreach ($status in @('offline','unauthorized')) {
        $m=Fresh-Module
        $message=& $m {
            param($Status)
            $script:DeviceStatus=$Status
            function script:Get-SdkRoot {return 'C:\mock-sdk'}
            function script:Invoke-Native {param($File,[string[]]$Arguments,[switch]$Quiet) if ($Arguments[0] -ne 'devices') {throw 'Unexpected app query'}; return "List of devices attached`nusb-one $script:DeviceStatus"}
            try {Get-AcquisitionApps 'usb-one'} catch {$_.Exception.Message}
        } $status
        Assert-True ($message -match '확인|허용' -and $message -notmatch 'Unexpected') 'Connection guidance before app query'
    }
}
Run-Test 'Selected mobile target must exist on the managed analysis device' {
    $m=Fresh-Module
    & $m {
        function script:Get-SdkRoot {return 'C:\mock-sdk'}
        function script:Assert-AcquisitionDeviceConnected {param($Serial) if ($Serial -ne 'emulator-5554') {throw 'Wrong device'}}
        function script:Assert-ManagedAvd {}
        function script:Invoke-Native {param($File,$Arguments,[switch]$Quiet) if ($Arguments[-1] -eq 'com.company.installed') {return "package:/data/app/base.apk`npackage:/data/app/split.apk"}; return ''}
        $target=Set-MobileAnalysisTarget 'com.company.installed'
        if ($target.ApkPaths.Count -ne 2 -or $target.Package -ne 'com.company.installed') {throw 'Wrong selected APK set'}
        try {Set-MobileAnalysisTarget 'com.company.missing'; throw 'Missing package accepted'} catch {if ($_.Exception.Message -eq 'Missing package accepted') {throw}}
        if ($script:State['mobile-target'].Package -ne 'com.company.installed') {throw 'Invalid target replaced valid selection'}
    }
}
Run-Test 'Installation progress counts completed stages and never completes a failed run' {
    $m=Fresh-Module
    & $m {
        Initialize-InstallationProgress
        if ($script:State['install-progress'].Steps.Count -ne 9) {throw 'Full installation plan missing stages'}
        Set-InstallationProgressStage 'preflight' 'complete'
        Invoke-Step 'windows-features' {} | Out-Null
        Invoke-Step 'burp' {throw 'download failed'} | Out-Null
        Set-ConnectionResult '환경 설치' '일부 실패' 'Burp failed'
        $view=Get-InstallationProgressView $script:State['install-progress']
        if ($view.Percent -ne 22 -or $view.Completed -ne 2 -or $view.Total -ne 9 -or $view.Text -notmatch '일부 실패') {throw 'Failed stage counted as completion'}
        Set-ConnectionResult '환경 설치' '재부팅 필요' 'Resume later'
        if ((Get-InstallationProgressView $script:State['install-progress']).Text -notmatch '재부팅 필요') {throw 'Reboot progress not paused'}
        Initialize-InstallationProgress
        if ((Get-InstallationProgressView $script:State['install-progress']).Percent -ne 0) {throw 'Previous run completion leaked into new run'}
        foreach ($step in $script:State['install-progress'].Steps) {Set-InstallationProgressStage $step.Id 'complete'}
        Set-ConnectionResult '환경 설치' '완료' 'All ready'
        if ((Get-InstallationProgressView $script:State['install-progress']).Percent -ne 100) {throw 'Completed install not shown as 100 percent'}
    }
}
Run-Test 'Installation progress denominator matches selected web profile and persists' {
    $m=Fresh-Module
    & $m {
        $script:Config.profile='web'; Initialize-InstallationProgress
        Set-InstallationProgressStage 'preflight' 'complete'; Save-State
        $saved=Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
        $view=Get-InstallationProgressView $saved.'install-progress'
        if ($view.Total -ne 5 -or $view.Percent -ne 20) {throw 'Progress includes unselected Android/Docker stages'}
    }
}
Run-Test 'Preflight permits a fresh PC without WinGet to enter automatic installation' {
    $m=Fresh-Module
    & $m {
        function script:Get-CimInstance {
            param($ClassName,$Filter)
            switch ($ClassName) {
                'Win32_OperatingSystem' {[pscustomobject]@{Caption='Windows 11';BuildNumber=26300;ProductType=1}}
                'Win32_ComputerSystem' {[pscustomobject]@{HypervisorPresent=$true;TotalPhysicalMemory=32GB}}
                'Win32_Processor' {[pscustomobject]@{VirtualizationFirmwareEnabled=$true}}
                'Win32_LogicalDisk' {[pscustomobject]@{FreeSpace=100GB}}
            }
        }
        function script:Get-Command {param($Name,$ErrorAction) if ($Name -eq 'winget.exe') {return $null}; throw 'Unexpected lookup'}
        function script:Test-RebootPending {return $false}
        $inventory=[pscustomobject]@{Items=@((New-InventoryItem 'burp' 'Burp' $false $false '' 'Fresh PC' $true 1),(New-InventoryItem 'docker' 'Docker' $false $false '' 'Fresh PC' $true 4))}
        $pre=Get-Preflight -Inventory $inventory
        if ($pre.BlockingIssues.Count) {throw ($pre.BlockingIssues -join '; ')}
        if ($pre.AdditionalInstallGB -ne 5) {throw 'Missing apps excluded from install plan'}
    }
}
Run-Test 'Fresh PC installation continues all downloads after the reboot boundary' {
    $m=Fresh-Module
    $result=& $m {
        $script:Trace=New-Object 'System.Collections.Generic.List[string]'
        $script:FirstBoot=$true
        $script:Inventory=[pscustomobject]@{Items=@((New-InventoryItem 'mobsf' 'MobSF' $null $null '' 'Engine not installed'))}
        function script:Test-Admin {return $true}
        function script:Get-Preflight {return [pscustomobject]@{BlockingIssues=@();RAM_GB=32;RebootPending=$false}}
        function script:Get-Plan {}
        function script:Enable-VirtualizationFeatures {return $script:FirstBoot}
        function script:Test-RebootPending {return $false}
        function script:Install-WingetPackage {param($Id,$App) $script:Trace.Add($App)}
        function script:Install-AndroidJava {$script:Trace.Add('java')}
        function script:Install-Kali {$script:Trace.Add('kali')}
        function script:Install-KaliTools {$script:Trace.Add('kali-tools')}
        function script:Install-Android {$script:Trace.Add('android')}
        function script:Install-MobSfImage {$script:Trace.Add('mobsf')}
        $first=Install-Environment -AcceptLicenses
        if ($script:Trace.Count -or $script:State.connections['환경 설치'].Status -ne '재부팅 필요') {throw 'Premature downloads or misleading reboot state'}
        $script:FirstBoot=$false
        $second=Install-Environment -AcceptLicenses
        @{First=$first;Second=$second;Trace=$script:Trace.ToArray();Status=$script:State.connections['환경 설치'].Status}
    }
    Assert-True ($result.First -eq 3010 -and $result.Second -eq 0 -and $result.Status -eq '완료') 'Resume to completed install'
    Assert-True (($result.Trace -join ',') -eq 'Burp,java,Docker,kali,kali-tools,android,mobsf') 'All fresh dependencies including unknown MobSF installed'
}
Run-Test 'WinGet absent is automatically registered or bootstrapped from Microsoft' {
    $m=Fresh-Module
    $result=& $m {
        $script:Bootstrapped=$false; $script:Trace=New-Object 'System.Collections.Generic.List[string]'
        function script:Get-WingetCli {if ($script:Bootstrapped) {return 'downloaded-winget.exe'}; return $null}
        function script:Add-AppxPackage {throw 'Not yet installed'}
        function script:Install-PackageProvider {param($Name,$MinimumVersion,$Scope,[switch]$Force,$ErrorAction) $script:Trace.Add('nuget')}
        function script:Install-Module {param($Name,$Repository,$Scope,[switch]$Force,$ErrorAction) if ($Name -ne 'Microsoft.WinGet.Client' -or $Repository -ne 'PSGallery') {throw 'Wrong bootstrap source'}; $script:Trace.Add('module')}
        function script:Import-Module {param($Name,$ErrorAction) $script:Trace.Add('import')}
        function script:Repair-WinGetPackageManager {param([switch]$AllUsers,$ErrorAction) $script:Trace.Add('repair'); $script:Bootstrapped=$true}
        function script:Invoke-Native {param($File,$Arguments,[switch]$Quiet,$TimeoutSeconds) if ($File -ne 'downloaded-winget.exe' -or $Arguments[0] -ne '--version') {throw 'Invalid WinGet validation'}; return 'v1.12.0'}
        $path=Ensure-Winget
        @{Path=$path;Trace=$script:Trace.ToArray()}
    }
    Assert-True ($result.Path -eq 'downloaded-winget.exe' -and ($result.Trace -join ',') -eq 'nuget,module,import,repair') 'Missing installer automatically prepared'
}
Run-Test 'Installed WinGet and installed applications do not trigger bootstrap downloads' {
    $m=Fresh-Module
    & $m {
        function script:Get-WingetCli {return 'existing-winget.exe'}
        function script:Invoke-Native {return 'v1.12.0'}
        function script:Install-Module {throw 'Must not download'}
        if ((Ensure-Winget) -ne 'existing-winget.exe') {throw 'WinGet not reused'}
        function script:Get-AppPath {return 'existing-app.exe'}
        function script:Ensure-Winget {throw 'Existing app should not need WinGet'}
        Install-WingetPackage 'Docker.DockerDesktop' 'Docker'
    }
}
Run-Test 'Missing Windows application is downloaded after installer bootstrap' {
    $m=Fresh-Module
    & $m {
        $script:Installed=$false
        function script:Get-AppPath {if ($script:Installed) {return 'new-app.exe'}; return $null}
        function script:Ensure-Winget {return 'prepared-winget.exe'}
        function script:Invoke-Native {param($File,$Arguments,$SuccessCodes)
            if ($File -ne 'prepared-winget.exe' -or 'Docker.DockerDesktop' -notin $Arguments -or '--silent' -notin $Arguments -or '--accept-package-agreements' -notin $Arguments) {throw 'Missing unattended download/install arguments'}
            $script:Installed=$true
        }
        Install-WingetPackage 'Docker.DockerDesktop' 'Docker'
        if (-not $script:Installed) {throw 'Missing app only checked, never installed'}
    }
}
Run-Test 'Installation results expose the failed stage and real error' {
    $m=Fresh-Module
    & $m {
        Invoke-Step 'burp' {throw 'download blocked by proxy'} | Out-Null
        $message=Get-WorkerCompletionMessage -Action Install -ExitCode 1 -ConnectionsPath (Join-Path $script:Runtime 'connections.json') -Started (Get-Date).AddMinutes(-1)
        if ($message -notmatch 'Burp' -or $message -notmatch 'download blocked by proxy') {throw 'Actual install failure hidden'}
        if ((Get-WorkerCompletionMessage -Action Install -ExitCode 3010) -notmatch '재부팅 필요') {throw 'Reboot treated as failure'}
        if ((Get-WorkerCompletionMessage -Action Verify -ExitCode 1) -notmatch '설치가 필요한') {throw 'Missing components treated as unexplained failure'}
    }
}
Run-Test 'Mobile target preparation failure prevents MCP and terminal startup' {
    $m=Fresh-Module
    & $m {
        function script:Prepare-MobilePentestTarget {throw 'Selected APK unavailable'}
        function script:Start-OpenCodeIntegration {throw 'Must not start MCP'}
        function script:Open-AnalysisTerminal {throw 'Must not open terminal'}
    }
    Assert-Throws {& $m {Start-Tool MobileAI -Package 'com.company.app'}} 'Missing target propagated'
    Assert-True ((& $m {$script:State.connections['분석 환경 준비'].Detail}) -eq 'Selected APK unavailable') 'Target failure retained'
}
Run-Test 'Mobile and system terminals have separate identities and working directories' {
    $m=Fresh-Module
    & $m {
        $script:Launches=New-Object 'System.Collections.Generic.List[object]'
        function script:Get-KaliRuntime {return @{User='test';Work='/home/test/work';OpenCode='/bin/opencode'}}
        function script:Start-Process {param($FilePath,$WindowStyle,$ArgumentList,[switch]$PassThru) $script:Launches.Add(@{File=$FilePath;Args=$ArgumentList}); return (Get-Process -Id $PID)}
        Open-AnalysisTerminal -Kind OpenCode -Scope Mobile -Work '/work/mobile/com.company.app' -Package 'com.company.app'
        Open-AnalysisTerminal -Kind OpenCode -Scope System -Work '/work/system'
        if ($script:Launches.Count -ne 2 -or $script:Launches[1].File -notlike '*\cmd.exe') {throw 'System did not create a separate CMD'}
        if (-not $script:State.ContainsKey('terminal-OpenCode-Mobile-com.company.app') -or -not $script:State.ContainsKey('terminal-OpenCode-System')) {throw 'Terminal identities collided'}
        $mobile=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($script:Launches[0].Args[-1]))
        if ($mobile -notmatch '/work/mobile/com.company.app') {throw 'Mobile target working directory lost'}
        if ($script:Launches[1].Args[0] -ne '/k') {throw 'System CMD is not persistent'}
    }
}
Run-Test 'System target accepts IP or HTTP URL and rejects command text' {
    $m=Fresh-Module
    & $m {
        function script:Get-KaliRuntime {return @{Work='/work'}}
        function script:Invoke-Kali {param($Arguments,$InputText,[switch]$Quiet) if ($Arguments[0] -eq 'tee') {$script:TargetJson=$InputText}}
        Prepare-SystemPentestTarget '192.0.2.1' | Out-Null
        if (($script:TargetJson | ConvertFrom-Json).target -ne '192.0.2.1') {throw 'Target not passed'}
        Prepare-SystemPentestTarget 'https://example.com/api' | Out-Null
    }
    Assert-Throws {& $m {Prepare-SystemPentestTarget 'ip; whoami'}} 'Command rejected as target'
    Assert-Throws {& $m {Prepare-SystemPentestTarget 'file:///etc/passwd'}} 'Non HTTP URL rejected'
}
Write-Host "Self-test: $script:Passed passed, $script:Failed failed. No installers, reboot, or scans executed."
@{passed=$script:Passed;failed=$script:Failed;time=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testRoot 'result.json') -Encoding UTF8
if ($script:Failed) {exit 1}
exit 0
