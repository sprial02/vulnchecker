#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
Import-Module (Join-Path $root 'lib\Core.psm1') -Force -DisableNameChecking
Initialize-Context -Root (Join-Path $root ('runtime\infra-password-'+[guid]::NewGuid().ToString('N'))) -ConfigPath (Join-Path $root 'config.json')|Out-Null
& (Get-Module Core) {
    $script:PasswordToolReady=$false;$script:PasswordInstalls=0;$script:BridgeError=''
    function script:Assert-InfrastructureWsl {param([switch]$Install);return $true}
    function script:Get-InfrastructureHome {return '/fixture/infra'}
    function script:Get-InfrastructureSettings {return [pscustomobject]@{Servers=@([pscustomobject]@{Connection='ssh';Password='encrypted-fixture';BecomePassword='';KeyFile='';Alias='fixture'})}}
    function script:Get-AiPlainKey {param($value);if ($value) {return 'FIXTURE-ONLY-PASSWORD'};return ''}
    function script:Get-InfrastructureRuns {return @()}
    function script:Invoke-InfrastructureKali {
        param($Arguments,$InputText,[switch]$Root,[switch]$Quiet,$SuccessCodes)
        if ($Arguments[0] -eq 'wslpath') {return '/fixture/source'}
        if ($Arguments[0] -eq 'python3') {return [string]$script:PasswordToolReady}
        if ($Arguments[0] -eq 'apt-get' -and $Arguments -contains 'sshpass') {
            if (-not $Root) {throw 'Package install must use root'}
            $script:PasswordInstalls++;$script:PasswordToolReady=$true;return ''
        }
        if ($Arguments[-1] -eq 'preflight') {
            $payload=$InputText|ConvertFrom-Json
            if ($payload.Servers[0].Password -ne 'FIXTURE-ONLY-PASSWORD' -or $payload.Servers[0].KeyFile) {throw 'Password request not passed via stdin'}
            return '인프라 작업 오류: fixture 접속 암호 확인 필요'
        }
        return ''
    }
    for ($attempt=0;$attempt -lt 2;$attempt++) {
        try {Invoke-InfrastructureAction InfraPreflight;throw 'Expected bridge fixture error'}
        catch {if ($_.Exception.Message -ne 'fixture 접속 암호 확인 필요') {throw}}
    }
    if ($script:PasswordInstalls -ne 1) {throw 'Missing sshpass not installed once and reused'}
    if ((Get-Content $script:Log -Raw -Encoding UTF8).Contains('FIXTURE-ONLY-PASSWORD')) {throw 'Password leaked to log'}
}
Write-Host 'PASS sshpass on-demand install/reuse, password stdin, root package install and original error preservation'
