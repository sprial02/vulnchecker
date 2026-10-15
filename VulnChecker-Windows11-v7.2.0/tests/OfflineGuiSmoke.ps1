#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
Import-Module (Join-Path $root 'lib\Core.psm1') -Force -DisableNameChecking
$ctx=Initialize-Context -Root (Join-Path $root ('runtime\offline-import-test-'+[guid]::NewGuid().ToString('N'))) -ConfigPath (Join-Path $root 'config.json')
& (Get-Module Core) {
    $script:OfflineArguments=@();$script:OfflineSynced=$false
    function script:Ensure-ReportRuntime {return 'fixture-python'}
    function script:Assert-InfrastructureWsl {throw 'Offline import must not require WSL'}
    function script:Invoke-ReportPython {param($File,$Arguments) $script:OfflineArguments=@($Arguments)}
    function script:Sync-InfrastructureReportDatabase {$script:OfflineSynced=$true}
    Invoke-InfrastructureAction -Tool InfraOfflineImport -Target '{"Files":["fixture-one.zip","fixture-two.zip"]}'
    if (-not $script:OfflineSynced -or @($script:OfflineArguments | Where-Object {$_ -eq '--file'}).Count -ne 2 -or $script:OfflineArguments[0] -notmatch 'import-offline.py$') {throw 'Offline import did not dispatch both files and sync locally'}
}
Write-Host 'PASS offline import uses local runtime, accepts multiple files and syncs without WSL'
