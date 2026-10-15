function Get-LaunchDependencies {
    param([string]$Tool,[string]$Package='',[string]$CaptureRoute='Preview',[switch]$LaunchWithBypass)
    switch ($Tool) {
        {$_ -like 'Report*'} {return @()}
        'Burp' {return @('Burp')}
        'Kali' {return @('Kali')}
        'HexStrike' {return @('Kali','HexStrike')}
        'BinaryAnalysisTools' {return @('Kali','BinaryAnalysis')}
        {$_ -in @('OpenCode','SystemAnalysis','PenTest','CheckMcp')} {return @('Kali','AI')}
        {$_ -in @('WebAI','WebProxyTest')} {return @('Burp','Kali','AI')}
        'MobileAI' {return @('Android','ApkTools','Kali','AI')}
        {$_ -in @('Emulator','RefreshAnalysisApps')} {return @('Android')}
        'AndroidBurp' {return @('Android','Burp')}
        'MobSF' {return @('MobSF')}
        {$_ -in @('MobileAnalysis','MobSfAnalysis','Dynamic','FridaServer','AppDiagnostics','RootBypassDirect')} {return @('Android','MobSF')}
        'MobileApi' {return @('Android','Burp','MobSF')}
        'Combined' {return @('Android','Burp','MobSF')}
        'RootBypass' {
            if ($CaptureRoute -eq 'Preview' -or $CaptureRoute -eq 'Direct' -or ($CaptureRoute -eq 'Auto' -and $Package -eq 'com.gscaltex.energyplus')) {return @('Android','MobSF')}
            return @('Android','Burp','MobSF')
        }
        {$_ -in @('PlayDownload','ResetPlay')} {return @('Play')}
        {$_ -in @('RefreshApps','RefreshDevices')} {return @('Adb')}
        'AcquireApp' {
            $deps=@('Android','ApkTools')
            if ($LaunchWithBypass) {
                $deps+='MobSF'
                if ($CaptureRoute -eq 'Burp' -or ($CaptureRoute -eq 'Auto' -and $Package -ne 'com.gscaltex.energyplus')) {$deps+='Burp'}
            }
            return $deps
        }
        {$_ -in @('InfraInstall','InfraImport','InfraPreflight','InfraDiscover','InfraRun','InfraRetry')} {return @('Kali')}
        'StopRootBypass' {return @()}
        default {throw "지원하지 않는 실행 기능: $Tool"}
    }
}

function Assert-LaunchInstallAdmin {
    if (Test-Admin) {return}
    $errorRecord=New-Object InvalidOperationException('선택한 기능의 누락 구성 요소 설치를 위해 같은 계정의 관리자 권한을 요청합니다.')
    $errorRecord.Data['LaunchElevation']=$true
    throw $errorRecord
}

function Stop-LaunchForReboot {
    param([string]$Tool)
    Set-ConnectionResult "실행 준비: $Tool" '재부팅 필요' '필수 구성 요소 설치 완료. Windows 재부팅 후 같은 실행 버튼을 누르면 나머지 설치와 실행을 이어갑니다.'
    $errorRecord=New-Object InvalidOperationException('Windows 재부팅 후 같은 실행 버튼으로 이어가세요.')
    $errorRecord.Data['LaunchReboot']=$true
    throw $errorRecord
}

function Ensure-LaunchWsl {
    param([string]$Tool)
    $ready=$false
    try {
        $version=Invoke-Native wsl.exe @('--version') -Quiet -TimeoutSeconds 15
        $match=[regex]::Match($version,'\d+\.\d+\.\d+')
        if (-not $match.Success -or [version]$match.Value -lt [version]'2.1.5') {throw 'WSL update required'}
        Invoke-Native wsl.exe @('--status') -Quiet -TimeoutSeconds 15 | Out-Null
        $ready=$true
    } catch {}
    if (-not $ready) {
        Assert-LaunchInstallAdmin
        Write-Log '선택한 기능에 필요한 WSL / 가상화 구성 요소를 자동 준비합니다. 배포판은 별도로 선택합니다.'
        if (Enable-VirtualizationFeatures -WslOnly) {Stop-LaunchForReboot $Tool}
        Invoke-Native wsl.exe @('--status') -Quiet -TimeoutSeconds 15 | Out-Null
    }
}

function Ensure-LaunchKali {
    param([string]$Tool)
    Ensure-LaunchWsl $Tool
    if (-not (Assert-InfrastructureWsl -Install)) {Stop-LaunchForReboot $Tool}
    # Fresh Kali may not have the Python interpreter used by discovery.
    try {Invoke-InfrastructureKali -Arguments @('python3','--version') -Quiet | Out-Null}
    catch {
        Invoke-InfrastructureKali -Root -Arguments @('apt-get','update') | Out-Null
        Invoke-InfrastructureKali -Root -Arguments @('apt-get','install','-y','--no-install-recommends','python3') | Out-Null
    }
    $user=(Invoke-InfrastructureKali -Arguments @('id','-un') -Quiet).Trim()
    if ($user -eq 'root') {
        try {Invoke-InfrastructureKali -Root -Arguments @('id','-u','vulnchecker') -Quiet | Out-Null}
        catch {Invoke-InfrastructureKali -Root -Arguments @('useradd','--create-home','--shell','/bin/bash','vulnchecker') | Out-Null}
    }
}

function Test-LaunchAndroidFiles {
    param([string]$Component)
    $sdk=Get-SdkRoot
    $files=@('platform-tools\adb.exe')
    if ($Component -in @('Android','Play')) {$files+='emulator\emulator.exe'}
    if ($Component -eq 'Android') {$files+="system-images\android-$($script:Config.androidApi)\$($script:Config.androidImage)\x86_64\system.img"}
    if ($Component -eq 'ApkTools') {
        $versions=@(Get-ChildItem -LiteralPath (Join-Path $sdk 'build-tools') -Directory -ErrorAction SilentlyContinue)
        $found=$false
        foreach ($version in $versions) {
            if ((Test-Path (Join-Path $version.FullName 'aapt.exe') -PathType Leaf) -and (Test-Path (Join-Path $version.FullName 'aapt2.exe') -PathType Leaf) -and (Test-Path (Join-Path $version.FullName 'apksigner.bat') -PathType Leaf)) {$found=$true;break}
        }
        if (-not $found) {return $false}
    }
    foreach ($file in $files) {if (-not (Test-Path -LiteralPath (Join-Path $sdk $file) -PathType Leaf)) {return $false}}
    return $true
}

function Ensure-LaunchAndroid {
    param([string]$Component,[string]$Tool)
    if ($Component -in @('ApkTools','Play') -and -not (Get-JavaHome)) {Install-LaunchJava $Tool}
    if (-not (Test-LaunchAndroidFiles $Component)) {
        if (-not (Get-JavaHome)) {Install-LaunchJava $Tool}
        $installComponent=@{Android='Emulator';Play='Play';Adb='Adb';ApkTools='Tools'}[$Component]
        # Configure acceleration before the installer performs its final check.
        if ($Component -in @('Android','Play')) {Ensure-LaunchAcceleration $Tool}
        Install-Android -Component $installComponent
        if (-not (Test-LaunchAndroidFiles $Component)) {throw "Android $Component 자동 설치 후 필수 파일을 확인하지 못했습니다."}
    } else {Write-Log "기존 Android 구성 요소 재사용: $Component"}
    if ($Component -in @('Android','Play')) {
        Ensure-LaunchAcceleration $Tool
        if ($Component -eq 'Android') {
            $ini=Join-Path (Get-AvdRoot) "$($script:Config.avdName).avd\config.ini"
            if (-not (Test-Path -LiteralPath $ini -PathType Leaf)) {
                if (-not (Get-JavaHome)) {Install-LaunchJava $Tool}
                Ensure-AndroidAvd
            }
        }
    }
}

function Install-LaunchJava {
    param([string]$Tool)
    Assert-LaunchInstallAdmin
    Install-AndroidJava
    if (Test-RebootPending) {Stop-LaunchForReboot $Tool}
}

function Ensure-LaunchAcceleration {
    param([string]$Tool)
    $emulator=Join-Path (Get-SdkRoot) 'emulator\emulator.exe'
    if (Test-Path -LiteralPath $emulator -PathType Leaf) {
        try {Invoke-Native $emulator @('-accel-check') -Quiet -TimeoutSeconds 15 | Out-Null;return} catch {}
    }
    Assert-LaunchInstallAdmin
    $restart=$false
    foreach ($name in @('VirtualMachinePlatform','HypervisorPlatform')) {
        $feature=Get-WindowsOptionalFeature -Online -FeatureName $name
        if ($feature.State -eq 'EnablePending') {$restart=$true}
        elseif ($feature.State -ne 'Enabled') {
            $result=Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart
            if ($result.RestartNeeded) {$restart=$true}
        }
    }
    if ($restart) {Stop-LaunchForReboot $Tool}
}

function Ensure-LaunchPrerequisites {
    param([string]$Tool,[string]$Package='',[string]$CaptureRoute='Preview',[switch]$LaunchWithBypass)
    if ($Tool -in @('MobileApi','MobileAI','RootBypass','RootBypassDirect','AppDiagnostics')) {Assert-AppPackage $Package}
    $dependencies=@(Get-LaunchDependencies -Tool $Tool -Package $Package -CaptureRoute $CaptureRoute -LaunchWithBypass:$LaunchWithBypass)
    if (-not $dependencies.Count) {return}
    Set-ConnectionResult "실행 준비: $Tool" '진행 중' ('필요한 구성 요소 확인 / 누락분 자동 설치: '+($dependencies -join ', '))
    try {
        foreach ($dependency in $dependencies) {
            switch ($dependency) {
                'Burp' {
                    if (-not (Get-AppPath Burp)) {
                        Assert-LaunchInstallAdmin
                        Install-WingetPackage "PortSwigger.BurpSuite.$($script:Config.burpEdition)" 'Burp'
                        if (Test-RebootPending) {Stop-LaunchForReboot $Tool}
                    }
                    if (-not (Get-AppPath Burp)) {throw 'Burp 자동 설치 후 실행 파일을 찾지 못했습니다.'}
                }
                'Kali' {Ensure-LaunchKali $Tool}
                'HexStrike' {Install-KaliTools -HexOnly}
                'BinaryAnalysis' {Install-KaliTools -HexOnly -BinaryAnalysis}
                'AI' {Install-KaliTools -CoreOnly}
                {$_ -in @('Android','Play','Adb','ApkTools')} {Ensure-LaunchAndroid -Component $dependency -Tool $Tool}
                'MobSF' {
                    Ensure-LaunchWsl $Tool
                    if (-not (Get-AppPath Docker)) {
                        Assert-LaunchInstallAdmin
                        Install-WingetPackage 'Docker.DockerDesktop' 'Docker'
                        if (Test-RebootPending) {Stop-LaunchForReboot $Tool}
                    }
                    $docker=Wait-Docker
                    $spec=Get-MobSfSpec
                    $image=($spec -split '\|')[0]
                    try {Invoke-Native $docker @('image','inspect',$image) -Quiet | Out-Null}
                    catch {
                        # A cached image ID or local compatibility tag can outlive
                        # the Docker image. Fall back to the configured base image.
                        $compat=Join-Path $script:Runtime 'mobsf-compat-image.json'
                        if ($image -ne $script:Config.mobSfImage -and (Test-Path -LiteralPath $compat)) {Move-Item -LiteralPath $compat -Destination ($compat+'.missing-image-'+[guid]::NewGuid().ToString('N'))}
                        Install-MobSfImage
                    }
                }
            }
        }
        Set-ConnectionResult "실행 준비: $Tool" '완료' '필수 구성 요소 확인 완료. 선택한 기능을 실행합니다.'
    } catch {
        if (-not $_.Exception.Data['LaunchElevation'] -and -not $_.Exception.Data['LaunchReboot']) {Set-ConnectionResult "실행 준비: $Tool" '실패' $_.Exception.Message}
        throw
    }
}
