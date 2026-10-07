Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-Context {
    param([string]$Root, [string]$ConfigPath, [string]$ExpectedUserSid)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($ExpectedUserSid -and $ExpectedUserSid -ne $sid) {
        throw '관리자 승격에 다른 계정이 사용되었습니다. WSL/SDK는 사용자별 설치입니다. 같은 계정으로 관리자 권한을 사용하세요.'
    }
    $script:Root = $Root
    $script:ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    $script:Config = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Config $script:Config
    $script:Inventory=$null
    $script:LinuxRuntime=$null
    $script:Runtime = Join-Path $Root "runtime\$env:COMPUTERNAME-$sid"
    New-Item -ItemType Directory -Path $script:Runtime -Force | Out-Null
    $script:Log = Join-Path $script:Runtime 'activity.log'
    $script:StatePath = Join-Path $script:Runtime 'state.json'
    $script:State = @{}
    if (Test-Path -LiteralPath $script:StatePath) {
        $obj = Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $obj.PSObject.Properties) { $script:State[$p.Name] = $p.Value }
    }
    $script:Cache = Join-Path $script:Runtime 'cache'
    New-Item -ItemType Directory -Path $script:Cache -Force | Out-Null
    return @{ Config=$script:Config; Runtime=$script:Runtime; Log=$script:Log; Root=$Root; Sid=$sid }
}

function Assert-Config {
    param($C)
    if ($C.profile -notin @('web','mobile','full')) { throw 'profile: web/mobile/full만 가능합니다.' }
    if ($C.burpEdition -notin @('Community','Professional')) { throw 'Burp edition invalid.' }
    if ($C.kaliDistro -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$') { throw 'Invalid Kali distribution name.' }
    if ($C.hexstrikeCommit -notmatch '^[0-9a-f]{40}$') { throw 'HexStrike commit must be a full 40-character SHA.' }
    if ($C.opencodeVersion -notmatch '^(latest|[0-9]+\.[0-9]+\.[0-9]+([-+][a-zA-Z0-9.-]+)?)$') { throw 'Invalid OpenCode version.' }
    if ($C.androidApi -notin @(28,29,30)) { throw '이 구성은 MobSF 동적 분석용 Android API 28~30을 지원합니다. Android 11은 API 30입니다.' }
    if ($C.androidImage -notin @('default','google_apis')) { throw '루트가 없는 Google Play 이미지는 사용할 수 없습니다.' }
    if ($C.avdName -notmatch '^VulnChecker_[a-zA-Z0-9_]{1,50}$') { throw 'AVD name must start with VulnChecker_.' }
    if ($C.PSObject.Properties['playApi'] -and ($C.playApi -isnot [int] -or $C.playApi -lt 28 -or $C.playApi -gt 36)) { throw 'playApi must be integer 28~36.' }
    if ($C.PSObject.Properties['playAvdName'] -and ($C.playAvdName -notmatch '^VulnChecker_Play_[A-Za-z0-9_]{1,40}$' -or $C.playAvdName -eq $C.avdName)) { throw 'Invalid or shared Play AVD name.' }
    foreach ($port in @($C.mobSfPort,$C.hexstrikePort)) {
        if (($port -isnot [int] -and $port -isnot [long]) -or $port -lt 1024 -or $port -gt 65535) { throw 'Ports must be integer 1024~65535.' }
    }
    if ($C.mobSfPort -eq $C.hexstrikePort -or $C.mobSfPort -in @(1337,5554,5555,5556,5557,5560,5561) -or $C.hexstrikePort -in @(1337,5554,5555,5556,5557,5560,5561)) { throw 'Port conflict in config.' }
    if ($C.mobSfImage -notmatch '^opensecurity/mobile-security-framework-mobsf(:[a-zA-Z0-9_.-]+|@sha256:[0-9a-f]{64})$') { throw 'Use the official MobSF image with a tag or SHA256 digest.' }
    if ($C.dockerTimeoutSeconds -lt 30 -or $C.dockerTimeoutSeconds -gt 1800) { throw 'Invalid timeout settings.' }
    if ($C.PSObject.Properties['reserveFreeGB'] -and ($C.reserveFreeGB -lt 0 -or $C.reserveFreeGB -gt 100)) { throw 'Invalid capacity reserve.' }
    foreach ($pkg in $C.extraKaliPackages) { if ($pkg -notmatch '^[a-z0-9][a-z0-9.+-]*$') { throw 'Invalid apt package.' } }
    foreach ($p in $C.wingetVersions.PSObject.Properties) { if ($p.Value -notmatch '^[a-zA-Z0-9_.+-]+$') { throw 'Invalid package version.' } }
    if ($C.PSObject.Properties['existing']) {
        foreach ($p in $C.existing.PSObject.Properties) { if ([string]$p.Value -match '[\r\n\x00]') { throw 'Invalid existing path/user.' } }
        if ($C.existing.PSObject.Properties['kaliUser'] -and $C.existing.kaliUser -and $C.existing.kaliUser -notmatch '^[a-z_][a-z0-9_-]{0,31}$') { throw 'Invalid existing Kali user.' }
    }
}

function Write-Log {
    param([string]$Message)
    $Message=[regex]::Replace($Message,"$([char]27)\[[0-?]*[ -/]*[@-~]",'')
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    for ($attempt=0; $attempt -lt 5; $attempt++) {
        try { [IO.File]::AppendAllText($script:Log,$line+[Environment]::NewLine,(New-Object Text.UTF8Encoding($false))); break }
        catch [IO.IOException] { if ($attempt -eq 4) {throw}; Start-Sleep -Milliseconds 50 }
    }
    Write-Host $line
}

function Read-SharedText {
    param([string]$Path)
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8)
    try {return $reader.ReadToEnd()} finally {$reader.Dispose()}
}

function Save-State {
    $temp = "$script:StatePath.tmp"
    $script:State | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $script:StatePath -Force
}

function Initialize-InstallationProgress {
    $steps=@(@{Id='preflight';Name='기존 설치 / 사전 확인'},@{Id='windows-features';Name='Windows 가상화 / WSL'},@{Id='burp';Name='Burp'})
    if ($script:Config.profile -ne 'web') {$steps+=@(@{Id='android-java';Name='Java'},@{Id='docker-desktop';Name='Docker Desktop'})}
    $steps+=@(@{Id='kali';Name='Kali Linux'},@{Id='kali-tools';Name='Kali 분석 도구 / OpenCode'})
    if ($script:Config.profile -ne 'web') {$steps+=@(@{Id='android-sdk-avd';Name='Android SDK / 가상 기기'},@{Id='mobsf-image';Name='MobSF 이미지'})}
    foreach ($step in $steps) {$step.Status='pending'}
    $script:State['install-progress']=@{Started=(Get-Date).ToString('o');Status='진행 중';Current='preflight';Steps=$steps}
    Set-InstallationProgressStage 'preflight' 'running'
    Save-State
}

function Set-InstallationProgressStage {
    param([string]$Id,[string]$Status)
    if (-not $script:State.ContainsKey('install-progress')) {return}
    $progress=$script:State['install-progress']
    foreach ($step in $progress.Steps) {if ($step.Id -eq $Id) {$step.Status=$Status; $progress.Current=$Id; break}}
}

function Invoke-Step {
    param([string]$Id, [scriptblock]$Work)
    $script:State[$Id] = @{status='running'; updated=(Get-Date).ToString('o')}
    Set-InstallationProgressStage $Id 'running'
    Save-State
    $names=@{'windows-features'='Windows 가상화 / WSL';burp='Burp';'android-java'='Java';'docker-desktop'='Docker Desktop';kali='Kali Linux';'kali-tools'='Kali 분석 도구 / OpenCode';'android-sdk-avd'='Android SDK / 가상 기기';'mobsf-image'='MobSF 이미지'}
    $name=$Id; if ($names.ContainsKey($Id)) {$name=$names[$Id]}
    Set-ConnectionResult "설치 단계: $name" '진행 중' '필요한 구성 요소 확인 및 다운로드 / 설치'
    Write-Log "START $Id"
    try {
        & $Work
        $script:State[$Id] = @{status='complete'; updated=(Get-Date).ToString('o')}
        Set-InstallationProgressStage $Id 'complete'
        Save-State
        Set-ConnectionResult "설치 단계: $name" '완료' '설치 또는 기존 설치 재사용 완료'
        Write-Log "OK $Id"
        return $true
    } catch {
        $script:State[$Id] = @{status='failed'; updated=(Get-Date).ToString('o'); error=$_.Exception.Message}
        Set-InstallationProgressStage $Id 'failed'
        Save-State
        Set-ConnectionResult "설치 단계: $name" '실패' $_.Exception.Message
        Write-Log "FAILED $Id : $($_.Exception.Message)"
        return $false
    }
}

function Invoke-Native {
    param([string]$File, [string[]]$Arguments=@(), [int[]]$SuccessCodes=@(0), [string]$InputText, [switch]$Quiet, [Text.Encoding]$NativeEncoding, [ValidateRange(0,1800)][int]$TimeoutSeconds=0)
    if (-not (Get-Command $File -ErrorAction SilentlyContinue)) { throw "프로그램이 없습니다: $File" }
    if ($TimeoutSeconds) {
        if ($PSBoundParameters.ContainsKey('InputText')) {throw '시간 제한 실행은 표준 입력을 지원하지 않습니다.'}
        $outPath=[IO.Path]::GetTempFileName(); $errPath=[IO.Path]::GetTempFileName()
        $process=$null
        try {
            # Quote according to Windows argv rules, including trailing backslashes.
            $quoted=@($Arguments | ForEach-Object {'"'+([regex]::Replace([regex]::Replace($_,'(\\*)"','$1$1\"'),'(\\+)$','$1$1'))+'"'})
            $start=@{FilePath=$File;WindowStyle='Hidden';RedirectStandardOutput=$outPath;RedirectStandardError=$errPath;PassThru=$true}
            if ($quoted.Count) {$start.ArgumentList=$quoted}
            $process=Start-Process @start
            $process.Handle | Out-Null
            if (-not $process.WaitForExit($TimeoutSeconds*1000)) {throw "프로그램 응답 시간 초과 (${TimeoutSeconds}초): $File"}
            $process.WaitForExit()
            $encoding=New-Object Text.UTF8Encoding($false); if ($NativeEncoding) {$encoding=$NativeEncoding}
            $out=([IO.File]::ReadAllText($outPath,$encoding)+[IO.File]::ReadAllText($errPath,$encoding)).Trim()
            if (-not $Quiet -and $out) {Write-Log $out}
            if ($process.ExitCode -notin $SuccessCodes) {throw "$File 종료 코드 $($process.ExitCode) : $out"}
            return $out
        } finally {
            if ($process) {if (-not $process.HasExited) {$process.Kill(); $process.WaitForExit(5000) | Out-Null}; $process.Dispose()}
            Remove-Item -LiteralPath $outPath,$errPath -Force -ErrorAction SilentlyContinue
        }
    }
    # Windows PowerShell treats native stderr as ErrorRecord. Preserve it as diagnostic output.
    $old = $ErrorActionPreference
    $oldConsole=[Console]::OutputEncoding
    $oldInput=$OutputEncoding
    $oldWsl=$env:WSL_UTF8
    $utf8=New-Object Text.UTF8Encoding($false)
    # WSL emits localized Windows messages as UTF-16 by default. Force both the
    # producer and PowerShell decoder to UTF-8, then restore process settings.
    $isWsl=[IO.Path]::GetFileNameWithoutExtension($File) -eq 'wsl'
    # Android tools and Docker emit UTF-8, including localized Windows socket
    # errors. Decode their output independently of the host console code page.
    $nativeName=[IO.Path]::GetFileNameWithoutExtension($File)
    $changeEncoding=$isWsl -or $nativeName -in @('adb','docker','emulator','aapt','aapt2') -or $PSBoundParameters.ContainsKey('NativeEncoding')
    if ($changeEncoding) {
        $encoding=$utf8; if ($NativeEncoding) {$encoding=$NativeEncoding}
        [Console]::OutputEncoding=$encoding; $OutputEncoding=$encoding
    }
    if ($isWsl) { $env:WSL_UTF8='1' }
    $ErrorActionPreference = 'Continue'
    $lines = New-Object 'System.Collections.Generic.List[string]'
    try {
        if ($PSBoundParameters.ContainsKey('InputText')) {
            $InputText | & $File @Arguments 2>&1 | ForEach-Object { $lines.Add($_.ToString()); if (-not $Quiet) { Write-Log $_.ToString() } }
        } else {
            & $File @Arguments 2>&1 | ForEach-Object { $lines.Add($_.ToString()); if (-not $Quiet) { Write-Log $_.ToString() } }
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
        if ($isWsl) { $env:WSL_UTF8=$oldWsl }
        if ($changeEncoding) {[Console]::OutputEncoding=$oldConsole; $OutputEncoding=$oldInput}
    }
    $out = ($lines -join "`n") -replace "`0",''
    if ($code -notin $SuccessCodes) { throw "$File 종료 코드 $code : $out" }
    return $out
}

function Test-Admin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-RebootPending {
    foreach ($path in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
        if (Test-Path $path) { return $true }
    }
    $session = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
    if ($session -and $session.PSObject.Properties['PendingFileRenameOperations'] -and $session.PendingFileRenameOperations) { return $true }
    return $false
}

function Get-Preflight {
    param($Inventory)
    if (-not $Inventory) { $Inventory=Get-InstallationInventory }
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = @(Get-CimInstance Win32_Processor)[0]
    $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
    $arch = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE')
    $issues = New-Object 'System.Collections.Generic.List[string]'
    $capacity=Get-CapacityPlan $Inventory
    $requiredGB=$capacity.RequiredGB
    if ([int]$os.BuildNumber -lt 22000 -or $os.ProductType -ne 1) { $issues.Add('Windows 11 클라이언트가 필요합니다.') }
    if ($arch -ne 'AMD64' -or -not [Environment]::Is64BitProcess) { $issues.Add('64비트 Windows x64 및 64비트 PowerShell이 필요합니다. ARM64는 미지원입니다.') }
    if (-not $cs.HypervisorPresent -and -not $cpu.VirtualizationFirmwareEnabled) { $issues.Add('BIOS/UEFI 가상화 VT-x/AMD-V를 활성화해야 합니다.') }
    if ($requiredGB -gt 0 -and $drive.FreeSpace / 1GB -lt $requiredGB) { $issues.Add("추가 설치 예상 용량과 여유 공간 합계 ${requiredGB}GB가 필요합니다. 설치된 항목은 제외했습니다.") }
    # WinGet is an installable prerequisite, not a hardware/policy blocker.
    [pscustomobject]@{
        OS=$os.Caption; Build=$os.BuildNumber; Architecture=$arch; Administrator=(Test-Admin)
        Virtualization=($cs.HypervisorPresent -or $cpu.VirtualizationFirmwareEnabled)
        RAM_GB=[math]::Round($cs.TotalPhysicalMemory/1GB,1)
        Free_GB=[math]::Round($drive.FreeSpace/1GB,1)
        AdditionalInstallGB=$capacity.AdditionalGB; RequiredFreeGB=$requiredGB
        CapacityPlan=$capacity.Items; InventoryUnknown=$capacity.Unknown
        RebootPending=(Test-RebootPending); BlockingIssues=@($issues.ToArray())
    }
}

function Get-Plan {
    $p = $script:Config.profile
    $list = New-Object 'System.Collections.Generic.List[string]'
    $list.Add("Burp Suite $($script:Config.burpEdition)")
    if ($p -ne 'web') { $list.Add('Standalone Java + Android SDK + root-capable AVD'); $list.Add('Docker Desktop + MobSF static/dynamic runtime') }
    $list.Add('WSL2 + Kali Linux + non-root VulnChecker user')
    $list.Add('HexStrike pinned source + virtual environment + OpenCode + local MCP config')
    if ($p -ne 'mobile') { $list.Add('nmap, ffuf, sqlmap, nikto, nuclei, gobuster, feroxbuster') }
    if ($p -ne 'web') { $list.Add('jadx, apktool, frida-tools, objection') }
    foreach ($item in $list) { Write-Log "PLAN $item" }
    Write-Log '계정 인증, 고객사 정책 승인 및 재부팅은 사용자 작업입니다. 설치만 수행하며 대상 스캔을 시작하지 않습니다.'
}

function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User') + ';' + $env:Path
}

function Get-AppPath {
    param([string]$Name)
    if ($Name -eq 'Burp') { $explicit=Get-ExistingOption burpPath; if ($explicit -and (Test-Path -LiteralPath $explicit -PathType Leaf)) { return $explicit } }
    $paths = switch ($Name) {
        'Burp' {
            if ($script:Config.burpEdition -eq 'Community') { @("$env:ProgramFiles\BurpSuiteCommunity\BurpSuiteCommunity.exe","$env:LOCALAPPDATA\Programs\BurpSuiteCommunity\BurpSuiteCommunity.exe","$env:ProgramFiles\BurpSuiteCommunity\BurpSuite.exe","$env:LOCALAPPDATA\Programs\BurpSuiteCommunity\BurpSuite.exe") }
            else { @("$env:ProgramFiles\BurpSuitePro\BurpSuitePro.exe","$env:LOCALAPPDATA\Programs\BurpSuitePro\BurpSuitePro.exe") }
        }
        'Studio' { @("$env:ProgramFiles\Android\Android Studio\bin\studio64.exe","$env:LOCALAPPDATA\Programs\Android Studio\bin\studio64.exe") }
        'Docker' { @("$env:ProgramFiles\Docker\Docker\Docker Desktop.exe","$env:LOCALAPPDATA\Programs\DockerDesktop\Docker Desktop.exe") }
    }
    foreach ($path in $paths) { if (Test-Path -LiteralPath $path) { return $path } }
    # Custom installer locations: use only matching uninstall DisplayNames, not arbitrary executables.
    $names = @{ Burp='^Burp Suite'; Studio='^Android Studio'; Docker='^Docker Desktop' }
    $leaf = @{ Burp=@('BurpSuiteCommunity.exe','BurpSuitePro.exe'); Studio=@('bin\studio64.exe'); Docker=@('Docker Desktop.exe') }
    if ($script:Config.burpEdition -eq 'Community') { $names.Burp='^Burp Suite'; $leaf.Burp=@('BurpSuiteCommunity.exe','BurpSuite.exe') }
    else { $names.Burp='^Burp Suite Professional'; $leaf.Burp=@('BurpSuitePro.exe') }
    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        foreach ($app in @(Get-ItemProperty $key -ErrorAction SilentlyContinue)) {
            if ($app.PSObject.Properties['DisplayName'] -and $app.DisplayName -match $names[$Name]) {
                $locations=@()
                if ($app.PSObject.Properties['InstallLocation'] -and $app.InstallLocation) { $locations+=([string]$app.InstallLocation).Trim('"') }
                if ($app.PSObject.Properties['DisplayIcon'] -and $app.DisplayIcon) {
                    $icon=([string]$app.DisplayIcon -replace ',\s*-?\d+$','').Trim('"')
                    if (Test-Path -LiteralPath $icon -PathType Leaf) { $locations+=Split-Path $icon }
                }
                foreach ($location in $locations) {
                    if ($Name -eq 'Burp' -and $script:Config.burpEdition -eq 'Community' -and $app.DisplayName -notmatch 'Community' -and $location -notmatch 'BurpSuiteCommunity') { continue }
                    foreach ($exe in $leaf[$Name]) { $path=Join-Path $location $exe; if (Test-Path -LiteralPath $path) { return $path } }
                }
            }
        }
    }
    return $null
}

function Get-SdkRoot {
    $explicit=Get-ExistingOption sdkRoot
    if ($explicit) { return $explicit }
    foreach ($path in Get-SdkCandidates) {
        if ((Test-Path -LiteralPath (Join-Path $path 'emulator\emulator.exe')) -or (Test-Path -LiteralPath (Join-Path $path 'platform-tools\adb.exe'))) { return $path }
    }
    return (Join-Path $env:LOCALAPPDATA 'VulnChecker\Android\Sdk')
}
function Get-AvdRoot {
    $explicit=Get-ExistingOption avdRoot
    if ($explicit) { return $explicit }
    foreach ($path in Get-AvdCandidates) {
        if (@(Get-ChildItem -LiteralPath $path -Filter *.ini -File -ErrorAction SilentlyContinue).Count) { return $path }
    }
    return (Join-Path $env:LOCALAPPDATA 'VulnChecker\Android\avd')
}
function Get-JavaHome {
    $candidates=@($env:JAVA_HOME,[Environment]::GetEnvironmentVariable('JAVA_HOME','Machine'),[Environment]::GetEnvironmentVariable('JAVA_HOME','User'))
    foreach ($base in @("$env:ProgramFiles\Microsoft","$env:ProgramFiles\Eclipse Adoptium")) {
        if (Test-Path $base) { $candidates+=@(Get-ChildItem $base -Directory | Where-Object {$_.Name -match 'jdk-?(21|25)'} | ForEach-Object {$_.FullName}) }
    }
    $studio=Get-AppPath Studio
    if ($studio) { $candidates+=(Join-Path (Split-Path (Split-Path $studio)) 'jbr') }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'bin\java.exe'))) {
            try { $version=Invoke-Native (Join-Path $candidate 'bin\java.exe') @('-version') -Quiet; if ($version -match 'version "(\d+)' -and [int]$Matches[1] -ge 21) { return $candidate } } catch { }
        }
    }
    return $null
}
function Install-AndroidJava {
    if (Get-JavaHome) { Write-Log '기존 Java 사용'; return }
    $winget=Ensure-Winget
    Write-Log '다운로드 / 설치 시작: Microsoft OpenJDK 21'
    $arguments=@('install','--id','Microsoft.OpenJDK.21','--exact','--source','winget','--silent','--accept-package-agreements','--accept-source-agreements','--disable-interactivity')
    $pin=$script:Config.wingetVersions.PSObject.Properties['Microsoft.OpenJDK.21']
    if ($pin) { $arguments+=@('--version',[string]$pin.Value) }
    Invoke-Native $winget $arguments -SuccessCodes @(0,3010) | Out-Null
    Refresh-Path
    if (-not (Get-JavaHome)) { throw 'Standalone Java 21 설치 후 찾지 못했습니다.' }
}
function Set-AndroidEnvironment {
    param([switch]$RequireJava)
    $env:ANDROID_HOME=Get-SdkRoot
    $env:ANDROID_AVD_HOME=Get-AvdRoot
    $env:ANDROID_USER_HOME=Join-Path $env:LOCALAPPDATA 'VulnChecker\Android\user'
    foreach ($path in @($env:ANDROID_HOME,$env:ANDROID_AVD_HOME,$env:ANDROID_USER_HOME)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    $java=Get-JavaHome
    if ($java) { $env:JAVA_HOME=$java; $env:Path="$java\bin;$env:Path" }
    elseif ($RequireJava) { throw 'SDK 가상 기기 생성용 Java 21이 필요합니다. 설치 메뉴를 실행하세요.' }
    $env:Path="$env:ANDROID_HOME\platform-tools;$env:ANDROID_HOME\emulator;$env:Path"
}

function Invoke-Kali {
    param([string[]]$Arguments, [string]$InputText, [switch]$Root, [switch]$Quiet)
    $user='root'
    if (-not $Root) { $user=(Get-KaliRuntime).User }
    $a=@('-d',$script:Config.kaliDistro,'-u',$user,'--exec') + $Arguments
    $params=@{File='wsl.exe'; Arguments=$a; Quiet=$Quiet}
    if ($PSBoundParameters.ContainsKey('InputText')) { $params.InputText=$InputText }
    return (Invoke-Native @params)
}

function Quote-PsLiteral { param([string]$Text); return ("'" + $Text.Replace("'","''") + "'") }
function Stop-GuiWorker {
    param([Diagnostics.Process]$Process)
    $Process.Refresh()
    if ($Process.HasExited) {return}
    $current=Get-Process -Id $Process.Id -ErrorAction SilentlyContinue
    if (-not $current) {return}
    if ($current.ProcessName -notin @('powershell','pwsh') -or $current.StartTime -ne $Process.StartTime -or $current.Id -eq $PID) {throw '작업 프로세스 식별 불일치'}
    $nativeChildren=@(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($current.Id)" | Where-Object {$_.Name -in @('docker.exe','adb.exe','wsl.exe') -and $_.CreationDate -ge $current.StartTime})
    # The operation lock must be released before starting the stop worker.
    $current.Kill()
    if (-not $current.WaitForExit(5000)) {throw '작업 취소를 확인하지 못했습니다.'}
    foreach ($child in $nativeChildren) {
        $live=Get-CimInstance Win32_Process -Filter "ProcessId=$($child.ProcessId)"
        if ($live -and $live.CreationDate -eq $child.CreationDate -and $live.ExecutablePath -eq $child.ExecutablePath) {Stop-Process -Id $child.ProcessId -Force -ErrorAction Stop}
    }
    Write-Log '진행 중인 준비 작업 취소. 관리 환경 종료를 시작합니다.'
}
function Start-Worker {
    param([string]$Action, [string]$Tool, [string]$Package, [string]$Target, [string]$SourceSerial, [string[]]$ApkPaths=@(), [switch]$AcceptLicenses, [switch]$LaunchWithBypass, [ValidateSet('Auto','Burp','Direct','Preview')][string]$CaptureRoute='Preview')
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $code='& ' + (Quote-PsLiteral (Join-Path $script:Root 'VulnChecker.ps1')) + ' -Action ' + (Quote-PsLiteral $Action) + ' -ConfigPath ' + (Quote-PsLiteral $script:ConfigPath) + ' -ExpectedUserSid ' + (Quote-PsLiteral $sid)
    if ($Tool) { $code+=' -Tool ' + (Quote-PsLiteral $Tool) }
    if ($Package) { $code+=' -Package ' + (Quote-PsLiteral $Package) }
    if ($Target) {$code+=' -Target '+(Quote-PsLiteral $Target)}
    if ($SourceSerial) { $code+=' -SourceSerial ' + (Quote-PsLiteral $SourceSerial) }
    if ($ApkPaths.Count) { $code+=' -ApkPaths @('+(($ApkPaths | ForEach-Object {Quote-PsLiteral $_}) -join ',')+')' }
    if ($AcceptLicenses) { $code+=' -AcceptLicenses' }
    $code+=' -CaptureRoute '+(Quote-PsLiteral $CaptureRoute)
    if ($LaunchWithBypass) {$code+=' -LaunchWithBypass'}
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $params=@{FilePath="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"; WindowStyle='Hidden'; ArgumentList=@('-NoProfile','-STA','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded); PassThru=$true}
    if ($Action -eq 'Install' -and -not (Test-Admin)) { $params.Verb='RunAs' }
    $worker=Start-Process @params
    # Keep the process handle so Windows PowerShell can retrieve ExitCode after exit.
    if ($worker -is [Diagnostics.Process]) {$worker.Handle | Out-Null}
    return $worker
}

. (Join-Path $PSScriptRoot 'Install.ps1')
. (Join-Path $PSScriptRoot 'Inventory.ps1')
  . (Join-Path $PSScriptRoot 'Launch.ps1')
  . (Join-Path $PSScriptRoot 'Integrations.ps1')
  . (Join-Path $PSScriptRoot 'Mobile.ps1')
  . (Join-Path $PSScriptRoot 'AppAcquisition.ps1')
. (Join-Path $PSScriptRoot 'MobileTargets.ps1')
. (Join-Path $PSScriptRoot 'Gui.ps1')
Export-ModuleMember -Function *
