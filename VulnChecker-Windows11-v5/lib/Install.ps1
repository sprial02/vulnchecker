function Install-WingetPackage {
    param([string]$Id, [string]$App)
    Refresh-Path
    if (Get-AppPath $App) { Write-Log "기존 $App 설치 사용 (자동 업그레이드 없음)"; return }
    $winget=Ensure-Winget
    Write-Log "다운로드 / 설치 시작: $Id"
    $args=@('install','--id',$Id,'--exact','--source','winget','--silent','--accept-package-agreements','--accept-source-agreements','--disable-interactivity')
    $pin=$script:Config.wingetVersions.PSObject.Properties[$Id]
    if ($pin) { $args+=@('--version',[string]$pin.Value) }
    if ($App -eq 'Docker') { $args+=@('--override','install --quiet --accept-license --backend=wsl-2') }
    Invoke-Native $winget $args -SuccessCodes @(0,3010) | Out-Null
    Refresh-Path
    if (-not (Get-AppPath $App)) { throw "$Id 설치 후 실행 파일을 찾지 못했습니다. 사용자 지정 설치 위치를 확인하세요." }
}

function Get-WingetCli {
    Refresh-Path
    $command=Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($command) {return $command.Source}
    foreach ($package in @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue)) {
        $path=Join-Path $package.InstallLocation 'winget.exe'
        if (Test-Path -LiteralPath $path -PathType Leaf) {return $path}
    }
    return $null
}

function Ensure-Winget {
    $winget=Get-WingetCli
    if ($winget) {
        try {Invoke-Native $winget @('--version') -Quiet -TimeoutSeconds 15 | Out-Null; return $winget}
        catch {Write-Log "Windows 앱 설치 도구 응답 확인 실패: $($_.Exception.Message)"}
    }
    Write-Log 'Windows 앱 설치 도구(WinGet)를 준비합니다. 새 PC의 앱 등록 및 Microsoft 공식 설치 경로를 확인합니다.'
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop
        $winget=Get-WingetCli
        if ($winget) {Invoke-Native $winget @('--version') -Quiet -TimeoutSeconds 15 | Out-Null; return $winget}
    } catch {Write-Log '앱 등록만으로 준비되지 않아 WinGet 다운로드·설치를 진행합니다.'}
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    try {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
        Install-Module -Name Microsoft.WinGet.Client -Repository PSGallery -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
        Repair-WinGetPackageManager -AllUsers -ErrorAction Stop | Out-Null
        $winget=Get-WingetCli
        if (-not $winget) {throw '설치 후 winget.exe를 찾지 못했습니다.'}
        Invoke-Native $winget @('--version') -Quiet -TimeoutSeconds 15 | Out-Null
        Write-Log 'Windows 앱 설치 도구 준비 완료. 누락된 프로그램 다운로드·설치를 계속합니다.'
        return $winget
    } catch {throw "Windows 앱 설치 도구 자동 준비 실패: $($_.Exception.Message). Microsoft 다운로드/PowerShell Gallery 접근 및 Windows 앱 설치 정책을 확인하세요."}
}

function Enable-VirtualizationFeatures {
    $restart=$false
    $features=@('Microsoft-Windows-Subsystem-Linux','VirtualMachinePlatform')
    if ($script:Config.profile -ne 'web') { $features+='HypervisorPlatform' }
    foreach ($name in $features) {
        $f=Get-WindowsOptionalFeature -Online -FeatureName $name
        if ($f.State -eq 'EnablePending') { $restart=$true; continue }
        if ($f.State -ne 'Enabled') {
            $result=Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart
            if ($result.RestartNeeded) { $restart=$true }
        }
    }
    # web-download avoids requiring Microsoft Store access, but still needs outbound HTTPS.
    $wslVersion=$null
    try { $wslVersion=Invoke-Native wsl.exe @('--version') -Quiet }
    catch {
        Invoke-Native wsl.exe @('--install','--no-distribution','--web-download') -SuccessCodes @(0,3010) | Out-Null
        $restart=$true
    }
    if ($wslVersion) {
        $match=[regex]::Match($wslVersion,'\d+\.\d+\.\d+')
        if (-not $match.Success) { throw 'WSL 버전 식별 실패. wsl --version 출력과 기업 정책을 확인하세요.' }
        if ([version]$match.Value -lt [version]'2.1.5') {
            Invoke-Native wsl.exe @('--update','--web-download') -SuccessCodes @(0,3010) | Out-Null
            $restart=$true
        }
    }
    return $restart
}

function Install-Kali {
    Invoke-Native wsl.exe @('--set-default-version','2') | Out-Null
    $distros=(Invoke-Native wsl.exe @('--list','--quiet') -Quiet) -split '\r?\n' | ForEach-Object { $_.Trim() }
    if ($script:Config.kaliDistro -notin $distros) {
        if ($script:Config.kaliImportTar) {
            $tar=(Resolve-Path -LiteralPath $script:Config.kaliImportTar).Path
            $location=Join-Path $env:LOCALAPPDATA "VulnChecker\WSL\$($script:Config.kaliDistro)"
            New-Item -ItemType Directory -Path $location -Force | Out-Null
            Invoke-Native wsl.exe @('--import',$script:Config.kaliDistro,$location,$tar,'--version','2') | Out-Null
        } else {
            if ($script:Config.kaliDistro -ne 'kali-linux') { throw '사용자 지정 배포판 이름은 kaliImportTar가 필요합니다.' }
            Invoke-Native wsl.exe @('--install','--distribution','kali-linux','--web-download','--no-launch') | Out-Null
        }
    }
    # An existing WSL1 distribution is not converted silently (conversion changes its storage).
    $version=Invoke-Kali -Root -Arguments @('uname','-r') -Quiet
    if ($version -notmatch 'WSL2|microsoft-standard') { throw 'Kali가 WSL2가 아닙니다. 고객사 승인 후 wsl --set-version <배포판> 2를 수행하세요.' }
    $id=Invoke-Kali -Root -Arguments @('cat','/etc/os-release') -Quiet
    if ($id -notmatch '(?m)^ID=kali\s*$') { throw '선택한 배포판이 Kali Linux가 아닙니다.' }
}

function Install-KaliTools {
    $rt=Get-KaliRuntime -Refresh
    $probe=$rt.Probe
    $missing=@()
    $names=@()
    if ($script:Config.profile -ne 'mobile') { $names+=@('nmap','ffuf','sqlmap','nikto','nuclei','gobuster','feroxbuster') }
    if ($script:Config.profile -ne 'web') { $names+=@('jadx','apktool','frida','objection') }
    foreach ($name in $names) { if (-not $probe.commands.$name) { $missing+=$name } }
    $extrasReady=$true
    foreach ($pkg in $script:Config.extraKaliPackages) {
        try { $r=Invoke-Kali -Root -Arguments @('dpkg-query','--show','--showformat=${db:Status-Status}',$pkg) -Quiet; if ($r.Trim() -ne 'installed') { $extrasReady=$false } }
        catch { $extrasReady=$false }
    }
    $canReuse=($probe.user -ne 'root' -or $probe.hexstrike.path -eq $rt.HexRepo)
    if ($canReuse -and $probe.hexstrike.dependencies -eq $true -and $probe.commands.opencode -and -not $missing.Count -and $extrasReady) {
        Write-Log '기존 Kali 도구가 준비되어 있습니다. 패키지 다운로드와 소스 checkout 없이 연동만 구성합니다.'
        Ensure-KaliIntegration $rt
        return
    }
    $bootstrap=Get-Content -LiteralPath (Join-Path $script:Root 'scripts\kali-bootstrap.sh') -Raw -Encoding UTF8
    $reusePython='-'
    if ($probe.hexstrike.dependencies -eq $true -and $canReuse) { $reusePython=$rt.HexPython }
    $reuseOc='-'
    if ($probe.commands.opencode -and ($probe.user -ne 'root' -or $probe.commands.opencode.StartsWith($rt.Home+'/'))) { $reuseOc=$rt.OpenCode }
    $mobileReady='no'
    if ($probe.commands.frida -and $probe.commands.objection) { $mobileReady='yes' }
    $a=@('bash','-s','--',$script:Config.profile,$script:Config.hexstrikeCommit,$script:Config.opencodeVersion,$rt.User,$rt.HexRepo,$reusePython,$reuseOc,$mobileReady)+@($script:Config.extraKaliPackages)
    $inputScript=($bootstrap -replace "`r`n","`n").TrimEnd()+"`n# stdin-end"
    Invoke-Kali -Root -Arguments $a -InputText $inputScript | Out-Null
    $rt=Get-KaliRuntime -Refresh
    Ensure-KaliIntegration $rt
    $snapshot=Invoke-Kali -Arguments @('dpkg-query','-W') -Quiet
    $snapshot | Set-Content -LiteralPath (Join-Path $script:Runtime 'linux-versions.txt') -Encoding UTF8
}

function Install-Android {
    Set-AndroidEnvironment -RequireJava
    $sdk=Get-SdkRoot
    $manager=Join-Path $sdk 'cmdline-tools\latest\bin\sdkmanager.bat'
    if (-not (Test-Path -LiteralPath $manager)) {
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        Write-Log '공식 Google SDK 저장소에서 Windows command-line tools 메타데이터 확인'
        $meta=Invoke-WebRequest 'https://dl.google.com/android/repository/repository2-1.xml' -UseBasicParsing
        [xml]$xml=$meta.Content
        $archives=$xml.SelectNodes("//*[local-name()='remotePackage' and @path='cmdline-tools;latest']/*[local-name()='archives']/*[local-name()='archive']")
        $archive=@($archives | Where-Object { $_.'host-os' -eq 'windows' })[0]
        $filename=[string]$archive.complete.url
        if ($filename -notmatch '^commandlinetools-win-[0-9]+_latest\.zip$') { throw 'Unexpected Google SDK archive URL.' }
        $expected=([string]$archive.complete.checksum).ToLowerInvariant()
        if ($expected -notmatch '^[0-9a-f]{40}$') { throw 'Unexpected SDK checksum format.' }
        $zip=Join-Path $script:Cache $filename
        if (-not (Test-Path -LiteralPath $zip) -or (Get-FileHash -LiteralPath $zip -Algorithm SHA1).Hash.ToLowerInvariant() -ne $expected) {
            $partial="$zip.partial"
            Invoke-WebRequest ("https://dl.google.com/android/repository/$filename") -OutFile $partial -UseBasicParsing
            if ((Get-FileHash -LiteralPath $partial -Algorithm SHA1).Hash.ToLowerInvariant() -ne $expected) { throw 'Google SDK checksum mismatch; archive will not be executed.' }
            Move-Item -LiteralPath $partial -Destination $zip -Force
        }
        $stage=Join-Path $script:Cache ('sdk-expand-'+[guid]::NewGuid().ToString('N'))
        Expand-Archive -LiteralPath $zip -DestinationPath $stage
        $target=Join-Path $sdk 'cmdline-tools\latest'
        New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
        if (Test-Path -LiteralPath $target) { throw '불완전한 cmdline-tools 폴더가 있습니다. 로그를 확인하고 해당 폴더를 다른 이름으로 이동 후 재시도하세요.' }
        Move-Item -LiteralPath (Join-Path $stage 'cmdline-tools') -Destination $target
        @{url="https://dl.google.com/android/repository/$filename"; officialSHA1=$expected; sha256=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:Runtime 'android-download.json') -Encoding UTF8
    }
    $yes=(1..100 | ForEach-Object {'y'}) -join "`n"
    $image="system-images;android-$($script:Config.androidApi);$($script:Config.androidImage);x86_64"
    $packages=@()
    foreach ($package in @(@{Name='platform-tools';File='platform-tools\adb.exe'},@{Name='emulator';File='emulator\emulator.exe'},@{Name="platforms;android-$($script:Config.androidApi)";File="platforms\android-$($script:Config.androidApi)\android.jar"},@{Name=$image;File="system-images\android-$($script:Config.androidApi)\$($script:Config.androidImage)\x86_64\system.img"})) {
        if (-not (Test-Path -LiteralPath (Join-Path $sdk $package.File))) { $packages+=$package.Name }
    }
    if ($packages.Count) {
        Invoke-Native $manager @("--sdk_root=$sdk",'--licenses') -InputText $yes | Out-Null
        Invoke-Native $manager (@("--sdk_root=$sdk")+$packages) -InputText $yes | Out-Null
    } else { Write-Log '기존 SDK/에뮬레이터/이미지 사용 (업그레이드 다운로드 없음)' }
    Ensure-AndroidAvd
    Invoke-Native (Join-Path $sdk 'emulator\emulator.exe') @('-accel-check') | Out-Null
    Write-Log "Android SDK: $sdk; AVD: $($script:Config.avdName) (Play Store 없는 루트 후보 이미지)"
}

function Ensure-AndroidAvd {
    Set-AndroidEnvironment -RequireJava
    $sdk=Get-SdkRoot
    $image="system-images;android-$($script:Config.androidApi);$($script:Config.androidImage);x86_64"
    $imageFolder=Join-Path $sdk "system-images\android-$($script:Config.androidApi)\$($script:Config.androidImage)\x86_64"
    if (-not (Test-Path (Join-Path $imageFolder 'system.img'))) { throw 'Android 시스템 이미지가 없습니다. 설치 메뉴에서 SDK/에뮬레이터를 설치하세요.' }
    $avdm=Join-Path $sdk 'cmdline-tools\latest\bin\avdmanager.bat'
    $list=Invoke-Native (Join-Path $sdk 'emulator\emulator.exe') @('-list-avds') -Quiet
    $ini=Join-Path (Get-AvdRoot) "$($script:Config.avdName).avd\config.ini"
    if ($script:Config.avdName -notin @($list -split '\r?\n' | ForEach-Object {$_.Trim()})) {
        Invoke-Native $avdm @('create','avd','--name',$script:Config.avdName,'--package',$image) -InputText 'no' | Out-Null
    }
    if (-not (Test-Path -LiteralPath $ini)) { throw 'AVD 생성 후 config.ini가 없습니다.' }
    $avdConfig=Get-Content -LiteralPath $ini -Raw
    $expectedPath="system-images/android-$($script:Config.androidApi)/$($script:Config.androidImage)/x86_64/"
    if ($avdConfig.Replace('\','/') -notmatch [regex]::Escape($expectedPath)) { throw '기존 AVD와 config의 Android 이미지가 다릅니다. avdName을 새 이름으로 바꾸세요. 기존 데이터는 유지됩니다.' }
    # Only the reserved AVD is configured. Existing customer AVDs are preserved.
    if ($script:Config.avdName -match '^VulnChecker_') {
        $text=Get-Content -LiteralPath $ini -Raw
        foreach ($setting in @('hw.ramSize=2048','hw.cpu.ncore=2','hw.gpu.enabled=yes','hw.gpu.mode=software','disk.dataPartition.size=4G','hw.mainKeys=no')) {
            $key=($setting -split '=')[0]
            if ($text -match ('(?m)^'+[regex]::Escape($key)+'\s*=.*$')) { $text=[regex]::Replace($text,'(?m)^'+[regex]::Escape($key)+'\s*=.*$',$setting) }
            else { $text+="`n$setting`n" }
        }
        [IO.File]::WriteAllText($ini,$text,(New-Object Text.UTF8Encoding($false)))
    }
}

function Get-DockerCli {
    Refresh-Path
    $cmd=Get-Command docker.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $app=Get-AppPath Docker
    if ($app) { $path=Join-Path (Split-Path $app) 'resources\bin\docker.exe'; if (Test-Path -LiteralPath $path) { return $path } }
    throw 'Docker CLI를 찾을 수 없습니다.'
}

function Wait-Docker {
    $docker=Get-DockerCli
    $end=(Get-Date).AddSeconds($script:Config.dockerTimeoutSeconds)
    $started=$false; $lastError=''
    while ((Get-Date) -lt $end) {
        try {
            $remaining=[Math]::Max(1,[int]($end-(Get-Date)).TotalSeconds)
            $os=Invoke-Native $docker @('info','--format','{{.OSType}}') -Quiet -TimeoutSeconds ([Math]::Min(10,$remaining))
            if ($os.Trim() -ne 'linux') { throw 'Docker를 Linux containers 모드로 전환하세요.' }
            return $docker
        } catch {
            if ($_.Exception.Message -match 'Linux containers') { throw }
            $lastError=$_.Exception.Message
            if (-not $started) {
                $app=Get-AppPath Docker
                if (-not $app) {throw 'Docker Desktop이 없습니다.'}
                if (-not (Test-Path 'HKLM:\SOFTWARE\Docker Inc.\Docker Desktop') -and -not (Test-Path 'HKCU:\SOFTWARE\Docker Inc.\Docker Desktop')) {
                    throw 'Docker Desktop 설치 등록이 손상되었습니다: SOFTWARE\Docker Inc.\Docker Desktop 항목 없음. Docker Desktop 설치 복구 후 다시 실행하세요.'
                }
                $desktopProcesses=@(Get-Process -Name 'Docker Desktop','com.docker.backend' -ErrorAction SilentlyContinue)
                $attemptStart=Get-Date
                if (-not $desktopProcesses.Count) {
                    Start-Process -FilePath $app -WindowStyle Hidden | Out-Null
                    Write-Log 'Docker Desktop 시작 중. 준비 완료를 기다립니다.'
                } else {
                    Write-Log '실행 중인 Docker Desktop 엔진 준비 대기. 중복 실행하지 않습니다.'
                    foreach ($process in $desktopProcesses) {
                        if ($process.PSObject.Properties['StartTime'] -and $process.StartTime -lt $attemptStart) {$attemptStart=$process.StartTime}
                    }
                }
                $started=$true
            }
            $backendLog=Join-Path $env:LOCALAPPDATA 'Docker\log\host\com.docker.backend.exe.log'
            if (Test-Path -LiteralPath $backendLog) {
                foreach ($line in @(Get-Content -LiteralPath $backendLog -Tail 80 -ErrorAction SilentlyContinue)) {
                    if ($line -match '^\[(?<time>[^\]]+)\].*backend crashed.*?: (?<reason>.+)$' -and [DateTimeOffset]::Parse($Matches.time).LocalDateTime -ge $attemptStart.AddSeconds(-2)) {
                        throw "Docker Desktop 시작 실패: $($Matches.reason). 설치 복구 후 다시 실행하세요. 로그: $backendLog"
                    }
                }
            }
            if (-not (Get-Process -Name 'Docker Desktop','com.docker.backend' -ErrorAction SilentlyContinue)) {throw "Docker Desktop이 준비 중 종료되었습니다. 마지막 오류: $lastError"}
            Start-Sleep -Seconds 3
        }
    }
    throw "Docker 엔진이 제한 시간 내 준비되지 않았습니다. Docker Desktop 화면, WSL 상태, 고객사 정책을 확인하세요. 마지막 오류: $lastError"
}

function Install-MobSfImage {
    $docker=Wait-Docker
    if ($script:Config.mobSfImageTar) { Invoke-Native $docker @('load','--input',(Resolve-Path -LiteralPath $script:Config.mobSfImageTar).Path) | Out-Null }
    else {
        try { Invoke-Native $docker @('image','inspect',$script:Config.mobSfImage) -Quiet | Out-Null }
        catch { Invoke-Native $docker @('pull',$script:Config.mobSfImage) | Out-Null }
    }
    $details=Invoke-Native $docker @('image','inspect',$script:Config.mobSfImage) -Quiet
    $details | Set-Content -LiteralPath (Join-Path $script:Runtime 'mobsf-image.json') -Encoding UTF8
}

function Install-Environment {
    param([switch]$AcceptLicenses)
    if (-not (Test-Admin)) { throw '설치는 같은 Windows 계정의 관리자 권한으로 실행해야 합니다.' }
    if (-not $AcceptLicenses) { throw '약관을 검토한 뒤 GUI의 약관 동의란을 선택하거나 -AcceptLicenses를 지정하세요.' }
    Initialize-InstallationProgress
    Set-ConnectionResult '환경 설치' '진행 중' '기존 설치를 확인한 뒤 누락된 프로그램을 인터넷에서 다운로드 / 설치합니다.'
    Write-Log '자동 설치 시작: 사전 확인 결과의 미탐지·미확인 항목은 아래 단계에서 설치하거나 실행 준비합니다.'
    $pre=Get-Preflight
    if ($script:Inventory) { Write-Inventory $script:Inventory }
    if ($script:Inventory -and @($script:Inventory.Items | Where-Object {$_.Id -eq 'linux-probe'}).Count) { throw '기존 Kali 내부를 확인하지 못했습니다. 계정/접근 오류를 먼저 해결한 뒤 설치하세요. 미확인 환경을 덮어쓰지 않습니다.' }
    $pre | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $script:Runtime 'preflight.json') -Encoding UTF8
    if ($pre.BlockingIssues.Count) { throw ($pre.BlockingIssues -join "`n") }
    if ($pre.RAM_GB -lt 16) { Write-Log 'WARNING: 메모리 16GB 미만입니다. Docker와 Android를 함께 실행하면 느릴 수 있습니다.' }
    Get-Plan
    Set-InstallationProgressStage 'preflight' 'complete'; Save-State
    if ($pre.RebootPending) {Set-ConnectionResult '환경 설치' '재부팅 필요' 'Windows 재부팅 후 같은 계정에서 자동 설치 / 이어하기를 누르세요.'; Write-Log 'REBOOT REQUIRED: 기존 Windows 재부팅 대기를 먼저 완료하고 같은 계정에서 다시 설치하세요.'; return 3010 }
    $script:NeedRestart=$false
    $ok=Invoke-Step 'windows-features' { $script:NeedRestart=Enable-VirtualizationFeatures }
    if (-not $ok) {Set-ConnectionResult '환경 설치' '실패' 'Windows 가상화 / WSL 설치 단계의 오류를 확인하세요.'; return 1 }
    if ($script:NeedRestart) {Set-ConnectionResult '환경 설치' '재부팅 필요' '가상화 / WSL 설치 완료. 재부팅 후 자동 설치 / 이어하기를 누르면 프로그램 설치를 계속합니다.'; Write-Log 'REBOOT REQUIRED: 작업을 저장하고 Windows를 재부팅한 뒤 Start.cmd → 자동 설치/이어하기를 실행하세요.'; return 3010 }
    $failed=$false
    $javaOK=$true
    $dockerOK=$true
    if (-not (Invoke-Step 'burp' { Install-WingetPackage "PortSwigger.BurpSuite.$($script:Config.burpEdition)" 'Burp' })) { $failed=$true }
    if ($script:Config.profile -ne 'web') {
        $javaOK=Invoke-Step 'android-java' { Install-AndroidJava }
        $dockerOK=Invoke-Step 'docker-desktop' { Install-WingetPackage 'Docker.DockerDesktop' 'Docker' }
        if (-not $javaOK -or -not $dockerOK) { $failed=$true }
    }
    if (Test-RebootPending) {Set-ConnectionResult '환경 설치' '재부팅 필요' 'Windows 프로그램 설치 완료. 재부팅 후 자동 설치 / 이어하기로 나머지 단계를 진행하세요.'; Write-Log 'REBOOT REQUIRED: 설치 프로그램이 재부팅을 요청했습니다. 재부팅 후 이어하기를 실행하세요.'; return 3010 }
    $kaliOK=Invoke-Step 'kali' { Install-Kali }
    if ($kaliOK) {
        if (-not (Invoke-Step 'kali-tools' { Install-KaliTools })) { $failed=$true }
    } else { $failed=$true }
    if ($script:Config.profile -ne 'web') {
        if ($javaOK -and -not (Invoke-Step 'android-sdk-avd' { Install-Android })) { $failed=$true }
        if ($dockerOK -and -not (Invoke-Step 'mobsf-image' { Install-MobSfImage })) { $failed=$true }
    }
    if ($failed) {Set-ConnectionResult '환경 설치' '일부 실패' '실패한 설치 단계의 구체적인 오류를 확인한 뒤 자동 설치 / 이어하기를 다시 실행하세요.'; Write-Log '일부 단계 실패. activity.log/state.json을 확인한 뒤 자동 설치/이어하기를 다시 실행하세요.'; return 1 }
    Set-ConnectionResult '환경 설치' '완료' '필수 구성 요소 설치 완료. 실행 / 연동 탭에서 도구를 선택하세요.'
    Write-Log '설치 단계 완료. 준비 상태 확인 후 필요한 도구를 실행하세요. 동적 분석 준비 버튼으로 루트/시스템/컨테이너 ADB를 검증하세요.'
    return 0
}
