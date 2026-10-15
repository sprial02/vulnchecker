#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
Import-Module (Join-Path $root 'lib\Core.psm1') -Force -DisableNameChecking
$testRoot=Join-Path $root ('runtime\infra-scale-test-'+[guid]::NewGuid().ToString('N'))
$ctx=Initialize-Context -Root $testRoot -ConfigPath (Join-Path $root 'config.json')
$csv=Join-Path $testRoot 'servers.csv'
$rows=for ($i=0;$i -lt 1200;$i++) {
    [pscustomobject]@{Alias=('server-{0:d4}' -f $i);Host='192.0.2.1';User='audit';Connection=$(if ($i%2) {'psrp'} else {'ssh'});Platform=$(if ($i%2) {'Windows'} else {'Auto'});Port=$(if ($i%2) {5986} else {22});Enabled=$(if ($i%3) {'true'} else {'false'});Password='fixture-only'}
}
$rows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
if ((Import-InfrastructureCsv $csv) -ne 1200) {throw 'Mass import count failed'}
$stored=@((Get-InfrastructureSettings).Servers)
if ($stored.Count -ne 1200 -or $stored[0].Enabled -or $stored[1].Port -ne 5986) {throw 'CSV normalization failed'}
$before=Read-SharedText (Join-Path $ctx.Runtime 'infra-settings.json')
$rows[1].Alias=$rows[0].Alias
$rows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
$rejected=$false
try {Import-InfrastructureCsv $csv | Out-Null} catch {$rejected=$true}
if (-not $rejected -or $before -ne (Read-SharedText (Join-Path $ctx.Runtime 'infra-settings.json'))) {throw 'Invalid import changed settings'}
$one=[pscustomobject]@{Alias='';Host='192.0.2.99';User='audit';Connection='ssh';Platform='Auto';Port='22';Password='fixture-only'}
$one | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
Import-InfrastructureCsv $csv | Out-Null
if (-not @((Get-InfrastructureSettings).Servers | Where-Object Alias -eq '192.0.2.99').Count) {throw 'Empty alias did not use IP'}
$before=Read-SharedText (Join-Path $ctx.Runtime 'infra-settings.json')
foreach ($column in @('Host','User','Connection','Platform','Port','Password')) {
    $bad=$one.PSObject.Copy();$bad.Host='192.0.2.100';$bad.$column='   ';if ($column -eq 'Password') {$bad.Password=''}
    $bad | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
    $rejected=$false
    try {Import-InfrastructureCsv $csv | Out-Null} catch {$rejected=$_.Exception.Message -match 'CSV 2행'}
    if (-not $rejected -or $before -ne (Read-SharedText (Join-Path $ctx.Runtime 'infra-settings.json'))) {throw ('Required CSV value accepted or non-atomic: '+$column)}
}
$web=[pscustomobject]@{Alias='protocol-fixture';Host='192.0.2.101';User='audit';Connection='winrm';Platform='Windows';Port='5985';Protocol='';Password='fixture-only'}
$web | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
Import-InfrastructureCsv $csv | Out-Null
if (@((Get-InfrastructureSettings).Servers | Where-Object Alias -eq 'protocol-fixture')[0].Protocol -ne 'http') {throw '5985 with blank Protocol did not select HTTP'}
$web.Port='5986';$web.Connection='psrp';$web | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
Import-InfrastructureCsv $csv | Out-Null
if (@((Get-InfrastructureSettings).Servers | Where-Object Alias -eq 'protocol-fixture')[0].Protocol -ne 'https') {throw '5986 with blank Protocol did not select HTTPS'}
$web.Port='15985';$web.Protocol='';$web | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
$rejected=$false;try {Import-InfrastructureCsv $csv | Out-Null} catch {$rejected=$_.Exception.Message -match 'Protocol'}
if (-not $rejected) {throw 'Custom port silently guessed a protocol'}
$web.Port='5985';$web.Protocol='https';$web | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
Import-InfrastructureCsv $csv | Out-Null
if (@((Get-InfrastructureSettings).Servers | Where-Object Alias -eq 'protocol-fixture')[0].Protocol -ne 'https') {throw 'Explicit custom listener protocol was silently overridden'}
$text='Linux용 Windows 하위 시스템이 설치되어 있지 않습니다.'
foreach ($encoding in @([Text.Encoding]::Unicode,[Text.Encoding]::UTF8)) {
    if ((ConvertFrom-NativeBytes ($encoding.GetBytes($text))) -ne $text) {throw 'Localized WSL output decoding failed'}
}
$python=(Get-Command python.exe).Source
$output=Invoke-WslNative -File $python -Arguments @('-c','import sys; sys.stdout.buffer.write(bytes([87,0,83,0,76,0,32,0,36,193,88,206])); sys.stderr.buffer.write(b"diagnostic"); sys.exit(1)') -SuccessCodes @(1) -Quiet -TimeoutSeconds 10
if ($output -notmatch 'WSL 설치' -or $output -notmatch 'diagnostic') {throw 'Raw stdout/stderr capture failed'}
& (Get-Module Core) {
    $script:ProbeCalls=0
    $originalNative=(Get-Item Function:\Invoke-Native).ScriptBlock
    function Invoke-Native {param($File,$Arguments,[switch]$Quiet,$TimeoutSeconds)
        $script:ProbeCalls++
        if ($TimeoutSeconds -ne 15) {throw 'Missing probe timeout'}
        throw 'WSL unavailable'
    }
    try {
        $rejected=$false
        try {Assert-InfrastructureWsl} catch {$rejected=$_.Exception.Message -match 'WSL이 준비되지'}
        if (-not $rejected -or $script:ProbeCalls -ne 1) {throw 'Missing WSL did not fail before distro launch'}
    } finally {Set-Item Function:\Invoke-Native $originalNative}
}
Write-Host 'PASS 1200 mixed servers, boolean defaults, atomic rejection, UTF-8/UTF-16 Korean and raw process pipes'
