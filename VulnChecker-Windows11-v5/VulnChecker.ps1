#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Gui','Plan','Preflight','Install','Verify','Launch','Stop','Guide')][string]$Action='Gui',
    [ValidateSet('MobileAnalysis','MobSfAnalysis','MobileApi','MobileAI','SystemAnalysis','WebProxyTest','RefreshAnalysisApps','PenTest','Burp','AndroidBurp','WebAI','Kali','HexStrike','OpenCode','Emulator','MobSF','Dynamic','Combined','FridaServer','RootBypass','RootBypassDirect','StopRootBypass','AppDiagnostics','PlayDownload','RefreshApps','RefreshDevices','AcquireApp','ResetPlay')][string]$Tool='Burp',
    [string]$Package='',
    [string]$Target='',
    [string]$SourceSerial='',
    [string[]]$ApkPaths=@(),
    [ValidateSet('Auto','Burp','Direct','Preview')][string]$CaptureRoute='Preview',
    [switch]$LaunchWithBypass,
    [string]$ConfigPath='',
    [switch]$AcceptLicenses,
    [string]$ExpectedUserSid
)
$ErrorActionPreference='Stop'
if (-not $ConfigPath) { $ConfigPath=Join-Path $PSScriptRoot 'config.json' }
Import-Module (Join-Path $PSScriptRoot 'lib\Core.psm1') -Force -DisableNameChecking
$exitCode=0
$lock=$null
try {
    $ctx=Initialize-Context -Root $PSScriptRoot -ConfigPath $ConfigPath -ExpectedUserSid $ExpectedUserSid
    if ($Action -in @('Install','Launch','Stop')) {
        # OS releases this file lock even after interruption/crash; no stale PID bypass.
        $lock=[IO.File]::Open((Join-Path $ctx.Runtime 'operation.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    }
    switch ($Action) {
        'Gui' { Show-SetupGui }
        'Plan' { Get-Plan }
        'Preflight' { $inventory=Get-InstallationInventory; Write-Inventory $inventory; $pre=Get-Preflight -Inventory $inventory; Write-Log ($pre | ConvertTo-Json -Depth 8); if ($pre.BlockingIssues.Count) { $exitCode=1 } }
        'Install' { $exitCode=Install-Environment -AcceptLicenses:$AcceptLicenses }
        'Verify' { if (-not (Test-Environment)) { $exitCode=1 } }
        'Launch' {
            if ($Tool -in @('PlayDownload','RefreshApps','RefreshDevices','AcquireApp','ResetPlay')) { Invoke-AppAcquisition -Tool $Tool -Package $Package -SourceSerial $SourceSerial -ApkPaths $ApkPaths -AcceptLicenses:$AcceptLicenses -LaunchWithBypass:$LaunchWithBypass -CaptureRoute $CaptureRoute }
            else { Start-Tool $Tool -Package $Package -CaptureRoute $CaptureRoute -Target $Target }
        }
        'Stop' { Stop-ManagedRuntime }
        'Guide' { Show-Guide }
    }
} catch {
    $exitCode=1
    if ($Action -eq 'Install' -and $ctx) {try {Set-ConnectionResult '환경 설치' '실패' $_.Exception.Message} catch {}}
    Write-Host $_.Exception.Message -ForegroundColor Red
    if ($ctx) { Add-Content -LiteralPath $ctx.Log -Encoding UTF8 -Value ("ERROR: "+$_.Exception.Message) }
} finally {
    if ($lock) { $lock.Dispose() }
    if ($Action -eq 'Install' -and $ctx) { try { Show-Guide } catch { Write-Host 'docs\GUIDE.ko.html을 직접 열어주세요.' } }
}
exit $exitCode
