#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Gui','Plan','Preflight','Install','Verify','Launch','Stop','Guide','Infrastructure','Report')][string]$Action='Gui',
    [ValidateSet('ReportRawExport','ReportSync','ReportImport','ReportRefresh','ReportPreview','ReportExport','ReportTemplates','BinaryAnalysisTools','InfraOfflineImport','InfraInstall','InfraPreflight','InfraRun','InfraRetry','InfraImport','MobileAnalysis','MobSfAnalysis','MobileApi','MobileAI','SystemAnalysis','WebProxyTest','CheckMcp','RefreshAnalysisApps','PenTest','Burp','AndroidBurp','WebAI','Kali','HexStrike','OpenCode','Emulator','MobSF','Dynamic','Combined','FridaServer','RootBypass','RootBypassDirect','StopRootBypass','AppDiagnostics','PlayDownload','RefreshApps','RefreshDevices','AcquireApp','ResetPlay')][string]$Tool='Burp',
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
    if ($Action -in @('Install','Launch','Stop','Infrastructure','Report')) {
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
            Ensure-LaunchPrerequisites -Tool $Tool -Package $Package -CaptureRoute $CaptureRoute -LaunchWithBypass:$LaunchWithBypass
            if ($Tool -in @('PlayDownload','RefreshApps','RefreshDevices','AcquireApp','ResetPlay')) { Invoke-AppAcquisition -Tool $Tool -Package $Package -SourceSerial $SourceSerial -ApkPaths $ApkPaths -AcceptLicenses -LaunchWithBypass:$LaunchWithBypass -CaptureRoute $CaptureRoute }
            else { Start-Tool $Tool -Package $Package -CaptureRoute $CaptureRoute -Target $Target }
        }
        'Stop' { Stop-ManagedRuntime }
        'Guide' { Show-Guide }
        'Infrastructure' { Ensure-LaunchPrerequisites -Tool $Tool; $result=Invoke-InfrastructureAction -Tool $Tool -Target $Target; if ($result -eq 3010) {$exitCode=3010} }
        'Report' {Invoke-ReportAction -Tool $Tool -Target $Target}
    }
} catch {
    if ($_.Exception.Data['LaunchReboot']) {$exitCode=3010}
    elseif ($_.Exception.Data['LaunchElevation']) {
        if ($lock) {$lock.Dispose();$lock=$null}
        Write-Log '누락된 구성 요소 자동 설치를 위해 관리자 권한으로 같은 작업을 이어갑니다.'
        try {
            $worker=Start-Worker -Action $Action -Tool $Tool -Package $Package -Target $Target -SourceSerial $SourceSerial -ApkPaths $ApkPaths -AcceptLicenses -LaunchWithBypass:$LaunchWithBypass -CaptureRoute $CaptureRoute -RequireAdmin
            try {$worker.WaitForExit();$exitCode=$worker.ExitCode} finally {$worker.Dispose()}
        } catch {$exitCode=1;Set-ConnectionResult "실행 준비: $Tool" '실패' ("관리자 권한 작업 시작 실패: "+$_.Exception.Message)}
    } else {
        $exitCode=1
        if ($Action -eq 'Install' -and $ctx) {try {Set-ConnectionResult '환경 설치' '실패' $_.Exception.Message} catch {}}
        Write-Host $_.Exception.Message -ForegroundColor Red
        if ($ctx) { Add-Content -LiteralPath $ctx.Log -Encoding UTF8 -Value ("ERROR: "+$_.Exception.Message) }
    }
} finally {
    if ($lock) { $lock.Dispose() }
}
exit $exitCode
