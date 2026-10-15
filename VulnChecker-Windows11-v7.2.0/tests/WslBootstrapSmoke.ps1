#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
function Assert-True([bool]$Value,[string]$Name) {if (-not $Value) {throw $Name}}
function New-Fixture {
    Import-Module (Join-Path $root 'lib\Core.psm1') -Force -DisableNameChecking
    $m=Get-Module Core
    & $m {
        $script:Config=[pscustomobject]@{profile='web';kaliDistro='kali-linux';kaliImportTar='';existing=[pscustomobject]@{kaliUser=''}}
        $script:Calls=New-Object 'System.Collections.Generic.List[string]'
        $script:MissingWsl=$false; $script:MissingKali=$false; $script:Restart=$false
        function script:Write-Log {param($Message)}
        function script:Test-Admin {return $true}
        function script:Invoke-Native {
            param($File,$Arguments,$SuccessCodes,[switch]$Quiet,$TimeoutSeconds)
            $script:Calls.Add(($Arguments -join ' '))
            switch ($Arguments[0]) {
                '--version' {if ($script:MissingWsl) {throw 'WSL missing'}; return 'WSL version: 3.0.3.0'}
                '--list' {if (-not $script:MissingKali) {return 'kali-linux'}; return ''}
                '--install' {$script:MissingWsl=$false; if ($Arguments -contains '--distribution') {$script:MissingKali=$false}; return ''}
            }
        }
        function script:Get-WindowsOptionalFeature {param([switch]$Online,$FeatureName); return [pscustomobject]@{State='Disabled'}}
        function script:Enable-WindowsOptionalFeature {
            param([switch]$Online,$FeatureName,[switch]$All,[switch]$NoRestart)
            $script:Calls.Add('enable '+$FeatureName)
            return [pscustomobject]@{RestartNeeded=$script:Restart}
        }
        function script:Invoke-Kali {
            param([switch]$Root,$Arguments,[switch]$Quiet)
            if ($Arguments[0] -eq 'uname') {return '6.18.54-microsoft-standard-WSL2'}
            return 'ID=kali'
        }
    }
    return $m
}
$m=New-Fixture
& $m {if (-not (Assert-InfrastructureWsl -Install)) {throw 'Existing environment rejected'}; if ($script:Calls -match '^--install') {throw 'Existing environment reinstalled'}}
$m=New-Fixture
& $m {
    $script:MissingKali=$true
    if (-not (Assert-InfrastructureWsl -Install)) {throw 'Kali bootstrap not ready'}
    if ('--install --distribution kali-linux --web-download --no-launch' -notin $script:Calls) {throw 'Kali automatic install missing'}
}
$m=New-Fixture
& $m {
    $script:MissingWsl=$true; $script:MissingKali=$true; $script:Restart=$true
    if (Assert-InfrastructureWsl -Install) {throw 'Reboot not reported'}
    if ('--install --no-distribution --web-download' -notin $script:Calls) {throw 'WSL automatic install missing'}
    if ('enable VirtualMachinePlatform' -notin $script:Calls) {throw 'Virtualization not enabled'}
    if ($script:Calls -match '^--install --distribution') {throw 'Kali installed before required reboot'}
    $script:MissingWsl=$false; $script:Restart=$false
    if (-not (Assert-InfrastructureWsl -Install)) {throw 'Resume failed'}
    if ('--install --distribution kali-linux --web-download --no-launch' -notin $script:Calls) {throw 'Kali install not resumed'}
}
$m=New-Fixture
& $m {
    $script:MissingWsl=$true
    function script:Test-Admin {return $false}
    $denied=$false
    try {Assert-InfrastructureWsl -Install | Out-Null} catch {$denied=$true}
    if (-not $denied -or $script:Calls -match '^--install') {throw 'Non-admin install guard failed'}
}
# Exercise the real launcher with read-only commands on machines with WSL/Kali.
Import-Module (Join-Path $root 'lib\Core.psm1') -Force -DisableNameChecking
Assert-True ((Get-WorkerCompletionMessage -Action Infrastructure -ExitCode 3010) -match '재부팅 필요') 'Infrastructure GUI reboot state'
& (Get-Module Core) {
    $odd=ConvertFrom-NativeBytes ([Text.Encoding]::UTF8.GetBytes('abc'))
    if ($odd -ne 'abc') {throw 'Odd byte count decoding failed'}
}
if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
    $version=Invoke-Native wsl.exe @('--version') -Quiet -TimeoutSeconds 15
    Assert-True ($version -match '\d+\.\d+\.\d+') 'Quoted WSL switch regression'
    $distros=Invoke-Native wsl.exe @('--list','--quiet') -Quiet -TimeoutSeconds 15
    if ($distros -match 'kali-linux') {
        $values=@('space value','한글 경로','quote"value','C:\path with space\','')
        $raw=Invoke-Native wsl.exe (@('-d','kali-linux','--exec','python3','-c','import json,sys; print(json.dumps(sys.argv[1:]))')+$values) -Quiet -TimeoutSeconds 15
        $actual=ConvertFrom-Json -InputObject $raw
        Assert-True ($actual.Count -eq $values.Count) 'WSL argv count'
        for ($i=0; $i -lt $values.Count; $i++) {Assert-True ($actual[$i] -ceq $values[$i]) "WSL argv value $i"}
    }
}
Write-Host 'PASS WSL/Kali bootstrap, reboot/resume, administrator guard, native switches and argument quoting.'
