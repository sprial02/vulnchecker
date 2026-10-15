#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$fixture=Join-Path $root ('runtime\on-demand-test-'+[guid]::NewGuid().ToString('N'))
$passed=0
function Check([bool]$Value,[string]$Name) {if (-not $Value) {throw $Name}; $script:passed++; Write-Host "PASS $Name"}
function Fresh {
    Import-Module (Join-Path $root 'lib\Core.psm1') -Force -DisableNameChecking
    Initialize-Context -Root $fixture -ConfigPath (Join-Path $root 'config.json') | Out-Null
    $m=Get-Module Core
    & $m {
        param($actualRoot)
        $script:Root=$actualRoot
        $script:Trace=New-Object 'System.Collections.Generic.List[string]'
        $script:Apps=@{}; $script:Admin=$true; $script:ImageReady=$false
        function script:Test-Admin {return $script:Admin}
        function script:Test-RebootPending {return $false}
        function script:Get-AppPath {param($Name); return $script:Apps[$Name]}
        function script:Install-WingetPackage {param($Id,$App);$script:Trace.Add('install '+$App);$script:Apps[$App]='mock.exe'}
        function script:Ensure-LaunchKali {param($Tool);$script:Trace.Add('Kali')}
        function script:Ensure-LaunchWsl {param($Tool);$script:Trace.Add('WSL')}
        function script:Install-KaliTools {param([switch]$CoreOnly,[switch]$HexOnly,[switch]$BinaryAnalysis);$detail="core=$CoreOnly hex=$HexOnly";if ($BinaryAnalysis) {$detail+=' binary=True'};$script:Trace.Add($detail)}
        function script:Ensure-LaunchAndroid {param($Component,$Tool);$script:Trace.Add('Android '+$Component)}
        function script:Wait-Docker {return 'mock-docker'}
        function script:Install-MobSfImage {$script:Trace.Add('image');$script:ImageReady=$true}
        function script:Invoke-Native {
            param($File,$Arguments,[switch]$Quiet,$TimeoutSeconds)
            if ($File -eq 'mock-docker' -and $Arguments[0] -eq 'image') {
                if (-not $script:ImageReady) {throw 'Image missing'}
                return '{}'
            }
            throw "Unexpected native call: $File $Arguments"
        }
    } $root
    return $m
}
$m=Fresh
$tok=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'VulnChecker.ps1'),[ref]$tok,[ref]$errors)
$toolParam=@($ast.ParamBlock.Parameters | Where-Object {$_.Name.VariablePath.UserPath -eq 'Tool'})[0]
$tools=@(@($toolParam.Attributes | Where-Object {$_.TypeName.Name -eq 'ValidateSet'})[0].PositionalArguments | ForEach-Object {$_.SafeGetValue()})
foreach ($tool in $tools) {Get-LaunchDependencies -Tool $tool -Package com.example.app | Out-Null}
Check ($tools.Count -gt 30) 'Every CLI launch button has an explicit dependency plan'
Check (((Get-LaunchDependencies SystemAnalysis) -join ',') -eq 'Kali,AI') 'System pentest excludes Android, Docker and Burp'
Check (((Get-LaunchDependencies HexStrike) -join ',') -eq 'Kali,HexStrike') 'HexStrike does not require OpenCode'
Check (((Get-LaunchDependencies RefreshDevices) -join ',') -eq 'Adb') 'Physical device listing requires only ADB'
Check (((Get-LaunchDependencies RootBypass -CaptureRoute Preview -Package com.example.app) -join ',') -eq 'Android,MobSF') 'Preview avoids Burp and Kali'
Check (((Get-LaunchDependencies PlayDownload) -join ',') -eq 'Play') 'Play download avoids rooted emulator image'
& $m {Ensure-LaunchPrerequisites SystemAnalysis}
Check (((& $m {$script:Trace.ToArray()}) -join ',') -eq 'Kali,core=True hex=False') 'System button prepares only its required stack'
$m=Fresh
& $m {Ensure-LaunchPrerequisites BinaryAnalysisTools}
Check (((& $m {$script:Trace.ToArray()}) -join ',') -eq 'Kali,core=False hex=True binary=True') 'Optional binary installation is explicit and excludes OpenCode, Docker and Android'
$m=Fresh
& $m {Ensure-LaunchPrerequisites Burp;Ensure-LaunchPrerequisites Burp}
Check (((& $m {$script:Trace.ToArray()}) -join ',') -eq 'install Burp') 'Missing Burp installs once and existing executable is reused'
$m=Fresh
& $m {Ensure-LaunchPrerequisites MobSF;Ensure-LaunchPrerequisites MobSF}
Check (((& $m {$script:Trace.ToArray()}) -join ',') -eq 'WSL,install Docker,image,WSL') 'Missing Docker/image are installed once without Android or Kali'
$m=Fresh
$elevated=& $m {
    $script:Admin=$false
    try {Ensure-LaunchPrerequisites Burp;return $false} catch {return [bool]$_.Exception.Data['LaunchElevation']}
}
Check ($elevated -and @(& $m {$script:Trace.ToArray()}).Count -eq 0) 'Administrator retry is requested before a privileged install'
$m=Fresh
& $m {
    $script:Admin=$false
    function script:Start-Process {
        param($FilePath,$WindowStyle,$ArgumentList,$Verb,[switch]$PassThru)
        $script:WorkerVerb=$Verb
        $script:WorkerCode=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[-1]))
    }
    Start-Worker -Action Launch -Tool MobileApi -Package com.example.app -CaptureRoute Burp -RequireAdmin
}
Check ((& $m {$script:WorkerVerb}) -eq 'RunAs' -and (& $m {$script:WorkerCode}) -match "-Tool 'MobileApi'.*-Package 'com.example.app'.*-ExpectedUserSid|-ExpectedUserSid.*-Tool 'MobileApi'.*-Package 'com.example.app'" -and (& $m {$script:WorkerCode}) -match "-CaptureRoute 'Burp'") 'Elevation preserves the selected action, user identity, package and route'
$m=Fresh
& $m {
    $script:Apps['Burp']='existing.exe'
    function script:Test-RebootPending {return $true}
    Ensure-LaunchPrerequisites Burp
}
Check (@(& $m {$script:Trace.ToArray()}).Count -eq 0) 'Existing application can run without unrelated pending updates forcing reinstalls'
$m=Fresh
$failed=& $m {
    function script:Install-WingetPackage {throw 'Download blocked'}
    try {Ensure-LaunchPrerequisites Burp;return $false} catch {return $_.Exception.Message -eq 'Download blocked'}
}
Check ($failed -and (& $m {$script:State.connections['실행 준비: Burp'].Status}) -eq '실패') 'Installation failure retains the cause and prevents launch'
$m=Fresh
$reboot=& $m {try {Stop-LaunchForReboot SystemAnalysis} catch {return [bool]$_.Exception.Data['LaunchReboot']}}
Check ($reboot -and (Get-WorkerCompletionMessage -Action Launch -ExitCode 3010) -match '같은 실행 버튼') 'Reboot boundary is reported with launch-specific resume instructions'
$m=Fresh
$invalid=& $m {try {Ensure-LaunchPrerequisites MobileApi -Package '';return $false} catch {return $script:Trace.Count -eq 0}}
Check $invalid 'Invalid mobile target is rejected before downloads'
# Exercise the real scoped Kali installer with an isolated mock probe/bootstrap.
$m=Fresh
Import-Module (Join-Path $root 'lib\Core.psm1') -Force -DisableNameChecking
$m=Get-Module Core
Initialize-Context -Root $fixture -ConfigPath (Join-Path $root 'config.json') | Out-Null
& $m {
    param($actualRoot)
    $script:Root=$actualRoot; $script:Done=$false; $script:Bootstrap=$null
    function script:Get-KaliRuntime {
        param([switch]$Refresh)
        $oc=$null; if ($script:Done) {$oc='/existing/opencode'}
        return [pscustomobject]@{User='audit';Home='/home/audit';HexRepo='/existing/hex';HexPython='/existing/python';OpenCode='/existing/opencode';Probe=[pscustomobject]@{user='audit';commands=[pscustomobject]@{opencode=$oc;frida=$null;objection=$null};hexstrike=[pscustomobject]@{path='/existing/hex';dependencies=$true}}}
    }
    function script:Invoke-Kali {
        param($Arguments,[switch]$Root,[switch]$Quiet,$InputText)
        if ($Arguments[0] -eq 'bash') {$script:Bootstrap=$Arguments;$script:Done=$true}
        return ''
    }
    function script:Ensure-KaliIntegration {}
    Install-KaliTools -CoreOnly
} $root
$bootstrap=& $m {$script:Bootstrap}
Check ($bootstrap[3] -eq 'web' -and $bootstrap.Count -eq 11 -and $bootstrap -contains '/existing/python') 'AI repair reuses HexStrike and excludes profile packages and mobile venv'
& $m {
    $script:Done=$false;$script:Bootstrap=$null
    function script:Get-KaliRuntime {
        param([switch]$Refresh)
        return [pscustomobject]@{User='audit';Home='/home/audit';HexRepo='/existing/hex';HexPython='/existing/python';OpenCode='/existing/opencode';Probe=[pscustomobject]@{user='audit';commands=[pscustomobject]@{opencode='/existing/opencode';frida=$null;objection=$null};hexstrike=[pscustomobject]@{path='/existing/hex';dependencies=$true;files_ready=$script:Done}}}
    }
    Install-KaliTools -CoreOnly
}
Check ($null -ne (& $m {$script:Bootstrap}) -and (& $m {$script:Bootstrap}) -contains '/existing/python') 'Missing HexStrike source triggers repair while preserving the detected interpreter'
# The same installer must support ADB-only installs without downloading images.
Import-Module (Join-Path $root 'lib\Core.psm1') -Force -DisableNameChecking
$m=Get-Module Core
Initialize-Context -Root $fixture -ConfigPath (Join-Path $root 'config.json') | Out-Null
& $m {
    $script:MockSdk=Join-Path $script:Runtime 'sdk'
    New-Item -ItemType Directory -Path (Join-Path $script:MockSdk 'cmdline-tools\latest\bin') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $script:MockSdk 'cmdline-tools\latest\bin\sdkmanager.bat') -Value 'mock'
    function script:Get-SdkRoot {return $script:MockSdk}
    function script:Set-AndroidEnvironment {param([switch]$RequireJava)}
    function script:Install-AndroidSdkPackages {
        param($Sdk,$Packages)
        $script:RequestedPackages=$Packages
        New-Item -ItemType Directory -Path (Join-Path $Sdk 'platform-tools') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Sdk 'platform-tools\adb.exe') -Value 'mock'
    }
    function script:Ensure-AndroidAvd {throw 'ADB-only install must not create rooted AVD'}
    function script:Invoke-Native {throw 'ADB-only install must not check emulator acceleration'}
    Install-Android -Component Adb
}
Check (((& $m {$script:RequestedPackages}) -join ',') -eq 'platform-tools') 'SDK installer downloads only platform-tools for ADB-only requests'
# Missing Ansible is installed before the requested operation, then reused.
$m=Fresh
& $m {
    $script:AnsibleReady=$false
    function script:Assert-InfrastructureWsl {param([switch]$Install);return $true}
    function script:Get-InfrastructureHome {return '/home/audit/.local/share/vulnchecker-infra'}
    function script:Invoke-InfrastructureKali {
        param($Arguments,[switch]$Root,[switch]$Quiet)
        if ($Arguments[0] -eq 'wslpath') {return '/source/infrastructure'}
        if ($Arguments -contains '-c' -and -not $script:AnsibleReady) {throw 'Ansible missing'}
        if ($Arguments[0] -eq 'apt-get') {$script:Trace.Add($Arguments -join ' ');return ''}
        if ($Arguments[0] -eq 'bash' -and $Arguments[-1] -eq 'install') {$script:AnsibleReady=$true;$script:Trace.Add('ansible install');return ''}
        if ($Arguments[-1] -eq 'import') {$script:Trace.Add('infra import');return '[]'}
        return ''
    }
    Invoke-InfrastructureAction InfraImport
    Invoke-InfrastructureAction InfraImport
}
$trace=@(& $m {$script:Trace.ToArray()})
Check (@($trace | Where-Object {$_ -eq 'ansible install'}).Count -eq 1 -and @($trace | Where-Object {$_ -eq 'infra import'}).Count -eq 2 -and [array]::IndexOf($trace,'ansible install') -lt [array]::IndexOf($trace,'infra import')) 'Infrastructure button installs missing Ansible before its operation and reuses it next time'
Write-Host "On-demand smoke: $passed passed. All installation calls isolated; no real downloads or launches."
